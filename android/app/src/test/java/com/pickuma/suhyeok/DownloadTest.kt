package com.pickuma.suhyeok

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.IOException
import java.net.ServerSocket
import kotlin.concurrent.thread
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** The video viewer downloads before playing; leaving it must close the connection, not leave a response unread. */
class DownloadTest {
    private val size = 8 * 1024 * 1024

    /** Answers one GET with `size` bytes, slowly; [closed] counts down when the client stops reading (a write fails). */
    private fun server(closed: CountDownLatch): ServerSocket = ServerSocket(0, 1, java.net.InetAddress.getLoopbackAddress()).also { ss ->
        thread(isDaemon = true) {
            runCatching {
                ss.accept().use { sock ->
                    val input = sock.getInputStream().bufferedReader()
                    while (input.readLine().orEmpty().isNotEmpty()) Unit  // request head
                    val out = sock.getOutputStream()
                    out.write("HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: $size\r\nConnection: close\r\n\r\n".toByteArray())
                    val chunk = ByteArray(64 * 1024)
                    try {
                        repeat(size / chunk.size) { out.write(chunk); out.flush(); Thread.sleep(20) }
                    } catch (_: IOException) {
                        closed.countDown()
                    }
                }
            }
        }
    }

    @Test fun downloadsTheWholeFile() = runBlocking {
        val s = server(CountDownLatch(1))
        try {
            val file = File.createTempFile("video", ".mp4").also { it.delete() }
            Api("http://127.0.0.1:${s.localPort}", "t").download("/x.mp4", file) {}
            assertEquals(size.toLong(), file.length())
            assertFalse(File(file.path + ".part").exists())
        } finally {
            s.close()
        }
    }

    @Test fun cancellingClosesTheConnection() = runBlocking {
        val closed = CountDownLatch(1)
        val s = server(closed)
        try {
            val file = File.createTempFile("video", ".mp4").also { it.delete() }
            val started = CompletableDeferred<Unit>()
            val job = async(Dispatchers.Default) {
                Api("http://127.0.0.1:${s.localPort}", "t").download("/x.mp4", file) { if (it > 0.05f) started.complete(Unit) }
            }
            withTimeout(10_000) { started.await() }
            job.cancelAndJoin()
            assertTrue("server never saw the client go away", closed.await(5, TimeUnit.SECONDS))
            assertFalse(file.exists())
            assertFalse(File(file.path + ".part").exists())
        } finally {
            s.close()
        }
    }
}
