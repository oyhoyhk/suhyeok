package com.pickuma.suhyeok

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import org.junit.Assert.assertEquals
import org.junit.Test

/** Terminal tab: `tmux capture-pane -e` lines keep their text and colors, other escapes disappear. */
class AnsiTest {
    @Test fun textWithoutEscapes() = assertEquals("$ ls -la", ansi("\u001B[0m$ ls -la\u001B[K").text)

    @Test fun basicColorAndBold() {
        val a = ansi("\u001B[1;32m✔ passed\u001B[0m done")
        assertEquals("✔ passed done", a.text)
        val s = a.spanStyles.single { it.start == 0 }
        assertEquals(FontWeight.Bold, s.item.fontWeight)
        assertEquals(Color(0xFF98C379), s.item.color)
    }

    @Test fun trueColorForeground() {
        val a = ansi("\u001B[38;2;255;128;0mwarn\u001B[39m")
        assertEquals("warn", a.text)
        assertEquals(Color(255, 128, 0), a.spanStyles.single().item.color)
    }
}
