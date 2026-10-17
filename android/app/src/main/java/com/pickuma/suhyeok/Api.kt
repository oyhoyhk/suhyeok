package com.pickuma.suhyeok

import android.content.Context
import androidx.annotation.StringRes
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
    /** Done and waiting for the next instruction (rather than resting). */
    val waitingForNext get() = isWaitingActivity(activity)
}

/** The Mac's activity label for "waiting for the next instruction", in whichever language the Mac runs. */
fun isWaitingActivity(activity: String) = activity == "대기 중" || activity == "Waiting"

/** The Mac's world map (WorldView): where each agent stands, the bosses, sizes in map units (width 1). */
data class WorldMap(
    val width: Float, val height: Float, val avatar: Float, val crystals: Int,
    val agents: List<WorldAgent>, val bosses: List<Boss>,
)
data class WorldAgent(val agent: Agent, val x: Float, val y: Float, val tier: String?)   // tier null: at the camp
data class Boss(val key: String, val name: String, val x: Float, val y: Float, val w: Float, val h: Float)

/** A session on 수혁's own tmux server (MobileTerminal.swift): agents, plain shells, the bottom panel. */
data class Terminal(val name: String, val title: String, val cwd: String, val kind: String, val agentName: String, val character: String)
/** A pane as lines with ANSI colors; the cursor is within the last [height] lines. */
data class TermScreen(val lines: List<String>, val height: Int, val cx: Int, val cy: Int)

data class AgentEvent(val id: String, val name: String, val title: String, val kind: String, val text: String)  // kind: asking / done
data class Events(val boot: String, val seq: Int, val events: List<AgentEvent>)

data class Release(val code: Int, val name: String, val sha256: String, val notes: String)

data class ChatItem(val role: String, val text: String)   // me / agent / tool
data class Chat(
    val items: List<ChatItem>,
    val live: String?,
    val menu: List<String>,
    val menuDetails: List<String> = emptyList(),   // each option's description, "" when it has none
    val menuQuestion: String = "",                 // what is being asked, read from the screen
    val menuContext: String = "",                  // why: the tool, command or file above the question
    val status: String,      // as in Agent
    val activity: String,
    val action: String,
)

/** Thrown when the Mac no longer accepts this phone's token: pair again. */
class Unpaired : Exception("pair")

/** A failure in the phone's own words, shown in the phone's language ([describe]). The Mac's messages pass as they are. */
class Failure(@StringRes val res: Int, vararg val args: Any) : Exception()

fun Throwable.describe(context: Context): String? = if (this is Failure) context.getString(res, *args) else message

/**
 * Talks to 수혁's phone server on the Mac (MobileServer.swift) through its Cloudflare address.
 * Every call after pairing carries the token as the `sh` cookie, as the phone web page does.
 */
class Api(val base: String, private val token: String?) {
    /** Sample sessions without a Mac (Demo.kt). */
    val demo = base == Demo.BASE

    suspend fun state(): List<Agent> = withContext(Dispatchers.IO) {
        val o = request("GET", "/api/state")
        val arr = o.getJSONArray("agents")
        (0 until arr.length()).map { i -> agent(arr.getJSONObject(i)) }
    }

    /** The same state with positions, for the world tab. null when the Mac sends no map (demo mode). */
    suspend fun world(): WorldMap? = withContext(Dispatchers.IO) {
        val o = request("GET", "/api/state")
        val w = o.optJSONObject("world") ?: return@withContext null
        val arr = o.getJSONArray("agents")
        val bosses = o.optJSONArray("bosses") ?: JSONArray()
        WorldMap(
            w.getDouble("w").toFloat(), w.getDouble("h").toFloat(), o.optDouble("avatar", 0.034).toFloat(), o.optInt("crystals"),
            (0 until arr.length()).map { i ->
                val a = arr.getJSONObject(i)
                WorldAgent(agent(a), a.optDouble("x").toFloat(), a.optDouble("y").toFloat(),
                    if (a.isNull("tier")) null else a.optString("tier").ifEmpty { null })
            },
            (0 until bosses.length()).map { i ->
                val b = bosses.getJSONObject(i)
                Boss(b.getString("key"), b.optString("name"), b.getDouble("x").toFloat(), b.getDouble("y").toFloat(),
                    b.getDouble("w").toFloat(), b.getDouble("h").toFloat())
            },
        )
    }

    private fun agent(a: JSONObject) = Agent(
        id = a.getString("id"), name = a.getString("name"), title = a.optString("title"),
        project = a.optString("project"), cwd = a.optString("cwd"), status = a.optString("status"), activity = a.optString("activity"),
        character = a.optString("character"), action = a.optString("action"), last = a.optDouble("last", 0.0),
        canSend = a.optBoolean("canSend", false), kind = a.optString("agent"),
        hosted = a.optBoolean("hosted", false), canClone = a.optBoolean("canClone", false),
    )

    suspend fun chat(id: String): Chat = withContext(Dispatchers.IO) {
        val o = request("GET", "/api/chat?id=" + java.net.URLEncoder.encode(id, "UTF-8"))
        val items = o.optJSONArray("items") ?: JSONArray()
        val menu = o.optJSONArray("menu") ?: JSONArray()
        Chat(
            items = (0 until items.length()).map { items.getJSONObject(it).let { j -> ChatItem(j.getString("role"), j.getString("text")) } },
            live = o.optString("live").ifEmpty { null },
            menu = (0 until menu.length()).map { menu.getJSONObject(it).getString("label") },
            menuDetails = (0 until menu.length()).map { menu.getJSONObject(it).optString("detail") },
            menuQuestion = o.optString("menuQuestion"), menuContext = o.optString("menuContext"),
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

    // Terminal tab (MobileServer /api/term…).

    suspend fun terminals(): List<Terminal> = withContext(Dispatchers.IO) {
        val arr = request("GET", "/api/terminals").optJSONArray("terminals") ?: JSONArray()
        (0 until arr.length()).map { i ->
            arr.getJSONObject(i).let { t ->
                Terminal(t.getString("name"), t.optString("title"), t.optString("cwd"), t.optString("kind"),
                    t.optString("agentName"), t.optString("character"))
            }
        }
    }

    /** null when the session is gone. */
    suspend fun term(name: String, history: Int = 300): TermScreen? = withContext(Dispatchers.IO) {
        val o = runCatching { request("GET", "/api/term?history=$history&name=" + java.net.URLEncoder.encode(name, "UTF-8")) }
            .getOrElse { if (it is Unpaired) throw it else return@withContext null }
        val arr = o.optJSONArray("lines") ?: return@withContext null
        TermScreen((0 until arr.length()).map { arr.getString(it) }, o.optInt("height"), o.optInt("cx"), o.optInt("cy"))
    }

    suspend fun termType(name: String, text: String): Boolean = post("/api/term-input", JSONObject().put("name", name).put("text", text))
    /** tmux key names: Enter, Tab, Escape, BSpace, Up, Down, Left, Right, C-c … */
    suspend fun termKey(name: String, key: String): Boolean = post("/api/term-input", JSONObject().put("name", name).put("key", key))
    /** A new shell in the Mac's home folder; returns its name. */
    suspend fun termNew(): String? = withContext(Dispatchers.IO) {
        request("POST", "/api/term-new", JSONObject()).let { if (it.optBoolean("ok")) it.optString("name") else null }
    }

    // New session (MobileServer /api/folders, /api/new).

    /** The Mac's home folder and the folders of its recent sessions. */
    suspend fun folders(): Pair<String, List<String>> = withContext(Dispatchers.IO) {
        val o = request("GET", "/api/folders")
        val arr = o.optJSONArray("folders") ?: JSONArray()
        o.optString("home") to (0 until arr.length()).map { arr.getString(it) }
    }

    /** Starts Claude Code or Codex ("Claude" / "Codex") in [cwd]; returns whether it started and the Mac's note. */
    suspend fun newSession(agent: String, cwd: String, prompt: String): Pair<Boolean, String> = withContext(Dispatchers.IO) {
        val o = request("POST", "/api/new", JSONObject().put("agent", agent).put("cwd", cwd).put("prompt", prompt))
        o.optBoolean("ok", false) to o.optString("message")
    }

    /** Map art (field, bosses, sprite frames). Built-in art is public; bought characters need the cookie. */
    fun art(path: String): android.graphics.Bitmap? = runCatching {
        val c = open("GET", "/art/$path")
        if (c.responseCode != 200) return null
        c.inputStream.use { android.graphics.BitmapFactory.decodeStream(it) }
    }.getOrNull()

    /** Sends a file to the Mac (MobileServer /api/upload); returns its path there, to put in a message. */
    suspend fun upload(name: String, bytes: ByteArray): String = withContext(Dispatchers.IO) {
        if (demo) {
            // Shaped like the Mac's answer (Attachments.savePhone): temporary folder, own subfolder, spaces escaped.
            val clean = name.map { if (it in "/:\\") '_' else it }.joinToString("").trimStart('.').ifEmpty { "file" }
            val stamp = java.text.SimpleDateFormat("yyyyMMdd-HHmmss", java.util.Locale.US).format(java.util.Date())
            return@withContext "/var/folders/demo/T/Suhyeok-phone/phone-$stamp-DEMO01/$clean".replace(" ", "\\ ")
        }
        val c = open("POST", "/api/upload?name=" + java.net.URLEncoder.encode(name, "UTF-8").replace("+", "%20"))
        c.readTimeout = 120000
        c.doOutput = true
        c.setFixedLengthStreamingMode(bytes.size)
        c.setRequestProperty("Content-Type", "application/octet-stream")
        c.outputStream.use { it.write(bytes) }
        val code = c.responseCode
        if (code == 401) throw Unpaired()
        val o = read(c, code)
        o.optString("path").ifEmpty { null } ?: throw failure(o, R.string.error_code, code)
    }

    private suspend fun post(path: String, body: JSONObject): Boolean = withContext(Dispatchers.IO) {
        request("POST", path, body).optBoolean("ok", false)
    }

    fun portrait(character: String) =
        if (demo) "file:///android_asset/portraits/$character.jpg" else "$base/art/portraits/$character.jpg"

    // App updates the Mac hands out (android/publish.sh → MobileServer /app/…).

    /** The newest phone app on the Mac, or null when none was published there. */
    suspend fun latestApp(): Release? = withContext(Dispatchers.IO) {
        if (demo) return@withContext null
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
        if (c.responseCode != 200) throw Failure(R.string.error_update_download, c.responseCode)
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
        if (release.sha256.isNotEmpty() && sha != release.sha256) { file.delete(); throw Failure(R.string.error_update_corrupt) }
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
                ?: throw Failure(R.string.error_no_token)
            return@withContext cookie.substringAfter("sh=").substringBefore(";")
        }
        if (code == 200) return@withContext null
        throw failure(body, R.string.error_pair_code, code)
    }

    private fun request(method: String, path: String, body: JSONObject? = null): JSONObject {
        if (demo) return Demo.respond(method, path, body)
        val c = open(method, path)
        if (body != null) {
            c.doOutput = true
            c.setRequestProperty("Content-Type", "application/json")
            c.outputStream.use { it.write(body.toString().toByteArray()) }
        }
        val code = c.responseCode
        if (code == 401) throw Unpaired()
        val o = read(c, code)
        if (code !in 200..299) throw failure(o, R.string.error_code, code)
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
        return runCatching { JSONObject(text) }.getOrElse { JSONObject().put(UNREADABLE, true) }
    }

    /** The Mac's own error message (already in its language), else ours. */
    private fun failure(o: JSONObject, @StringRes fallback: Int, code: Int): Exception =
        o.optString("error").ifEmpty { null }?.let(::Exception)
            ?: Failure(if (o.has(UNREADABLE)) R.string.error_unreadable else fallback, code)

    companion object {
        /** Marks a reply body that was not JSON (see [read]). */
        private const val UNREADABLE = "_unreadable"

        /** The QR holds `https://host/#pair=<secret>`. */
        fun parseQr(text: String): Pair<String, String>? {
            val i = text.indexOf("#pair=")
            if (i < 0 || !text.startsWith("https://")) return null
            return text.substring(0, i).trimEnd('/') to text.substring(i + 6)
        }
    }
}
