package com.markschmidt.sift.core

import com.markschmidt.sift.core.jmap.JmapCapability
import com.markschmidt.sift.core.jmap.JmapClient
import com.markschmidt.sift.core.jmap.JmapDates
import com.markschmidt.sift.core.jmap.JmapException
import com.markschmidt.sift.core.jmap.JmapSession
import com.markschmidt.sift.core.jmap.MethodCall
import com.markschmidt.sift.core.jmap.QueryResponse
import com.markschmidt.sift.core.jmap.SetResponse
import com.markschmidt.sift.core.jmap.SiftJson
import com.markschmidt.sift.core.jmap.isTransientNetworkFailure
import com.markschmidt.sift.core.jmap.obj
import com.markschmidt.sift.core.screener.ContactsRuleStore
import com.markschmidt.sift.core.store.BodyRecord
import com.markschmidt.sift.core.sync.BodyAssembler
import com.markschmidt.sift.core.jmap.EmailBodyPart
import com.markschmidt.sift.core.jmap.EmailBodyValue
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.jsonObject
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** A fake Fastmail: answers each request with the next canned response and records what it was sent. */
private class FakeFastmail(val handler: (Request, String?) -> Pair<Int, String>) {
    val requests = mutableListOf<Pair<Request, String?>>()

    val client: OkHttpClient = OkHttpClient.Builder().addInterceptor(Interceptor { chain ->
        val request = chain.request()
        val body = request.body?.let { Buffer().also(it::writeTo).readUtf8() }
        requests += request to body
        val (status, text) = handler(request, body)
        val type = if (request.header("Accept") == "text/event-stream") "text/event-stream" else "application/json"
        Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(status).message("x")
            .body(text.toResponseBody(type.toMediaType())).build()
    }).build()
}

private fun session(state: String = "s1") = """
    {"apiUrl": "https://api.example/jmap/api/", "downloadUrl": "https://api.example/download/{accountId}/{blobId}/{name}?type={type}",
     "uploadUrl": "https://api.example/upload/{accountId}/", "eventSourceUrl": "https://api.example/events?types={types}&closeafter={closeafter}&ping={ping}",
     "username": "me@fastmail.com", "state": "$state",
     "primaryAccounts": {"urn:ietf:params:jmap:mail": "A1", "urn:ietf:params:jmap:contacts": "A1"},
     "capabilities": {"urn:ietf:params:jmap:core": {"maxSizeUpload": 50000000}}}
""".trimIndent()

class JmapClientTest {
    @Test fun sendsBearerTokenAndMethodCallTriples() = runBlocking<Unit> {
        val fake = FakeFastmail { request, _ ->
            if (request.url.encodedPath.endsWith("/session")) 200 to session()
            else 200 to """{"methodResponses": [["Email/query", {"accountId": "A1", "ids": ["M1", "M2"], "total": 2}, "q"]], "sessionState": "s1"}"""
        }
        val client = JmapClient("fmu1-secret", "https://api.example/jmap/session", fake.client)
        val response = client.perform(listOf(MethodCall("Email/query", obj("accountId" to "A1", "limit" to 2), "q")))
        assertEquals(listOf("M1", "M2"), response.result<QueryResponse>("q").ids)

        val (sessionRequest, _) = fake.requests[0]
        assertEquals("Bearer fmu1-secret", sessionRequest.header("Authorization"))
        val (apiRequest, body) = fake.requests[1]
        assertEquals("POST", apiRequest.method)
        assertEquals("https://api.example/jmap/api/", apiRequest.url.toString())
        assertEquals("Bearer fmu1-secret", apiRequest.header("Authorization"))
        val json = SiftJson.parseToJsonElement(body!!).jsonObject
        assertEquals(SiftJson.parseToJsonElement("""["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"]"""), json["using"])
        assertEquals(
            SiftJson.parseToJsonElement("""[["Email/query", {"accountId": "A1", "limit": 2}, "q"]]"""),
            json["methodCalls"],
        )
        // The session is cached while its state holds.
        client.perform(listOf(MethodCall("Email/query", obj(), "q")))
        assertEquals(3, fake.requests.size)
    }

    @Test fun refetchesTheSessionWhenItsStateChanges() = runBlocking<Unit> {
        var sessions = 0
        val fake = FakeFastmail { request, _ ->
            if (request.url.encodedPath.endsWith("/session")) { sessions++; 200 to session("s$sessions") }
            else 200 to """{"methodResponses": [], "sessionState": "s9"}"""
        }
        val client = JmapClient("t", "https://api.example/jmap/session", fake.client)
        client.perform(emptyList())
        client.perform(emptyList())
        assertEquals(2, sessions)
    }

    @Test fun resultReferencesAndNamedResponses() = runBlocking<Unit> {
        val fake = FakeFastmail { request, _ ->
            if (request.url.encodedPath.endsWith("/session")) 200 to session()
            else 200 to """{"methodResponses": [
                ["EmailSubmission/set", {"accountId": "A1", "created": {"send": {"id": "S1"}}}, "submit"],
                ["Email/set", {"accountId": "A1", "updated": {"M1": null}}, "submit"]
            ]}"""
        }
        val client = JmapClient("t", "https://api.example/jmap/session", fake.client)
        val response = client.perform(listOf(MethodCall("EmailSubmission/set", obj(), "submit")))
        assertEquals("S1", response.result<SetResponse>("submit", "EmailSubmission/set").createdId("send"))
        assertTrue(response.result<SetResponse>("submit", "Email/set").updated!!.containsKey("M1"))
        assertEquals(
            obj("resultOf" to "q", "name" to "Email/query", "path" to "/ids"),
            MethodCall.reference("q", "Email/query", "/ids"),
        )
        assertFailsWith<JmapException.MissingResponse> { response.raw("nope") }
    }

    @Test fun methodErrorsAndHttpFailuresBecomeExceptions() = runBlocking<Unit> {
        val fake = FakeFastmail { request, _ ->
            when {
                request.header("Authorization") == "Bearer bad" ->
                    401 to """{"type":"about:blank","title":"Unauthorized","detail":"Token expired"}"""
                request.url.encodedPath.endsWith("/session") -> 200 to session()
                else -> 200 to """{"methodResponses": [["error", {"type": "cannotCalculateChanges", "description": "too old"}, "c"]]}"""
            }
        }
        val unauthorized = assertFailsWith<JmapException.Unauthorized> {
            JmapClient("bad", "https://api.example/jmap/session", fake.client).session()
        }
        assertEquals("Token expired", unauthorized.detail)
        assertTrue(unauthorized.message!!.contains("fmu1-"))

        val response = JmapClient("good", "https://api.example/jmap/session", fake.client).perform(emptyList())
        val error = assertFailsWith<JmapException.Method> { response.raw("c") }
        assertEquals("cannotCalculateChanges", error.type)
        assertEquals("too old", error.description)
    }

    @Test fun setFailuresNameWhatWasAttempted() {
        val result = SiftJson.decodeFromString(SetResponse.serializer(),
            """{"notCreated": {"g": {"type": "invalidProperties", "properties": ["members"], "description": "nope"}}}""")
        val failure = assertFailsWith<Exception> { result.throwIfFailed("save the screening rule") }
        assertEquals("Fastmail wouldn't save the screening rule (invalidProperties [members]: nope).", failure.message)
    }

    @Test fun streamsStateChangesFromEventSource() = runBlocking<Unit> {
        val fake = FakeFastmail { request, _ ->
            if (request.url.encodedPath.endsWith("/session")) 200 to session()
            else 200 to "event: ping\ndata: {\"interval\":60}\n\n" +
                "event: state\ndata: {\"changed\":{\"A1\":{\"Email\":\"e5\",\"Mailbox\":\"m2\"}}}\n\n" +
                ": comment\n\nevent: state\ndata: not json\n\n"
        }
        val client = JmapClient("t", "https://api.example/jmap/session", fake.client)
        val changes = client.stateChanges().toList()
        assertEquals(listOf(mapOf("A1" to mapOf("Email" to "e5", "Mailbox" to "m2"))), changes.map { it.changed })
        val request = fake.requests.last().first
        assertEquals("https://api.example/events?types=*&closeafter=no&ping=60", request.url.toString())
        assertEquals("text/event-stream", request.header("Accept"))
    }

    @Test fun reportsMissingScopes() {
        fun session(capabilities: List<String>, readOnly: Boolean = false): JmapSession {
            val caps = capabilities.joinToString(",") { "\"$it\": {}" }
            val primary = capabilities.joinToString(",") { "\"$it\": \"A1\"" }
            return SiftJson.decodeFromString(JmapSession.serializer(), """
                {"apiUrl": "https://x/api", "downloadUrl": "d", "uploadUrl": "u", "eventSourceUrl": "e",
                 "username": "me", "state": "1", "capabilities": {$caps}, "primaryAccounts": {$primary},
                 "accounts": {"A1": {"name": "me", "isReadOnly": $readOnly, "accountCapabilities": {$caps}}}}
            """)
        }
        val all = listOf(JmapCapability.CORE, JmapCapability.MAIL, JmapCapability.SUBMISSION, JmapCapability.CONTACTS)
        assertTrue(session(all).missingScopes.isEmpty())
        assertEquals(listOf("Email submission", "Contacts"), session(listOf(JmapCapability.CORE, JmapCapability.MAIL)).missingScopes)
        assertTrue(session(all, readOnly = true).missingScopes.first().startsWith("Email write access"))
        assertEquals(
            "This API token doesn't include Email submission and Contacts. In Fastmail, create a new token with Email, Email submission, and Contacts access.",
            JmapException.MissingScopes(listOf("Email submission", "Contacts")).message,
        )
    }

    @Test fun fillsDownloadAndUploadTemplates() {
        val session = SiftJson.decodeFromString(JmapSession.serializer(), session())
        assertEquals(
            "https://api.example/download/A1/G+x/My%20File.pdf?type=application%2Fpdf",
            session.downloadUrl("A1", "G+x", "My File.pdf", "application/pdf"),
        )
        assertEquals("https://api.example/upload/A1/", session.uploadUrl("A1"))
    }

    @Test fun surfacesFastmailErrorDetail() {
        assertEquals("Token expired", JmapException.serverDetail("""{"type":"about:blank","title":"Unauthorized","detail":"Token expired"}"""))
        assertEquals("Authorization header not a valid format", JmapException.serverDetail("Authorization header not a valid format"))
        assertNull(JmapException.serverDetail("<html>nope</html>"))
    }

    @Test fun transientFailuresAreTheRetryableOnes() {
        assertTrue(SocketTimeoutException().isTransientNetworkFailure)
        assertTrue(UnknownHostException().isTransientNetworkFailure)
        assertTrue(JmapException.Http(503, "").isTransientNetworkFailure)
        assertFalse(JmapException.Unauthorized(null).isTransientNetworkFailure)
        assertFalse(JmapException.Http(400, "").isTransientNetworkFailure)
        assertFalse(IllegalStateException().isTransientNetworkFailure)
    }

    @Test fun parsesJmapDates() {
        assertEquals(Instant.ofEpochSecond(1_792_152_000), JmapDates.parse("2026-10-16T12:00:00Z"))
        assertEquals(Instant.ofEpochSecond(1_792_152_000), JmapDates.parse("2026-10-16T14:00:00+02:00"))
        assertEquals(Instant.ofEpochSecond(1_792_152_000, 250_000_000), JmapDates.parse("2026-10-16T12:00:00.250Z"))
        assertEquals("2026-10-16T12:00:00Z", JmapDates.format(Instant.ofEpochSecond(1_792_152_000, 250_000_000)))
        assertNull(JmapDates.parse("yesterday"))
    }

    /** The group uids every device must agree on, as computed by the Swift app. */
    @Test fun deterministicUidsMatchTheAppleApps() {
        assertEquals("urn:uuid:7cff125a-e022-836c-8702-5eaca00a5412", ContactsRuleStore.uid("group:screened-in"))
        assertEquals("urn:uuid:774a3a44-85d1-86cb-8e12-dc7f901d9093", ContactsRuleStore.uid("group:screened-out"))
        assertEquals("urn:uuid:696e567e-9b48-8765-b795-52298207ad9a", ContactsRuleStore.uid("group:notify"))
        assertEquals("urn:uuid:d97faaa1-1f87-830c-b273-a7bd29019003", ContactsRuleStore.uid("group:badge"))
        assertEquals("urn:uuid:ff2880b3-1163-8cbc-bd53-351a853cc6a9", ContactsRuleStore.Group.Label("travel").uid)
        assertEquals("urn:uuid:f94b2eee-5b35-8de4-b6f0-076093b378e5", ContactsRuleStore.Group.Label("P2a").uid)
        assertEquals("mailto:alex@example.com", ContactsRuleStore.memberKey("Alex@Example.com"))
        assertEquals("members/a~1b~0c", "members/" + ContactsRuleStore.pointerEscape("a/b~c"))
    }

    @Test fun assemblesHtmlWithInlineImages() {
        val message = email("1", "a@x.com").copy(
            htmlBody = listOf(EmailBodyPart(partId = "1", size = 10, type = "text/html")),
            attachments = listOf(
                EmailBodyPart(partId = "2", blobId = "Gabc", size = 10, name = "logo.png", type = "image/png", disposition = "inline", cid = "<logo@x>"),
                EmailBodyPart(partId = "3", blobId = "Gdef", size = 10, name = "report.pdf", type = "application/pdf", disposition = "attachment"),
            ),
            bodyValues = mapOf("1" to EmailBodyValue("""<img src="cid:logo@x"> Hi""")),
        )
        val body: BodyRecord = BodyAssembler.assemble(message)
        assertEquals("""<img src="sift-blob://blob/Gabc?type=image/png&name=logo.png"> Hi""", body.html)
        assertEquals(listOf("report.pdf"), body.attachments.map { it.name })
        assertEquals("Hi", body.text)
    }
}
