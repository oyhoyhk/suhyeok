package com.pickuma.suhyeok

import android.content.ActivityNotFoundException
import android.content.Intent
import android.webkit.MimeTypeMap
import android.widget.MediaController
import android.widget.VideoView
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.InsertDriveFile
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.FileProvider
import coil.compose.AsyncImage
import coil.request.ImageRequest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.io.File

/** How the viewer shows a file, from its name. Audio plays in the video player too. */
enum class FileKind {
    Video, Image, Markdown, Text, Other;

    companion object {
        private val video = setOf("mp4", "m4v", "mov", "webm", "mkv", "3gp", "mp3", "m4a", "wav", "aac", "ogg", "flac")
        private val image = setOf("png", "jpg", "jpeg", "gif", "webp", "bmp", "heic")
        private val text = setOf("txt", "log", "csv", "json", "yaml", "yml", "toml", "xml", "html", "css", "sql", "srt", "vtt",
            "swift", "kt", "kts", "java", "py", "js", "ts", "tsx", "jsx", "sh", "zsh", "go", "rs", "rb", "c", "h", "cpp", "gradle")

        fun of(name: String): FileKind = when (name.substringAfterLast('.', "").lowercase()) {
            in video -> Video
            in image -> Image
            "md", "markdown" -> Markdown
            in text -> Text
            else -> Other
        }
    }
}

/** A file on the Mac, full screen: videos stream, images zoom, text reads; anything else goes to another app. */
@Composable
fun FileViewer(api: Api, path: String, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val name = path.substringAfterLast('/')
    val kind = FileKind.of(name)
    var progress by remember { mutableStateOf<Float?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    val noApp = stringResource(R.string.viewer_no_app)

    // Another app opens a copy: downloaded into the cache, handed over through the FileProvider.
    fun openWith() = scope.launch {
        try {
            val dir = File(context.cacheDir, "open")
            dir.listFiles()?.filter { System.currentTimeMillis() - it.lastModified() > 86_400_000 }?.forEach { it.deleteRecursively() }
            val file = File(dir, Integer.toHexString(path.hashCode()) + "/" + name)
            progress = 0f
            api.download(path, file) { progress = it }
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
            val type = MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase()) ?: "*/*"
            context.startActivity(Intent.createChooser(Intent(Intent.ACTION_VIEW).setDataAndType(uri, type)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), name))
        } catch (_: ActivityNotFoundException) {
            notice = noApp
        } catch (e: Exception) {
            notice = e.describe(context)
        } finally {
            progress = null
        }
    }

    Column(Modifier.fillMaxSize().background(Navy).statusBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onClose) { Icon(Icons.Filled.Close, stringResource(R.string.viewer_close), tint = Gold) }
            Column(Modifier.weight(1f)) {
                Text(name, color = Gold, fontSize = 16.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(path.substringBeforeLast('/').replace(Regex("^/Users/[^/]+"), "~"), color = Color.White.copy(alpha = 0.6f),
                    fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            IconButton(onClick = { openWith() }, enabled = progress == null) {
                Icon(Icons.AutoMirrored.Filled.OpenInNew, stringResource(R.string.viewer_open_with), tint = Gold)
            }
        }
        progress?.let { LinearProgressIndicator(progress = { it }, Modifier.fillMaxWidth(), color = Gold) }
        notice?.let { Text(it, color = Color(0xFFFFB74D), fontSize = 12.sp, modifier = Modifier.padding(horizontal = 14.dp, vertical = 4.dp)) }
        Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
            when {
                api.demo -> Other(name, stringResource(R.string.files_demo)) { openWith() }
                kind == FileKind.Video -> Video(api, path) { notice = it }
                kind == FileKind.Image -> Picture(api, path)
                kind == FileKind.Markdown || kind == FileKind.Text -> TextFile(api, path, kind == FileKind.Markdown)
                else -> Other(name, stringResource(R.string.viewer_other)) { openWith() }
            }
        }
    }
}

/**
 * Downloads the whole file, then plays it from the phone. Streaming it instead let the player read the start of a
 * full-length response and leave the rest unread: through the Cloudflare tunnel that open response stalled every
 * request to the Mac, the player's own range requests included (a black screen that never loaded).
 */
@Composable
private fun Video(api: Api, path: String, onError: (String) -> Unit) {
    val context = LocalContext.current
    val failed = stringResource(R.string.viewer_video_failed)
    var local by remember(path) { mutableStateOf<File?>(null) }
    var progress by remember(path) { mutableFloatStateOf(0f) }
    LaunchedEffect(path) {
        // One video at a time in the cache; closing the viewer cancels the download (Api.download).
        val dir = File(context.cacheDir, "video")
        dir.listFiles()?.forEach { it.deleteRecursively() }
        val file = File(dir, Integer.toHexString(path.hashCode()) + "." + path.substringAfterLast('.', "mp4"))
        try {
            api.download(path, file) { progress = it }
            local = file
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            onError(e.describe(context) ?: failed)
        }
    }
    val f = local
    if (f == null) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            LinearProgressIndicator(progress = { progress }, Modifier.fillMaxWidth(0.6f), color = Gold)
            Text(stringResource(R.string.update_downloading, (progress * 100).toInt()), color = Color.White.copy(alpha = 0.7f), fontSize = 13.sp)
        }
    } else AndroidView(
        factory = { ctx ->
            VideoView(ctx).apply {
                val controls = MediaController(ctx)
                controls.setAnchorView(this)
                setMediaController(controls)
                setOnPreparedListener { start(); controls.show(3000) }
                setOnErrorListener { _, _, _ -> onError(failed); true }
                setVideoPath(f.path)
            }
        },
        onRelease = { it.stopPlayback() },
    )
}

/** Fits the screen; pinch to zoom, drag to look around. */
@Composable
private fun Picture(api: Api, path: String) {
    val context = LocalContext.current
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    val request = remember(path) {
        ImageRequest.Builder(context).data(api.fileUrl(path)).apply { api.headers.forEach { (k, v) -> addHeader(k, v) } }.build()
    }
    AsyncImage(request, null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize()
        .pointerInput(Unit) {
            detectTransformGestures { _, pan, zoom, _ ->
                scale = (scale * zoom).coerceIn(1f, 6f)
                offset = if (scale == 1f) Offset.Zero else offset + pan
            }
        }
        .graphicsLayer(scaleX = scale, scaleY = scale, translationX = offset.x, translationY = offset.y))
}

@Composable
private fun TextFile(api: Api, path: String, markdown: Boolean) {
    val context = LocalContext.current
    var text by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(path) {
        runCatching { api.text(path) }.onSuccess { text = it }.onFailure { error = it.describe(context) }
    }
    val t = text
    when {
        t == null -> Text(error ?: stringResource(R.string.loading), color = Color.White.copy(alpha = 0.6f))
        markdown -> Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(14.dp)) { Markdown(t) }
        else -> SelectionContainer(Modifier.fillMaxSize()) {
            Text(t, color = Color(0xFFE0E0E0), fontFamily = FontFamily.Monospace, fontSize = 12.sp, lineHeight = 16.sp,
                modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).horizontalScroll(rememberScrollState()).padding(12.dp))
        }
    }
}

@Composable
private fun Other(name: String, note: String, openWith: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier.padding(24.dp)) {
        Icon(Icons.AutoMirrored.Filled.InsertDriveFile, null, tint = Gold, modifier = Modifier.size(56.dp))
        Text(name, color = Color.White, fontWeight = FontWeight.Bold)
        Text(note, color = Color.White.copy(alpha = 0.6f), fontSize = 13.sp)
        OutlinedButton(onClick = openWith) { Text(stringResource(R.string.viewer_open_with), color = Gold) }
    }
}
