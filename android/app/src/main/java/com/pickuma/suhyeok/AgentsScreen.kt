package com.pickuma.suhyeok

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.FloatingActionButton
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
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
fun AgentsScreen(api: Api, openRequest: String?, onOpen: (Agent) -> Unit, onUnpaired: () -> Unit) {
    var agents by remember { mutableStateOf<List<Agent>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val unreachable = stringResource(R.string.agents_unreachable)

    // Poll only while the app is on screen.
    LaunchedEffect(api) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                try {
                    agents = api.state(); error = null
                } catch (e: Unpaired) {
                    onUnpaired(); return@repeatOnLifecycle
                } catch (e: Exception) {
                    error = unreachable
                }
                delay(3000)
            }
        }
    }

    var menuFor by remember { mutableStateOf<Agent?>(null) }
    var result by remember { mutableStateOf<String?>(null) }
    var creating by remember { mutableStateOf(false) }
    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            Row(Modifier.fillMaxWidth().padding(start = 18.dp, end = 4.dp, top = 10.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(stringResource(R.string.app_name), color = Gold, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                    Text(if (api.demo) stringResource(R.string.demo_subtitle) else (if (error == null) "● " else "○ ") + api.base.removePrefix("https://").removePrefix("http://"),
                        color = if (error == null) Color(0xFF66BB6A) else Color(0xFFFFB74D), fontSize = 12.sp)
                }
            }
            error?.let {
                Text(it, color = Color(0xFFFFB74D), fontSize = 13.sp, modifier = Modifier.padding(horizontal = 18.dp, vertical = 4.dp))
            }
            result?.let {
                Text(it, color = Color(0xFF66BB6A), fontSize = 13.sp, modifier = Modifier.padding(horizontal = 18.dp, vertical = 4.dp))
                LaunchedEffect(it) { delay(4000); result = null }
            }
            menuFor?.let { a -> SessionMenu(api, a, onOpen = { onOpen(a) }, onDismiss = { menuFor = null }, onResult = { result = it }) }
            if (BuildConfig.SELF_UPDATE) UpdateBanner(api)
            // Opened from a notification: go straight to that agent once it is in the list.
            LaunchedEffect(openRequest, agents) {
                openRequest?.let { id -> agents?.firstOrNull { it.id == id }?.let(onOpen) }
            }
            val list = agents
            if (list == null) {
                Text(stringResource(R.string.loading), color = Color.White.copy(alpha = 0.6f), modifier = Modifier.padding(18.dp))
                return@Column
            }
            if (list.isEmpty()) Text(stringResource(R.string.agents_empty), color = Color.White.copy(alpha = 0.6f), modifier = Modifier.padding(18.dp))
            val groups = listOf(
                R.string.needs_choice to list.filter { it.asking },
                R.string.working to list.filter { it.busy },
                R.string.group_waiting to list.filter { !it.asking && !it.busy && it.waitingForNext },
                R.string.group_resting to list.filter { !it.asking && !it.busy && !it.waitingForNext },
            ).filter { it.second.isNotEmpty() }
            // New entries above (an agent that now needs a choice) would otherwise stay above the screen, because the
            // list keeps the item you were looking at in place. Near the top, show them.
            val listState = rememberLazyListState()
            val head = groups.firstOrNull()?.let { (t, m) -> "$t" + m.joinToString { it.id } }
            LaunchedEffect(head) { if (listState.firstVisibleItemIndex <= 3) listState.scrollToItem(0) }
            // Room at the bottom so the ＋ button does not cover the last agent.
            LazyColumn(Modifier.fillMaxSize(), state = listState, verticalArrangement = Arrangement.spacedBy(2.dp),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 88.dp)) {
                groups.forEach { (title, members) ->
                    item(key = "h-$title") {
                        Text("${stringResource(title)} ${members.size}", color = if (title == R.string.needs_choice) Color(0xFFFF6B6B) else Gold,
                            fontWeight = FontWeight.Bold, fontSize = 13.sp,
                            modifier = Modifier.padding(start = 18.dp, top = 14.dp, bottom = 4.dp))
                    }
                    items(members.sortedByDescending { it.last }, key = { it.id }) { a -> AgentRow(api, a, { menuFor = a }) { onOpen(a) } }
                }
            }
        }
        // New session, bottom right (the Mac's ＋ in the sidebar).
        FloatingActionButton(onClick = { creating = true }, containerColor = Gold, contentColor = Color.Black,
            modifier = Modifier.align(Alignment.BottomEnd).padding(18.dp)) {
            Icon(Icons.Filled.Add, stringResource(R.string.new_session))
        }
        if (creating) NewSessionDialog(api, onDismiss = { creating = false }) { creating = false; result = it }
    }
}

@Composable
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
private fun AgentRow(api: Api, a: Agent, onLongClick: () -> Unit, onClick: () -> Unit) {
    val haptic = androidx.compose.ui.platform.LocalHapticFeedback.current
    val ring = statusColor(a.status, a.activity)
    Row(
        // Long press: the same options as right-clicking the agent on the Mac.
        Modifier.fillMaxWidth().combinedClickable(onClick = onClick, onLongClick = {
            haptic.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.LongPress); onLongClick()
        }).padding(horizontal = 18.dp, vertical = 8.dp),
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
                a.asking -> stringResource(R.string.agent_asking)
                a.busy && a.action.isNotEmpty() -> a.action
                else -> a.activity + " · " + a.project
            }
            Text(sub, color = Color.White.copy(alpha = 0.6f), fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.width(8.dp))
        Text(ago(a.last), color = Color.White.copy(alpha = 0.5f), fontSize = 11.sp)
    }
}

@Composable
fun ago(epochSeconds: Double): String {
    if (epochSeconds <= 0) return ""
    val r = LocalContext.current.resources
    val m = ((System.currentTimeMillis() / 1000.0 - epochSeconds) / 60).toInt().coerceAtLeast(0)
    return when {
        m < 1 -> r.getString(R.string.ago_now)
        m < 60 -> r.getQuantityString(R.plurals.ago_minutes, m, m)
        m < 1440 -> r.getQuantityString(R.plurals.ago_hours, m / 60, m / 60)
        else -> r.getQuantityString(R.plurals.ago_days, m / 1440, m / 1440)
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
                        if (!Updater.install(context, file)) message = context.getString(R.string.update_allow_source)
                    } catch (e: Exception) {
                        progress = null
                        Updater.file(context, r.code).delete()
                        message = e.describe(context)
                    }
                }
            }
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(stringResource(R.string.update_new, r.name), color = Gold, fontWeight = FontWeight.Bold, fontSize = 14.sp)
            Text(message ?: progress?.let { stringResource(R.string.update_downloading, (it * 100).toInt()) } ?: (r.notes.ifEmpty { stringResource(R.string.update_tap) }),
                color = Color.White.copy(alpha = 0.75f), fontSize = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.width(8.dp))
        Text(if (progress != null) "…" else stringResource(R.string.update_button), color = Color.Black, fontWeight = FontWeight.Bold, fontSize = 13.sp,
            modifier = Modifier.background(Gold, RoundedCornerShape(50)).padding(horizontal = 12.dp, vertical = 6.dp))
    }
}
