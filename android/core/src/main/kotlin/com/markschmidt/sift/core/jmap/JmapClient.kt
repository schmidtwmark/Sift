package com.markschmidt.sift.core.jmap

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.serializer
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketException
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Couldn't reach Fastmail just now (timeout, dropped or missing network, or
 * Fastmail briefly unavailable). Trying again later is the fix.
 */
val Throwable.isTransientNetworkFailure: Boolean
    get() = when (this) {
        is UnknownHostException, is ConnectException, is NoRouteToHostException, is InterruptedIOException,
        is SocketException -> true
        is JmapException.Http -> status in setOf(502, 503, 504)
        else -> false
    }

sealed class JmapException(message: String) : Exception(message) {
    /** HTTP 401: Fastmail didn't accept the credential at all. */
    class Unauthorized(val detail: String?) : JmapException(
        "Fastmail didn't accept this API token (HTTP 401)${quoted(detail)}. API tokens start with “fmu1-”; " +
            "app passwords made for IMAP or CalDAV won't work. Check the whole token was copied."
    )

    /** HTTP 403: the credential is valid but not allowed to do this. */
    class Forbidden(val detail: String?) : JmapException(
        "Fastmail refused the request (HTTP 403)${quoted(detail)}. The token may be missing the Email submission or Contacts scope."
    )

    class MissingScopes(val scopes: List<String>) : JmapException(
        "This API token doesn't include ${scopes.formattedList()}. In Fastmail, create a new token with Email, Email submission, and Contacts access."
    )

    class Http(val status: Int, val body: String) : JmapException("Fastmail returned HTTP $status. ${body.take(200)}")
    class Method(val type: String, val description: String?) :
        JmapException("JMAP error $type${description?.let { ": $it" } ?: ""}")
    class MissingResponse(val id: String) : JmapException("Missing JMAP response for call $id.")
    object NoMailAccount : JmapException("This Fastmail account has no mail account.")
    object BadUrl : JmapException("Fastmail returned a malformed URL.")

    companion object {
        private fun quoted(detail: String?) = if (detail.isNullOrEmpty()) "" else ": “$detail”"

        /**
         * Fastmail's own explanation from an error response: RFC 7807 problem
         * JSON (`detail`/`title`), or short plain text.
         */
        fun serverDetail(body: String): String? {
            val json = runCatching { SiftJson.parseToJsonElement(body) }.getOrNull()
            if (json is JsonObject) {
                for (key in listOf("detail", "title", "description", "error")) {
                    json[key].stringValue?.takeIf { it.isNotEmpty() }?.let { return it.take(200) }
                }
                return null
            }
            val text = body.trim()
            if (text.isEmpty() || text.contains("<")) return null
            return text.take(200)
        }
    }
}

/** One JMAP method invocation: `[name, arguments, callId]`. */
data class MethodCall(val name: String, val arguments: JsonObject, val id: String) {
    fun toJson(): JsonArray = JsonArray(listOf(JsonPrimitive(name), arguments, JsonPrimitive(id)))

    companion object {
        /** A result reference (`#name`) pointing at a path in an earlier call's result. */
        fun reference(to: String, name: String, path: String): JsonObject =
            obj("resultOf" to to, "name" to name, "path" to path)
    }
}

class JmapResponse(val invocations: List<Invocation>, val sessionState: String?) {
    data class Invocation(val name: String, val arguments: JsonObject, val id: String)

    /**
     * The arguments of call [id]. When a call produces several responses (an
     * implicit `Email/set` after `EmailSubmission/set`), the one named [name] wins.
     */
    fun raw(id: String, name: String? = null): JsonObject {
        val matches = invocations.filter { it.id == id }
        matches.firstOrNull { it.name == "error" }?.let { error ->
            throw JmapException.Method(
                error.arguments["type"].stringValue ?: "unknown",
                error.arguments["description"].stringValue,
            )
        }
        val invocation = name?.let { wanted -> matches.firstOrNull { it.name == wanted } } ?: matches.firstOrNull()
            ?: throw JmapException.MissingResponse(id)
        return invocation.arguments
    }

    inline fun <reified T> result(id: String, name: String? = null): T =
        SiftJson.decodeFromJsonElement(serializer<T>(), raw(id, name))
}

/** A minimal JMAP client for Fastmail, authenticated with an API token. */
class JmapClient(
    private val token: String,
    private val sessionUrl: String = FASTMAIL_SESSION_URL,
    private val http: OkHttpClient = defaultHttpClient,
) {
    private val sessionLock = Mutex()
    @Volatile private var cachedSession: JmapSession? = null

    suspend fun session(refresh: Boolean = false): JmapSession = sessionLock.withLock {
        cachedSession?.takeIf { !refresh }?.let { return it }
        val body = send(authorized(Request.Builder().url(sessionUrl)).build())
        val session = SiftJson.decodeFromString(JmapSession.serializer(), body.decodeToString())
        cachedSession = session
        session
    }

    suspend fun accountId(): String = session().mailAccountId ?: throw JmapException.NoMailAccount

    suspend fun perform(
        calls: List<MethodCall>,
        using: List<String> = listOf(JmapCapability.CORE, JmapCapability.MAIL),
    ): JmapResponse {
        val session = session()
        val payload = obj("using" to using, "methodCalls" to JsonArray(calls.map { it.toJson() }))
        val request = authorized(Request.Builder().url(session.apiUrl))
            .post(SiftJson.encodeToString(JsonElement.serializer(), payload).toRequestBody(JSON))
            .build()
        val data = send(request).decodeToString()
        val root = runCatching { SiftJson.parseToJsonElement(data).jsonObject }.getOrNull()
        val responses = root?.get("methodResponses") as? JsonArray ?: throw JmapException.Http(200, data.take(200))
        val invocations = responses.mapNotNull { triple ->
            val parts = (triple as? JsonArray) ?: return@mapNotNull null
            if (parts.size != 3) return@mapNotNull null
            val name = parts[0].stringValue ?: return@mapNotNull null
            val id = parts[2].stringValue ?: return@mapNotNull null
            JmapResponse.Invocation(name, parts[1] as? JsonObject ?: JsonObject(emptyMap()), id)
        }
        val sessionState = root["sessionState"].stringValue
        if (sessionState != null && sessionState != session.state) cachedSession = null
        return JmapResponse(invocations, sessionState)
    }

    suspend fun download(blobId: String, name: String = "blob", type: String = "application/octet-stream"): ByteArray {
        val url = session().downloadUrl(accountId(), blobId, name, type)
        return send(authorized(Request.Builder().url(url)).build())
    }

    suspend fun upload(data: ByteArray, type: String): String {
        val url = session().uploadUrl(accountId())
        val request = authorized(Request.Builder().url(url)).post(data.toRequestBody(type.toMediaType())).build()
        val response = SiftJson.parseToJsonElement(send(request).decodeToString())
        return response["blobId"].stringValue ?: throw JmapException.MissingResponse("upload")
    }

    /**
     * Streams push notifications from the session's EventSource endpoint. The
     * flow ends when the connection drops; callers reconnect.
     */
    fun stateChanges(): Flow<StateChange> = callbackFlow {
        val url = session().eventSourceUrl()
        val request = authorized(Request.Builder().url(url)).header("Accept", "text/event-stream").build()
        val call = http.newBuilder().readTimeout(0, TimeUnit.MILLISECONDS).build().newCall(request)
        val reader = launch(Dispatchers.IO) {
            try {
                call.execute().use { response ->
                    check(response)
                    val source = response.body?.source() ?: return@use
                    var event = ""
                    val data = mutableListOf<String>()
                    while (true) {
                        val line = source.readUtf8Line() ?: break
                        when {
                            line.isEmpty() -> {
                                // A blank line ends the event.
                                if (event == "state" && data.isNotEmpty()) {
                                    runCatching {
                                        SiftJson.decodeFromString(StateChange.serializer(), data.joinToString("\n"))
                                    }.getOrNull()?.let { trySend(it) }
                                }
                                event = ""
                                data.clear()
                            }
                            line.startsWith("event:") -> event = line.removePrefix("event:").trim()
                            line.startsWith("data:") -> data += line.removePrefix("data:").trim()
                        }
                    }
                }
                close()
            } catch (error: Throwable) {
                close(error)
            }
        }
        awaitClose {
            call.cancel()
            reader.cancel()
        }
    }.flowOn(Dispatchers.IO)

    // MARK: - Plumbing

    private fun authorized(builder: Request.Builder) = builder.header("Authorization", "Bearer $token")

    private suspend fun send(request: Request): ByteArray {
        val response = http.newCall(request).await()
        return response.use {
            val bytes = it.body?.bytes() ?: ByteArray(0)
            check(it, bytes)
            bytes
        }
    }

    private fun check(response: Response, body: ByteArray? = null) {
        if (response.isSuccessful) return
        val text = (body ?: response.body?.bytes() ?: ByteArray(0)).decodeToString()
        val detail = JmapException.serverDetail(text)
        // Never logs headers, so the token stays out of the log.
        throw when (response.code) {
            401 -> JmapException.Unauthorized(detail)
            403 -> JmapException.Forbidden(detail)
            else -> JmapException.Http(response.code, detail ?: text.take(200))
        }
    }

    companion object {
        const val FASTMAIL_SESSION_URL = "https://api.fastmail.com/jmap/session"
        private val JSON = "application/json".toMediaType()

        val defaultHttpClient: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(20, TimeUnit.SECONDS)
                .readTimeout(60, TimeUnit.SECONDS)
                .build()
        }
    }
}

/** Runs an OkHttp call without blocking a thread, cancelling it with the coroutine. */
suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
    enqueue(object : Callback {
        override fun onResponse(call: Call, response: Response) = continuation.resume(response)
        override fun onFailure(call: Call, e: IOException) {
            if (!continuation.isCancelled) continuation.resumeWithException(e)
        }
    })
    continuation.invokeOnCancellation { runCatching { cancel() } }
}

internal fun JsonElement.asArray(): JsonArray = this.jsonArray
