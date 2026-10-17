package com.pickuma.suhyeok

import android.os.Build
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * `/피드백 …` typed in the chat goes to the 수혁 developers as a public GitHub issue, through the same relay
 * the Mac uses (Feedback.swift, server/feedback) — straight from the phone, not via the Mac.
 */
object Feedback {
    private const val ENDPOINT = "https://suhyeok-feedback.pickuma.workers.dev"

    /** The report in a draft starting with `/피드백` (or `/feedback`); null for an ordinary instruction. */
    fun command(draft: String): String? {
        for (prefix in listOf("/피드백", "/feedback")) {
            if (!draft.startsWith(prefix)) continue
            val rest = draft.removePrefix(prefix)
            if (rest.isNotEmpty() && !rest.first().isWhitespace()) return null
            return rest.trim()
        }
        return null
    }

    /** Sends the report; returns the new issue's address, or throws with the server's message. */
    suspend fun send(text: String, agent: String): String = withContext(Dispatchers.IO) {
        val body = JSONObject().put("text", text).put("source", "phone").put("version", BuildConfig.VERSION_NAME)
            .put("os", "Android ${Build.VERSION.RELEASE}").put("agent", agent)
        val c = URL(ENDPOINT).openConnection() as HttpURLConnection
        c.requestMethod = "POST"
        c.doOutput = true
        c.connectTimeout = 10_000
        c.readTimeout = 15_000
        c.setRequestProperty("content-type", "application/json")
        c.outputStream.use { it.write(body.toString().toByteArray()) }
        val ok = c.responseCode in 200..299
        val reply = JSONObject((if (ok) c.inputStream else c.errorStream).bufferedReader().readText())
        if (!ok) throw reply.optString("error").ifEmpty { null }?.let(::Exception) ?: Failure(R.string.send_failed)
        reply.getString("url")
    }
}
