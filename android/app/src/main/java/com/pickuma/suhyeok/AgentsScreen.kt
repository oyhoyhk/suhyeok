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
import androidx.compose.foundation.lazy.rememberLazyListState
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.launch
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
fun AgentsScreen(api: Api, prefs: Prefs, openRequest: String?, onOpen: (Agent) -> Unit, onUnpaired: () -> Unit, onRepair: () -> Unit) {
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
    // Kept here, not in the menu: the menu closes before Android answers the permission request.
    val context = LocalContext.current
    var notifyOn by remember { mutableStateOf(prefs.notify) }
    val enable = { prefs.notify = true; notifyOn = true; NotifyService.start(context) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { if (it) enable() }
    val setNotify: (Boolean) -> Unit = { want ->
        when {
            !want -> { prefs.notify = false; notifyOn = false; NotifyService.stop(context) }
            android.os.Build.VERSION.SDK_INT >= 33 -> permission.launch(android.Manifest.permission.POST_NOTIFICATIONS)
            else -> enable()
        }
    }
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
                    NotifyMenuItems(prefs, notifyOn, setNotify) { menu = false }
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
        UpdateBanner(api)
        // Opened from a notification: go straight to that agent once it is in the list.
        LaunchedEffect(openRequest, agents) {
            openRequest?.let { id -> agents?.firstOrNull { it.id == id }?.let(onOpen) }
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
        // New entries above (an agent that now needs a choice) would otherwise stay above the screen, because the
        // list keeps the item you were looking at in place. Near the top, show them.
        val listState = rememberLazyListState()
        val head = groups.firstOrNull()?.let { (t, m) -> t + m.joinToString { it.id } }
        LaunchedEffect(head) { if (listState.firstVisibleItemIndex <= 3) listState.scrollToItem(0) }
        LazyColumn(Modifier.fillMaxSize(), state = listState, verticalArrangement = Arrangement.spacedBy(2.dp)) {
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

/** A newer phone app published on the Mac (android/publish.sh): checked on open and every 30 minutes. */
@Composable
private fun UpdateBanner(api: Api) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var release by remember { mutableStateOf<Release?>(null) }
    var progress by remember { mutableStateOf<Float?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle

    LaunchedEffect(api) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                runCatching { api.latestApp() }.getOrNull()
                    ?.let { release = if (it.code > BuildConfig.VERSION_CODE) it else null }
                delay(30 * 60 * 1000L)
            }
        }
    }
    val r = release ?: return
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 6.dp)
            .background(Gold.copy(alpha = 0.15f), RoundedCornerShape(10.dp))
            .border(1.dp, Gold.copy(alpha = 0.6f), RoundedCornerShape(10.dp))
            .clickable(enabled = progress == null) {
                scope.launch {
                    message = null
                    try {
                        val file = Updater.file(context, r.code)
                        if (!file.exists()) {
                            progress = 0f
                            api.downloadApp(r, file) { progress = it }
                        }
                        progress = null
                        if (!Updater.install(context, file)) message = "'이 출처 허용'을 켠 뒤 다시 누르기"
                    } catch (e: Exception) {
                        progress = null
                        Updater.file(context, r.code).delete()
                        message = e.message
                    }
                }
            }
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text("새 버전 ${r.name}", color = Gold, fontWeight = FontWeight.Bold, fontSize = 14.sp)
            Text(message ?: progress?.let { "받는 중 ${(it * 100).toInt()}%" } ?: (r.notes.ifEmpty { "눌러서 업데이트" }),
                color = Color.White.copy(alpha = 0.75f), fontSize = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.width(8.dp))
        Text(if (progress != null) "…" else "업데이트", color = Color.Black, fontWeight = FontWeight.Bold, fontSize = 13.sp,
            modifier = Modifier.background(Gold, RoundedCornerShape(50)).padding(horizontal = 12.dp, vertical = 6.dp))
    }
}

/** ⋮ menu entries for background notifications: on/off, and which kinds. */
@Composable
private fun NotifyMenuItems(prefs: Prefs, on: Boolean, setOn: (Boolean) -> Unit, close: () -> Unit) {
    var asking by remember { mutableStateOf(prefs.notifyAsking) }
    var done by remember { mutableStateOf(prefs.notifyDone) }
    DropdownMenuItem(text = { Text(if (on) "백그라운드 알림 끄기" else "백그라운드 알림 켜기") }, onClick = { close(); setOn(!on) })
    DropdownMenuItem(text = { Text((if (asking) "✓ " else "   ") + "알림: 선택 필요") },
        onClick = { asking = !asking; prefs.notifyAsking = asking })
    DropdownMenuItem(text = { Text((if (done) "✓ " else "   ") + "알림: 작업 완료") },
        onClick = { done = !done; prefs.notifyDone = done })
}
