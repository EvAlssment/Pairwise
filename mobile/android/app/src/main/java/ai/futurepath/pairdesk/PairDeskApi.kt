package ai.futurepath.pairdesk

import com.google.gson.Gson
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import org.json.JSONObject
import java.util.concurrent.TimeUnit

data class TeamUser(val id: String, val name: String, val email: String, val online: Boolean = false, val busy: Boolean = false)
data class TeamMember(val id: String, val name: String, val email: String, val online: Boolean = false)
data class CallRoom(val id: String, val name: String, val participantCount: Int = 0, val participants: List<TeamMember> = emptyList())
data class Invitation(val id: String, val status: String, val caller: TeamMember, val target: TeamMember, val room: CallRoom, val createdAt: String? = null)
data class JoinRequest(val id: String, val status: String, val requester: TeamMember, val room: CallRoom)
data class LiveKitGrant(val room: CallRoom, val url: String, val token: String)

class PairDeskApi(base: String) : PushDeviceRegistrar {
    private val baseUrl = base.trim().trimEnd('/')
    private val gson = Gson()
    private val client = OkHttpClient.Builder().callTimeout(20, TimeUnit.SECONDS).build()
    private val jsonType = "application/json; charset=utf-8".toMediaType()
    var bearer: String? = null

    private suspend fun request(method: String, path: String, body: JSONObject? = null): JSONObject = withContext(Dispatchers.IO) {
        val parsedBase = baseUrl.toHttpUrlOrNull() ?: throw IllegalArgumentException("Enter a valid PairDesk server URL.")
        require(parsedBase.scheme == "https" || (parsedBase.scheme == "http" && parsedBase.host == "10.0.2.2")) { "Use HTTPS for the server address." }
        val builder = Request.Builder().url(baseUrl + path).header("Accept", "application/json")
        bearer?.let { builder.header("Authorization", "Bearer $it") }
        val payload = body?.toString()?.toRequestBody(jsonType)
        builder.method(method, if (method == "GET") null else payload ?: "{}".toRequestBody(jsonType))
        client.newCall(builder.build()).execute().use { response ->
            val text = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                val message = runCatching { JSONObject(text).optString("error") }.getOrNull().orEmpty()
                throw PairDeskApiException(response.code, message.ifBlank { "PairDesk server returned HTTP ${response.code}" })
            }
            if (text.isBlank()) JSONObject() else JSONObject(text)
        }
    }

    suspend fun login(email: String, password: String): TeamUser {
        val response = request("POST", "/v1/login", JSONObject().put("email", email.trim()).put("password", password))
        bearer = response.getString("token")
        return gson.fromJson(response.getJSONObject("user").toString(), TeamUser::class.java)
    }
    suspend fun me() = gson.fromJson(request("GET", "/v1/me").getJSONObject("user").toString(), TeamUser::class.java)
    suspend fun heartbeat() { request("POST", "/v1/heartbeat") }
    override suspend fun register(deviceId: String, pushToken: String) {
        request("POST", "/v1/devices", JSONObject().put("deviceId", deviceId).put("platform", "android").put("pushToken", pushToken))
    }
    override suspend fun unregister(deviceId: String) { request("DELETE", "/v1/devices/$deviceId") }
    suspend fun users(): List<TeamUser> = parseList(request("GET", "/v1/users"), "users", TeamUser::class.java)
    suspend fun calls(): List<Invitation> = parseList(request("GET", "/v1/calls"), "calls", Invitation::class.java)
    suspend fun activeCalls(): List<CallRoom> = parseList(request("GET", "/v1/active-calls"), "calls", CallRoom::class.java)
    suspend fun joinRequests(): List<JoinRequest> = parseList(request("GET", "/v1/join-requests"), "requests", JoinRequest::class.java)
    suspend fun startCall(userId: String, roomId: String? = null): Invitation {
        val body = JSONObject().put("userId", userId)
        if (roomId != null) body.put("roomId", roomId)
        val response = request("POST", "/v1/calls", body)
        return gson.fromJson(response.getJSONObject("call").toString(), Invitation::class.java)
    }
    suspend fun callAction(id: String, action: String) = request("POST", "/v1/calls/$id/$action")
    suspend fun requestJoin(roomId: String) = request("POST", "/v1/rooms/$roomId/join-requests")
    suspend fun joinAction(id: String, action: String) = request("POST", "/v1/join-requests/$id/$action")
    suspend fun joinRoom(roomId: String): LiveKitGrant {
        val value = request("POST", "/v1/rooms/$roomId/join")
        return LiveKitGrant(gson.fromJson(value.getJSONObject("room").toString(), CallRoom::class.java), value.getString("url"), value.getString("token"))
    }
    suspend fun roomHeartbeat(roomId: String) { request("POST", "/v1/rooms/$roomId/heartbeat") }
    suspend fun leaveRoom(roomId: String) { request("POST", "/v1/rooms/$roomId/leave") }
    suspend fun logout(deviceId: String?) {
        val body = JSONObject()
        if (!deviceId.isNullOrBlank()) body.put("deviceId", deviceId)
        request("POST", "/v1/logout", body)
        bearer = null
    }

    private fun <T> parseList(response: JSONObject, key: String, type: Class<T>): List<T> =
        gson.fromJson(response.getJSONArray(key).toString(), com.google.gson.reflect.TypeToken.getParameterized(List::class.java, type).type)
}
