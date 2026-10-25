package com.markschmidt.sift.core.demo

import com.markschmidt.sift.core.jmap.JmapCapability
import com.markschmidt.sift.core.jmap.JmapDates
import com.markschmidt.sift.core.jmap.SiftJson
import com.markschmidt.sift.core.jmap.toAny
import com.markschmidt.sift.core.jmap.toJson
import com.markschmidt.sift.core.privacy.HtmlText
import kotlinx.serialization.json.JsonElement
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import java.time.Instant
import java.util.UUID

/**
 * An in-process fake of Fastmail's JMAP API, good enough to run Sift end to
 * end without an account: tests use it, and the app's demo mode runs on it.
 * Requests to [HOST] are answered by an OkHttp interceptor and never leave
 * the device.
 */
@Suppress("UNCHECKED_CAST")
class DemoServer(seed: Boolean = true) {
    companion object {
        const val HOST = "demo.sift.invalid"
        const val SESSION_URL = "https://$HOST/jmap/session"
    }

    private val lock = Any()
    private val mailboxes = LinkedHashMap<String, MutableMap<String, Any?>>()
    private val emails = LinkedHashMap<String, MutableMap<String, Any?>>()
    private val bodies = HashMap<String, Pair<String?, String>>()
    private val blobs = HashMap<String, ByteArray>()
    /** Submission id → its emailId, undoStatus and HOLDFOR seconds. */
    private val submissions = HashMap<String, Submission>()
    private val books = LinkedHashMap<String, Map<String, Any?>>()
    private val cards = LinkedHashMap<String, MutableMap<String, Any?>>()
    private var emailState = 1
    private var mailboxState = 1
    private var cardState = 1
    /** state → ids changed when moving to that state. */
    private val changeLog = mutableListOf<Change>()
    private var nextId = 1000

    data class Submission(val emailId: String, var undoStatus: String, val holdFor: Int)
    private data class Change(val state: Int, val created: Set<String>, val updated: Set<String>, val destroyed: Set<String>)

    /** Mimic a server that only allows real contacts as group members. */
    @Volatile var rejectsAddressMembers = false
    /** Fail every Email/set with a server error. */
    @Volatile var failsEmailSet = false
    /** Advertised `maxDelayedSend`: how long submissions may be held (Undo Send). */
    @Volatile var maxDelayedSend = 0

    init {
        // Like Fastmail: one default address book, and apps can't create more.
        books["personal"] = mapOf("id" to "personal", "name" to "Personal", "isDefault" to true)
        if (seed) DemoSeed.populate(this)
    }

    private fun <T> locked(body: () -> T): T = synchronized(lock, body)

    fun submission(id: String): Submission? = locked { submissions[id]?.copy() }

    /** A held submission's time is up: it can no longer be canceled. */
    fun release(id: String) = locked { submissions[id]?.undoStatus = "final" }

    fun emailExists(id: String) = locked { emails[id] != null }

    fun emailAttachments(id: String): List<Map<String, Any?>> =
        locked { emails[id]?.get("attachments") as? List<Map<String, Any?>> ?: emptyList() }

    /** A change made elsewhere (the Fastmail web app) to one message's keywords. */
    fun setKeyword(keyword: String, id: String) = locked {
        val email = emails[id] ?: return@locked
        email["keywords"] = (email["keywords"] as? Map<String, Any?> ?: emptyMap()) + (keyword to true)
        record(updated = setOf(id))
    }

    /** An OkHttp client whose requests to the demo host are answered by this server. */
    fun httpClient(): OkHttpClient = OkHttpClient.Builder().addInterceptor(interceptor).build()

    val interceptor = Interceptor { chain ->
        val request = chain.request()
        if (request.url.host != HOST) return@Interceptor chain.proceed(request)
        val body = request.body?.let { Buffer().also(it::writeTo).readByteArray() }
        val (status, data, type) = respond(request.url.encodedPath, request.header("Content-Type"), body)
        Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(status)
            .message(if (status in 200..299) "OK" else "Error")
            .body(data.toResponseBody(type.toMediaType()))
            .build()
    }

    // MARK: - Seeding & test hooks

    fun addMailbox(id: String, name: String, role: String? = null, sortOrder: Int = 10) = locked {
        mailboxes[id] = mutableMapOf("id" to id, "name" to name, "parentId" to null, "role" to role, "sortOrder" to sortOrder)
    }

    /** Delivers a message. [html] defaults to a paragraph of [text]. */
    fun deliver(
        from: Pair<String, String>, subject: String, text: String, html: String? = null,
        mailbox: String = "inbox", receivedAt: Instant = Instant.now(), keywords: List<String> = emptyList(),
        threadId: String? = null, to: String = "you@fastmail.com",
    ): String = locked {
        val id = "M$nextId"
        nextId += 1
        emails[id] = mutableMapOf(
            "id" to id, "blobId" to "B$id", "threadId" to (threadId ?: "T$id"),
            "mailboxIds" to mapOf(mailbox to true),
            "keywords" to keywords.associateWith { true },
            "size" to text.toByteArray().size + 400,
            "receivedAt" to JmapDates.format(receivedAt),
            "sentAt" to JmapDates.format(receivedAt),
            "from" to listOf(mapOf("name" to from.first, "email" to from.second)),
            "to" to listOf(mapOf("name" to "You", "email" to to)),
            "cc" to emptyList<Any>(), "replyTo" to emptyList<Any>(),
            "subject" to subject,
            "preview" to text.take(180),
            "hasAttachment" to false,
            "messageId" to listOf("<$id@demo.sift>"), "inReplyTo" to null, "references" to null,
        )
        bodies[id] = (html ?: "<p>${HtmlText.escape(text)}</p>") to text
        record(created = setOf(id))
        id
    }

    fun emailMailboxes(id: String): Set<String> = locked { (emails[id]?.get("mailboxIds") as? Map<String, Any?>)?.keys?.toSet() ?: emptySet() }

    fun emailKeywords(id: String): Set<String> = locked { (emails[id]?.get("keywords") as? Map<String, Any?>)?.keys?.toSet() ?: emptySet() }

    fun mailboxId(named: String): String? = locked { mailboxes.values.firstOrNull { it["name"] == named }?.get("id") as? String }

    fun mailboxSortOrder(id: String): Int? = locked { mailboxes[id]?.get("sortOrder") as? Int }

    /** Sift's contact groups, as raw JSON-like maps. */
    fun siftGroups(): List<Map<String, Any?>> = locked {
        cards.values.filter { it["kind"] == "group" && ((it["name"] as? Map<String, Any?>)?.get("full") as? String)?.startsWith("Sift") == true }
            .map { it.toMap() }
    }

    val individualCardCount: Int get() = locked { cards.values.count { it["kind"] != "group" } }

    /** Adds a contact to the default address book. Returns its uid. */
    fun addContact(name: String, email: String): String = locked {
        val id = "C$nextId"
        nextId += 1
        val uid = "urn:uuid:${UUID.randomUUID().toString().lowercase()}"
        cards[id] = mutableMapOf(
            "id" to id, "uid" to uid, "kind" to "individual", "name" to mapOf("full" to name),
            "emails" to mapOf("e1" to mapOf("address" to email)), "addressBookIds" to mapOf("personal" to true),
        )
        cardState += 1
        uid
    }

    /** What a user does in Fastmail's UI: drag a contact into a group. */
    fun addMember(memberKey: String, groupName: String) = locked {
        val card = cards.values.firstOrNull { (it["name"] as? Map<String, Any?>)?.get("full") == groupName } ?: return@locked
        card["members"] = (card["members"] as? Map<String, Any?> ?: emptyMap()) + (memberKey to true)
        cardState += 1
    }

    private fun record(created: Set<String> = emptySet(), updated: Set<String> = emptySet(), destroyed: Set<String> = emptySet()) {
        emailState += 1
        changeLog += Change(emailState, created, updated, destroyed)
    }

    // MARK: - HTTP

    private fun json(value: Any?): ByteArray = SiftJson.encodeToString(JsonElement.serializer(), value.toJson()).toByteArray()

    fun respond(path: String, contentType: String?, body: ByteArray?): Triple<Int, ByteArray, String> = when {
        path == "/jmap/session" -> Triple(200, json(sessionObject()), "application/json")
        path == "/jmap/api" || path == "/jmap/api/" -> {
            val root = body?.let { runCatching { SiftJson.parseToJsonElement(it.decodeToString()).toAny() as? Map<String, Any?> }.getOrNull() }
            val calls = root?.get("methodCalls") as? List<List<Any?>>
            if (calls == null) {
                Triple(400, ByteArray(0), "text/plain")
            } else {
                val responses = locked { handle(calls) }
                Triple(200, json(mapOf("methodResponses" to responses, "sessionState" to "demo")), "application/json")
            }
        }
        path.startsWith("/jmap/download/") -> {
            val parts = path.split("/").filter { it.isNotEmpty() }
            val blobId = parts.getOrNull(3) ?: ""
            val data = locked { blobs[blobId] }
            if (data != null) {
                Triple(200, data, "application/octet-stream")
            } else {
                val text = locked { bodies[blobId.drop(1)]?.second } ?: ""
                Triple(200, text.toByteArray(), "text/plain")
            }
        }
        path.startsWith("/jmap/upload/") -> {
            val data = body ?: ByteArray(0)
            val type = contentType ?: "application/octet-stream"
            val blobId = locked {
                val id = "U$nextId"
                nextId += 1
                blobs[id] = data
                id
            }
            Triple(201, json(mapOf("accountId" to "A1", "blobId" to blobId, "type" to type, "size" to data.size)), "application/json")
        }
        // No EventSource in the demo; the app falls back to periodic refresh.
        else -> Triple(404, ByteArray(0), "text/plain")
    }

    private fun sessionObject(): Map<String, Any?> = mapOf(
        "apiUrl" to "https://$HOST/jmap/api/",
        "downloadUrl" to "https://$HOST/jmap/download/{accountId}/{blobId}/{name}?type={type}",
        "uploadUrl" to "https://$HOST/jmap/upload/{accountId}/",
        "eventSourceUrl" to "https://$HOST/jmap/event/?types={types}&closeafter={closeafter}&ping={ping}",
        "username" to "you@fastmail.com",
        "state" to "demo",
        "accounts" to mapOf("A1" to mapOf(
            "name" to "you@fastmail.com", "isReadOnly" to false,
            "accountCapabilities" to mapOf(
                JmapCapability.MAIL to emptyMap<String, Any>(), JmapCapability.SUBMISSION to emptyMap<String, Any>(),
                JmapCapability.CONTACTS to emptyMap<String, Any>(),
            ),
        )),
        "primaryAccounts" to mapOf(JmapCapability.MAIL to "A1", JmapCapability.SUBMISSION to "A1", JmapCapability.CONTACTS to "A1"),
        "capabilities" to mapOf(
            JmapCapability.CORE to mapOf("maxSizeUpload" to 50_000_000), JmapCapability.MAIL to emptyMap<String, Any>(),
            JmapCapability.SUBMISSION to mapOf("maxDelayedSend" to maxDelayedSend), JmapCapability.CONTACTS to emptyMap<String, Any>(),
        ),
    )

    // MARK: - Method dispatch

    private fun handle(calls: List<List<Any?>>): List<List<Any?>> {
        val responses = mutableListOf<List<Any?>>()
        for (call in calls) {
            if (call.size != 3) continue
            val name = call[0] as? String ?: continue
            val args = (call[1] as? Map<String, Any?>)?.toMutableMap() ?: continue
            val callId = call[2] as? String ?: continue
            // Resolve "#prop" result references against earlier responses.
            for (key in args.keys.filter { it.startsWith("#") }) {
                val ref = args[key] as? Map<String, Any?>
                val resultOf = ref?.get("resultOf") as? String
                val path = ref?.get("path") as? String
                val prior = responses.lastOrNull { it[2] == resultOf }?.get(1) as? Map<String, Any?>
                if (prior != null && path != null) args[key.drop(1)] = prior[path.drop(1)] ?: emptyList<Any>()
                args -= key
            }
            val result: List<List<Any?>> = when (name) {
                "Mailbox/get" -> listOf(listOf(name, mailboxGet(), callId))
                "Mailbox/set" -> listOf(listOf(name, mailboxSet(args), callId))
                "Identity/get" -> listOf(listOf(name, mapOf(
                    "accountId" to "A1", "state" to "1",
                    "list" to listOf(mapOf("id" to "I1", "name" to "You", "email" to "you@fastmail.com")),
                ), callId))
                "Email/query" -> listOf(listOf(name, emailQuery(args), callId))
                "Email/get" -> listOf(listOf(name, emailGet(args), callId))
                "Email/set" -> if (failsEmailSet) {
                    listOf(listOf("error", mapOf("type" to "serverFail", "description" to "demo failure"), callId))
                } else {
                    listOf(listOf(name, emailSet(args), callId))
                }
                "Email/changes" -> {
                    val changes = emailChanges(args)
                    listOf(listOf(if (changes == null) "error" else name, changes ?: mapOf("type" to "cannotCalculateChanges"), callId))
                }
                "EmailSubmission/set" -> emailSubmissionSet(args, callId, responses)
                "SearchSnippet/get" -> listOf(listOf(name, searchSnippets(args), callId))
                "AddressBook/get" -> listOf(listOf(name, mapOf("accountId" to "A1", "state" to "$cardState", "list" to books.values.toList()), callId))
                "AddressBook/set" -> listOf(listOf(name, addressBookSet(args), callId))
                "ContactCard/query" -> {
                    val ids = cards.keys.sorted()
                    val position = (args["position"] as? Number)?.toInt() ?: 0
                    val limit = (args["limit"] as? Number)?.toInt() ?: ids.size
                    listOf(listOf(name, mapOf("accountId" to "A1", "ids" to ids.drop(position).take(limit), "position" to position), callId))
                }
                "ContactCard/get" -> {
                    val ids = args["ids"] as? List<String> ?: cards.keys.toList()
                    listOf(listOf(name, mapOf("accountId" to "A1", "state" to "$cardState", "list" to ids.mapNotNull { cards[it] }), callId))
                }
                "ContactCard/set" -> listOf(listOf(name, cardSet(args), callId))
                else -> listOf(listOf("error", mapOf("type" to "unknownMethod"), callId))
            }
            responses.addAll(result)
        }
        return responses
    }

    private fun mailboxGet(): Map<String, Any?> {
        val list = mailboxes.values.map { box ->
            val id = box["id"] as String
            val inside = emails.values.filter { (it["mailboxIds"] as? Map<String, Any?>)?.get(id) == true }
            box.toMutableMap().apply {
                this["totalEmails"] = inside.size
                this["unreadEmails"] = inside.count { (it["keywords"] as? Map<String, Any?>)?.get("\$seen") != true }
            }
        }
        return mapOf("accountId" to "A1", "state" to "$mailboxState-$emailState", "list" to list)
    }

    private fun mailboxSet(args: Map<String, Any?>): Map<String, Any?> {
        val created = LinkedHashMap<String, Any?>()
        for ((key, value) in args["create"] as? Map<String, Map<String, Any?>> ?: emptyMap()) {
            val id = "MB$nextId"
            nextId += 1
            mailboxes[id] = mutableMapOf("id" to id, "name" to (value["name"] ?: "Untitled"), "parentId" to null, "role" to null, "sortOrder" to 20)
            created[key] = mapOf("id" to id)
        }
        val updated = LinkedHashMap<String, Any?>()
        for ((id, patch) in args["update"] as? Map<String, Map<String, Any?>> ?: emptyMap()) {
            val box = mailboxes[id] ?: continue
            for ((key, value) in patch) box[key] = value
            updated[id] = null
        }
        val destroyed = mutableListOf<String>()
        val notDestroyed = LinkedHashMap<String, Any?>()
        for (id in args["destroy"] as? List<String> ?: emptyList()) {
            val inUse = emails.values.any { (it["mailboxIds"] as? Map<String, Any?>)?.get(id) == true }
            if (inUse) {
                notDestroyed[id] = mapOf("type" to "mailboxHasEmail")
            } else {
                mailboxes -= id
                destroyed += id
            }
        }
        mailboxState += 1
        val result = mutableMapOf<String, Any?>("accountId" to "A1", "newState" to "$mailboxState", "created" to created,
            "updated" to updated, "destroyed" to destroyed)
        if (notDestroyed.isNotEmpty()) result["notDestroyed"] = notDestroyed
        return result
    }

    private fun emailQuery(args: Map<String, Any?>): Map<String, Any?> {
        val filter = args["filter"] as? Map<String, Any?>
        val list = emails.values.filter { matches(it, filter) }.sortedByDescending { it["receivedAt"] as String }
        val ids = list.map { it["id"] as String }
        val position = (args["position"] as? Number)?.toInt() ?: 0
        val limit = (args["limit"] as? Number)?.toInt() ?: ids.size
        return mapOf("accountId" to "A1", "queryState" to "$emailState", "position" to position, "total" to ids.size,
            "ids" to ids.drop(position).take(limit))
    }

    private fun matches(email: Map<String, Any?>, filter: Map<String, Any?>?): Boolean {
        if (filter == null) return true
        val op = filter["operator"] as? String
        val conditions = filter["conditions"] as? List<Map<String, Any?>>
        if (op != null && conditions != null) {
            return when (op) {
                "AND" -> conditions.all { matches(email, it) }
                "OR" -> conditions.any { matches(email, it) }
                else -> conditions.none { matches(email, it) }
            }
        }
        val boxes = email["mailboxIds"] as? Map<String, Any?> ?: emptyMap()
        val keywords = email["keywords"] as? Map<String, Any?> ?: emptyMap()
        val received = email["receivedAt"] as? String ?: ""
        val from = (email["from"] as? List<Map<String, Any?>>)?.firstOrNull()?.let { "${it["name"] ?: ""} ${it["email"] ?: ""}" } ?: ""
        val subject = email["subject"] as? String ?: ""
        val body = bodies[email["id"] as? String ?: ""]?.second ?: ""
        fun contains(haystack: String, key: String): Boolean {
            val needle = filter[key] as? String ?: return true
            return haystack.contains(needle, ignoreCase = true)
        }
        (filter["inMailbox"] as? String)?.let { if (boxes[it] != true) return false }
        (filter["before"] as? String)?.let { if (received >= it) return false }
        (filter["after"] as? String)?.let { if (received < it) return false }
        (filter["hasKeyword"] as? String)?.let { if (keywords[it] != true) return false }
        (filter["notKeyword"] as? String)?.let { if (keywords[it] == true) return false }
        return contains(from, "from") && contains(subject, "subject") && contains(body, "body") &&
            contains("$from $subject $body", "text")
    }

    private fun emailGet(args: Map<String, Any?>): Map<String, Any?> {
        val ids = args["ids"] as? List<String> ?: emails.keys.toList()
        val properties = (args["properties"] as? List<String> ?: emptyList()).toSet()
        val list = ids.mapNotNull { id ->
            val email = emails[id]?.toMutableMap() ?: return@mapNotNull null
            val body = bodies[id]
            if (("htmlBody" in properties || "textBody" in properties) && body != null) {
                email["htmlBody"] = listOf(mapOf("partId" to "1", "blobId" to "B$id", "type" to if (body.first == null) "text/plain" else "text/html", "size" to 100))
                email["textBody"] = listOf(mapOf("partId" to "2", "blobId" to "B$id", "type" to "text/plain", "size" to 100))
                email["attachments"] = email["attachments"] ?: emptyList<Any>()
                email["bodyValues"] = mapOf("2" to mapOf("value" to body.second), "1" to mapOf("value" to (body.first ?: body.second)))
            }
            email
        }
        return mapOf("accountId" to "A1", "state" to "$emailState", "list" to list, "notFound" to ids.filter { emails[it] == null })
    }

    private fun emailSet(args: Map<String, Any?>): Map<String, Any?> {
        val updated = LinkedHashMap<String, Any?>()
        val notUpdated = LinkedHashMap<String, Any?>()
        val created = LinkedHashMap<String, Any?>()
        for ((id, patch) in args["update"] as? Map<String, Map<String, Any?>> ?: emptyMap()) {
            if (emails[id] == null) {
                notUpdated[id] = mapOf("type" to "notFound")
                continue
            }
            apply(patch, id)
            updated[id] = null
        }
        for ((key, value) in args["create"] as? Map<String, Map<String, Any?>> ?: emptyMap()) {
            val id = "M$nextId"
            nextId += 1
            val email = value.toMutableMap()
            email["id"] = id
            email["threadId"] = "T$id"
            email["blobId"] = "B$id"
            email["receivedAt"] = JmapDates.format(Instant.now())
            val text = ((value["bodyValues"] as? Map<String, Map<String, Any?>>)?.values?.firstOrNull()?.get("value") as? String) ?: ""
            email["preview"] = text.take(180)
            email["hasAttachment"] = !(value["attachments"] as? List<Any?>).isNullOrEmpty()
            email["size"] = text.toByteArray().size
            emails[id] = email
            bodies[id] = null to text
            created[key] = mapOf("id" to id, "threadId" to "T$id", "blobId" to "B$id")
        }
        val destroyed = mutableListOf<String>()
        for (id in args["destroy"] as? List<String> ?: emptyList()) {
            if (emails.remove(id) != null) {
                bodies -= id
                destroyed += id
            }
        }
        if (updated.isNotEmpty() || created.isNotEmpty() || destroyed.isNotEmpty()) {
            record(created = created.values.mapNotNull { (it as? Map<String, Any?>)?.get("id") as? String }.toSet(),
                updated = updated.keys, destroyed = destroyed.toSet())
        }
        val result = mutableMapOf<String, Any?>("accountId" to "A1", "newState" to "$emailState", "updated" to updated,
            "created" to created, "destroyed" to destroyed)
        if (notUpdated.isNotEmpty()) result["notUpdated"] = notUpdated
        return result
    }

    private fun apply(patch: Map<String, Any?>, id: String) {
        val email = emails[id] ?: return
        for ((path, value) in patch) {
            val parts = path.split("/", limit = 2)
            val map = (email[parts[0]] as? Map<String, Any?>)
            if (parts.size == 2 && map != null) {
                email[parts[0]] = if (value == null) map - parts[1] else map + (parts[1] to true)
            } else {
                email[path] = value
            }
        }
    }

    private fun emailChanges(args: Map<String, Any?>): Map<String, Any?>? {
        val since = (args["sinceState"] as? String)?.toIntOrNull() ?: return null
        if (since > emailState || since < (changeLog.firstOrNull()?.state ?: 1) - 1) return null
        val created = mutableSetOf<String>()
        val updated = mutableSetOf<String>()
        val destroyed = mutableSetOf<String>()
        for (entry in changeLog) {
            if (entry.state <= since) continue
            created += entry.created
            updated += entry.updated - created
            destroyed += entry.destroyed
        }
        return mapOf("accountId" to "A1", "oldState" to "$since", "newState" to "$emailState", "hasMoreChanges" to false,
            "created" to created.toList(), "updated" to updated.toList(), "destroyed" to destroyed.toList())
    }

    private fun emailSubmissionSet(args: Map<String, Any?>, callId: String, responses: List<List<Any?>>): List<List<Any?>> {
        val created = LinkedHashMap<String, Any?>()
        val updates = LinkedHashMap<String, Map<String, Any?>>()
        val onSuccess = args["onSuccessUpdateEmail"] as? Map<String, Map<String, Any?>> ?: emptyMap()
        for ((key, value) in args["create"] as? Map<String, Map<String, Any?>> ?: emptyMap()) {
            var emailId = value["emailId"] as? String ?: ""
            if (emailId.startsWith("#")) {
                val ref = emailId.drop(1)
                for (response in responses) {
                    val createdMap = (response[1] as? Map<String, Any?>)?.get("created") as? Map<String, Map<String, Any?>>
                    (createdMap?.get(ref)?.get("id") as? String)?.let { emailId = it }
                }
            }
            val submissionId = "S$nextId"
            nextId += 1
            val envelope = value["envelope"] as? Map<String, Any?>
            val hold = (((envelope?.get("mailFrom") as? Map<String, Any?>)?.get("parameters") as? Map<String, Any?>)?.get("HOLDFOR") as? String)
                ?.toIntOrNull() ?: 0
            submissions[submissionId] = Submission(emailId, if (hold > 0) "pending" else "final", hold)
            created[key] = mapOf("id" to submissionId, "undoStatus" to if (hold > 0) "pending" else "final")
            onSuccess["#$key"]?.let { updates[emailId] = it }
        }
        val updated = LinkedHashMap<String, Any?>()
        val notUpdated = LinkedHashMap<String, Any?>()
        for ((id, patch) in args["update"] as? Map<String, Map<String, Any?>> ?: emptyMap()) {
            val submission = submissions[id]
            if (patch["undoStatus"] == "canceled" && submission?.undoStatus == "pending") {
                submission.undoStatus = "canceled"
                updated[id] = null
            } else {
                notUpdated[id] = mapOf("type" to "cannotUnsend", "description" to "Already sent")
            }
        }
        val response = mutableMapOf<String, Any?>("accountId" to "A1", "created" to created, "updated" to updated)
        if (notUpdated.isNotEmpty()) response["notUpdated"] = notUpdated
        val result = mutableListOf<List<Any?>>(listOf("EmailSubmission/set", response, callId))
        if (updates.isNotEmpty()) result.add(listOf("Email/set", emailSet(mapOf("update" to updates)), callId))
        return result
    }

    private fun searchSnippets(args: Map<String, Any?>): Map<String, Any?> {
        val ids = args["emailIds"] as? List<String> ?: emptyList()
        return mapOf("accountId" to "A1", "list" to ids.map { id ->
            mapOf("emailId" to id, "subject" to emails[id]?.get("subject"), "preview" to emails[id]?.get("preview"))
        })
    }

    private fun addressBookSet(args: Map<String, Any?>): Map<String, Any?> {
        // Fastmail's answer, verbatim.
        val notCreated = (args["create"] as? Map<String, Any?> ?: emptyMap()).keys.associateWith {
            mapOf("type" to "forbidden", "description" to "AddressBooks may not be created")
        }
        return mapOf("accountId" to "A1", "newState" to "$cardState", "notCreated" to notCreated)
    }

    private fun cardSet(args: Map<String, Any?>): Map<String, Any?> {
        val created = LinkedHashMap<String, Any?>()
        val updated = LinkedHashMap<String, Any?>()
        val notCreated = LinkedHashMap<String, Any?>()
        val notUpdated = LinkedHashMap<String, Any?>()
        val rejection = mapOf("type" to "invalidProperties", "properties" to listOf("members"), "description" to "members must be contact uids")
        fun hasAddressMember(keys: Collection<String>) =
            rejectsAddressMembers && keys.any { it.startsWith("mailto:") || it.startsWith("members/mailto:") }
        for ((key, value) in args["create"] as? Map<String, Map<String, Any?>> ?: emptyMap()) {
            if (hasAddressMember((value["members"] as? Map<String, Any?> ?: emptyMap()).keys)) {
                notCreated[key] = rejection
                continue
            }
            val id = "C$nextId"
            nextId += 1
            cards[id] = value.toMutableMap().apply { this["id"] = id }
            created[key] = mapOf("id" to id)
        }
        for ((id, patch) in args["update"] as? Map<String, Map<String, Any?>> ?: emptyMap()) {
            val card = cards[id] ?: continue
            if (hasAddressMember(patch.keys)) {
                notUpdated[id] = rejection
                continue
            }
            for ((path, value) in patch) {
                val parts = path.split("/", limit = 2)
                if (parts.size == 2) {
                    val key = parts[1].replace("~1", "/").replace("~0", "~")
                    val map = (card[parts[0]] as? Map<String, Any?> ?: emptyMap()).toMutableMap()
                    if (value == null) map -= key else map[key] = value
                    card[parts[0]] = map
                } else {
                    if (value == null) card -= path else card[path] = value
                }
            }
            updated[id] = null
        }
        cardState += 1
        val result = mutableMapOf<String, Any?>("accountId" to "A1", "newState" to "$cardState", "created" to created, "updated" to updated)
        if (notCreated.isNotEmpty()) result["notCreated"] = notCreated
        if (notUpdated.isNotEmpty()) result["notUpdated"] = notUpdated
        return result
    }
}
