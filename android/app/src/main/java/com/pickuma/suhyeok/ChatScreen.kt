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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
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
    val list = rememberLazyListState()
    val lifecycle = LocalLifecycleOwner.current.lifecycle

    // Korean text-to-speech for new replies while "읽어 주기" is on.
    val tts = remember { mutableStateOf<TextToSpeech?>(null) }
    DisposableEffect(Unit) {
        lateinit var engine: TextToSpeech
        engine = TextToSpeech(context) { if (it == TextToSpeech.SUCCESS) { engine.language = Locale.KOREAN; tts.value = engine } }
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
                        c.items.lastOrNull { it.role == "agent" }?.let { tts.value?.speak(spoken(it.text), TextToSpeech.QUEUE_FLUSH, null, "reply") }
                    }
                    seenReplies = replies
                    val grew = c.items.size != chat?.items?.size || c.live != chat?.live
                    // Follow new content only while the end is on screen, so reading older messages is not interrupted.
                    val info = list.layoutInfo
                    val atEnd = info.totalItemsCount == 0 || (info.visibleItemsInfo.lastOrNull()?.index ?: 0) >= info.totalItemsCount - 2
                    chat = c
                    if (grew && atEnd) list.scrollToItem((list.layoutInfo.totalItemsCount - 1).coerceAtLeast(0))
                } catch (e: Unpaired) {
                    onUnpaired(); return@repeatOnLifecycle
                } catch (e: Exception) {
                    notice = "Mac에 연결할 수 없음"
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

    fun send() {
        val text = draft.trim()
        if (text.isEmpty()) return
        scope.launch {
            val ok = runCatching { api.send(agent.id, text) }.getOrDefault(false)
            if (ok) { draft = ""; notice = if (agent.busy) "작업이 끝나면 읽을 거예요" else null }
            else notice = "보내지 못함"
        }
    }

    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().imePadding()) {
        // Header: back, portrait, name, read-aloud toggle.
        Row(Modifier.fillMaxWidth().padding(horizontal = 6.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "뒤로", tint = Color.White) }
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
                    status == "waiting" -> "선택 필요 — 아래에서 골라 주세요"
                    status == "busy" -> "작업 중" + (if (action.isNotEmpty()) " · $action" else "")
                    else -> activity
                }
                Text(line, color = statusColor(status, activity), fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            IconButton(onClick = { readAloud = !readAloud; prefs.readAloud = readAloud; if (!readAloud) tts.value?.stop() }) {
                Icon(if (readAloud) Icons.Filled.VolumeUp else Icons.Filled.VolumeOff, "답변 읽어 주기",
                    tint = if (readAloud) Gold else Color.White.copy(alpha = 0.5f))
            }
        }

        val c = chat
        LazyColumn(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 12.dp), state = list,
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (c == null) item { Text("불러오는 중…", color = Color.White.copy(alpha = 0.6f)) }
            else {
                if (c.items.isEmpty()) item { Text("아직 주고받은 대화가 없음", color = Color.White.copy(alpha = 0.6f)) }
                itemsIndexed(c.items) { _, it -> Bubble(it) }
                c.live?.let { live -> item { LiveBox(live) } }
                if (c.menu.isNotEmpty()) item {
                    MenuCard(c.menu) { i -> scope.launch { if (runCatching { api.choose(agent.id, i) }.getOrDefault(false)) notice = null else notice = "선택하지 못함" } }
                }
            }
        }

        notice?.let { Text(it, color = Color(0xFFFFB74D), fontSize = 12.sp, modifier = Modifier.padding(horizontal = 14.dp)) }

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

        Row(Modifier.fillMaxWidth().padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = draft, onValueChange = { draft = it }, modifier = Modifier.weight(1f),
                placeholder = { Text("${agent.name}에게 지시하기") }, maxLines = 5,
                colors = OutlinedTextFieldDefaults.colors(focusedTextColor = Color.White, unfocusedTextColor = Color.White,
                    focusedBorderColor = Gold, cursorColor = Gold),
            )
            IconButton(onClick = {
                dictate.launch(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                    .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                    .putExtra(RecognizerIntent.EXTRA_LANGUAGE, "ko-KR")
                    .putExtra(RecognizerIntent.EXTRA_PROMPT, "${agent.name}에게 말하기"))
            }) { Icon(Icons.Filled.Mic, "말로 지시", tint = Gold) }
            IconButton(onClick = { showKeys = !showKeys }) {
                Icon(Icons.Filled.Keyboard, "빠른 키", tint = if (showKeys) Gold else Color.White.copy(alpha = 0.5f))
            }
            IconButton(onClick = ::send, enabled = draft.isNotBlank()) {
                Icon(Icons.AutoMirrored.Filled.Send, "보내기", tint = if (draft.isNotBlank()) Gold else Color.Gray)
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
        Text("작업 중 화면 (마지막 14줄)", color = Color(0xFF66BB6A), fontSize = 11.sp, fontWeight = FontWeight.Bold)
        Text(linksOnly(tail, Color(0xFF80D8FF)), color = Color(0xFFB9F6CA), fontFamily = FontFamily.Monospace, fontSize = 11.sp, lineHeight = 14.sp,
            modifier = Modifier.heightIn(max = 220.dp).verticalScroll(rememberScrollState(), reverseScrolling = true))
    }
}

@Composable
private fun MenuCard(options: List<String>, choose: (Int) -> Unit) {
    Column(Modifier.fillMaxWidth().background(Color(0xFF3A1F1F), RoundedCornerShape(12.dp)).padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("선택이 필요해요", color = Color(0xFFFF8A80), fontWeight = FontWeight.Bold)
        options.forEachIndexed { i, label ->
            Button(onClick = { choose(i) }, modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = Panel, contentColor = Color.White)) {
                Text("${i + 1}. $label")
            }
        }
    }
}

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
