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
    var confirm by remember { mutableStateOf<Pair<String, String>?>(null) }   // action to (question, button)
    var renaming by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf(agent.title) }

    fun run(action: String, text: String? = null, done: String) {
        onDismiss()
        scope.launch {
            val (ok, note) = runCatching { api.action(agent.id, action, text) }.getOrElse { false to (it.message ?: "실패") }
            onResult(if (ok) note.ifEmpty { done } else "${agent.name}: ${note.ifEmpty { "하지 못함" }}")
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
            Item("💬", "대화하기") { onDismiss(); onOpen() }
            Item("✏️", "세션 이름 수정…") { renaming = true }
            Item("🧬", "클론으로 새 에이전트 만들기", enabled = agent.canClone) { run("clone", done = "클론을 만드는 중") }
            Item("🧹", "대화 새로 시작 (/clear)", enabled = agent.kind == "Claude" && agent.canSend) {
                confirm = "clear" to "${agent.name}의 대화를 비우고 새로 시작할까요? 이전 대화는 Mac의 '최근 대화'에서 다시 열 수 있어요."
            }
            if (!agent.hosted) Item("🏠", "수혁으로 옮기기", enabled = agent.canClone) {
                confirm = "migrate" to "${agent.name}을(를) 수혁 터미널로 옮길까요? 원래 터미널의 세션은 종료돼요."
            }
            HorizontalDivider(color = Color.White.copy(alpha = 0.1f), modifier = Modifier.padding(vertical = 6.dp))
            Item("⛔", "세션 종료…", color = Color(0xFFFF6B6B)) {
                confirm = "end" to "${agent.name}의 세션을 종료할까요?"
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
                    run(action, done = mapOf("clear" to "새 대화를 시작함", "migrate" to "옮기는 중", "end" to "종료함")[action] ?: "완료")
                }) { Text(if (action == "end") "종료" else "확인", color = if (action == "end") Color(0xFFFF6B6B) else Gold) }
            },
            dismissButton = { TextButton(onClick = { confirm = null }) { Text("취소") } },
        )
    }
    if (renaming) AlertDialog(
        onDismissRequest = { renaming = false },
        title = { Text("세션 이름 수정") },
        text = { OutlinedTextField(value = name, onValueChange = { name = it }, singleLine = true,
            placeholder = { Text("비우면 원래 제목으로") }) },
        confirmButton = { TextButton(onClick = { renaming = false; run("rename", name.trim(), done = "이름을 바꿈") }) { Text("저장", color = Gold) } },
        dismissButton = { TextButton(onClick = { renaming = false }) { Text("취소") } },
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
