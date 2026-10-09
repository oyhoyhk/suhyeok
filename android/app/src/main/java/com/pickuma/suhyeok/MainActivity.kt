package com.pickuma.suhyeok

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color

val Navy = Color(0xFF121A38)
val Panel = Color(0xFF1C2550)
val Gold = Color(0xFFD9AD40)

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val prefs = Prefs(this)
        // Debug builds: `adb shell am start … --es base <url> --es token <t>` connects without the QR (UI checks).
        if (BuildConfig.DEBUG) {
            intent.getStringExtra("base")?.let { prefs.base = it }
            intent.getStringExtra("token")?.let { prefs.token = it }
        }
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(primary = Gold, background = Navy, surface = Navy)) {
                Surface(Modifier.fillMaxSize(), color = Navy) {
                    var base by remember { mutableStateOf(prefs.base) }
                    var token by remember { mutableStateOf(prefs.token) }
                    var open by remember { mutableStateOf<Agent?>(null) }
                    val api = remember(base, token) { base?.let { Api(it, token) } }
                    val unpair = { prefs.token = null; token = null; open = null }

                    when {
                        api == null || token == null -> PairScreen(prefs.base, prefs.token) { b, t ->
                            prefs.base = b; prefs.token = t; base = b; token = t
                        }
                        open == null -> AgentsScreen(api, onOpen = { open = it }, onUnpaired = unpair, onRepair = unpair)
                        else -> {
                            BackHandler { open = null }
                            ChatScreen(api, open!!, prefs, onBack = { open = null }, onUnpaired = unpair)
                        }
                    }
                }
            }
        }
    }
}
