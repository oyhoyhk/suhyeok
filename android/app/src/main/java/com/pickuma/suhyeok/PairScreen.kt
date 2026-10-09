package com.pickuma.suhyeok

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
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
fun PairScreen(savedBase: String?, savedToken: String?, onPaired: (base: String, token: String) -> Unit) {
    var status by remember { mutableStateOf<String?>(null) }
    var waiting by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    val scan = rememberLauncherForActivityResult(ScanContract()) { result ->
        val text = result.contents ?: return@rememberLauncherForActivityResult
        val (base, secret) = Api.parseQr(text) ?: run { status = "수혁의 연결 QR이 아님"; return@rememberLauncherForActivityResult }
        scope.launch {
            waiting = true
            try {
                // Still paired (the Mac only got a new address): keep the token.
                if (savedToken != null && runCatching { Api(base, savedToken).state() }.isSuccess) {
                    onPaired(base, savedToken); return@launch
                }
                val api = Api(base, null)
                val pending = api.pair(secret)
                status = "Mac에서 이 폰을 허용해 주세요"
                repeat(80) {
                    delay(1500)
                    api.pairStatus(pending)?.let { token -> onPaired(base, token); return@launch }
                }
                status = "시간이 지나 만료됨 — 다시 시도"
            } catch (e: Exception) {
                status = e.message ?: "연결 실패"
            } finally {
                waiting = false
            }
        }
    }

    Column(
        Modifier.fillMaxSize().padding(28.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("수혁", color = Gold, fontSize = 34.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(10.dp))
        Text(
            "Mac의 수혁 설정(⌘,)에서 '모바일 접속'을 켜고 '연결 시작'을 누른 뒤, 화면의 QR을 찍어 주세요.",
            color = Color.White.copy(alpha = 0.8f), textAlign = TextAlign.Center,
        )
        if (savedBase != null) {
            Spacer(Modifier.height(6.dp))
            Text("이전 주소: $savedBase", color = Color.White.copy(alpha = 0.5f), fontSize = 12.sp)
        }
        Spacer(Modifier.height(28.dp))
        if (waiting) CircularProgressIndicator(color = Gold)
        else Button(
            onClick = {
                status = null
                scan.launch(ScanOptions().setPrompt("수혁 연결 QR").setBeepEnabled(false).setOrientationLocked(false)
                    .setDesiredBarcodeFormats(ScanOptions.QR_CODE))
            },
            colors = ButtonDefaults.buttonColors(containerColor = Gold, contentColor = Color.Black),
        ) { Text("QR 찍기", fontWeight = FontWeight.Bold) }
        status?.let {
            Spacer(Modifier.height(16.dp))
            Text(it, color = Color.White, textAlign = TextAlign.Center)
        }
    }
}
