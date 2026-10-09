package com.pickuma.suhyeok

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/** The Mac's address and this phone's pairing token, kept encrypted on the device. */
class Prefs(context: Context) {
    private val prefs = EncryptedSharedPreferences.create(
        context, "suhyeok",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    var base: String?
        get() = prefs.getString("base", null)
        set(v) = prefs.edit().putString("base", v).apply()

    var token: String?
        get() = prefs.getString("token", null)
        set(v) = prefs.edit().putString("token", v).apply()

    var readAloud: Boolean
        get() = prefs.getBoolean("readAloud", false)
        set(v) = prefs.edit().putBoolean("readAloud", v).apply()
}
