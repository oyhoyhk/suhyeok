package com.pickuma.suhyeok

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Agent notifications while the app is closed: a foreground service asks the Mac every 15 s for the state
 * changes it recorded (so turns shorter than that are not missed) and posts
 * "선택 필요" (stopped on a question) and "작업 완료" (finished a turn). Android requires the ongoing
 * "수혁 알림 켜짐" notification for a service like this; it can be turned off from the app's ⋮ menu.
 */
class NotifyService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var running = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        channels(this)
        val ongoing = NotificationCompat.Builder(this, CH_SERVICE)
            .setSmallIcon(R.drawable.ic_stat).setContentTitle("수혁 알림 켜짐")
            .setContentText("에이전트가 선택을 기다리거나 일을 마치면 알려 줌")
            .setContentIntent(openApp(this, null)).setOngoing(true).build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(ID_SERVICE, ongoing, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else startForeground(ID_SERVICE, ongoing)
        if (!running) { running = true; scope.launch { loop() } }
        return START_STICKY
    }

    private suspend fun loop() {
        val prefs = Prefs(this)
        var boot: String? = null
        var after = 0
        while (true) {
            val base = prefs.base; val token = prefs.token
            if (base == null || token == null) { stopSelf(); return }
            try {
                val e = Api(base, token).events(boot, after)
                for (ev in e.events) when {
                    ev.kind == "asking" && prefs.notifyAsking -> notify(ev, "${ev.name} · 선택 필요", ev.text, CH_ASKING)
                    ev.kind == "done" && prefs.notifyDone -> notify(ev, "${ev.name} · 작업 완료", ev.text, CH_DONE)
                }
                boot = e.boot; after = e.seq
            } catch (e: Unpaired) {
                stopSelf(); return
            } catch (_: Exception) {
                // The Mac is asleep or offline: try again; the Mac keeps what happened meanwhile.
            }
            delay(15_000)
        }
    }

    private fun notify(e: AgentEvent, title: String, text: String, channel: String) {
        val n = NotificationCompat.Builder(this, channel)
            .setSmallIcon(R.drawable.ic_stat).setContentTitle(title).setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(openApp(this, e.id)).setAutoCancel(true)
            .setPriority(if (channel == CH_ASKING) NotificationCompat.PRIORITY_HIGH else NotificationCompat.PRIORITY_DEFAULT)
            .build()
        // One notification per agent: a newer state replaces the older one.
        getSystemService(NotificationManager::class.java).notify(e.id.hashCode(), n)
    }

    override fun onDestroy() { scope.cancel(); super.onDestroy() }

    companion object {
        const val CH_SERVICE = "service"
        const val CH_ASKING = "asking"
        const val CH_DONE = "done"
        const val ID_SERVICE = 1
        const val EXTRA_AGENT = "agent"

        fun start(context: Context) = ContextCompat.startForegroundService(context, Intent(context, NotifyService::class.java))
        fun stop(context: Context) = context.stopService(Intent(context, NotifyService::class.java))

        fun channels(context: Context) {
            val m = context.getSystemService(NotificationManager::class.java)
            m.createNotificationChannel(NotificationChannel(CH_ASKING, "선택 필요", NotificationManager.IMPORTANCE_HIGH)
                .apply { description = "에이전트가 권한 확인·질문 선택지에서 멈춤" })
            m.createNotificationChannel(NotificationChannel(CH_DONE, "작업 완료", NotificationManager.IMPORTANCE_DEFAULT)
                .apply { description = "에이전트가 한 차례 작업을 마침" })
            m.createNotificationChannel(NotificationChannel(CH_SERVICE, "알림 서비스", NotificationManager.IMPORTANCE_MIN)
                .apply { description = "백그라운드에서 상태를 확인하는 동안 표시" })
        }

        /** Opens the app, on the given agent's conversation when there is one. */
        fun openApp(context: Context, agentId: String?): PendingIntent {
            val i = Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            if (agentId != null) i.putExtra(EXTRA_AGENT, agentId)
            return PendingIntent.getActivity(context, agentId?.hashCode() ?: 0, i,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
    }
}
