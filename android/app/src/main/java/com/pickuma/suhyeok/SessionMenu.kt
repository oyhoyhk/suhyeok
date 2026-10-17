package com.pickuma.suhyeok

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch

/**
 * Long-press menu for an agent, the phone's version of the Mac's right-click menu (AgentMenu): talk, rename,
 * clone, start over (/clear), move into 수혁, end. Actions that cannot be undone ask first.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionMenu(api: Api, agent: Agent, onOpen: () -> Unit, onDismiss: () -> Unit, onResult: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var confirm by remember { mutableStateOf<Pair<String, String>?>(null) }   // action to (question, button)
    var renaming by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf(agent.title) }

    fun run(action: String, text: String? = null, done: String) {
        onDismiss()
        scope.launch {
            val (ok, note) = runCatching { api.action(agent.id, action, text) }.getOrElse { false to (it.describe(context) ?: context.getString(R.string.action_failed)) }
            onResult(if (ok) note.ifEmpty { done } else "${agent.name}: ${note.ifEmpty { context.getString(R.string.action_not_done) }}")
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = Panel) {
        Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(bottom = 12.dp)) {
            Row(Modifier.padding(horizontal = 20.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                NameTag(agent.name, agent.cwd)
                Spacer(Modifier.width(8.dp))
                Text(agent.title, color = Color.White, fontSize = 14.sp, maxLines = 1)
            }
            HorizontalDivider(color = Color.White.copy(alpha = 0.1f), modifier = Modifier.padding(vertical = 6.dp))
            Item("💬", stringResource(R.string.session_chat)) { onDismiss(); onOpen() }
            Item("✏️", stringResource(R.string.session_rename)) { renaming = true }
            Item("🧬", stringResource(R.string.session_clone), enabled = agent.canClone) { run("clone", done = context.getString(R.string.done_clone)) }
            Item("🧹", stringResource(R.string.session_clear), enabled = agent.kind == "Claude" && agent.canSend) {
                confirm = "clear" to context.getString(R.string.session_clear_question, agent.name)
            }
            if (!agent.hosted) Item("🏠", stringResource(R.string.session_migrate), enabled = agent.canClone) {
                confirm = "migrate" to context.getString(R.string.session_migrate_question, agent.name)
            }
            HorizontalDivider(color = Color.White.copy(alpha = 0.1f), modifier = Modifier.padding(vertical = 6.dp))
            Item("⛔", stringResource(R.string.session_end), color = Color(0xFFFF6B6B)) {
                confirm = "end" to context.getString(R.string.session_end_question, agent.name)
            }
        }
    }

    confirm?.let { (action, question) ->
        AlertDialog(
            onDismissRequest = { confirm = null },
            text = { Text(question) },
            confirmButton = {
                TextButton(onClick = {
                    confirm = null
                    run(action, done = context.getString(mapOf("clear" to R.string.done_clear, "migrate" to R.string.done_migrate,
                        "end" to R.string.done_end)[action] ?: R.string.done_generic))
                }) { Text(stringResource(if (action == "end") R.string.session_end_confirm else R.string.ok), color = if (action == "end") Color(0xFFFF6B6B) else Gold) }
            },
            dismissButton = { TextButton(onClick = { confirm = null }) { Text(stringResource(R.string.cancel)) } },
        )
    }
    if (renaming) AlertDialog(
        onDismissRequest = { renaming = false },
        title = { Text(stringResource(R.string.rename_title)) },
        text = { OutlinedTextField(value = name, onValueChange = { name = it }, singleLine = true,
            placeholder = { Text(stringResource(R.string.rename_placeholder)) }) },
        confirmButton = { TextButton(onClick = { renaming = false; run("rename", name.trim(), done = context.getString(R.string.done_rename)) }) { Text(stringResource(R.string.save), color = Gold) } },
        dismissButton = { TextButton(onClick = { renaming = false }) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
private fun Item(icon: String, label: String, enabled: Boolean = true, color: Color = Color.White, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(enabled = enabled, onClick = onClick).padding(horizontal = 20.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Text(icon, fontSize = 18.sp)
        Spacer(Modifier.width(14.dp))
        Text(label, color = if (enabled) color else Color.White.copy(alpha = 0.3f), fontSize = 16.sp,
            fontWeight = if (color != Color.White) FontWeight.Bold else null)
    }
}
