package com.pickuma.suhyeok

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.text.DateFormat
import java.util.Date

/**
 * What the agents made on the Mac: their working folders first, then a folder's files newest first.
 * [dir] null is the folder list; tapping a file opens it ([onFile], FileViewer).
 */
@Composable
fun FilesTab(api: Api, dir: String?, onDir: (String?) -> Unit, onFile: (String) -> Unit, onUnpaired: () -> Unit) {
    var roots by remember { mutableStateOf<Pair<String, List<String>>?>(null) }
    var listing by remember { mutableStateOf<Listing?>(null) }
    var failed by remember { mutableStateOf(false) }
    var reload by remember { mutableIntStateOf(0) }
    LaunchedEffect(api, dir, reload) {
        failed = false
        listing = null
        try {
            roots = api.fileRoots()
            if (dir != null) { listing = api.listing(dir); failed = listing == null }
        } catch (_: Unpaired) { onUnpaired() } catch (_: Exception) { failed = true }
    }
    // Back goes up one folder; from an agent's folder, back to the folder list.
    if (dir != null) BackHandler { onDir(if (roots?.second?.contains(dir) == true) null else listing?.parent) }
    val home = roots?.first.orEmpty()
    fun short(p: String) = if (home.length > 1 && p.startsWith(home)) "~" + p.removePrefix(home) else p
    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(start = if (dir == null) 18.dp else 4.dp, end = 6.dp, top = 10.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically) {
            if (dir != null) IconButton(onClick = { onDir(null) }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back), tint = Gold) }
            Column(Modifier.weight(1f)) {
                Text(if (dir == null) stringResource(R.string.tab_files) else dir.trimEnd('/').substringAfterLast('/'),
                    color = Gold, fontSize = 24.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(if (dir == null) stringResource(R.string.files_subtitle) else short(dir), color = Color.White.copy(alpha = 0.6f),
                    fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            IconButton(onClick = { reload++ }) { Icon(Icons.Filled.Refresh, stringResource(R.string.files_refresh), tint = Gold) }
        }
        if (dir == null) {
            val r = roots
            when {
                r == null -> Note(stringResource(if (failed) R.string.files_unavailable else R.string.loading))
                else -> LazyColumn(Modifier.fillMaxSize()) {
                    items(r.second + r.first, key = { it }) { f ->
                        Line(Icons.Filled.Folder, projectColor(f), f.trimEnd('/').substringAfterLast('/').ifEmpty { f }, short(f)) { onDir(f) }
                    }
                }
            }
        } else {
            val l = listing
            when {
                l == null -> Note(stringResource(if (failed) R.string.files_gone else R.string.loading))
                l.entries.isEmpty() -> Note(stringResource(R.string.files_empty))
                else -> LazyColumn(Modifier.fillMaxSize()) {
                    l.parent?.let { p -> item(key = "..") { Line(Icons.Filled.Folder, Color.Gray, "..", short(p)) { onDir(p) } } }
                    items(l.entries, key = { it.path }) { e ->
                        val detail = DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date((e.mtime * 1000).toLong())) +
                            if (e.dir) "" else " · " + size(e.size)
                        Line(icon(e), if (e.dir) Gold else Color.White.copy(alpha = 0.7f), e.name, detail) {
                            if (e.dir) onDir(e.path) else onFile(e.path)
                        }
                    }
                }
            }
        }
    }
}

private fun icon(e: FileEntry) = when {
    e.dir -> Icons.Filled.Folder
    FileKind.of(e.name) == FileKind.Video -> Icons.Filled.Movie
    FileKind.of(e.name) == FileKind.Image -> Icons.Filled.Image
    else -> Icons.AutoMirrored.Filled.InsertDriveFile
}

/** 1.2 MB style, decimal as the Mac's Finder shows sizes. */
fun size(bytes: Long): String = when {
    bytes < 1000 -> "$bytes B"
    bytes < 1_000_000 -> "%.0f KB".format(bytes / 1e3)
    bytes < 1_000_000_000 -> "%.1f MB".format(bytes / 1e6)
    else -> "%.2f GB".format(bytes / 1e9)
}

@Composable
private fun Line(icon: androidx.compose.ui.graphics.vector.ImageVector, tint: Color, title: String, detail: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 18.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(38.dp).background(Panel, CircleShape), contentAlignment = Alignment.Center) { Icon(icon, null, tint = tint) }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(title, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(detail, color = Color.White.copy(alpha = 0.6f), fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun Note(s: String) = Text(s, color = Color.White.copy(alpha = 0.6f), modifier = Modifier.padding(18.dp))
