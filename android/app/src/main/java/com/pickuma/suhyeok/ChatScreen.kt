package com.pickuma.suhyeok

import android.app.Activity
import android.content.Intent
import android.speech.RecognizerIntent
import android.speech.tts.TextToSpeech
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
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
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
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

/** Conversation with one agent: its log, the reply being written, menu choices, and an input with dictation. */
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
    /** What was last sent from this screen (the ↑ button brings it back). */
    var sentHere by remember { mutableStateOf<String?>(null) }
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
                    val c = api.chat(agent.id)
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
                delay(if (chat?.live != null || chat?.menu?.isNotEmpty() == true) 1000 else 2000)
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
        scope.launch {
            val ok = runCatching { api.send(agent.id, text) }.getOrDefault(false)
            if (ok) { sentHere = text; draft = ""; attached.clear(); notice = if (agent.busy) context.getString(R.string.chat_queued) else null }
            else notice = context.getString(R.string.send_failed)
        }
    }

    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding()) {
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
                    MenuCard(c) { i -> scope.launch { if (runCatching { api.choose(agent.id, i) }.getOrDefault(false)) notice = null else notice = context.getString(R.string.chat_choose_failed) } }
                }
                c.live?.let { live -> item(key = "live") { LiveBox(live) } }
                val newestFirst = c.items.withIndex().reversed()
                items(newestFirst, key = { "m${it.index}" }) { Bubble(it.value) }
                if (c.items.isEmpty()) item { Text(stringResource(R.string.chat_empty), color = Color.White.copy(alpha = 0.6f)) }
            }
        }

        notice?.let { Text(linksOnly(it, Gold), color = Color(0xFFFFB74D), fontSize = 12.sp, modifier = Modifier.padding(horizontal = 14.dp)) }

        // As in Claude Code and Codex: stop the running turn (Esc), then bring back the last instruction to fix.
        val busyNow = (chat?.status ?: agent.status) == "busy"
        val last = (sentHere ?: chat?.items?.lastOrNull { it.role == "me" && !it.text.startsWith("/") }?.text)
            ?.substringBefore("\n\n(수혁 음성 지시")
        if (busyNow || (draft.isBlank() && last != null)) Row(Modifier.fillMaxWidth().padding(horizontal = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (busyNow) Button(
                onClick = { scope.launch { if (runCatching { api.key(agent.id, "Escape") }.getOrDefault(false)) notice = context.getString(R.string.chat_stopped) } },
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFC62828), contentColor = Color.White),
                modifier = Modifier.height(34.dp),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 14.dp, vertical = 0.dp),
            ) { Text(stringResource(R.string.chat_stop), fontSize = 13.sp, fontWeight = FontWeight.Bold) }
            if (draft.isBlank() && last != null) OutlinedButton(onClick = { draft = last }, modifier = Modifier.height(34.dp),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 12.dp, vertical = 0.dp)) {
                Text(stringResource(R.string.chat_recall), color = Color.White, fontSize = 13.sp)
            }
        }

        // Quick keys for menus and the terminal: shown with a menu on screen or on request.
        if (showKeys || chat?.menu?.isNotEmpty() == true) Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 10.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            listOf("Esc" to "Escape", "↑" to "Up", "↓" to "Down", "⏎" to "Enter", "1" to "1", "2" to "2", "3" to "3").forEach { (label, key) ->
                OutlinedButton(onClick = { scope.launch { runCatching { api.key(agent.id, key) } } },
                    modifier = Modifier.height(32.dp),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 12.dp, vertical = 0.dp)) {
                    Text(label, color = Color.White, fontSize = 13.sp)
                }
            }
        }

        // Files waiting to go out with the message; ✕ leaves one out (it stays on the Mac).
        if (attached.isNotEmpty() || uploading > 0) Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            attached.forEach { file ->
                Row(Modifier.background(Panel, RoundedCornerShape(8.dp)).padding(start = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(file.first, color = Color.White, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.widthIn(max = 160.dp))
                    IconButton(onClick = { attached.remove(file) }, modifier = Modifier.size(28.dp)) {
                        Icon(Icons.Filled.Close, stringResource(R.string.attach_remove), tint = Color.White.copy(alpha = 0.6f), modifier = Modifier.size(14.dp))
                    }
                }
            }
            if (uploading > 0) Text(stringResource(R.string.attach_uploading, uploading), color = Gold, fontSize = 12.sp)
        }

        Row(Modifier.fillMaxWidth().padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { pick.launch("*/*") }) { Icon(Icons.Filled.AttachFile, stringResource(R.string.attach), tint = Gold) }
            OutlinedTextField(
                value = draft, onValueChange = { draft = it }, modifier = Modifier.weight(1f),
                placeholder = { Text(stringResource(R.string.chat_placeholder, agent.name)) }, maxLines = 5,
                colors = OutlinedTextFieldDefaults.colors(focusedTextColor = Color.White, unfocusedTextColor = Color.White,
                    focusedBorderColor = Gold, cursorColor = Gold),
            )
            val dictatePrompt = stringResource(R.string.chat_dictate_prompt, agent.name)
            IconButton(onClick = {
                dictate.launch(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                    .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                    .putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toLanguageTag())
                    .putExtra(RecognizerIntent.EXTRA_PROMPT, dictatePrompt))
            }) { Icon(Icons.Filled.Mic, stringResource(R.string.dictate), tint = Gold) }
            IconButton(onClick = { showKeys = !showKeys }) {
                Icon(Icons.Filled.Keyboard, stringResource(R.string.quick_keys), tint = if (showKeys) Gold else Color.White.copy(alpha = 0.5f))
            }
            val ready = (draft.isNotBlank() || attached.isNotEmpty()) && uploading == 0
            IconButton(onClick = ::send, enabled = ready) {
                Icon(Icons.AutoMirrored.Filled.Send, stringResource(R.string.send), tint = if (ready) Gold else Color.Gray)
            }
        }
    }
}

@Composable
private fun Bubble(item: ChatItem) {
    when (item.role) {
        "me" -> Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
            Text(inline(item.text, linkColor = Color(0xFF0D2A8A)), color = Color.Black, modifier = Modifier.widthIn(max = 320.dp)
                .background(Gold, RoundedCornerShape(12.dp)).padding(10.dp))
        }
        "agent" -> Box(Modifier.fillMaxWidth().background(Panel, RoundedCornerShape(12.dp)).padding(10.dp)) { Markdown(item.text) }
        else -> Text("🔧 " + item.text, color = Color.White.copy(alpha = 0.5f), fontSize = 12.sp, maxLines = 2)
    }
}

@Composable
private fun LiveBox(live: String) {
    // The whole turn can be pages long; the last lines say what is happening now.
    val tail = live.lines().takeLast(14).joinToString("\n")
    Column(Modifier.fillMaxWidth().background(Color.Black.copy(alpha = 0.5f), RoundedCornerShape(8.dp)).padding(8.dp)) {
        Text(stringResource(R.string.chat_live_title), color = Color(0xFF66BB6A), fontSize = 11.sp, fontWeight = FontWeight.Bold)
        Text(linksOnly(tail, Color(0xFF80D8FF)), color = Color(0xFFB9F6CA), fontFamily = FontFamily.Monospace, fontSize = 11.sp, lineHeight = 14.sp,
            modifier = Modifier.heightIn(max = 220.dp).verticalScroll(rememberScrollState(), reverseScrolling = true))
    }
}

@Composable
private fun MenuCard(c: Chat, choose: (Int) -> Unit) {
    Column(Modifier.fillMaxWidth().background(Color(0xFF3A1F1F), RoundedCornerShape(12.dp)).padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp)) {
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
