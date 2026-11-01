package com.pickuma.suhyeok

import android.app.Activity
import android.content.Intent
import android.speech.RecognizerIntent
import android.speech.tts.TextToSpeech
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import coil.compose.AsyncImage
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.Locale
import kotlin.math.roundToInt

/** Conversation with one agent: its log, the reply being written, menu choices, and an input with dictation. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ChatScreen(api: Api, agent: Agent, prefs: Prefs, onBack: () -> Unit, onUnpaired: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var chat by remember { mutableStateOf<Chat?>(null) }
    var draft by remember { mutableStateOf("") }
    var notice by remember { mutableStateOf<String?>(null) }
    var readAloud by remember { mutableStateOf(prefs.readAloud) }
    var showKeys by remember { mutableStateOf(false) }
    /** Files from the phone already on the Mac: (name, path there). Their paths go out with the next message. */
    val attached = remember { mutableStateListOf<Pair<String, String>>() }
    var uploading by remember { mutableStateOf(0) }
    /** A send is on its way to the Mac: a second tap now would type the message twice. */
    var sending by remember { mutableStateOf(false) }
    /** What was last sent from this screen (the ↑ button brings it back). */
    var sentHere by remember { mutableStateOf<String?>(null) }
    /** The + drawer under the input, as in KakaoTalk: file, voice, quick keys and the agent's commands. */
    var more by remember { mutableStateOf(false) }
    /** The command whose dialog is shown as a panel (/status, /model …); null when closed. */
    var panel by remember { mutableStateOf<String?>(null) }
    val list = rememberLazyListState()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val unreachable = stringResource(R.string.chat_unreachable)

    // Text-to-speech for new replies while "read aloud" is on, in the reply's language (speechLocale).
    val tts = remember { mutableStateOf<TextToSpeech?>(null) }
    DisposableEffect(Unit) {
        lateinit var engine: TextToSpeech
        engine = TextToSpeech(context) { if (it == TextToSpeech.SUCCESS) tts.value = engine }
        onDispose { engine.shutdown() }
    }

    LaunchedEffect(agent.id) {
        var seenReplies = -1
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                try {
                    val c = api.chat(agent.id, screen = panel != null)
                    val replies = c.items.count { it.role == "agent" }
                    // A new finished reply (not the ones there on open): read it if asked.
                    if (seenReplies >= 0 && replies > seenReplies && prefs.readAloud) {
                        c.items.lastOrNull { it.role == "agent" }?.let { r ->
                            val say = spoken(r.text)
                            tts.value?.run { language = speechLocale(say); speak(say, TextToSpeech.QUEUE_FLUSH, null, "reply") }
                        }
                    }
                    seenReplies = replies
                    val grew = c.items.size != chat?.items?.size || c.live != chat?.live || c.menu != chat?.menu
                    // The list is laid out from the bottom (item 0 = newest), so it opens on the latest message.
                    // Follow new content only while the newest is on screen, so reading older messages is not interrupted.
                    val atEnd = list.firstVisibleItemIndex == 0 && list.firstVisibleItemScrollOffset < 200
                    chat = c
                    if (grew && atEnd) list.scrollToItem(0)
                } catch (e: Unpaired) {
                    onUnpaired(); return@repeatOnLifecycle
                } catch (e: Exception) {
                    notice = unreachable
                }
                delay(if (panel != null) 700 else if (chat?.live != null || chat?.menu?.isNotEmpty() == true) 1000 else 2000)
            }
        }
    }

    val dictate = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        if (r.resultCode == Activity.RESULT_OK) {
            val said = r.data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull().orEmpty()
            if (said.isNotEmpty()) draft = if (draft.isBlank()) said else "$draft $said"
        }
    }

    // Photos and files from the phone go to the Mac first; the agent gets their paths there, as with a file dropped on the Mac.
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.GetMultipleContents()) { uris ->
        for (uri in uris) scope.launch {
            val (name, size) = fileInfo(context, uri)
            if (size > MAX_UPLOAD) { notice = context.getString(R.string.attach_too_big, name); return@launch }
            uploading++
            try {
                val bytes = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                    context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                } ?: throw Failure(R.string.attach_unreadable)
                if (bytes.size > MAX_UPLOAD) throw Failure(R.string.attach_too_big, name)
                attached += name to api.upload(name, bytes)
            } catch (e: Unpaired) {
                onUnpaired()
            } catch (e: Exception) {
                notice = context.getString(R.string.attach_failed, name, e.describe(context) ?: "")
            } finally { uploading-- }
        }
    }

    fun send() {
        val typed = draft.trim()
        if (typed.isEmpty() && attached.isEmpty()) return
        val text = (listOf(typed) + attached.map { it.second }).filter { it.isNotEmpty() }.joinToString(" ")
        if (attached.isEmpty()) Feedback.command(text)?.let { report ->
            if (report.isEmpty()) { notice = context.getString(R.string.feedback_empty); return }
            draft = ""
            notice = context.getString(R.string.feedback_sending)
            scope.launch {
                notice = runCatching { context.getString(R.string.feedback_sent, Feedback.send(report, agent.kind)) }
                    .getOrElse { draft = text; context.getString(R.string.feedback_failed, it.describe(context)) }
            }
            return
        }
        if (sending) return
        // Clear the box before the request, not after: the send takes a second or two, and a tap in that window sent it again.
        val files = attached.toList()
        sending = true; draft = ""; attached.clear()
        scope.launch {
            val ok = runCatching { api.send(agent.id, text) }.getOrDefault(false)
            sending = false
            if (ok) { sentHere = text; notice = if (agent.busy) context.getString(R.string.chat_queued) else null }
            else {
                if (draft.isEmpty() && attached.isEmpty()) { draft = typed; attached.addAll(files) }
                notice = context.getString(R.string.send_failed)
            }
        }
    }

    // A command button types the command; one that opens a dialog also opens the panel that shows it.
    fun command(cmd: AgentCommand) {
        scope.launch { if (!runCatching { api.send(agent.id, cmd.text) }.getOrDefault(false)) notice = context.getString(R.string.send_failed) }
        if (cmd.panel) panel = cmd.text
    }
    // A key in the panel, then a quick look so the panel follows it without waiting for the next poll.
    fun panelKey(key: String) = scope.launch {
        runCatching { api.key(agent.id, key) }
        delay(250)
        runCatching { api.chat(agent.id, screen = true) }.getOrNull()?.let { chat = it }
    }

    fun choose(i: Int) = scope.launch {
        notice = if (runCatching { api.choose(agent.id, i) }.getOrDefault(false)) null else context.getString(R.string.chat_choose_failed)
    }
    /** Leaves a menu or dialog without choosing, as Esc does in the terminal. */
    fun cancel() = scope.launch { runCatching { api.key(agent.id, "Escape") } }

    panel?.let { cmd ->
        val screen = chat?.screen
        // The dialog's choices are in the panel too, so a choice does not mean closing the panel first.
        PanelSheet(cmd, screen, chat?.takeIf { it.menu.isNotEmpty() }, ::panelKey,
            choose = { i -> choose(i); panel = null }, cancel = { cancel(); panel = null }) {
            // Closing the panel closes the dialog too, or the next message would be typed into it. Only when the
            // screen offers Esc to close: a busy agent says "esc to interrupt", and Esc there would stop its work.
            if (screen != null && screen.lines().takeLast(8).any { escCloses.containsMatchIn(it) }) panelKey("Escape")
            panel = null
        }
    }

    Column(Modifier.fillMaxSize().statusBarsPadding().imePadding()) {
        // Header: back, portrait, name, read-aloud toggle.
        Row(Modifier.fillMaxWidth().padding(horizontal = 6.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back), tint = Color.White) }
            val status = chat?.status ?: agent.status
            val activity = chat?.activity ?: agent.activity
            Portrait(api, agent.character, agent.name, 36.dp, statusColor(status, activity))
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    NameTag(agent.name, agent.cwd)
                    Spacer(Modifier.width(6.dp))
                    Text(agent.title, color = Color.White, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                val action = chat?.action ?: agent.action
                val line = when {
                    status == "waiting" -> stringResource(R.string.chat_asking)
                    status == "busy" -> stringResource(R.string.working) + (if (action.isNotEmpty()) " · $action" else "")
                    else -> activity
                }
                Text(line, color = statusColor(status, activity), fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            IconButton(onClick = { readAloud = !readAloud; prefs.readAloud = readAloud; if (!readAloud) tts.value?.stop() }) {
                Icon(if (readAloud) Icons.Filled.VolumeUp else Icons.Filled.VolumeOff, stringResource(R.string.read_aloud),
                    tint = if (readAloud) Gold else Color.White.copy(alpha = 0.5f))
            }
        }

        val c = chat
        // Bottom-up: the first item drawn is the newest one at the bottom, so the conversation opens at its end
        // and a long last reply shows its ending, as in a messenger. Items are therefore listed newest first.
        LazyColumn(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 12.dp), state = list, reverseLayout = true,
            verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.Bottom)) {
            if (c == null) item { Text(stringResource(R.string.loading), color = Color.White.copy(alpha = 0.6f)) }
            else {
                if (c.menu.isNotEmpty()) item(key = "menu") {
                    MenuCard(c, ::choose, ::cancel)
                }
                c.live?.let { live -> item(key = "live") { LiveBox(live) } }
                val newestFirst = c.items.withIndex().reversed()
                items(newestFirst, key = { "m${it.index}" }) { Bubble(api, agent, it.value) }
                if (c.items.isEmpty()) item { Text(stringResource(R.string.chat_empty), color = Color.White.copy(alpha = 0.6f)) }
            }
        }

        // Notices sit in the middle like a messenger's date lines.
        notice?.let {
            Box(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 4.dp), contentAlignment = Alignment.Center) {
                Text(linksOnly(it, Gold), color = Color(0xFFFFB74D), fontSize = 12.sp,
                    modifier = Modifier.background(Panel, RoundedCornerShape(50)).padding(horizontal = 12.dp, vertical = 4.dp))
            }
        }

        // As in Claude Code and Codex: stop the running turn (Esc), then bring back the last instruction to fix.
        val busyNow = (chat?.status ?: agent.status) == "busy"
        val last = (sentHere ?: chat?.items?.lastOrNull { it.role == "me" && !it.text.startsWith("/") }?.text)
            ?.substringBefore("\n\n(수혁 음성 지시")
        if (busyNow || (draft.isBlank() && last != null)) Row(Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            if (busyNow) Chip(stringResource(R.string.chat_stop), container = Color(0xFFC62828), content = Color.White, bold = true) {
                scope.launch { if (runCatching { api.key(agent.id, "Escape") }.getOrDefault(false)) notice = context.getString(R.string.chat_stopped) }
            }
            if (draft.isBlank() && last != null) Chip(stringResource(R.string.chat_recall)) { draft = last }
        }

        // Quick keys for menus and the terminal: shown with a menu on screen or on request.
        if (showKeys || chat?.menu?.isNotEmpty() == true) Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 10.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            listOf("Esc" to "Escape", "↑" to "Up", "↓" to "Down", "⏎" to "Enter", "1" to "1", "2" to "2", "3" to "3").forEach { (label, key) ->
                Chip(label) { scope.launch { runCatching { api.key(agent.id, key) } } }
            }
        }

        // The input bar runs to the bottom edge; the + drawer opens under it.
        Column(Modifier.fillMaxWidth().background(Panel).navigationBarsPadding()) {
            // Files waiting to go out with the message; ✕ leaves one out (it stays on the Mac).
            if (attached.isNotEmpty() || uploading > 0) Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(start = 10.dp, end = 10.dp, top = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                attached.forEach { file ->
                    Row(Modifier.background(Navy, RoundedCornerShape(8.dp)).padding(start = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(file.first, color = Color.White, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.widthIn(max = 160.dp))
                        IconButton(onClick = { attached.remove(file) }, modifier = Modifier.size(28.dp)) {
                            Icon(Icons.Filled.Close, stringResource(R.string.attach_remove), tint = Color.White.copy(alpha = 0.6f), modifier = Modifier.size(14.dp))
                        }
                    }
                }
                if (uploading > 0) Text(stringResource(R.string.attach_uploading, uploading), color = Gold, fontSize = 12.sp)
            }

            // [+] [input] [send]: the input takes the rest of the width.
            Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 6.dp), verticalAlignment = Alignment.Bottom) {
                IconButton(onClick = { more = !more }) {
                    Icon(if (more) Icons.Filled.Close else Icons.Filled.Add, stringResource(R.string.chat_more), tint = Gold)
                }
                TextField(
                    value = draft, onValueChange = { draft = it }, modifier = Modifier.weight(1f),
                    placeholder = { Text(stringResource(R.string.chat_placeholder, agent.name), color = Color.White.copy(alpha = 0.4f)) }, maxLines = 6,
                    shape = RoundedCornerShape(20.dp),
                    colors = TextFieldDefaults.colors(focusedTextColor = Color.White, unfocusedTextColor = Color.White, cursorColor = Gold,
                        focusedContainerColor = Navy, unfocusedContainerColor = Navy,
                        focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent),
                )
                val ready = (draft.isNotBlank() || attached.isNotEmpty()) && uploading == 0 && !sending
                Box(Modifier.padding(start = 6.dp, end = 4.dp, bottom = 6.dp).size(44.dp)
                    .background(if (ready) Gold else Navy, RoundedCornerShape(10.dp))
                    .clickable(enabled = ready, onClick = ::send), contentAlignment = Alignment.Center) {
                    Icon(Icons.AutoMirrored.Filled.Send, stringResource(R.string.send), tint = if (ready) Color.Black else Color.Gray)
                }
            }

            chat?.usage?.let { UsageLine(it) }

            if (more) {
                val dictatePrompt = stringResource(R.string.chat_dictate_prompt, agent.name)
                Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                    Tile(Icons.Filled.AttachFile, stringResource(R.string.chat_tile_file), Color(0xFF7FC97F)) { more = false; pick.launch("*/*") }
                    Tile(Icons.Filled.Mic, stringResource(R.string.chat_tile_voice), Color(0xFF6FA8F5)) {
                        more = false
                        dictate.launch(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                            .putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toLanguageTag())
                            .putExtra(RecognizerIntent.EXTRA_PROMPT, dictatePrompt))
                    }
                    Tile(Icons.Filled.Keyboard, stringResource(R.string.chat_tile_keys), if (showKeys) Gold else Color(0xFF5A6390)) { showKeys = !showKeys }
                }
                // The agent's own slash commands, so settings like /status and /model are a tap instead of typing.
                Text(stringResource(R.string.chat_commands, agent.kind), color = Color.White.copy(alpha = 0.6f), fontSize = 12.sp,
                    modifier = Modifier.padding(start = 20.dp, bottom = 6.dp))
                FlowRow(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 14.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    commandsFor(agent.kind).forEach { cmd -> Chip(cmd.text) { more = false; command(cmd) } }
                }
            }
        }
    }
}

/** Messenger bubbles: mine on the right; the agent's on the left under its face and name. */
@Composable
private fun Bubble(api: Api, agent: Agent, item: ChatItem) {
    when (item.role) {
        "me" -> Box(Modifier.fillMaxWidth().padding(start = 48.dp), contentAlignment = Alignment.CenterEnd) {
            Text(inline(item.text, linkColor = Color(0xFF0D2A8A), files = item.files), color = Color.Black,
                modifier = Modifier.background(Gold, RoundedCornerShape(14.dp, 4.dp, 14.dp, 14.dp)).padding(horizontal = 12.dp, vertical = 9.dp))
        }
        "agent" -> Row(Modifier.fillMaxWidth()) {
            Portrait(api, agent.character, agent.name, 38.dp)
            Spacer(Modifier.width(8.dp))
            Column(Modifier.weight(1f)) {
                Text(agent.name, color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp)
                Spacer(Modifier.height(4.dp))
                Box(Modifier.background(Panel, RoundedCornerShape(4.dp, 14.dp, 14.dp, 14.dp)).padding(horizontal = 12.dp, vertical = 9.dp)) {
                    Markdown(item.text, files = item.files)
                }
            }
        }
        else -> Text("🔧 " + item.text, color = Color.White.copy(alpha = 0.5f), fontSize = 12.sp, maxLines = 2, modifier = Modifier.padding(start = 46.dp))
    }
}

/**
 * The Mac's status line under the input, as under Claude Code's prompt: model and effort, context use, and the
 * account's limits (5-hour, weekly) with the time left until each resets. Scrolls sideways when it does not fit.
 */
@Composable
private fun UsageLine(u: Usage) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(start = 16.dp, end = 16.dp, bottom = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        if (u.model.isNotEmpty()) Text(buildAnnotatedString {
            withStyle(SpanStyle(color = Color(0xFFD99AFF), fontWeight = FontWeight.Bold)) { append("◆ " + u.model) }
            if (u.effort.isNotEmpty()) withStyle(SpanStyle(color = Color.White.copy(alpha = 0.5f))) { append(" · " + u.effort) }
        }, fontSize = 11.sp, fontFamily = FontFamily.Monospace)
        u.contextPercent?.let { p ->
            Text(buildAnnotatedString {
                withStyle(SpanStyle(color = Color.White.copy(alpha = 0.5f))) { append(stringResource(R.string.usage_context) + " ") }
                withStyle(SpanStyle(color = usageColor(p))) { append("${p.roundToInt()}%") }
            }, fontSize = 11.sp, fontFamily = FontFamily.Monospace)
        }
        u.limits.forEach { l ->
            val filled = (l.percent / 20).toInt().coerceIn(0, 5)
            val left = l.resetsAt?.let { timeLeft(it) }
            Text(buildAnnotatedString {
                withStyle(SpanStyle(color = Color.White.copy(alpha = 0.5f))) { append(l.label + " ") }
                withStyle(SpanStyle(color = usageColor(l.percent))) { append("▰".repeat(filled)) }
                withStyle(SpanStyle(color = Color.Gray)) { append("▱".repeat(5 - filled)) }
                withStyle(SpanStyle(color = usageColor(l.percent))) { append(" ${l.percent.roundToInt()}%") }
                if (left != null) withStyle(SpanStyle(color = Color.White.copy(alpha = 0.5f))) { append(" ↻$left") }
            }, fontSize = 11.sp, fontFamily = FontFamily.Monospace)
        }
    }
}

/** Green, then yellow from half, red from 80%, as on the Mac. */
private fun usageColor(p: Double) = if (p >= 80) Color(0xFFFF6B6B) else if (p >= 50) Color(0xFFFFD54F) else Color(0xFF66BB6A)

/** "3일4h", "2h05m", "12m" until [epoch]; null once it has passed. */
@Composable
private fun timeLeft(epoch: Double): String? {
    val s = (epoch - System.currentTimeMillis() / 1000.0).toLong()
    if (s <= 0) return null
    val d = s / 86400; val h = s % 86400 / 3600; val m = s % 3600 / 60
    return if (d > 0) stringResource(R.string.usage_days_hours, d, h) else if (h > 0) String.format(Locale.ROOT, "%dh%02dm", h, m) else "${m}m"
}

/** A rounded button: stop and recall over the input, commands in the + drawer, keys in the panel. */
@Composable
private fun Chip(label: String, container: Color = Navy, content: Color = Color.White, bold: Boolean = false, onClick: () -> Unit) {
    Text(label, color = content, fontSize = 13.sp, fontWeight = if (bold) FontWeight.Bold else null, maxLines = 1,
        modifier = Modifier.clip(RoundedCornerShape(50)).background(container).clickable(onClick = onClick)
            .padding(horizontal = 13.dp, vertical = 7.dp))
}

/** A round icon with its name under it, as in a messenger's + drawer. */
@Composable
private fun Tile(icon: ImageVector, label: String, color: Color, onClick: () -> Unit) {
    Column(Modifier.clickable(onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(52.dp).background(color, CircleShape), contentAlignment = Alignment.Center) {
            Icon(icon, label, tint = Color.White)
        }
        Spacer(Modifier.height(6.dp))
        Text(label, color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp)
    }
}

/** A slash command button: [panel] when the command opens a dialog to show (rather than starting work, like /compact). */
data class AgentCommand(val text: String, val panel: Boolean = true)

/**
 * Each agent's settings and status commands, from its own slash menu (Claude Code 2.1.314, Codex 0.166, agy 1.4.12).
 * Commands that end the conversation (/clear, /new) are left out: one stray tap would lose it.
 */
fun commandsFor(kind: String): List<AgentCommand> = when (kind) {
    "Codex" -> listOf("/status", "/model", "/permissions", "/usage", "/mcp", "/diff", "/review").map(::AgentCommand) + AgentCommand("/compact", panel = false)
    "Antigravity" -> listOf("/model", "/effort", "/usage", "/credits", "/context", "/config", "/permissions", "/mcp").map(::AgentCommand) + AgentCommand("/compact", panel = false)
    else -> listOf("/status", "/model", "/effort", "/usage", "/context", "/config", "/permissions", "/mcp").map(::AgentCommand) + AgentCommand("/compact", panel = false)
}

/** A dialog's own way out ("Esc to cancel", "esc to close" …), not "esc to interrupt" on a busy agent. */
private val escCloses = Regex("""(?i)\besc to (cancel|close|exit|clear)\b""")

/**
 * The terminal's bottom lines in full width, for dialogs the chat cannot show (/status, /model …), with the keys
 * they take. Long rules are cut short so they do not wrap into rows of dashes, and the wide gaps of two-column
 * screens ("Model:      opus") shrink to two spaces so a row fits the phone's width.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PanelSheet(title: String, screen: String?, menu: Chat?, key: (String) -> Unit, choose: (Int) -> Unit,
                       cancel: () -> Unit, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Color(0xFF1E1E1E)) {
        Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(bottom = 10.dp)) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(title, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 16.sp, modifier = Modifier.weight(1f))
                TextButton(onClick = cancel) { Text(stringResource(R.string.chat_cancel), color = Color(0xFFFF8A80)) }
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.panel_close), color = Gold) }
            }
            menu?.let {
                // Scrolls on its own so a long model list never pushes the keys out of reach.
                Column(Modifier.fillMaxWidth().weight(1f, fill = false).verticalScroll(rememberScrollState()).padding(horizontal = 10.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    MenuOptions(it, choose)
                }
            }
            // The keys above the screen, so a long screen never pushes them out of reach.
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 10.dp, vertical = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                listOf("Esc" to "Escape", "←" to "Left", "→" to "Right", "↑" to "Up", "↓" to "Down", "Tab" to "Tab", "⏎" to "Enter").forEach { (label, k) ->
                    Chip(label, container = Color(0xFF3A3A3A), content = Color.White) { key(k) }
                }
            }
            val text = screen?.let { androidGlyphs(it.replace(Regex("[─━═▔▁]{6,}"), "─────").replace(Regex("(?<=\\S) {3,}"), "  ")) }
            // A Mac from before the panel sends no screen; its menu above is then all there is to show.
            if (text != null || menu == null) Text(text ?: stringResource(R.string.panel_waiting), color = Color(0xFFE0E0E0), fontFamily = FontFamily.Monospace,
                fontSize = 12.sp, lineHeight = 16.sp,
                modifier = Modifier.fillMaxWidth().weight(1f, fill = false).padding(horizontal = 10.dp)
                    .background(Color.Black, RoundedCornerShape(8.dp)).padding(10.dp)
                    .verticalScroll(rememberScrollState(), reverseScrolling = true))
        }
    }
}

@Composable
private fun LiveBox(live: String) {
    // The whole turn can be pages long; the last lines say what is happening now.
    val tail = live.lines().takeLast(14).joinToString("\n")
    Column(Modifier.fillMaxWidth().background(Color.Black.copy(alpha = 0.5f), RoundedCornerShape(8.dp)).padding(8.dp)) {
        Text(stringResource(R.string.chat_live_title), color = Color(0xFF66BB6A), fontSize = 11.sp, fontWeight = FontWeight.Bold)
        Text(linksOnly(androidGlyphs(tail), Color(0xFF80D8FF)), color = Color(0xFFB9F6CA), fontFamily = FontFamily.Monospace, fontSize = 11.sp, lineHeight = 14.sp,
            modifier = Modifier.heightIn(max = 220.dp).verticalScroll(rememberScrollState(), reverseScrolling = true))
    }
}

@Composable
private fun MenuCard(c: Chat, choose: (Int) -> Unit, cancel: () -> Unit) {
    Column(Modifier.fillMaxWidth().background(Color(0xFF3A1F1F), RoundedCornerShape(12.dp)).padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp)) {
        MenuOptions(c, choose)
        // Leaving without a choice, as Esc in the terminal.
        Chip(stringResource(R.string.chat_cancel), container = Color.Black.copy(alpha = 0.3f), content = Color(0xFFFF8A80), onClick = cancel)
    }
}

/** A menu's question, its grounds and the choices: in the chat's menu card and in the command panel. */
@Composable
private fun MenuOptions(c: Chat, choose: (Int) -> Unit) {
    // The question and its grounds (tool, command, file) instead of a generic title, as on the Mac.
    Text(c.menuQuestion.ifEmpty { stringResource(R.string.chat_menu_title) }, color = Color(0xFFFF8A80), fontWeight = FontWeight.Bold)
    if (c.menuContext.isNotEmpty()) Text(c.menuContext, color = Color(0xFFE0E0E0), fontFamily = FontFamily.Monospace, fontSize = 11.sp, lineHeight = 14.sp,
        modifier = Modifier.fillMaxWidth().background(Color.Black.copy(alpha = 0.4f), RoundedCornerShape(6.dp)).padding(8.dp)
            .heightIn(max = 220.dp).verticalScroll(rememberScrollState()))
    c.menu.forEachIndexed { i, label ->
        Button(onClick = { choose(i) }, modifier = Modifier.fillMaxWidth(),
            colors = ButtonDefaults.buttonColors(containerColor = Panel, contentColor = Color.White)) {
            Column(Modifier.fillMaxWidth()) {
                Text("${i + 1}. $label")
                c.menuDetails.getOrNull(i)?.takeIf { it.isNotEmpty() }?.let { Text(it, color = Color.White.copy(alpha = 0.6f), fontSize = 12.sp) }
            }
        }
    }
}

/** The Mac takes up to 25 MB per file (MobileServer.maxUpload). */
private const val MAX_UPLOAD = 25L * 1024 * 1024

/** A picked file's display name and size (-1 when the provider does not say). */
private fun fileInfo(context: android.content.Context, uri: android.net.Uri): Pair<String, Long> {
    var name = uri.lastPathSegment?.substringAfterLast('/') ?: "file"
    var size = -1L
    context.contentResolver.query(uri, null, null, null, null)?.use { c ->
        if (c.moveToFirst()) {
            c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 }?.let { c.getString(it) }?.let { name = it }
            c.getColumnIndex(android.provider.OpenableColumns.SIZE).takeIf { it >= 0 && !c.isNull(it) }?.let { size = c.getLong(it) }
        }
    }
    return name to size
}

/** Korean replies are read with a Korean voice, anything else in the phone's language. */
fun speechLocale(s: String): Locale = if (s.any { it in '\uAC00'..'\uD7A3' }) Locale.KOREAN else Locale.getDefault()

/** Markdown symbols are noise on a phone bubble and when spoken. */
fun plainMarkdown(s: String) = s.replace(Regex("""\*\*|`|^#+\s*""", RegexOption.MULTILINE), "")

/** What to say for a reply: its opening (replies lead with the conclusion), without code blocks or tables. */
fun spoken(s: String): String {
    var inCode = false
    val lines = s.lines().filter { l ->
        val t = l.trim()
        if (t.startsWith("```")) { inCode = !inCode; false } else !inCode && !t.startsWith("|")
    }
    return plainMarkdown(lines.joinToString(" ")).replace(Regex("""\(https?://[^)]*\)"""), "").take(400)
}
