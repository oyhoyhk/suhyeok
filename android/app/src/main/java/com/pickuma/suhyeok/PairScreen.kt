package com.pickuma.suhyeok

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import androidx.activity.compose.rememberLauncherForActivityResult

/**
 * Connect to the Mac: scan the QR from 수혁's settings (모바일 접속 → 연결 시작), then allow this phone on the Mac.
 * A phone that is already paired and only needs the Mac's new address keeps its token: no second approval.
 */
@Composable
fun PairScreen(savedBase: String?, savedToken: String?, onDemo: () -> Unit, onPaired: (base: String, token: String) -> Unit) {
    var status by remember { mutableStateOf<String?>(null) }
    var waiting by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current

    val scan = rememberLauncherForActivityResult(ScanContract()) { result ->
        val text = result.contents ?: return@rememberLauncherForActivityResult
        val (base, secret) = Api.parseQr(text) ?: run { status = context.getString(R.string.pair_not_qr); return@rememberLauncherForActivityResult }
        scope.launch {
            waiting = true
            try {
                // Still paired (the Mac only got a new address): keep the token.
                if (savedToken != null && runCatching { Api(base, savedToken).state() }.isSuccess) {
                    onPaired(base, savedToken); return@launch
                }
                val api = Api(base, null)
                val pending = api.pair(secret)
                status = context.getString(R.string.pair_allow_on_mac)
                repeat(80) {
                    delay(1500)
                    api.pairStatus(pending)?.let { token -> onPaired(base, token); return@launch }
                }
                status = context.getString(R.string.pair_expired)
            } catch (e: Exception) {
                status = e.describe(context) ?: context.getString(R.string.pair_failed)
            } finally {
                waiting = false
            }
        }
    }

    Column(
        Modifier.fillMaxSize().safeDrawingPadding().padding(28.dp),  // targetSdk 35+ draws under the system bars
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(stringResource(R.string.app_name), color = Gold, fontSize = 34.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(10.dp))
        Text(
            stringResource(R.string.pair_instructions),
            color = Color.White.copy(alpha = 0.8f), textAlign = TextAlign.Center,
        )
        if (savedBase != null) {
            Spacer(Modifier.height(6.dp))
            Text(stringResource(R.string.pair_previous, savedBase), color = Color.White.copy(alpha = 0.5f), fontSize = 12.sp)
        }
        Spacer(Modifier.height(28.dp))
        val prompt = stringResource(R.string.pair_scan_prompt)
        if (waiting) CircularProgressIndicator(color = Gold)
        else Button(
            onClick = {
                status = null
                scan.launch(ScanOptions().setPrompt(prompt).setBeepEnabled(false).setOrientationLocked(false)
                    .setDesiredBarcodeFormats(ScanOptions.QR_CODE))
            },
            colors = ButtonDefaults.buttonColors(containerColor = Gold, contentColor = Color.Black),
        ) { Text(stringResource(R.string.pair_scan), fontWeight = FontWeight.Bold) }
        if (!waiting) TextButton(onClick = onDemo) { Text(stringResource(R.string.pair_demo), color = Color.White.copy(alpha = 0.7f)) }
        status?.let {
            Spacer(Modifier.height(16.dp))
            Text(it, color = Color.White, textAlign = TextAlign.Center)
        }
    }
}
