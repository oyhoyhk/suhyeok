package com.pickuma.suhyeok

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** What used to sit in the list's ⋮ menu, plus the connection and the app version. */
@Composable
fun SettingsTab(api: Api, prefs: Prefs, onRepair: () -> Unit) {
    val context = LocalContext.current
    var confirm by remember { mutableStateOf(false) }
    // Kept here, not in a dialog: Android answers the permission request after the tap that asked for it.
    var notifyOn by remember { mutableStateOf(prefs.notify) }
    val enable = { prefs.notify = true; notifyOn = true; NotifyService.start(context) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { if (it) enable() }
    val setNotify: (Boolean) -> Unit = { want ->
        when {
            !want -> { prefs.notify = false; notifyOn = false; NotifyService.stop(context) }
            android.os.Build.VERSION.SDK_INT >= 33 -> permission.launch(android.Manifest.permission.POST_NOTIFICATIONS)
            else -> enable()
        }
    }
    var asking by remember { mutableStateOf(prefs.notifyAsking) }
    var done by remember { mutableStateOf(prefs.notifyDone) }

    Column(Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState())) {
        Text(stringResource(R.string.tab_settings), color = Gold, fontSize = 24.sp, fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(start = 18.dp, top = 10.dp, bottom = 10.dp))

        Section(stringResource(R.string.settings_connection))
        Item(stringResource(if (api.demo) R.string.demo_subtitle else R.string.settings_mac),
            if (api.demo) null else api.base.removePrefix("https://").removePrefix("http://"))
        Item(stringResource(if (api.demo) R.string.demo_end else R.string.unpair_menu), null, color = Color(0xFFFF8A80)) {
            if (api.demo) onRepair() else confirm = true
        }

        if (BuildConfig.BACKGROUND_NOTIFY && !api.demo) {
            Section(stringResource(R.string.settings_notify))
            Row(Modifier.fillMaxWidth().clickable { setNotify(!notifyOn) }.padding(horizontal = 18.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.settings_notify_background), color = Color.White, fontSize = 15.sp, modifier = Modifier.weight(1f))
                Switch(checked = notifyOn, onCheckedChange = setNotify, colors = SwitchDefaults.colors(checkedTrackColor = Gold))
            }
            Check(stringResource(R.string.notify_kind_asking), asking, notifyOn) { asking = it; prefs.notifyAsking = it }
            Check(stringResource(R.string.notify_kind_done), done, notifyOn) { done = it; prefs.notifyDone = it }
        }

        Section(stringResource(R.string.settings_app))
        Item(stringResource(R.string.settings_version), BuildConfig.VERSION_NAME)
    }

    if (confirm) AlertDialog(
        onDismissRequest = { confirm = false },
        title = { Text(stringResource(R.string.unpair_title)) },
        text = { Text(stringResource(R.string.unpair_text)) },
        confirmButton = { TextButton(onClick = { confirm = false; onRepair() }) { Text(stringResource(R.string.unpair_confirm), color = Color(0xFFFF6B6B)) } },
        dismissButton = { TextButton(onClick = { confirm = false }) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
private fun Section(title: String) {
    HorizontalDivider(color = Color.White.copy(alpha = 0.08f), modifier = Modifier.padding(top = 8.dp))
    Text(title, color = Gold, fontSize = 13.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(start = 18.dp, top = 12.dp, bottom = 4.dp))
}

@Composable
private fun Item(title: String, value: String?, color: Color = Color.White, onClick: (() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().let { if (onClick != null) it.clickable(onClick = onClick) else it }.padding(horizontal = 18.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Text(title, color = color, fontSize = 15.sp, modifier = Modifier.weight(1f))
        value?.let { Text(it, color = Color.White.copy(alpha = 0.6f), fontSize = 13.sp) }
    }
}

@Composable
private fun Check(title: String, checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(enabled = enabled) { onChange(!checked) }.padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Checkbox(checked = checked, onCheckedChange = onChange, enabled = enabled, colors = CheckboxDefaults.colors(checkedColor = Gold))
        Text(title, color = Color.White.copy(alpha = if (enabled) 1f else 0.4f), fontSize = 14.sp)
    }
}
