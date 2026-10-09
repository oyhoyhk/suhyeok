package com.pickuma.suhyeok

import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import org.junit.Assert.assertEquals
import org.junit.Test

/** Which addresses in a reply become tappable links, and where they point. */
class LinksTest {
    private fun urls(a: AnnotatedString) = a.getLinkAnnotations(0, a.length).map { (it.item as LinkAnnotation.Url).url }

    @Test fun bareAddressWithoutTrailingPeriod() =
        assertEquals(listOf("https://suhyeok.pickuma.com"), urls(inline("고정 주소는 https://suhyeok.pickuma.com.")))

    @Test fun addressQuotedAsCode() =
        assertEquals(listOf("https://suhyeok.pickuma.com"), urls(inline("고정 주소 `https://suhyeok.pickuma.com`으로 접속")))

    @Test fun labeledLink() {
        val a = inline("[수혁 릴리스](https://github.com/oyhoyhk/suhyeok/releases) 참고")
        assertEquals(listOf("https://github.com/oyhoyhk/suhyeok/releases"), urls(a))
        assertEquals("수혁 릴리스 참고", a.text)
    }

    @Test fun codeThatIsNotAnAddressStaysCode() = assertEquals(emptyList<String>(), urls(inline("`publish.sh`로 올림")))

    @Test fun javascriptIsNeverALink() = assertEquals(emptyList<String>(), urls(inline("[x](javascript:alert(1)) `javascript:alert(1)`")))

    @Test fun terminalText() =
        assertEquals(listOf("https://a.com/x", "http://b.org"), urls(linksOnly("see https://a.com/x, then http://b.org.", androidx.compose.ui.graphics.Color.Blue)))
}
