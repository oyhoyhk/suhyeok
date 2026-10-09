package com.pickuma.suhyeok

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/** One agent as the Mac reports it (GET /api/state). */
data class Agent(
    val id: String,
    val name: String,
    val title: String,
    val project: String,
    val cwd: String,
    val status: String,      // busy / waiting / shell / idle / unknown
    val activity: String,    // 작업 중 / 대기 중 / 휴식 중
    val character: String,
    val action: String,
    val last: Double,
    val canSend: Boolean,
    val kind: String,        // Claude / Codex
    val hosted: Boolean,     // runs on 수혁's own terminal server
    val canClone: Boolean,   // has a conversation to copy or resume
) {
    /** Stopped on a permission or question menu: blocked until you answer. */
    val asking get() = status == "waiting"
    val busy get() = status == "busy"
}

data class AgentEvent(val id: String, val name: String, val title: String, val kind: String, val text: String)  // kind: asking / done
data class Events(val boot: String, val seq: Int, val events: List<AgentEvent>)

data class Release(val code: Int, val name: String, val sha256: String, val notes: String)

data class ChatItem(val role: String, val text: String)   // me / agent / tool
data class Chat(
    val items: List<ChatItem>,
    val live: String?,
    val menu: List<String>,
    val status: String,      // as in Agent
    val activity: String,
    val action: String,
)

/** Thrown when the Mac no longer accepts this phone's token: pair again. */
class Unpaired : Exception("pair")

/**
 * Talks to 수혁's phone server on the Mac (MobileServer.swift) through its Cloudflare address.
 * Every call after pairing carries the token as the `sh` cookie, as the phone web page does.
 */
class Api(val base: String, private val token: String?) {

    suspend fun state(): List<Agent> = withContext(Dispatchers.IO) {
        val o = request("GET", "/api/state")
        val arr = o.getJSONArray("agents")
        (0 until arr.length()).map { i ->
            val a = arr.getJSONObject(i)
            Agent(
                id = a.getString("id"), name = a.getString("name"), title = a.optString("title"),
                project = a.optString("project"), cwd = a.optString("cwd"), status = a.optString("status"), activity = a.optString("activity"),
                character = a.optString("character"), action = a.optString("action"), last = a.optDouble("last", 0.0),
                canSend = a.optBoolean("canSend", false), kind = a.optString("agent"),
                hosted = a.optBoolean("hosted", false), canClone = a.optBoolean("canClone", false),
            )
        }
    }

    suspend fun chat(id: String): Chat = withContext(Dispatchers.IO) {
        val o = request("GET", "/api/chat?id=" + java.net.URLEncoder.encode(id, "UTF-8"))
        val items = o.optJSONArray("items") ?: JSONArray()
        val menu = o.optJSONArray("menu") ?: JSONArray()
        Chat(
            items = (0 until items.length()).map { items.getJSONObject(it).let { j -> ChatItem(j.getString("role"), j.getString("text")) } },
            live = o.optString("live").ifEmpty { null },
            menu = (0 until menu.length()).map { menu.getJSONObject(it).getString("label") },
            status = o.optString("status"), activity = o.optString("activity"), action = o.optString("action"),
        )
    }

    /**
     * State changes the Mac saw since [after] in its run [boot] (MobileServer /api/events). With an unknown boot
     * (first call, or the Mac restarted) no events come back, only the boot and sequence number to continue from.
     */
    suspend fun events(boot: String?, after: Int): Events = withContext(Dispatchers.IO) {
        val o = request("GET", "/api/events?after=$after&boot=" + java.net.URLEncoder.encode(boot ?: "", "UTF-8"))
        val arr = o.optJSONArray("events") ?: JSONArray()
        Events(o.getString("boot"), o.getInt("seq"), (0 until arr.length()).map { i ->
            arr.getJSONObject(i).let { e -> AgentEvent(e.getString("id"), e.getString("name"), e.optString("title"), e.getString("kind"), e.optString("text")) }
        })
    }

    /** The Mac's right-click menu: clone / rename / clear / migrate / end. Returns whether it worked and the Mac's note. */
    suspend fun action(id: String, action: String, text: String? = null): Pair<Boolean, String> = withContext(Dispatchers.IO) {
        val body = JSONObject().put("id", id).put("action", action)
        if (text != null) body.put("text", text)
        val o = request("POST", "/api/action", body)
        o.optBoolean("ok", false) to o.optString("message")
    }

    suspend fun send(id: String, text: String): Boolean = post("/api/send", JSONObject().put("id", id).put("text", text))
    suspend fun choose(id: String, index: Int): Boolean = post("/api/choose", JSONObject().put("id", id).put("index", index))
    /** Up, Down, Enter, Escape, 1, 2, 3 */
    suspend fun key(id: String, key: String): Boolean = post("/api/key", JSONObject().put("id", id).put("key", key))

    private suspend fun post(path: String, body: JSONObject): Boolean = withContext(Dispatchers.IO) {
        request("POST", path, body).optBoolean("ok", false)
    }

    fun portrait(character: String) = "$base/art/portraits/$character.jpg"

    // App updates the Mac hands out (android/publish.sh → MobileServer /app/…).

    /** The newest phone app on the Mac, or null when none was published there. */
    suspend fun latestApp(): Release? = withContext(Dispatchers.IO) {
        val c = open("GET", "/app/android.json")
        val code = c.responseCode
        if (code == 401) throw Unpaired()
        if (code != 200) return@withContext null
        val o = read(c, code)
        Release(o.getInt("versionCode"), o.getString("versionName"), o.optString("sha256"), o.optString("notes"))
    }

    /** Downloads the published APK into [file], checking it against the published SHA-256. */
    suspend fun downloadApp(release: Release, file: java.io.File, progress: (Float) -> Unit) = withContext(Dispatchers.IO) {
        val c = open("GET", "/app/android.apk")
        c.readTimeout = 60000
        if (c.responseCode != 200) throw Exception("업데이트 파일을 받지 못함 (${c.responseCode})")
        val total = c.contentLengthLong.coerceAtLeast(1)
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        file.parentFile?.mkdirs()
        c.inputStream.use { input ->
            file.outputStream().use { out ->
                val buf = ByteArray(64 * 1024)
                var done = 0L
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n); digest.update(buf, 0, n)
                    done += n
                    progress(done.toFloat() / total)
                }
            }
        }
        val sha = digest.digest().joinToString("") { "%02x".format(it) }
        if (release.sha256.isNotEmpty() && sha != release.sha256) { file.delete(); throw Exception("받은 파일이 손상됨 — 다시 시도") }
    }

    // Pairing: the QR's one-time secret makes a request the owner allows on the Mac; the token comes back once.

    /** Returns the pending request id to poll. */
    suspend fun pair(secret: String): String = withContext(Dispatchers.IO) {
        request("POST", "/pair", JSONObject().put("secret", secret)).getString("pending")
    }

    /** null while waiting on the Mac; the token once allowed. Throws with the Mac's message otherwise. */
    suspend fun pairStatus(pending: String): String? = withContext(Dispatchers.IO) {
        val c = open("GET", "/pair/status?id=$pending")
        val code = c.responseCode
        val body = read(c, code)
        if (code == 200 && body.optBoolean("ok")) {
            val cookie = c.headerFields["Set-Cookie"].orEmpty().firstOrNull { it.startsWith("sh=") }
                ?: throw Exception("토큰을 받지 못함")
            return@withContext cookie.substringAfter("sh=").substringBefore(";")
        }
        if (code == 200) return@withContext null
        throw Exception(body.optString("error", "연결 실패 ($code)"))
    }

    private fun request(method: String, path: String, body: JSONObject? = null): JSONObject {
        val c = open(method, path)
        if (body != null) {
            c.doOutput = true
            c.setRequestProperty("Content-Type", "application/json")
            c.outputStream.use { it.write(body.toString().toByteArray()) }
        }
        val code = c.responseCode
        if (code == 401) throw Unpaired()
        val o = read(c, code)
        if (code !in 200..299) throw Exception(o.optString("error", "오류 $code"))
        return o
    }

    private fun open(method: String, path: String): HttpURLConnection {
        val c = URL(base + path).openConnection() as HttpURLConnection
        c.requestMethod = method
        c.connectTimeout = 8000
        c.readTimeout = 15000
        // The Mac names the device from this ("Android").
        c.setRequestProperty("User-Agent", "Suhyeok-Android (Android ${android.os.Build.VERSION.RELEASE}; ${android.os.Build.MODEL})")
        if (token != null) c.setRequestProperty("Cookie", "sh=$token")
        return c
    }

    private fun read(c: HttpURLConnection, code: Int): JSONObject {
        val stream = if (code in 200..299) c.inputStream else c.errorStream
        val text = stream?.bufferedReader()?.use { it.readText() }.orEmpty()
        return runCatching { JSONObject(text) }.getOrElse { JSONObject().put("error", "응답을 읽지 못함 ($code)") }
    }

    companion object {
        /** The QR holds `https://host/#pair=<secret>`. */
        fun parseQr(text: String): Pair<String, String>? {
            val i = text.indexOf("#pair=")
            if (i < 0 || !text.startsWith("https://")) return null
            return text.substring(0, i).trimEnd('/') to text.substring(i + 6)
        }
    }
}
