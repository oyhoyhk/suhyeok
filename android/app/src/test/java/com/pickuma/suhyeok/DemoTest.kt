package com.pickuma.suhyeok

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DemoTest {
    private fun agent(id: String) = Demo.respond("GET", "/api/state", null).getJSONArray("agents")
        .let { a -> (0 until a.length()).map { a.getJSONObject(it) } }.first { it.getString("id") == id }

    @Test fun choosingAnswersTheMenuAndStartsWork() {
        assertEquals("waiting", agent("demo-1").getString("status"))
        val ok = Demo.respond("POST", "/api/choose", JSONObject().put("id", "demo-1").put("index", 0))
        assertTrue(ok.getBoolean("ok"))
        assertEquals("busy", agent("demo-1").getString("status"))
        val chat = Demo.respond("GET", "/api/chat?id=demo-1", null)
        assertEquals(0, chat.getJSONArray("menu").length())
    }

    @Test fun sentTextAppearsInTheChat() {
        Demo.respond("POST", "/api/send", JSONObject().put("id", "demo-3").put("text", "색 바꿔 줘"))
        val items = Demo.respond("GET", "/api/chat?id=demo-3", null).getJSONArray("items")
        assertEquals("색 바꿔 줘", items.getJSONObject(items.length() - 1).getString("text"))
    }
}
