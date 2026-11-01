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

    /** Answers one GET for the app with [body], stopping after [send] bytes: closing, or with [hold] keeping the connection open. */
    private fun appServer(body: ByteArray, send: Int, hold: Boolean = false): ServerSocket = ServerSocket(0, 1, java.net.InetAddress.getLoopbackAddress()).also { ss ->
        thread(isDaemon = true) {
            runCatching {
                ss.accept().use { sock ->
                    val input = sock.getInputStream().bufferedReader()
                    while (input.readLine().orEmpty().isNotEmpty()) Unit
                    val out = sock.getOutputStream()
                    out.write("HTTP/1.1 200 OK\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray())
                    out.write(body, 0, send); out.flush()
                    if (hold) Thread.sleep(30_000)
                }
            }
        }
    }

    private val apk = ByteArray(2 * 1024 * 1024) { (it % 251).toByte() }
    private val release = Release(1, "test", java.security.MessageDigest.getInstance("SHA-256").digest(apk).joinToString("") { "%02x".format(it) }, "")

    @Test fun appUpdateLandsUnderItsNameOnlyWhenWhole() = runBlocking {
        val s = appServer(apk, apk.size)
        try {
            val file = File.createTempFile("suhyeok", ".apk").also { it.delete() }
            Api("http://127.0.0.1:${s.localPort}", "t").downloadApp(release, file) {}
            assertEquals(apk.size.toLong(), file.length())
            assertFalse(File(file.path + ".part").exists())
        } finally {
            s.close()
        }
    }

    /**
     * While the update is still coming, nothing sits under the final name: if the app is closed mid-download, the
     * next tap finds no file and downloads again instead of installing the partial one ("problem parsing the package").
     */
    @Test fun unfinishedAppUpdateIsNeverUnderTheFinalName() = runBlocking {
        val s = appServer(apk, apk.size / 2, hold = true)
        try {
            val file = File.createTempFile("suhyeok", ".apk").also { it.delete() }
            val halfway = CompletableDeferred<Unit>()
            val job = async(Dispatchers.Default) {
                // Ends in a failure once the test closes the connection; only the file during the download matters here.
                runCatching { Api("http://127.0.0.1:${s.localPort}", "t").downloadApp(release, file) { if (it >= 0.45f) halfway.complete(Unit) } }
            }
            withTimeout(10_000) { halfway.await() }
            assertFalse("a partial APK is under the final name", file.exists())
            job.cancel()
        } finally {
            s.close()
        }
    }
}
