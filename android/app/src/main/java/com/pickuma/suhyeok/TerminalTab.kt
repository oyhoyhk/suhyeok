package com.pickuma.suhyeok

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** The Mac's terminals on 수혁's own tmux server: pick one, read its screen, type into it, or start a new shell. */
@Composable
fun TerminalTab(api: Api, onUnpaired: () -> Unit) {
    var open by rememberSaveable { mutableStateOf<String?>(null) }
    val name = open
    if (name == null) TerminalList(api, onUnpaired) { open = it }
    else {
        BackHandler { open = null }
        TerminalView(api, name, onUnpaired) { open = null }
    }
}

@Composable
private fun TerminalList(api: Api, onUnpaired: () -> Unit, onOpen: (String) -> Unit) {
    var list by remember { mutableStateOf<List<Terminal>?>(null) }
    var failed by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(api) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                try { list = api.terminals(); failed = false } catch (e: Unpaired) { onUnpaired(); return@repeatOnLifecycle } catch (_: Exception) { failed = true }
                delay(3000)
            }
        }
    }
    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(start = 18.dp, end = 6.dp, top = 10.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.tab_terminal), color = Gold, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                Text(stringResource(R.string.term_subtitle), color = Color.White.copy(alpha = 0.6f), fontSize = 12.sp)
            }
            if (!api.demo) IconButton(onClick = { scope.launch { runCatching { api.termNew() }.getOrNull()?.let(onOpen) } }) {
                Icon(Icons.Filled.Add, stringResource(R.string.term_new), tint = Gold)
            }
        }
        val l = list
        when {
            api.demo -> Hint(stringResource(R.string.term_demo))
            l == null -> Hint(stringResource(if (failed) R.string.term_unavailable else R.string.loading))
            l.isEmpty() -> Hint(stringResource(R.string.term_empty))
            else -> LazyColumn(Modifier.fillMaxSize()) {
                items(l, key = { it.name }) { t ->
                    Row(Modifier.fillMaxWidth().clickable { onOpen(t.name) }.padding(horizontal = 18.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        if (t.character.isNotEmpty()) Portrait(api, t.character, t.agentName, 38.dp)
                        else Box(Modifier.width(38.dp), contentAlignment = Alignment.Center) { Icon(Icons.Filled.Terminal, null, tint = Gold) }
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(t.agentName.ifEmpty { t.title.ifEmpty { t.name } }, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Bold,
                                maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(t.kind + " · " + t.cwd.replace(Regex("^/Users/[^/]+"), "~"), color = Color.White.copy(alpha = 0.6f), fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Hint(s: String) = Text(s, color = Color.White.copy(alpha = 0.6f), modifier = Modifier.padding(18.dp))

@Composable
private fun TerminalView(api: Api, name: String, onUnpaired: () -> Unit, onBack: () -> Unit) {
    var screen by remember { mutableStateOf<TermScreen?>(null) }
    var gone by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    val list = rememberLazyListState()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    // Faster than the other tabs: you are watching what you typed come back.
    LaunchedEffect(name) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                try { val s = api.term(name); gone = s == null; if (s != null) screen = s } catch (e: Unpaired) { onUnpaired(); return@repeatOnLifecycle } catch (_: Exception) {}
                delay(800)
            }
        }
    }
    // A fresh shell is mostly empty rows below its prompt: stop at the cursor or the last text, whichever is lower.
    val lines = remember(screen) {
        screen?.let { s ->
            val cursor = s.lines.size - s.height + s.cy
            val text = s.lines.indexOfLast { ansi(it).text.isNotBlank() }
            s.lines.take(maxOf(cursor, text) + 1).map(::ansi)
        }.orEmpty()
    }
    // Follow the bottom, as a terminal does.
    LaunchedEffect(lines.size) { if (lines.isNotEmpty()) list.scrollToItem(lines.size - 1) }
    fun key(k: String) = scope.launch { runCatching { api.termKey(name, k) } }

    Column(Modifier.fillMaxSize().statusBarsPadding().imePadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 6.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back), tint = Color.White) }
            Text(name, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 15.sp, modifier = Modifier.weight(1f))
            if (gone) Text(stringResource(R.string.term_gone), color = Color(0xFFFFB74D), fontSize = 12.sp, modifier = Modifier.padding(end = 10.dp))
        }
        // Lines keep their width (scroll sideways) so tables and boxes stay aligned.
        Box(Modifier.weight(1f).fillMaxWidth().background(Color(0xFF0B0E1A)).horizontalScroll(rememberScrollState())) {
            LazyColumn(Modifier.fillMaxSize().padding(6.dp), state = list) {
                items(lines.size) { i ->
                    Text(lines[i], color = Color(0xFFD8DEE9), fontFamily = FontFamily.Monospace, fontSize = 11.sp, lineHeight = 14.sp,
                        softWrap = false, maxLines = 1)
                }
            }
        }
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 8.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            listOf("Esc" to "Escape", "Tab" to "Tab", "^C" to "C-c", "↑" to "Up", "↓" to "Down", "←" to "Left", "→" to "Right",
                "⌫" to "BSpace", "⏎" to "Enter").forEach { (label, k) ->
                OutlinedButton(onClick = { key(k) }, modifier = Modifier.height(32.dp), contentPadding = PaddingValues(horizontal = 12.dp, vertical = 0.dp)) {
                    Text(label, color = Color.White, fontSize = 13.sp)
                }
            }
        }
        // Send types the text and presses Enter, as a command line expects.
        fun send() {
            val t = draft; draft = ""
            scope.launch { runCatching { if (t.isNotEmpty()) api.termType(name, t); api.termKey(name, "Enter") } }
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = draft, onValueChange = { draft = it }, modifier = Modifier.weight(1f), singleLine = true,
                placeholder = { Text(stringResource(R.string.term_placeholder)) },
                textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace, fontSize = 14.sp),
                // Commands are ASCII: ask for a Latin keyboard without corrections.
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, imeAction = ImeAction.Send, autoCorrectEnabled = false),
                keyboardActions = KeyboardActions(onSend = { send() }),
                colors = OutlinedTextFieldDefaults.colors(focusedTextColor = Color.White, unfocusedTextColor = Color.White,
                    focusedBorderColor = Gold, cursorColor = Gold),
            )
            IconButton(onClick = ::send) { Icon(Icons.AutoMirrored.Filled.Send, stringResource(R.string.send), tint = Gold) }
        }
    }
}

private val basic = longArrayOf(0xFF000000, 0xFFE06C75, 0xFF98C379, 0xFFE5C07B, 0xFF61AFEF, 0xFFC678DD, 0xFF56B6C2, 0xFFD8DEE9,
    0xFF5C6370, 0xFFFF7A85, 0xFFB5E890, 0xFFFFD68A, 0xFF82C4FF, 0xFFE09CFF, 0xFF7FDCE6, 0xFFFFFFFF)

/** xterm 256-color palette: 16 basic, a 6×6×6 cube, then 24 grays. */
private fun color256(n: Int): Color = when {
    n < 16 -> Color(basic[n])
    n < 232 -> { val i = n - 16; val v = { c: Int -> if (c == 0) 0 else 55 + c * 40 }; Color(v(i / 36), v(i / 6 % 6), v(i % 6)) }
    else -> { val g = 8 + (n - 232) * 10; Color(g, g, g) }
}

/** One line of `tmux capture-pane -e` output: SGR color and bold escapes become styles, other escapes are dropped. */
fun ansi(line: String): AnnotatedString = buildAnnotatedString {
    var fg: Color? = null; var bg: Color? = null; var bold = false; var dim = false
    var i = 0
    val run = StringBuilder()
    fun flush() {
        if (run.isEmpty()) return
        withStyle(SpanStyle(color = (fg ?: Color.Unspecified).let { if (dim && it != Color.Unspecified) it.copy(alpha = 0.6f) else it },
            background = bg ?: Color.Unspecified, fontWeight = if (bold) FontWeight.Bold else null)) { append(run.toString()) }
        run.clear()
    }
    while (i < line.length) {
        val c = line[i]
        if (c == '\u001B' && i + 1 < line.length && line[i + 1] == '[') {
            var j = i + 2
            while (j < line.length && line[j] !in '@'..'~') j++
            if (j < line.length && line[j] == 'm') {
                flush()
                val p = line.substring(i + 2, j).split(';').map { it.toIntOrNull() ?: 0 }
                var k = 0
                while (k < p.size) {
                    when (val n = p[k]) {
                        0 -> { fg = null; bg = null; bold = false; dim = false }
                        1 -> bold = true
                        2 -> dim = true
                        22 -> { bold = false; dim = false }
                        in 30..37 -> fg = color256(n - 30)
                        in 90..97 -> fg = color256(n - 90 + 8)
                        39 -> fg = null
                        in 40..47 -> bg = color256(n - 40)
                        in 100..107 -> bg = color256(n - 100 + 8)
                        49 -> bg = null
                        38, 48 -> {
                            val c2 = when (p.getOrNull(k + 1)) {
                                5 -> p.getOrNull(k + 2)?.let(::color256).also { k += 2 }
                                2 -> if (k + 4 < p.size) Color(p[k + 2], p[k + 3], p[k + 4]).also { k += 4 } else null
                                else -> null
                            }
                            if (n == 38) fg = c2 else bg = c2
                        }
                    }
                    k++
                }
            }
            i = j + 1
            continue
        }
        if (c != '\u001B') run.append(c)
        i++
    }
    flush()
}
