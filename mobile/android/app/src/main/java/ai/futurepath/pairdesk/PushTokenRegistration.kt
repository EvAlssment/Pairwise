package ai.futurepath.pairdesk

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.CancellationException
import java.util.concurrent.TimeUnit

private const val PUSH_TOKEN_KEY = "fcm_push_token"
internal const val PUSH_REGISTRATION_WORK = "pairdesk-push-token-registration"

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

/** Saves FCM tokens encrypted and schedules durable registration without putting the token in WorkManager's database. */
internal fun enqueuePushTokenRegistration(context: Context, pushToken: String) {
    if (pushToken.isBlank()) return
    val prefs = securePreferences(context)
    prefs.edit().putString(PUSH_TOKEN_KEY, pushToken).apply()

    val request = OneTimeWorkRequestBuilder<PushTokenRegistrationWorker>()
        .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
        .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
        .build()
    WorkManager.getInstance(context).enqueueUniqueWork(
        PUSH_REGISTRATION_WORK,
        ExistingWorkPolicy.REPLACE,
        request,
    )
}

internal class PushTokenRegistrationWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val prefs = securePreferences(applicationContext)
        val pushToken = prefs.getString(PUSH_TOKEN_KEY, null)?.takeIf(String::isNotBlank)
            ?: return Result.success()
        val config = PushRegistrationConfig.from(
            prefs.getString("server", null),
            prefs.getString("token", null),
            prefs.getString("device_id", null),
        ) ?: return Result.success()

        return try {
            PairDeskApi(config.server).apply { bearer = config.bearer }.register(config.deviceId, pushToken)
            Result.success()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            if (runAttemptCount < MAX_ATTEMPTS) Result.retry() else Result.failure()
        }
    }

    private companion object {
        const val MAX_ATTEMPTS = 8
    }
}
