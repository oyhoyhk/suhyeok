package com.pickuma.suhyeok

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource

val Navy = Color(0xFF121A38)
val Panel = Color(0xFF1C2550)
val Gold = Color(0xFFD9AD40)

class MainActivity : ComponentActivity() {
    /** An agent to open, from a tapped notification. */
    private val openRequest = mutableStateOf<String?>(null)

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra(NotifyService.EXTRA_AGENT)?.let { openRequest.value = it }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val prefs = Prefs(this)
        openRequest.value = intent.getStringExtra(NotifyService.EXTRA_AGENT)
        if (BuildConfig.BACKGROUND_NOTIFY && prefs.notify && prefs.token != null) NotifyService.start(this)
        // Debug builds: `adb shell am start … --es base <url> --es token <t>` connects without the QR (UI checks).
        if (BuildConfig.DEBUG) {
            intent.getStringExtra("base")?.let { prefs.base = it }
            intent.getStringExtra("token")?.let { prefs.token = it }
        }
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(primary = Gold, background = Navy, surface = Navy)) {
                // The guild hall illustration, faint behind every screen (same art as the Mac's dialogue backdrop).
                Surface(Modifier.fillMaxSize(), color = Navy) {
                    Image(painterResource(R.drawable.backdrop), null, Modifier.fillMaxSize(),
                        contentScale = ContentScale.Crop, alpha = 0.12f)
                    var base by remember { mutableStateOf(prefs.base) }
                    var token by remember { mutableStateOf(prefs.token) }
                    var open by remember { mutableStateOf<Agent?>(null) }
                    // The session list first; kept while a chat is open so Back returns to the same tab.
                    var tab by rememberSaveable { mutableStateOf(Tab.Sessions) }
                    // A tapped notification opens its agent from the list.
                    if (openRequest.value != null) tab = Tab.Sessions
                    // Demo mode is not saved: the next launch shows the pairing screen again.
                    var demo by remember { mutableStateOf(false) }
                    val api = remember(base, token, demo) { if (demo) Api(Demo.BASE, null) else base?.let { Api(it, token) } }
                    val unpair = { if (demo) demo = false else { prefs.token = null; token = null }; open = null }

                    when {
                        api == null || (token == null && !demo) -> PairScreen(prefs.base, prefs.token, onDemo = { demo = true }) { b, t ->
                            prefs.base = b; prefs.token = t; base = b; token = t
                        }
                        open == null -> HomeScreen(api, prefs, tab, { tab = it }, openRequest.value,
                            onOpen = { open = it; openRequest.value = null }, onUnpaired = unpair, onRepair = unpair)
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
