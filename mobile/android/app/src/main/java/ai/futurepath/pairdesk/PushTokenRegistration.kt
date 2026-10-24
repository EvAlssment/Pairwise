package ai.futurepath.pairdesk

import android.content.Context

internal data class PushRegistrationConfig(
    val server: String,
    val bearer: String,
    val deviceId: String,
) {
    companion object {
        fun from(server: String?, bearer: String?, deviceId: String?): PushRegistrationConfig? {
            val cleanServer = server?.trim()?.trimEnd('/').orEmpty()
            val cleanBearer = bearer?.trim().orEmpty()
            val cleanDeviceId = deviceId?.trim().orEmpty()
            if (cleanServer.isBlank() || cleanBearer.isBlank() || cleanDeviceId.isBlank()) return null
            return PushRegistrationConfig(cleanServer, cleanBearer, cleanDeviceId)
        }
    }
}

/** Re-registers FCM token rotations only when this installation has an authenticated session. */
internal suspend fun registerRefreshedPushToken(context: Context, pushToken: String) {
    if (pushToken.isBlank()) return
    val prefs = securePreferences(context)
    val config = PushRegistrationConfig.from(
        prefs.getString("server", null),
        prefs.getString("token", null),
        prefs.getString("device_id", null),
    ) ?: return
    val api = PairDeskApi(config.server).apply { bearer = config.bearer }
    api.register(config.deviceId, pushToken)
}
