package ai.futurepath.pairdesk

import android.Manifest
import android.content.Context
import android.media.AudioManager
import android.os.Bundle
import android.os.Build
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import androidx.compose.ui.unit.dp
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import io.livekit.android.LiveKit
import io.livekit.android.compose.local.RoomScope
import io.livekit.android.compose.state.rememberTracks
import io.livekit.android.compose.ui.VideoTrackView
import io.livekit.android.room.Room
import io.livekit.android.room.track.Track
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.UUID

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { MaterialTheme { PairDeskApp() } }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PairDeskApp() {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val scope = rememberCoroutineScope()
    val prefs = remember { securePreferences(context) }
    var server by remember { mutableStateOf(prefs.getString("server", "https://api.136-80-31-73.sslip.io") ?: "") }
    var email by remember { mutableStateOf(prefs.getString("email", "") ?: "") }
    var password by remember { mutableStateOf("") }
    var api by remember { mutableStateOf<PairDeskApi?>(null) }
    var me by remember { mutableStateOf<TeamUser?>(null) }
    var roster by remember { mutableStateOf<List<TeamUser>>(emptyList()) }
    var calls by remember { mutableStateOf<List<Invitation>>(emptyList()) }
    var activeCalls by remember { mutableStateOf<List<CallRoom>>(emptyList()) }
    var requests by remember { mutableStateOf<List<JoinRequest>>(emptyList()) }
    var error by remember { mutableStateOf("") }
    var message by remember { mutableStateOf("") }
    var roomId by remember { mutableStateOf<String?>(null) }
    var liveRoom by remember { mutableStateOf<Room?>(null) }
    var muted by remember { mutableStateOf(false) }
    var cameraOn by remember { mutableStateOf(false) }
    var speakerOn by remember { mutableStateOf(true) }
    var available by remember { mutableStateOf(true) }
    var busy by remember { mutableStateOf(false) }
    var hasSavedSession by remember { mutableStateOf(prefs.getString("token", null) != null) }
    val callPermissionGate = remember { CallPermissionGate() }

    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) scope.launch {
            runCatching { liveRoom?.localParticipant?.setCameraEnabled(true) }
                .onSuccess { cameraOn = true }.onFailure { error = it.message ?: "Could not enable camera." }
        } else error = "Camera permission was not granted."
    }
    val notificationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { }

    fun registerPushIfConfigured() {
        if (FirebaseApp.getApps(context).isEmpty()) return
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        val deviceId = prefs.getString("device_id", null) ?: UUID.randomUUID().toString().also {
            prefs.edit().putString("device_id", it).apply()
        }
        FirebaseMessaging.getInstance().token.addOnSuccessListener { token ->
            prefs.edit().putString("device_id", deviceId).apply()
            enqueuePushTokenRegistration(context, token)
        }
    }

    suspend fun refresh() {
        val service = api ?: return
        runCatching {
            if (available) service.heartbeat()
            val currentRoom = roomId
            if (currentRoom != null) runCatching { service.roomHeartbeat(currentRoom) }.onFailure {
                runCatching { liveRoom?.disconnect() }
                liveRoom = null; roomId = null; cameraOn = false; muted = false
                message = "The call ended or your reservation expired."
            }
            roster = service.users()
            calls = service.calls()
            activeCalls = service.activeCalls()
            requests = service.joinRequests()
        }.onFailure { error = it.message ?: "Could not refresh PairDesk." }
    }

    suspend fun connectToRoom(id: String) {
        val service = api ?: return
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            throw IllegalStateException("Microphone permission is needed to join a voice call.")
        }
        var connecting: Room? = null
        try {
            val grant = service.joinRoom(id)
            val room = LiveKit.create(context)
            connecting = room
            room.connect(grant.url, grant.token)
            room.localParticipant.setMicrophoneEnabled(true)
            liveRoom = room
            roomId = id
            muted = false
            message = "Connected to ${grant.room.name}"
        } catch (t: Throwable) {
            runCatching { connecting?.disconnect() }
            runCatching { service.leaveRoom(id) }
            error = t.message ?: "Could not join the call."
        }
    }

    suspend fun performCallAction(action: PendingCallAction) {
        val service = api
        if (service == null) { busy = false; return }
        busy = true
        error = ""
        try {
            when (action) {
                is PendingCallAction.Place -> {
                    val invitation = service.startCall(action.userId)
                    message = "Calling ${invitation.target.name}…"
                    connectToRoom(invitation.room.id)
                }
                is PendingCallAction.Answer -> {
                    service.callAction(action.invitationId, "accept")
                    connectToRoom(action.roomId)
                }
                is PendingCallAction.Join -> connectToRoom(action.roomId)
            }
        } catch (t: Exception) { error = t.message ?: "Could not connect the call." }
        finally { busy = false }
        refresh()
    }

    val audioPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val action = callPermissionGate.resolve(granted)
        busy = action != null
        if (action != null) scope.launch { performCallAction(action) }
        else if (!granted) error = "Microphone permission is needed to join a voice call."
    }

    fun requestCallAction(action: PendingCallAction) {
        if (busy) return
        val granted = context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == android.content.pm.PackageManager.PERMISSION_GRANTED
        if (callPermissionGate.request(action, granted)) { busy = true; scope.launch { performCallAction(action) } }
        else { busy = true; audioPermission.launch(Manifest.permission.RECORD_AUDIO) }
    }

    suspend fun restoreSavedSignIn() {
        val token = prefs.getString("token", null) ?: return
        if (server.isBlank() || busy) return
        busy = true
        error = ""
        val restored = PairDeskApi(server).apply { bearer = token }
        try {
            restoreAuthenticatedSession(load = { restored.me() }, clearSavedToken = {
                prefs.edit().remove("token").apply()
                hasSavedSession = false
            }).onSuccess { me = it; api = restored }
                .onFailure { error = it.message ?: "Could not restore your session. Check your connection and retry." }
        } finally { busy = false }
    }

    LaunchedEffect(api, available, roomId, lifecycleOwner) {
        lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (api != null) { refresh(); delay(if (roomId == null) 5_000 else 8_000) }
        }
    }

    LaunchedEffect(api, lifecycleOwner) {
        lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            if (api != null) registerPushIfConfigured()
        }
    }

    LaunchedEffect(Unit) { restoreSavedSignIn() }

    if (me == null) {
        Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("PairDesk", style = MaterialTheme.typography.headlineMedium)
            Text("Sign in to call your team from mobile.")
            if (hasSavedSession) {
                OutlinedButton(enabled = !busy, onClick = { scope.launch { restoreSavedSignIn() } }) { Text("Retry saved sign-in") }
                Text("Your saved session is kept while the server is unreachable.", style = MaterialTheme.typography.bodySmall)
            }
            OutlinedTextField(server, { server = it }, label = { Text("PairDesk server URL") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(email, { email = it }, label = { Text("Email") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(password, { password = it }, label = { Text("Password") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Button(enabled = !busy, onClick = { scope.launch {
                busy = true; error = ""
                runCatching {
                    val service = PairDeskApi(server)
                    me = service.login(email, password)
                    api = service
                    prefs.edit().putString("server", server.trim()).putString("email", email.trim()).putString("token", service.bearer).apply()
                    password = ""
                    hasSavedSession = true
                }.onFailure { error = it.message ?: "Sign in failed." }
                busy = false
            } }) { Text(if (busy) "Signing in…" else "Sign in") }
            if (error.isNotBlank()) Text(error, color = MaterialTheme.colorScheme.error)
            Text("Availability is active while this app is open. Background call alerts require FCM setup on the server.", style = MaterialTheme.typography.bodySmall)
        }
        return
    }

    Scaffold(topBar = {
        TopAppBar(title = { Column { Text("PairDesk"); Text(me?.name.orEmpty(), style = MaterialTheme.typography.labelMedium) } },
            actions = { TextButton(enabled = roomId == null, onClick = { available = !available; message = if (available) "Availability on; you are online" else "Availability off; you will appear offline shortly" }) { Text(if (available) "Available" else "Away") } })
    }) { insets ->
        LazyColumn(Modifier.fillMaxSize().padding(insets).padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (message.isNotBlank()) item { Text(message, color = MaterialTheme.colorScheme.primary) }
            if (error.isNotBlank()) item { Text(error, color = MaterialTheme.colorScheme.error) }
            if (roomId != null) {
                item {
                    Card(Modifier.fillMaxWidth()) { Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text("On a call", style = MaterialTheme.typography.titleLarge)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Button(onClick = { scope.launch { runCatching { liveRoom?.localParticipant?.setMicrophoneEnabled(muted) }.onSuccess { muted = !muted }.onFailure { error = it.message.orEmpty() } } }) { Text(if (muted) "Unmute" else "Mute") }
                            OutlinedButton(onClick = { val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager; speakerOn = !speakerOn; audio.isSpeakerphoneOn = speakerOn }) { Text(if (speakerOn) "Speaker" else "Earpiece") }
                            OutlinedButton(onClick = {
                                if (!cameraOn && context.checkSelfPermission(Manifest.permission.CAMERA) != android.content.pm.PackageManager.PERMISSION_GRANTED) cameraPermission.launch(Manifest.permission.CAMERA)
                                else scope.launch { runCatching { liveRoom?.localParticipant?.setCameraEnabled(!cameraOn) }.onSuccess { cameraOn = !cameraOn }.onFailure { error = it.message.orEmpty() } }
                            }) { Text(if (cameraOn) "Camera off" else "Camera") }
                        }
                        Text("Camera stays off until you enable it. Mobile screen sharing and remote control are not available.", style = MaterialTheme.typography.bodySmall)
                        liveRoom?.let { CameraVideoTiles(it) }
                        Button(onClick = { scope.launch {
                            val id = roomId ?: return@launch
                            runCatching { liveRoom?.disconnect(); api?.leaveRoom(id) }.onFailure { error = it.message.orEmpty() }
                            liveRoom = null; roomId = null; cameraOn = false; muted = false; refresh()
                        } }) { Text("Leave call") }
                    } }
                }
            }
            item { Text("YOUR TEAM", style = MaterialTheme.typography.titleMedium) }
            items(roster.filter { it.id != me?.id }, key = { it.id }) { person ->
                Card(Modifier.fillMaxWidth()) { Row(Modifier.padding(12.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                    Column(Modifier.weight(1f)) { Text(person.name); Text(when { person.busy -> "In a call"; person.online -> "Online"; else -> "Offline" }, style = MaterialTheme.typography.bodySmall) }
            Button(enabled = person.online && !person.busy && roomId == null && !busy, onClick = { requestCallAction(PendingCallAction.Place(person.id)) }) { Text("Call") }
                } }
            }
            if (calls.any { it.status == "pending" && it.target.id == me?.id }) item { Text("INCOMING CALLS", style = MaterialTheme.typography.titleMedium) }
            items(calls.filter { it.status == "pending" && it.target.id == me?.id }, key = { "call-${it.id}" }) { invitation ->
                Card(Modifier.fillMaxWidth()) { Row(Modifier.padding(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("${invitation.caller.name} is calling", Modifier.weight(1f))
                    Button(enabled = !busy, onClick = { requestCallAction(PendingCallAction.Answer(invitation.id, invitation.room.id)) }) { Text("Answer") }
                    TextButton(onClick = { scope.launch { runCatching { api?.callAction(invitation.id, "decline") }; refresh() } }) { Text("Decline") }
                } }
            }
            val recentCalls = calls.filter { it.status in listOf("expired", "declined", "cancelled") }.take(12)
            if (recentCalls.isNotEmpty()) item { Text("RECENT CALLS", style = MaterialTheme.typography.titleMedium) }
            items(recentCalls, key = { "history-${it.id}" }) { invitation ->
                val incoming = invitation.target.id == me?.id
                val person = if (incoming) invitation.caller else invitation.target
                val missed = incoming && invitation.status == "expired"
                val availablePerson = roster.firstOrNull { it.id == person.id }
                Card(Modifier.fillMaxWidth()) { Row(Modifier.padding(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Column(Modifier.weight(1f)) {
                        Text(person.name)
                        Text("${callHistoryLabel(invitation, incoming)} · ${callHistoryTime(invitation.createdAt)}", style = MaterialTheme.typography.bodySmall,
                            color = if (missed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (availablePerson?.online == true && availablePerson.busy != true) {
                        OutlinedButton(enabled = !busy && roomId == null, onClick = { requestCallAction(PendingCallAction.Place(person.id)) }) { Text("Call back") }
                    }
                } }
            }
            if (requests.any { it.status == "pending" && it.requester.id != me?.id }) item { Text("JOIN REQUESTS", style = MaterialTheme.typography.titleMedium) }
            items(requests.filter { it.status == "pending" && it.requester.id != me?.id }, key = { "join-${it.id}" }) { request ->
                Card(Modifier.fillMaxWidth()) { Row(Modifier.padding(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("${request.requester.name} wants to join ${request.room.name}", Modifier.weight(1f))
                    Button(onClick = { scope.launch { runCatching { api?.joinAction(request.id, "accept") }.onFailure { error = it.message.orEmpty() }; refresh() } }) { Text("Allow") }
                    TextButton(onClick = { scope.launch { runCatching { api?.joinAction(request.id, "decline") }; refresh() } }) { Text("Decline") }
                } }
            }
            if (requests.any { it.status == "accepted" && it.requester.id == me?.id }) item { Text("JOIN APPROVED", style = MaterialTheme.typography.titleMedium) }
            items(requests.filter { it.status == "accepted" && it.requester.id == me?.id }, key = { "approved-${it.id}" }) { request ->
                Card(Modifier.fillMaxWidth()) { Row(Modifier.padding(12.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Your request to join ${request.room.name} was approved", Modifier.weight(1f))
                    Button(enabled = roomId == null && !busy, onClick = { requestCallAction(PendingCallAction.Join(request.room.id)) }) { Text("Join") }
                } }
            }
            if (activeCalls.isNotEmpty()) item { Text("ACTIVE CALLS", style = MaterialTheme.typography.titleMedium) }
            items(activeCalls, key = { "room-${it.id}" }) { call ->
                Card(Modifier.fillMaxWidth()) { Row(Modifier.padding(12.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                    Column(Modifier.weight(1f)) { Text(call.name); Text(call.participants.joinToString { it.name }, style = MaterialTheme.typography.bodySmall) }
                    Button(enabled = roomId == null && !busy, onClick = { scope.launch { runCatching { api?.requestJoin(call.id); message = "Join request sent" }.onFailure { error = it.message.orEmpty() }; refresh() } }) { Text("Request to join") }
                } }
            }
            item { TextButton(onClick = { scope.launch {
                androidx.work.WorkManager.getInstance(context).cancelUniqueWork(PUSH_REGISTRATION_WORK)
                val deviceId = prefs.getString("device_id", null)
                runCatching { roomId?.let { api?.leaveRoom(it) } }
                runCatching { liveRoom?.disconnect() }
                runCatching { api?.logout(deviceId) }
                api = null; me = null; roomId = null; liveRoom = null; hasSavedSession = false; prefs.edit().remove("token").apply()
            } }) { Text("Sign out") } }
        }
    }
}

private fun callHistoryLabel(invitation: Invitation, incoming: Boolean): String = when (invitation.status) {
    "expired" -> if (incoming) "Missed call" else "No answer"
    "declined" -> if (incoming) "Declined" else "Call declined"
    else -> "Call ended"
}

private fun callHistoryTime(value: String?): String = runCatching {
    val date = value?.let(Instant::parse) ?: return ""
    DateTimeFormatter.ofLocalizedDateTime(FormatStyle.SHORT).withZone(ZoneId.systemDefault()).format(date)
}.getOrDefault("")

@Composable
private fun CameraVideoTiles(room: Room) {
    RoomScope(passedRoom = room, disconnectOnDispose = false) {
        val tracks by rememberTracks(sources = listOf(Track.Source.CAMERA), passedRoom = room)
        if (tracks.isEmpty()) Text("Camera video appears here when a teammate enables their camera.", style = MaterialTheme.typography.bodySmall)
        tracks.forEach { reference ->
            VideoTrackView(trackReference = reference, modifier = Modifier.fillMaxWidth().height(200.dp), room = room)
        }
    }
}

internal fun securePreferences(context: Context) = EncryptedSharedPreferences.create(
    context, "pairdesk_private", MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
    EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
    EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
)
