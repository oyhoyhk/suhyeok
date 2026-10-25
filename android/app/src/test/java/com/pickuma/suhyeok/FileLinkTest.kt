package com.pickuma.suhyeok

import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** File links in replies: the paths the Mac found (ChatItem.files) become suhyeok-file: links, nothing else does. */
class FileLinkTest {
    private fun links(a: AnnotatedString) = a.getLinkAnnotations(0, a.length).map {
        a.text.substring(it.start, it.end) to fileLinkPath((it.item as LinkAnnotation.Url).url)
    }

    @Test fun plainAndCodePathsLink() {
        val files = mapOf("out/demo.mp4" to "/Users/me/p/out/demo.mp4", "~/p/dist" to "/Users/me/p/dist/")
        val a = inline("영상은 `out/demo.mp4`, 폴더는 ~/p/dist 에 있음", files = files)
        assertEquals("영상은 out/demo.mp4, 폴더는 ~/p/dist 에 있음", a.text)
        assertEquals(listOf("out/demo.mp4" to "/Users/me/p/out/demo.mp4", "~/p/dist" to "/Users/me/p/dist/"), links(a))
    }

    @Test fun pathInsideLongerCodeLinksOnlyThePath() {
        val files = mapOf("/Users/me/p/out/demo.mp4" to "/Users/me/p/out/demo.mp4")
        val a = inline("터미널에서 `open \"/Users/me/p/out/demo.mp4\"` 실행", files = files)
        assertEquals("터미널에서 open \"/Users/me/p/out/demo.mp4\" 실행", a.text)
        assertEquals(listOf("/Users/me/p/out/demo.mp4" to "/Users/me/p/out/demo.mp4"), links(a))
    }

    @Test fun pathGluedInsideCodeDoesNotLink() {
        val a = inline("`xout/demo.mp4`", files = mapOf("out/demo.mp4" to "/x"))
        assertEquals(emptyList<Any>(), links(a))
    }

    @Test fun pathInsideALongerWordDoesNotLink() {
        val a = inline("see xout/demo.mp4", files = mapOf("out/demo.mp4" to "/x"))
        assertEquals(emptyList<Any>(), links(a))
    }

    @Test fun longestPathWins() {
        val a = inline("a/b/c.txt", files = mapOf("a/b" to "/r/a/b/", "a/b/c.txt" to "/r/a/b/c.txt"))
        assertEquals(listOf("a/b/c.txt" to "/r/a/b/c.txt"), links(a))
    }

    @Test fun webLinksStayWebLinks() {
        val a = inline("https://example.com/a.mp4", files = mapOf("a.mp4" to "/x"))
        assertNull(links(a).single().second)
    }

    @Test fun pathsWithSpacesSurviveTheLink() = assertEquals("/a b/c+d.png", fileLinkPath(fileLink("/a b/c+d.png")))

    @Test fun kinds() {
        assertEquals(FileKind.Video, FileKind.of("Clip.MP4"))
        assertEquals(FileKind.Video, FileKind.of("voice.m4a"))
        assertEquals(FileKind.Image, FileKind.of("shot.png"))
        assertEquals(FileKind.Markdown, FileKind.of("README.md"))
        assertEquals(FileKind.Text, FileKind.of("server.log"))
        assertEquals(FileKind.Other, FileKind.of("deck.pptx"))
        assertEquals(FileKind.Other, FileKind.of("Makefile"))
    }
}
