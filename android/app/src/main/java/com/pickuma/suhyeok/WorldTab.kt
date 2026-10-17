package com.pickuma.suhyeok

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sign

/**
 * The Mac's world on the phone, drawn like the phone web page (MobilePage.swift): the field, the bosses, agents
 * walking to their spot and attacking while they work. Drag to move, pinch to zoom, tap an agent to open its chat.
 */
@Composable
fun WorldTab(api: Api, onOpen: (Agent) -> Unit, onUnpaired: () -> Unit) {
    var map by remember { mutableStateOf<WorldMap?>(null) }
    var loaded by remember { mutableStateOf(false) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    LaunchedEffect(api) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                try { map = api.world(); loaded = true } catch (e: Unpaired) { onUnpaired(); return@repeatOnLifecycle } catch (_: Exception) {}
                delay(1500)
            }
        }
    }
    val m = map
    // Gesture handlers outlive a poll: they read the newest map through this.
    val cur = androidx.compose.runtime.rememberUpdatedState(m)
    if (m == null) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(stringResource(if (!loaded) R.string.loading else if (api.demo) R.string.world_demo else R.string.world_none),
                color = Color.White.copy(alpha = 0.6f), modifier = Modifier.padding(24.dp))
        }
        return
    }

    // Art, fetched once per name; null while loading or missing.
    val art = remember(api) { mutableStateMapOf<String, ImageBitmap?>() }
    val asked = remember(api) { mutableSetOf<String>() }
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    fun img(path: String): ImageBitmap? {
        if (asked.add(path)) scope.launch { art[path] = withContext(Dispatchers.IO) { api.art(path)?.asImageBitmap() } }
        return art[path]
    }

    // Camera: map point at the screen center and pixels per map unit.
    var size by remember { mutableStateOf(IntSize.Zero) }
    var camX by remember { mutableFloatStateOf(0.5f) }
    var camY by remember { mutableFloatStateOf(0.28f) }
    var camS by remember { mutableFloatStateOf(0f) }
    fun clamp() {
        val m = cur.value ?: return
        if (size.width == 0) return
        val minS = max(size.width / m.width, size.height / m.height)
        camS = camS.coerceIn(minS, size.width * 6f)
        val hw = size.width / camS / 2; val hh = size.height / camS / 2
        camX = if (hw * 2 >= m.width) m.width / 2 else camX.coerceIn(hw, m.width - hw)
        camY = if (hh * 2 >= m.height) m.height / 2 else camY.coerceIn(hh, m.height - hh)
    }
    LaunchedEffect(size, m.agents.isNotEmpty()) {
        if (size.width == 0 || camS > 0f || m.agents.isEmpty()) return@LaunchedEffect
        // Start where the action is: the first working agent, else the camp.
        val at = m.agents.firstOrNull { it.agent.busy } ?: m.agents.firstOrNull { it.tier == null }
        camX = at?.x ?: 0.25f; camY = at?.y ?: 0.15f
        camS = max(size.width / m.width, size.height / m.height); clamp()
    }

    // Walking: along x first, then y, at map speed, as on the web page.
    val pos = remember { mutableMapOf<String, FloatArray>() }      // x, y, walking (1/0)
    val facing = remember { mutableMapOf<String, String>() }
    var time by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(Unit) {
        var last = 0L
        while (true) withFrameNanos { now ->
            val dt = if (last == 0L) 0f else min(0.25f, (now - last) / 1e9f); last = now; time += dt
            for (w in map?.agents.orEmpty()) {
                val p = pos.getOrPut(w.agent.id) { floatArrayOf(w.x, w.y, 0f) }
                val v = 0.12f * dt; val dx = w.x - p[0]; val dy = w.y - p[1]
                when {
                    abs(dx) > 1e-4f -> { p[0] += sign(dx) * min(abs(dx), v); facing[w.agent.id] = if (dx < 0) "left" else "right"; p[2] = 1f }
                    abs(dy) > 1e-4f -> { p[1] += sign(dy) * min(abs(dy), v); facing[w.agent.id] = if (dy < 0) "up" else "down"; p[2] = 1f }
                    else -> p[2] = 0f
                }
            }
        }
    }

    val text = rememberTextMeasurer()
    fun sx(x: Float) = (x - camX) * camS + size.width / 2f
    fun sy(y: Float) = (y - camY) * camS + size.height / 2f

    Box(Modifier.fillMaxSize()) {
        Canvas(
            Modifier.fillMaxSize()
                .onSizeChanged { size = it; if (camS > 0f) clamp() }   // the first fit happens below, once agents are known
                .pointerInput(Unit) {
                    detectTransformGestures { centroid, pan, zoom, _ ->
                        // Keep the map point under the fingers in place while zooming.
                        val wx = camX + (centroid.x - size.width / 2f) / camS
                        val wy = camY + (centroid.y - size.height / 2f) / camS
                        camS *= zoom; clamp()
                        camX = wx - (centroid.x - size.width / 2f) / camS - pan.x / camS
                        camY = wy - (centroid.y - size.height / 2f) / camS - pan.y / camS
                        clamp()
                    }
                }
                .pointerInput(Unit) {
                    detectTapGestures { o ->
                        val m = cur.value ?: return@detectTapGestures
                        val base = m.avatar * camS
                        val best = m.agents.minByOrNull { w ->
                            val p = pos[w.agent.id]; hypot(sx(p?.get(0) ?: w.x) - o.x, sy(p?.get(1) ?: w.y) - base * 0.4f - o.y)
                        } ?: return@detectTapGestures
                        val p = pos[best.agent.id]
                        val d = hypot(sx(p?.get(0) ?: best.x) - o.x, sy(p?.get(1) ?: best.y) - base * 0.4f - o.y)
                        if (d < max(36.dp.toPx(), base)) onOpen(best.agent)
                    }
                },
        ) {
            if (camS == 0f) return@Canvas
            val t = time
            drawRect(Color(0xFF120F1C))
            img("field.jpg")?.let { drawImg(it, sx(0f), sy(0f), m.width * camS, m.height * camS) }
            for (b in m.bosses) {
                val h = b.h * camS * 1.25f
                img("bosses/${b.key}_${(t * 6).toInt() % 6}.png")?.let { i ->
                    val w = h * i.width / i.height
                    drawImg(i, sx(b.x) - w / 2, sy(b.y) + b.h * camS / 2 - h, w, h)
                }
                label(text, b.name, sx(b.x), sy(b.y) - b.h * camS * 0.95f, null)
            }
            for (w in m.agents.sortedBy { pos[it.agent.id]?.get(1) ?: it.y }) {
                val a = w.agent
                val p = pos[a.id] ?: floatArrayOf(w.x, w.y, 0f)
                val (frame, mirror) = frameOf(w, p, facing[a.id], m.bosses, t)
                val base = m.avatar * camS
                val x = sx(p[0]); val y = sy(p[1]) + base * 0.5f
                drawOval(Color(0x55000000), Offset(x - base * 0.22f, y - base * 0.06f), Size(base * 0.44f, base * 0.12f))
                img("frames/${a.character}/$frame.png")?.let { i ->
                    val h = base * i.height / 128f; val wd = h * i.width / i.height
                    translate(x, y) { scale(if (mirror) -1f else 1f, 1f, pivot = Offset.Zero) { drawImg(i, -wd / 2, -h, wd, h) } }
                }
                if (a.asking) label(text, "!", x + base * 0.25f, y - base * 1.1f, Color(0xFFE5534B))
                label(text, a.name, x, y + 10.dp.toPx(), Color(0xCC3B5BDB))
            }
        }
        // Who is where, and the guild's crystals (same counts as the web page's top bar).
        val n = { k: String? -> m.agents.count { it.tier == k } }
        Row(
            Modifier.statusBarsPadding().padding(10.dp).background(Color(0xAA120F1C), RoundedCornerShape(50)).padding(horizontal = 12.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("${stringResource(R.string.world_camp)} ${n(null)} · ${stringResource(R.string.world_low)} ${n("low")} · " +
                "${stringResource(R.string.world_mid)} ${n("mid")} · ${stringResource(R.string.world_high)} ${n("high")} · 💎 ${m.crystals}",
                color = Color.White, fontSize = 12.sp)
        }
    }
}

private val beat = intArrayOf(0, 0, 1, 1, 2, 3, 3, 4, 5, 5, 0, 0)

/** The sprite frame and whether to mirror it: walking, attacking its boss while it works, else standing. */
private fun frameOf(w: WorldAgent, p: FloatArray, facing: String?, bosses: List<Boss>, t: Float): Pair<String, Boolean> {
    val ph = (w.agent.id.length * 7) % 10 / 10f
    if (p[2] > 0f) {
        val f = (t * 10).toInt() % 6; val d = facing ?: "down"
        return (if (d == "right") "walk_left_$f" else "walk_${d}_$f") to (d == "right")
    }
    w.tier?.let { tier ->
        val right = bosses.firstOrNull { it.key == tier }?.let { p[0] < it.x } ?: false
        return (if (w.agent.busy) "attack_" + beat[((t + ph) * 10).toInt() % beat.size] else "walk_left_2") to right
    }
    return "walk_down_2" to false
}

private fun DrawScope.drawImg(i: ImageBitmap, x: Float, y: Float, w: Float, h: Float) =
    drawImage(i, dstOffset = IntOffset(x.toInt(), y.toInt()), dstSize = IntSize(w.toInt().coerceAtLeast(1), h.toInt().coerceAtLeast(1)),
        filterQuality = FilterQuality.None)

/** White bold text centered on (x, y), on a rounded pill when [bg] is given. */
private fun DrawScope.label(m: androidx.compose.ui.text.TextMeasurer, s: String, x: Float, y: Float, bg: Color?) {
    val r = m.measure(s, TextStyle(color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Bold))
    val w = r.size.width.toFloat(); val h = r.size.height.toFloat()
    if (bg != null) {
        val pad = 5.dp.toPx()
        drawRoundRect(bg, Offset(x - w / 2 - pad, y - h / 2 - 1), Size(w + pad * 2, h + 2), CornerRadius(h, h))
    }
    drawText(r, topLeft = Offset(x - w / 2, y - h / 2))
}
