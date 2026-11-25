package com.pickuma.suhyeok

import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

/**
 * Sample sessions for people without the Mac app (Play reviewers, testers): answers the same requests as the
 * Mac's phone server (MobileServer.swift), from memory. Nothing leaves the phone except /피드백.
 */
object Demo {
    const val BASE = "demo:"

    /** The app's assets, for the world art (set by MainActivity; null in unit tests). */
    var assets: android.content.res.AssetManager? = null

    /** World art bundled for the sample characters (assets/demo-art), in place of the Mac's /art. */
    fun art(path: String): android.graphics.Bitmap? = runCatching {
        assets?.open("demo-art/$path")?.use { android.graphics.BitmapFactory.decodeStream(it) }
    }.getOrNull()

    /**
     * The Mac's map (art/out/walkmap.json, World.swift): boss rects and the standing spots in map units (width 1).
     * Each sample agent has its own boss: it fights there while working or waits there for a choice, else it rests at camp.
     */
    private class Ground(val key: String, val korean: String, val english: String,
                         val x: Double, val y: Double, val w: Double, val h: Double, val spots: List<Pair<Double, Double>>)
    private val grounds = listOf(
        Ground("low", "숲의 슬라임 왕", "Forest Slime King", 0.75, 0.1434, 0.09, 0.084375, listOf(0.675 to 0.1434, 0.825 to 0.1434)),
        Ground("mid", "수정 동굴 골렘", "Crystal Cave Golem", 0.255, 0.4191, 0.1, 0.095625, listOf(0.175 to 0.4191, 0.335 to 0.4191)),
        Ground("high", "화염 용왕", "Flame Dragon King", 0.735, 0.4303, 0.11, 0.106875, listOf(0.65 to 0.4303, 0.82 to 0.4303)),
    )
    private val camp = listOf(0.2474 to 0.1849, 0.2578 to 0.1016, 0.2161 to 0.1849, 0.2995 to 0.1432)

    private class Session(
        val id: String, val name: String, val character: String, val title: String, val project: String,
        val kind: String, var status: String, var activity: String, var action: String, var last: Double,
        val items: MutableList<ChatItem>, var menu: List<String> = emptyList(),
        var doneAt: Double = 0.0, var reply: String = "", val ground: String = "low",
    )

    private fun now() = System.currentTimeMillis() / 1000.0

    /** Sample text in the phone's language, as the app's strings: Korean on a Korean phone, English elsewhere. */
    private fun tr(korean: String, english: String) = if (Locale.getDefault().language == "ko") korean else english

    private val sessions by lazy {
        val t = now()
        listOf(
            Session("demo-1", tr("시엘", "Ciel"), "bard", tr("로그인 버그 수정", "Fix login bug"), "web-shop", "Claude", "waiting",
                tr("작업 중", "Working"), "", t - 30,
                mutableListOf(
                    ChatItem("me", tr("로그인하면 가끔 빈 화면이 나와. 원인 찾아서 고쳐 줘",
                        "Logging in sometimes shows a blank screen. Find the cause and fix it")),
                    ChatItem("agent", tr("세션 쿠키가 만료된 상태에서 리다이렉트가 두 번 일어나는 문제로 보입니다. `auth/session.ts`를 고치고 테스트를 돌려 보겠습니다.",
                        "It looks like the redirect runs twice when the session cookie has expired. I'll fix `auth/session.ts` and run the tests.")),
                    ChatItem("tool", "Edit auth/session.ts"),
                ),
                menu = listOf(tr("예", "Yes"), tr("예, 이 명령은 다시 묻지 않기", "Yes, and don't ask again for this command"), tr("아니요", "No")),
                ground = "mid",
            ).also { it.reply = tr("테스트 42개가 모두 통과했습니다. 만료된 쿠키를 먼저 지우도록 고쳤습니다.",
                "All 42 tests pass. It now clears the expired cookie first.") },
            Session("demo-2", tr("노아", "Noah"), "alchemist", tr("결제 API 문서화", "Document the payments API"), "payments", "Codex", "busy",
                tr("작업 중", "Working"), tr("README.md 작성 중", "Writing README.md"), t - 5,
                mutableListOf(ChatItem("me", tr("결제 API 엔드포인트를 README에 정리해 줘", "List the payments API endpoints in the README")),
                    ChatItem("tool", "Read src/routes/pay.ts")), ground = "low"),
            Session("demo-3", tr("리오", "Rio"), "archer", tr("대시보드 차트 추가", "Add dashboard chart"), "admin", "Claude", "idle",
                tr("대기 중", "Waiting"), "", t - 300,
                mutableListOf(
                    ChatItem("me", tr("주간 매출 차트를 대시보드 맨 위에 추가해 줘", "Add a weekly sales chart to the top of the dashboard")),
                    ChatItem("agent", tr("## 완료\n- `WeeklySales` 차트 추가\n- 데이터는 기존 `/api/sales?range=7d` 사용\n\n확인해 보시고 색이나 크기를 바꿀 곳이 있으면 알려 주세요.",
                        "## Done\n- Added the `WeeklySales` chart\n- Data comes from the existing `/api/sales?range=7d`\n\nTake a look and tell me if you want a different color or size.")),
                ), ground = "high"),
            Session("demo-4", tr("하람", "Haram"), "cleric", tr("의존성 업데이트", "Update dependencies"), "web-shop", "Claude", "idle",
                tr("휴식 중", "Resting"), "", t - 7200,
                mutableListOf(ChatItem("me", tr("패키지 보안 업데이트 해 줘", "Apply the package security updates")),
                    ChatItem("agent", tr("보안 업데이트 3건을 적용했고 빌드가 통과했습니다.", "Applied 3 security updates, and the build passes."))), ground = "low"),
        )
    }

    @Synchronized
    fun respond(method: String, path: String, body: JSONObject?): JSONObject {
        tick()
        val route = path.substringBefore('?')
        val id = body?.optString("id") ?: path.substringAfter("id=", "").substringBefore('&')
        val s = sessions.firstOrNull { it.id == java.net.URLDecoder.decode(id, "UTF-8") }
        return when (route) {
            "/api/state" -> state()
            "/api/chat" -> s?.let(::chat) ?: JSONObject().put("items", JSONArray())
            "/api/events" -> JSONObject().put("boot", "demo").put("seq", 0).put("events", JSONArray())
            "/api/send" -> {
                s?.run {
                    items += ChatItem("me", body!!.getString("text"))
                    work(tr("답변 작성 중", "Writing a reply"), tr(
                        "체험 모드라 실제 에이전트에게는 전달되지 않습니다. Mac의 수혁과 연결하면 이 지시가 Claude Code나 Codex 세션으로 바로 들어갑니다.",
                        "This is demo mode, so no real agent gets this. Pair with Suhyeok on your Mac and your instructions go straight to a Claude Code or Codex session."))
                }
                JSONObject().put("ok", s != null)
            }
            "/api/choose" -> {
                s?.takeIf { it.menu.isNotEmpty() }?.run {
                    val label = menu.getOrNull(body!!.optInt("index")) ?: menu.first()
                    val no = label == menu.last()   // the last option is "No"
                    menu = emptyList()
                    items += ChatItem("me", label)
                    if (no) { status = "idle"; activity = tr("대기 중", "Waiting"); last = now() }
                    else { items += ChatItem("tool", "Bash npm test"); work(tr("테스트 실행 중", "Running tests"), reply) }
                }
                JSONObject().put("ok", s != null)
            }
            "/api/key" -> JSONObject().put("ok", true)
            // Sample folders for the Files tab; opening a file says it needs the Mac (Api.text / download).
            "/api/files" -> if (!path.contains("dir=")) JSONObject().put("home", "~")
                .put("folders", JSONArray(sessions.map { "~/" + it.project }.distinct()))
            else {
                val dir = java.net.URLDecoder.decode(path.substringAfter("dir="), "UTF-8")
                val t = now()
                JSONObject().put("dir", dir).put("parent", "~").put("entries", JSONArray(listOf(
                    Triple("dist", true, 0L), Triple("demo.mp4", false, 18_400_000L), Triple("README.md", false, 4_200L),
                ).mapIndexed { i, (n, d, size) ->
                    JSONObject().put("name", n).put("path", "$dir/$n").put("dir", d).put("size", size).put("mtime", t - 600 * (i + 1))
                }))
            }
            "/api/action" -> JSONObject().put("ok", false).put("message", tr("체험 모드에서는 쓸 수 없음", "Not available in demo mode"))
            else -> JSONObject().put("error", tr("체험 모드", "Demo mode"))
        }
    }

    private fun Session.work(what: String, answer: String) {
        status = "busy"; activity = tr("작업 중", "Working"); action = what; last = now()
        doneAt = now() + 5; reply = answer
    }

    /** Finishes work started by send/choose after a few seconds. */
    private fun tick() {
        for (s in sessions) if (s.doneAt > 0 && now() >= s.doneAt) {
            s.items += ChatItem("agent", s.reply)
            s.status = "idle"; s.activity = tr("대기 중", "Waiting"); s.action = ""; s.last = now(); s.doneAt = 0.0
        }
    }

    /** The session list with the world on top, as the Mac's /api/state: where each agent stands, the bosses, the crystals. */
    private fun state(): JSONObject {
        val placed = mutableMapOf<String?, Int>()   // ground key (null = camp) → agents placed there so far
        val agents = sessions.map { s ->
            val g = grounds.firstOrNull { it.key == s.ground }?.takeIf { s.status == "busy" || s.status == "waiting" }
            val i = placed.merge(g?.key, 1, Int::plus)!! - 1
            val (x, y) = g?.let { it.spots[i % it.spots.size] } ?: camp[i % camp.size]
            agent(s).put("x", x).put("y", y).put("tier", g?.key ?: JSONObject.NULL)
        }
        return JSONObject().put("agents", JSONArray(agents))
            .put("world", JSONObject().put("w", 1).put("h", 9.0 / 16)).put("avatar", 0.034).put("crystals", 1280)
            .put("bosses", JSONArray(grounds.map {
                JSONObject().put("key", it.key).put("name", tr(it.korean, it.english)).put("x", it.x).put("y", it.y).put("w", it.w).put("h", it.h)
            }))
    }

    private fun agent(s: Session) = JSONObject()
        .put("id", s.id).put("name", s.name).put("title", s.title).put("project", s.project)
        .put("cwd", "~/" + s.project).put("status", s.status).put("activity", s.activity)
        .put("character", s.character).put("action", s.action).put("last", s.last)
        .put("canSend", true).put("agent", s.kind).put("hosted", false).put("canClone", false)

    private fun chat(s: Session) = JSONObject()
        .put("items", JSONArray(s.items.map { JSONObject().put("role", it.role).put("text", it.text) }))
        .put("live", if (s.status == "busy") s.action + "…" else "")
        .put("menu", JSONArray(s.menu.map { JSONObject().put("label", it) }))
        .put("status", s.status).put("activity", s.activity).put("action", s.action)
}
