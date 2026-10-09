package com.pickuma.suhyeok

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import coil.compose.AsyncImage
import kotlinx.coroutines.delay

/** Agents on the Mac, the ones that need you first: stopped on a question, then finished and waiting. */
@Composable
fun AgentsScreen(api: Api, onOpen: (Agent) -> Unit, onUnpaired: () -> Unit, onRepair: () -> Unit) {
    var agents by remember { mutableStateOf<List<Agent>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle

    // Poll only while the app is on screen.
    LaunchedEffect(api) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                try {
                    agents = api.state(); error = null
                } catch (e: Unpaired) {
                    onUnpaired(); return@repeatOnLifecycle
                } catch (e: Exception) {
                    error = "Mac에 연결할 수 없음 — 수혁이 켜져 있고 '모바일 접속'이 켜져 있는지 확인"
                }
                delay(3000)
            }
        }
    }

    var menu by remember { mutableStateOf(false) }
    var confirm by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(start = 18.dp, end = 4.dp, top = 10.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("수혁", color = Gold, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                Text((if (error == null) "● " else "○ ") + api.base.removePrefix("https://").removePrefix("http://"),
                    color = if (error == null) Color(0xFF66BB6A) else Color(0xFFFFB74D), fontSize = 12.sp)
            }
            Box {
                IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, "메뉴", tint = Color.White.copy(alpha = 0.7f)) }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("다른 Mac에 연결 / 연결 끊기") }, onClick = { menu = false; confirm = true })
                }
            }
        }
        if (confirm) AlertDialog(
            onDismissRequest = { confirm = false },
            title = { Text("연결을 끊을까요?") },
            text = { Text("이 폰의 연결 정보를 지움. 다시 쓰려면 Mac에서 QR을 찍고 허용해야 함.") },
            confirmButton = { TextButton(onClick = { confirm = false; onRepair() }) { Text("끊기", color = Color(0xFFFF6B6B)) } },
            dismissButton = { TextButton(onClick = { confirm = false }) { Text("취소") } },
        )
        error?.let {
            Text(it, color = Color(0xFFFFB74D), fontSize = 13.sp, modifier = Modifier.padding(horizontal = 18.dp, vertical = 4.dp))
        }
        val list = agents
        if (list == null) {
            Text("불러오는 중…", color = Color.White.copy(alpha = 0.6f), modifier = Modifier.padding(18.dp))
            return@Column
        }
        val groups = listOf(
            "선택 필요" to list.filter { it.asking },
            "작업 중" to list.filter { it.busy },
            "다음 지시 대기" to list.filter { !it.asking && !it.busy && it.activity == "대기 중" },
            "휴식 중" to list.filter { !it.asking && !it.busy && it.activity != "대기 중" },
        ).filter { it.second.isNotEmpty() }
        LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            groups.forEach { (title, members) ->
                item(key = "h-$title") {
                    Text("$title ${members.size}", color = if (title == "선택 필요") Color(0xFFFF6B6B) else Gold,
                        fontWeight = FontWeight.Bold, fontSize = 13.sp,
                        modifier = Modifier.padding(start = 18.dp, top = 14.dp, bottom = 4.dp))
                }
                items(members.sortedByDescending { it.last }, key = { it.id }) { a -> AgentRow(api, a) { onOpen(a) } }
            }
        }
    }
}

@Composable
private fun AgentRow(api: Api, a: Agent, onClick: () -> Unit) {
    val ring = statusColor(a.status, a.activity)
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 18.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box {
            Portrait(api, a.character, a.name, 46.dp, ring)
            if (a.asking) Text("!", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 12.sp,
                modifier = Modifier.align(Alignment.TopEnd).background(Color(0xFFE53935), CircleShape).padding(horizontal = 6.dp))
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                NameTag(a.name, a.cwd)
                Spacer(Modifier.width(6.dp))
                Text(a.title, color = Color.White, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            val sub = when {
                a.asking -> "선택지에서 멈춤 — 눌러서 답하기"
                a.busy && a.action.isNotEmpty() -> a.action
                else -> a.activity + " · " + a.project
            }
            Text(sub, color = Color.White.copy(alpha = 0.6f), fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.width(8.dp))
        Text(ago(a.last), color = Color.White.copy(alpha = 0.5f), fontSize = 11.sp)
    }
}

fun ago(epochSeconds: Double): String {
    if (epochSeconds <= 0) return ""
    val m = ((System.currentTimeMillis() / 1000.0 - epochSeconds) / 60).toInt().coerceAtLeast(0)
    return when {
        m < 1 -> "방금"
        m < 60 -> "${m}분 전"
        m < 1440 -> "${m / 60}시간 전"
        else -> "${m / 1440}일 전"
    }
}
