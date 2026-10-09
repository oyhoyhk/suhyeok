package com.pickuma.suhyeok

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File

/** Hands a downloaded APK to Android's installer, after the owner allows installs from this app once. */
object Updater {
    /** One file per version, so a file left from an earlier download is never mistaken for this one. */
    fun file(context: Context, code: Int): File {
        val dir = File(context.cacheDir, "updates")
        dir.listFiles()?.filter { it.name != "suhyeok-$code.apk" }?.forEach { it.delete() }
        return File(dir, "suhyeok-$code.apk")
    }

    /** False when Android first needs "이 출처 허용": its settings page is opened instead. */
    fun install(context: Context, file: File): Boolean {
        if (!context.packageManager.canRequestPackageInstalls()) {
            context.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return false
        }
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
        context.startActivity(Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK))
        return true
    }
}
