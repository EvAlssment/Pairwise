package ai.futurepath.pairdesk

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Handles FCM call events. The API sends only an event and ID; the app refreshes
 * authenticated state before exposing the accept/decline flow.
 */
class PairDeskMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        super.onNewToken(token)
        if (FirebaseApp.getApps(this).isEmpty()) return

        // FCM rotates tokens independently of app launches. Persist the new token
        // encrypted and let WorkManager retry registration across process exits.
        enqueuePushTokenRegistration(this, token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val title = "PairDesk"
        val body = when (message.data["event"]) {
            "direct_call" -> "An incoming call is waiting. Open PairDesk to answer."
            "join_request" -> "A teammate wants to join your call. Open PairDesk to respond."
            else -> "Open PairDesk to check your team."
        }
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Calls", NotificationManager.IMPORTANCE_HIGH)
        )
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("callId", message.data["callId"])
            putExtra("roomId", message.data["roomId"])
        }
        val pending = PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        manager.notify((message.data["callId"] ?: System.currentTimeMillis().toString()).hashCode(),
            NotificationCompat.Builder(this, CHANNEL).setSmallIcon(android.R.drawable.sym_call_incoming)
                .setContentTitle(title).setContentText(body).setContentIntent(pending).setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH).build())
    }

    companion object { private const val CHANNEL = "pairdesk_calls" }
}
