package com.pickuma.suhyeok

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.FormatListBulleted
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource

enum class Tab { World, Sessions, Terminal, Files, Settings }

/** The tabs under one bottom bar: world, session list, the Mac's terminals, its files, settings. */
@Composable
fun HomeScreen(api: Api, prefs: Prefs, tab: Tab, onTab: (Tab) -> Unit, openRequest: String?,
               onOpen: (Agent) -> Unit, onUnpaired: () -> Unit, onRepair: () -> Unit,
               filesDir: String?, onFilesDir: (String?) -> Unit, onFile: (String) -> Unit) {
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f).fillMaxWidth()) {
            when (tab) {
                Tab.World -> WorldTab(api, onOpen, onUnpaired)
                Tab.Sessions -> AgentsScreen(api, openRequest, onOpen, onUnpaired)
                Tab.Terminal -> TerminalTab(api, onUnpaired)
                Tab.Files -> FilesTab(api, filesDir, onFilesDir, onFile, onUnpaired)
                Tab.Settings -> SettingsTab(api, prefs, onRepair)
            }
        }
        NavigationBar(containerColor = Panel) {
            listOf(
                Triple(Tab.World, Icons.Filled.Public, R.string.tab_world),
                Triple(Tab.Sessions, Icons.AutoMirrored.Filled.FormatListBulleted, R.string.tab_sessions),
                Triple(Tab.Terminal, Icons.Filled.Terminal, R.string.tab_terminal),
                Triple(Tab.Files, Icons.Filled.Folder, R.string.tab_files),
                Triple(Tab.Settings, Icons.Filled.Settings, R.string.tab_settings),
            ).forEach { (t, icon, label) ->
                NavigationBarItem(
                    selected = tab == t, onClick = { onTab(t) },
                    icon = { Icon(icon, null) }, label = { Text(stringResource(label)) },
                    colors = NavigationBarItemDefaults.colors(selectedIconColor = Color.Black, indicatorColor = Gold,
                        selectedTextColor = Gold, unselectedIconColor = Color.White.copy(alpha = 0.6f),
                        unselectedTextColor = Color.White.copy(alpha = 0.6f)),
                )
            }
        }
    }
}
