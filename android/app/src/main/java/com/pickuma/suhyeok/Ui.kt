package com.pickuma.suhyeok

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage

/** The agent's face; its initial shows until (or instead of) the picture. */
@Composable
fun Portrait(api: Api, character: String, name: String, size: Dp, ring: Color? = null) {
    val shape = Modifier.size(size).clip(CircleShape).background(Panel)
    Box(if (ring != null) shape.border(2.dp, ring, CircleShape) else shape, contentAlignment = Alignment.Center) {
        Text(name.take(1), color = Color.White.copy(alpha = 0.8f), fontWeight = FontWeight.Bold, fontSize = (size.value * 0.4f).sp)
        if (character.isNotEmpty()) {
            AsyncImage(api.portrait(character), name, contentScale = ContentScale.Crop, modifier = Modifier.size(size))
        }
    }
}

/** The name tag in the same color the Mac gives the agent's working folder (Characters.swift projectColor). */
@Composable
fun NameTag(name: String, cwd: String) {
    Text(name, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp,
        modifier = Modifier.background(projectColor(cwd).copy(alpha = 0.85f), RoundedCornerShape(50))
            .padding(horizontal = 8.dp, vertical = 1.dp))
}

private val palette = listOf(
    0xFF0A84FF, 0xFFFF375F, 0xFF40C8E0, 0xFFFF9F0A, 0xFFBF5AF2,   // blue pink teal orange purple
    0xFF66D4CF, 0xFFFFD60A, 0xFFFF453A, 0xFF64D2FF, 0xFF5E5CE6,   // mint yellow red cyan indigo
).map { Color(it) }

/** FNV-1a over the folder path, as on the Mac, so a project keeps its color on both screens. */
fun projectColor(cwd: String): Color {
    var h = 0xcbf29ce484222325uL
    for (b in cwd.toByteArray()) h = (h xor (b.toUByte().toULong())) * 0x100000001b3uL
    return palette[(h % palette.size.toULong()).toInt()]
}

/** Status line color: red needs you, green works, orange waits for the next instruction, gray rests. */
fun statusColor(status: String, activity: String): Color = when {
    status == "waiting" -> Color(0xFFFF6B6B)
    status == "busy" -> Color(0xFF66BB6A)
    activity == "대기 중" -> Color(0xFFFFA726)
    else -> Color.Gray
}

/**
 * A light Markdown view for agent replies: headings and **bold** in bold, `>` quotes indented with a bar,
 * fenced code in monospace. Enough to read a report on a phone; tables stay as text.
 */
@Composable
fun Markdown(text: String, color: Color = Color.White) {
    Column {
        var code: StringBuilder? = null
        val blocks = mutableListOf<Pair<String, String>>()   // kind to text
        for (line in text.lines()) {
            if (line.trimStart().startsWith("```")) {
                code = if (code == null) StringBuilder() else { blocks += "code" to code.toString().trimEnd(); null }
                continue
            }
            if (code != null) { code.append(line).append('\n'); continue }
            val t = line.trimStart()
            // Table rows: gather consecutive ones into one block (cells split later, the |---| rule dropped).
            if (t.startsWith("|")) {
                if (!t.replace(Regex("[|\\-: ]"), "").isEmpty() || !t.contains("-")) {
                    if (blocks.lastOrNull()?.first == "table") blocks[blocks.lastIndex] = "table" to blocks.last().second + "\n" + t
                    else blocks += "table" to t
                }
                continue
            }
            blocks += when {
                t.startsWith("#") -> "h" to t.trimStart('#').trim()
                t.startsWith(">") -> "quote" to t.removePrefix(">").trim()
                else -> "p" to line
            }
        }
        code?.let { blocks += "code" to it.toString().trimEnd() }
        for ((kind, s) in blocks) when (kind) {
            "h" -> Text(inline(s), color = Gold, fontWeight = FontWeight.Bold, fontSize = 15.sp, modifier = Modifier.padding(top = 4.dp))
            "quote" -> Row(Modifier.padding(vertical = 2.dp)) {
                Box(Modifier.width(3.dp).size(3.dp, 18.dp).background(Gold.copy(alpha = 0.6f)))
                Text(inline(s), color = color.copy(alpha = 0.85f), modifier = Modifier.padding(start = 8.dp))
            }
            "table" -> Table(s.lines(), color)
            "code" -> Text(s, color = Color(0xFFB9F6CA), fontFamily = FontFamily.Monospace, fontSize = 12.sp,
                modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp)
                    .background(Color.Black.copy(alpha = 0.4f), RoundedCornerShape(6.dp)).padding(8.dp))
            else -> Text(inline(s), color = color)
        }
    }
}

/** A Markdown table as a small grid: first row bold, columns sharing the width evenly. */
@Composable
private fun Table(rows: List<String>, color: Color) {
    Column(Modifier.fillMaxWidth().padding(vertical = 4.dp)
        .border(1.dp, Color.White.copy(alpha = 0.15f), RoundedCornerShape(6.dp))) {
        rows.forEachIndexed { r, row ->
            val cells = row.trim().trim('|').split("|").map { it.trim() }
            Row(Modifier.fillMaxWidth().background(if (r == 0) Color.White.copy(alpha = 0.08f) else Color.Transparent)
                .padding(horizontal = 6.dp, vertical = 4.dp)) {
                cells.forEach { c ->
                    Text(inline(c), color = color, fontSize = 12.sp, lineHeight = 15.sp,
                        fontWeight = if (r == 0) FontWeight.Bold else null,
                        modifier = Modifier.weight(1f).padding(end = 4.dp))
                }
            }
        }
    }
}

/** `[label](https://…)` or a bare http(s) address at the start of `s`; trailing sentence punctuation is not part of it. */
private val linkPattern = Regex("""^\[([^\]\n]+)]\((https?://[^\s)]+)\)|^https?://[^\s<>"'`)\]]+""")

/** **bold**, `code` and links inside a line; tapping a link opens it in the browser. */
fun inline(s: String, linkColor: Color = Gold): AnnotatedString = buildAnnotatedString {
    val linkStyle = TextLinkStyles(SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline))
    var i = 0
    while (i < s.length) {
        val link = if (s[i] == '[' || s[i] == 'h') linkPattern.find(s.substring(i)) else null
        when {
            link != null -> {
                var url = link.groupValues[2].ifEmpty { link.value }
                val label = link.groupValues[1].ifEmpty { null }
                var tail = ""
                if (label == null) url.takeLastWhile { it in ".,;:!?" }.let { if (it.isNotEmpty()) { tail = it; url = url.dropLast(it.length) } }
                withLink(LinkAnnotation.Url(url, linkStyle)) { append(label ?: url) }
                append(tail)
                i += link.value.length
            }
            s.startsWith("**", i) && s.indexOf("**", i + 2) > 0 -> {
                val end = s.indexOf("**", i + 2)
                withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(s.substring(i + 2, end)) }
                i = end + 2
            }
            s[i] == '`' && s.indexOf('`', i + 1) > 0 -> {
                val end = s.indexOf('`', i + 1)
                val code = s.substring(i + 1, end)
                // Replies often quote addresses as code (`https://…`): still a link.
                if (Regex("""https?://\S+""").matches(code)) withLink(LinkAnnotation.Url(code, linkStyle)) { append(code) }
                else withStyle(SpanStyle(fontFamily = FontFamily.Monospace, color = Color(0xFFFFE082))) { append(code) }
                i = end + 1
            }
            else -> { append(s[i]); i++ }
        }
    }
}

/** Terminal text as is, with its http(s) addresses tappable (no Markdown: the screen is shown verbatim). */
fun linksOnly(s: String, linkColor: Color): AnnotatedString = buildAnnotatedString {
    val style = TextLinkStyles(SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline))
    var last = 0
    for (m in Regex("""https?://[^\s<>"'`)\]]+""").findAll(s)) {
        val url = m.value.trimEnd('.', ',', ';', ':', '!', '?')
        append(s.substring(last, m.range.first))
        withLink(LinkAnnotation.Url(url, style)) { append(url) }
        last = m.range.first + url.length
    }
    append(s.substring(last))
}
