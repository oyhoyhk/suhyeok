package com.pickuma.suhyeok

import android.content.Context
import java.io.File

/** Play builds update through Google Play only (its policy forbids self-updating); the banner never shows. */
object Updater {
    fun file(context: Context, code: Int): File = File(context.cacheDir, "updates/suhyeok-$code.apk")
    fun install(context: Context, file: File): Boolean = false
}
