package com.pickuma.suhyeok

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch

/** The Mac's new-session sheet on the phone: Claude Code or Codex, a working folder, an optional first instruction. */
@Composable
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
fun NewSessionDialog(api: Api, onDismiss: () -> Unit, onStarted: (String) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var agent by remember { mutableStateOf("Claude") }
    var cwd by remember { mutableStateOf("") }
    var home by remember { mutableStateOf("") }
    var recent by remember { mutableStateOf<List<String>>(emptyList()) }
    var prompt by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    LaunchedEffect(api) {
        runCatching { api.folders() }.onSuccess { (h, f) -> home = h; recent = f; if (cwd.isEmpty()) cwd = short(f.firstOrNull() ?: h, h) }
    }
    // The field shows "~/…" like the Mac's picker; the Mac gets the full path.
    val full = { f: String -> if (f == "~" || f.startsWith("~/")) home + f.removePrefix("~") else f }
    val fieldColors = OutlinedTextFieldDefaults.colors(focusedTextColor = Color.White, unfocusedTextColor = Color.White,
        focusedBorderColor = Gold, cursorColor = Gold)

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.new_session)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    listOf("Claude" to "Claude Code", "Codex" to "Codex").forEachIndexed { i, (value, label) ->
                        SegmentedButton(selected = agent == value, onClick = { agent = value }, shape = SegmentedButtonDefaults.itemShape(i, 2)) {
                            Text(label)
                        }
                    }
                }
                OutlinedTextField(value = cwd, onValueChange = { cwd = it }, singleLine = true, colors = fieldColors,
                    label = { Text(stringResource(R.string.new_session_folder)) },
                    textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp))
                if (recent.isNotEmpty()) {
                    Text(stringResource(R.string.new_session_recent), color = Color.White.copy(alpha = 0.6f), fontSize = 12.sp)
                    Column(Modifier.heightIn(max = 160.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        recent.map { short(it, home) }.forEach { f ->
                            Text(f, color = if (f == cwd) Color.Black else Color.White, fontFamily = FontFamily.Monospace, fontSize = 12.sp,
                                maxLines = 1, overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.fillMaxWidth().background(if (f == cwd) Gold else Panel, RoundedCornerShape(6.dp))
                                    .clickable { cwd = f }.padding(horizontal = 10.dp, vertical = 6.dp))
                        }
                    }
                }
                OutlinedTextField(value = prompt, onValueChange = { prompt = it }, minLines = 2, maxLines = 5, colors = fieldColors,
                    label = { Text(stringResource(R.string.new_session_prompt)) })
                if (api.demo) Text(stringResource(R.string.new_session_demo), color = Color(0xFFFFB74D), fontSize = 12.sp)
                error?.let { Text(it, color = Color(0xFFFFB74D), fontSize = 12.sp) }
            }
        },
        confirmButton = {
            TextButton(enabled = cwd.isNotBlank() && !busy && !api.demo, onClick = {
                busy = true; error = null
                scope.launch {
                    runCatching { api.newSession(agent, full(cwd.trim()), prompt) }
                        .onSuccess { (ok, message) -> if (ok) onStarted(context.getString(R.string.new_session_started)) else error = message.ifEmpty { context.getString(R.string.new_session_failed) } }
                        .onFailure { error = it.describe(context) ?: context.getString(R.string.new_session_failed) }
                    busy = false
                }
            }) { Text(stringResource(R.string.new_session_start), color = Gold) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

private fun short(f: String, home: String) = if (home.isNotEmpty() && f.startsWith(home)) "~" + f.removePrefix(home) else f
