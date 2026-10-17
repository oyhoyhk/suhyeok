package com.pickuma.suhyeok

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class FeedbackTest {
    @Test fun commandTakesTheTextAfterThePrefix() {
        assertEquals("버튼이 안 눌림", Feedback.command("/피드백  버튼이 안 눌림 "))
        assertEquals("slow", Feedback.command("/feedback slow"))
        assertEquals("", Feedback.command("/피드백"))
    }

    @Test fun ordinaryInstructionsAreNotFeedback() {
        assertNull(Feedback.command("피드백 반영해줘"))
        assertNull(Feedback.command("/피드백함수 고쳐"))
        assertNull(Feedback.command("/clear"))
    }
}
