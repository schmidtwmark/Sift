package com.markschmidt.sift.core.sync

import com.markschmidt.sift.core.compose.OutgoingMessage
import com.markschmidt.sift.core.compose.SendException
import com.markschmidt.sift.core.compose.Sending
import com.markschmidt.sift.core.jmap.ChangesResponse
import com.markschmidt.sift.core.jmap.Email
import com.markschmidt.sift.core.jmap.EmailAddress
import com.markschmidt.sift.core.jmap.GetResponse
import com.markschmidt.sift.core.jmap.Identity
import com.markschmidt.sift.core.jmap.JmapCapability
import com.markschmidt.sift.core.jmap.JmapClient
import com.markschmidt.sift.core.jmap.JmapDates
import com.markschmidt.sift.core.jmap.JmapException
import com.markschmidt.sift.core.jmap.JsonValue
import com.markschmidt.sift.core.jmap.Mailbox
import com.markschmidt.sift.core.jmap.MailboxRole
import com.markschmidt.sift.core.jmap.MethodCall
import com.markschmidt.sift.core.jmap.QueryResponse
import com.markschmidt.sift.core.jmap.SearchSnippet
import com.markschmidt.sift.core.jmap.SetResponse
import com.markschmidt.sift.core.jmap.arr
import com.markschmidt.sift.core.jmap.obj
import com.markschmidt.sift.core.jmap.strings
import com.markschmidt.sift.core.screener.ContactsRuleStore
import com.markschmidt.sift.core.screener.EmailPatch
import com.markschmidt.sift.core.screener.OFF
import com.markschmidt.sift.core.screener.ON
import com.markschmidt.sift.core.screener.Router
import com.markschmidt.sift.core.screener.RoutingContext
import com.markschmidt.sift.core.screener.RuleSuggestion
import com.markschmidt.sift.core.screener.SortReason
import com.markschmidt.sift.core.screener.SortingInference
import com.markschmidt.sift.core.screener.SpecialMailboxes
import com.markschmidt.sift.core.screener.applying
import com.markschmidt.sift.core.search.SearchQuery
import com.markschmidt.sift.core.store.BodyRecord
import com.markschmidt.sift.core.store.Keyword
import com.markschmidt.sift.core.store.MailStore
import com.markschmidt.sift.core.store.MessageRecord
import com.markschmidt.sift.core.store.SenderRecord
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull
import java.time.Instant
import java.util.UUID

/**
 * Keeps [MailStore] in step with Fastmail, applies Screener routing, and
 * performs every mutation the UI asks for.
 *
 * Confined to one thread at a time, like the Swift actor it's ported from:
 * calls interleave only where they suspend.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SyncEngine(val client: JmapClient, val store: MailStore) {
    companion object {
        const val SCREENER_NAME = "Screener"
        const val SCREENED_OUT_NAME = "Screened Out"
    }

    object Key {
        const val EMAIL_STATE = "state.Email"
        const val MAILBOX_STATE = "state.Mailbox"
        const val ACTIVATED_AT = "screener.activatedAt"
        const val SCREENER_ID = "mailbox.screener"
        const val SCREENED_OUT_ID = "mailbox.screenedOut"
    }

    private val confined = Dispatchers.Default.limitedParallelism(1)
    private suspend fun <T> confined(block: suspend () -> T): T = withContext(confined) { block() }

    private val rules = ContactsRuleStore(client)

    /** How much history the first sync pulls down. Older mail is fetched on demand. */
    var initialSyncLimit = 3000

    @Volatile var mailboxes: SpecialMailboxes? = null
        private set
    @Volatile var identities: List<Identity> = emptyList()
        private set
    @Volatile var activatedAt: Instant = Instant.now()
        private set
    private var isRefreshing = false
    private var refreshAgain = false

    /**
     * Called with messages that arrived during this session (not on initial
     * sync), after routing. The app turns these into notifications.
     */
    private var newMailHandler: (suspend (List<MessageRecord>) -> Unit)? = null

    fun onNewMail(handler: suspend (List<MessageRecord>) -> Unit) {
        newMailHandler = handler
    }

    // MARK: - Lifecycle

    /**
     * First-run and launch work: mailboxes, identities, rules, then mail.
     * [activatedAtOverride] sets when the Screener was switched on (demo mode).
     */
    suspend fun start(activatedAtOverride: Instant? = null) = confined {
        client.session(refresh = true)
        val stored = store.value(Key.ACTIVATED_AT)?.let(JmapDates::parse)
        if (activatedAtOverride == null && stored != null) {
            activatedAt = stored
        } else {
            activatedAt = activatedAtOverride ?: Instant.now()
            store.setValue(JmapDates.format(activatedAt), Key.ACTIVATED_AT)
        }
        syncMailboxes()
        syncIdentities()
        syncRules()
        if (store.value(Key.EMAIL_STATE) == null) initialEmailSync() else refresh()
    }

    /** Pulls every change since the last sync, then routes new mail. */
    suspend fun refresh(): Unit = confined {
        if (isRefreshing) {
            refreshAgain = true
            return@confined
        }
        isRefreshing = true
        try {
            do {
                refreshAgain = false
                syncMailboxes()
                val created = syncEmailChanges()
                route()
                val handler = newMailHandler
                if (created.isNotEmpty() && handler != null) handler(store.messages(created))
            } while (refreshAgain)
        } finally {
            isRefreshing = false
        }
    }

    /**
     * Holds Fastmail's EventSource open and refreshes on every state change.
     * Runs until cancelled, reconnecting with backoff.
     */
    suspend fun listen() {
        var backoff = 2_000L
        while (currentCoroutineContext().isActive) {
            try {
                client.stateChanges().collect { change ->
                    backoff = 2_000L
                    val types = change.changed[client.accountId()] ?: return@collect
                    if (types["ContactCard"] != null && types["ContactCard"] != rules.state) runCatching { syncRules() }
                    if (types["Email"] != null || types["Mailbox"] != null) runCatching { refresh() }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                // Fall through to reconnect.
            }
            delay(backoff)
            backoff = minOf(backoff * 2, 120_000L)
            try { refresh() } catch (cancelled: CancellationException) { throw cancelled } catch (_: Throwable) {}
        }
    }

    // MARK: - Mailboxes, identities, rules

    suspend fun syncMailboxes() = confined {
        val accountId = client.accountId()
        val response = client.perform(listOf(MethodCall("Mailbox/get", obj("accountId" to accountId), "boxes")))
        val result = response.result<GetResponse<Mailbox>>("boxes")
        if (result.state != null && result.state == store.value(Key.MAILBOX_STATE) && mailboxes != null) return@confined
        val list = result.list.toMutableList()
        val screener = ensureMailbox(SCREENER_NAME, Key.SCREENER_ID, list)
        val screenedOut = ensureMailbox(SCREENED_OUT_NAME, Key.SCREENED_OUT_ID, list)
        store.replaceMailboxes(list)
        store.setValue(result.state, Key.MAILBOX_STATE)

        fun role(role: MailboxRole) = list.firstOrNull { it.role == role.raw }?.id
        val inbox = role(MailboxRole.INBOX) ?: throw JmapException.MissingResponse("inbox mailbox")
        mailboxes = SpecialMailboxes(
            inbox = inbox, screener = screener, screenedOut = screenedOut,
            archive = role(MailboxRole.ARCHIVE), trash = role(MailboxRole.TRASH), junk = role(MailboxRole.JUNK),
            sent = role(MailboxRole.SENT), drafts = role(MailboxRole.DRAFTS),
        )
    }

    private suspend fun ensureMailbox(name: String, key: String, list: MutableList<Mailbox>): String {
        store.value(key)?.let { id -> if (list.any { it.id == id }) return id }
        list.firstOrNull { it.name == name && it.parentId == null }?.let { existing ->
            store.setValue(existing.id, key)
            return existing.id
        }
        val id = createMailbox(name)
        list += Mailbox(id = id, name = name, parentId = null, role = null, sortOrder = 5)
        store.setValue(id, key)
        return id
    }

    /** Creates a label (a Fastmail mailbox). Returns its id. */
    suspend fun createMailbox(name: String): String = confined {
        val accountId = client.accountId()
        val response = client.perform(listOf(MethodCall("Mailbox/set", obj(
            "accountId" to accountId,
            "create" to obj("new" to obj("name" to name, "parentId" to null)),
        ), "create")))
        val result = response.result<SetResponse>("create")
        result.throwIfFailed("create the “$name” mailbox")
        val id = result.createdId("new") ?: throw JmapException.MissingResponse("Mailbox/set")
        if (mailboxes != null) syncMailboxes()
        id
    }

    /**
     * Puts [ids] (your folders) in this order, here and in Fastmail, by
     * renumbering their sortOrder. They stay after the system mailboxes, so
     * Fastmail's own folder list keeps Inbox, Archive and the rest on top.
     */
    suspend fun reorderMailboxes(ids: List<String>) = confined {
        val current = store.mailboxes()
        val byId = current.associateBy { it.id }
        val afterSystem = (current.filter { it.role != null }.maxOfOrNull { it.sortOrder } ?: 0) + 1
        val base = maxOf(afterSystem, ids.mapNotNull { byId[it]?.sortOrder }.minOrNull() ?: afterSystem)
        val changes = LinkedHashMap<String, Int>()
        ids.forEachIndexed { index, id -> if (byId[id] != null && byId[id]?.sortOrder != base + index) changes[id] = base + index }
        if (changes.isEmpty()) return@confined

        // Shown at once; put back if Fastmail says no.
        val before = changes.keys.associateWith { byId[it]?.sortOrder ?: 0 }
        store.setSortOrders(changes)
        try {
            val response = client.perform(listOf(MethodCall("Mailbox/set", obj(
                "accountId" to client.accountId(),
                "update" to changes.mapValues { obj("sortOrder" to it.value) },
            ), "order")))
            response.result<SetResponse>("order").throwIfFailed("reorder your folders")
        } catch (error: Throwable) {
            runCatching { store.setSortOrders(before) }
            throw error
        }
    }

    suspend fun syncIdentities() = confined {
        val response = client.perform(
            listOf(MethodCall("Identity/get", obj("accountId" to client.accountId()), "ids")),
            listOf(JmapCapability.CORE, JmapCapability.MAIL, JmapCapability.SUBMISSION),
        )
        identities = runCatching { response.result<GetResponse<Identity>>("ids").list }.getOrDefault(emptyList())
    }

    /** Reloads sender rules from Fastmail Contacts into the local cache. */
    suspend fun syncRules() = confined {
        val loaded = rules.load(store.mailboxes().map { it.id })
        store.replaceSenders(loaded)
        store.setLabelIcons(rules.labelIcons)
    }

    /**
     * Sets a label's icon (null goes back to the one guessed from its name).
     * Shows at once, and syncs to other devices through the label's contact group.
     */
    suspend fun setLabelIcon(symbol: String?, mailboxId: String) = confined {
        val before = store.labelIcons()
        store.setLabelIcons(if (symbol != null) before + (mailboxId to symbol) else before - mailboxId)
        try {
            val name = store.mailboxes().firstOrNull { it.id == mailboxId }?.name ?: "Label"
            rules.setIcon(symbol, mailboxId, name)
        } catch (error: Throwable) {
            runCatching { store.setLabelIcons(before) }
            throw error
        }
    }

    // MARK: - Email sync

    suspend fun initialEmailSync() = confined {
        val accountId = client.accountId()
        // Recent history across the whole account (this is the Everything view).
        val firstState = fetchQuery(null, initialSyncLimit, accountId)
        // Make sure the piles people act on are complete, not just recent.
        mailboxes?.let { boxes ->
            for (id in listOf(boxes.screener, boxes.inbox)) fetchQuery(obj("inMailbox" to id), 2000, accountId)
            boxes.sent?.let { learnSentRecipients(it, accountId) }
        }
        store.setValue(firstState, Key.EMAIL_STATE)
        route()
    }

    /** Queries newest-first and stores up to [limit] messages. Returns the Email state. */
    private suspend fun fetchQuery(filter: JsonValue?, limit: Int, accountId: String, skipKnown: Boolean = true): String? {
        val pageSize = 500
        var position = 0
        var state: String? = null
        val known = if (skipKnown) store.knownMessageIds() else emptySet()
        while (position < limit) {
            val query = linkedMapOf<String, JsonValue>(
                "accountId" to JsonPrimitive(accountId),
                "sort" to arr(obj("property" to "receivedAt", "isAscending" to false)),
                "position" to JsonPrimitive(position),
                "limit" to JsonPrimitive(minOf(pageSize, limit - position)),
            )
            if (filter != null) query["filter"] = filter
            val ids = client.perform(listOf(MethodCall("Email/query", JsonObject(query), "q"))).result<QueryResponse>("q").ids
            val missing = ids.filter { it !in known }
            if (missing.isNotEmpty() || state == null) {
                val emails = getEmails(missing, accountId)
                state = state ?: emails.state
                storeServerEmails(emails.list)
            }
            position += ids.size
            if (ids.size < pageSize) break
        }
        return state
    }

    private suspend fun getEmails(ids: List<String>, accountId: String): GetResponse<Email> =
        client.perform(listOf(MethodCall("Email/get", obj(
            "accountId" to accountId, "ids" to strings(ids), "properties" to strings(Email.listProperties),
        ), "get"))).result("get")

    /** Hey-style: anyone you've written to skips the Screener. */
    private suspend fun learnSentRecipients(sentMailbox: String, accountId: String) {
        val response = client.perform(listOf(
            MethodCall("Email/query", obj(
                "accountId" to accountId,
                "filter" to obj("inMailbox" to sentMailbox),
                "sort" to arr(obj("property" to "receivedAt", "isAscending" to false)),
                "limit" to 1000,
            ), "q"),
            MethodCall("Email/get", obj(
                "accountId" to accountId,
                "#ids" to MethodCall.reference("q", "Email/query", "/ids"),
                "properties" to strings(listOf("id", "to", "cc", "bcc")),
            ), "get"),
        ))
        val emails = response.result<GetResponse<Email>>("get").list
        store.recordSentRecipients(emails.flatMap { it.recipients }.map { it.normalized }.filter { it.isNotEmpty() })
    }

    /** Applies `Email/changes` since the stored state. Returns ids of newly created messages. */
    suspend fun syncEmailChanges(): List<String> = confined {
        var sinceState = store.value(Key.EMAIL_STATE)
        if (sinceState == null) {
            initialEmailSync()
            return@confined emptyList()
        }
        val accountId = client.accountId()
        val created = mutableListOf<String>()
        while (true) {
            val response = client.perform(listOf(
                MethodCall("Email/changes", obj("accountId" to accountId, "sinceState" to sinceState, "maxChanges" to 500), "changes"),
                MethodCall("Email/get", obj(
                    "accountId" to accountId,
                    "#ids" to MethodCall.reference("changes", "Email/changes", "/created"),
                    "properties" to strings(Email.listProperties),
                ), "created"),
                MethodCall("Email/get", obj(
                    "accountId" to accountId,
                    "#ids" to MethodCall.reference("changes", "Email/changes", "/updated"),
                    "properties" to strings(Email.listProperties),
                ), "updated"),
            ))
            val changes = try {
                response.result<ChangesResponse>("changes")
            } catch (error: JmapException.Method) {
                if (error.type != "cannotCalculateChanges") throw error
                store.setValue(null, Key.EMAIL_STATE)
                initialEmailSync()
                return@confined emptyList()
            }
            val fresh = response.result<GetResponse<Email>>("created").list
            val updated = response.result<GetResponse<Email>>("updated").list
            storeServerEmails(fresh + updated)
            store.delete(changes.destroyed)
            mailboxes?.sent?.let { sent ->
                val mine = fresh.filter { it.mailboxIds?.get(sent) == true }
                store.recordSentRecipients(mine.flatMap { it.recipients }.map { it.normalized }.filter { it.isNotEmpty() })
            }
            created += fresh.map { it.id }
            sinceState = changes.newState
            store.setValue(sinceState, Key.EMAIL_STATE)
            if (!changes.hasMoreChanges) break
        }
        created
    }

    /** Fetches older messages for a list that's been scrolled to the end. */
    suspend fun loadOlder(mailboxId: String?, before: Instant, count: Int = 200) = confined {
        val filter = linkedMapOf<String, JsonValue>("before" to JsonPrimitive(JmapDates.format(before)))
        if (mailboxId != null) filter["inMailbox"] = JsonPrimitive(mailboxId)
        fetchQuery(JsonObject(filter), count, client.accountId())
        Unit
    }

    // MARK: - Routing

    /**
     * Files unrouted Inbox mail according to sender rules. Idempotent across
     * devices thanks to the `$siftrouted` keyword.
     */
    suspend fun route() = confined {
        val boxes = mailboxes ?: return@confined
        val candidates = store.messagesIn(boxes.inbox).filter { !it.isRouted && it.receivedAt >= activatedAt }
        if (candidates.isEmpty()) return@confined

        val known = rules.contactAddresses.toMutableSet()
        for (candidate in candidates) if (store.hasWrittenTo(candidate.fromEmail)) known += candidate.fromEmail
        val context = RoutingContext(
            mailboxes = boxes,
            activatedAt = activatedAt,
            ownAddresses = identities.map { it.email.lowercase() }.toSet(),
            knownAddresses = known,
            rules = store.senders().associateBy { it.email },
        )
        val plan = Router.plan(candidates, context)
        for (address in plan.autoApproved) {
            runCatching { saveRules(listOf(SenderRecord(email = address.normalized, name = address.name, status = SenderRecord.Status.SCREENED_IN))) }
        }
        apply(plan.patches)
    }

    // MARK: - Screener actions

    suspend fun screenIn(sender: String, name: String?, labels: List<String>) = confined {
        val boxes = mailboxes ?: return@confined
        val rule = (store.sender(sender) ?: SenderRecord(email = sender, name = name)).copy(
            status = SenderRecord.Status.SCREENED_IN,
            // Empty means "Inbox"; Inbox plus labels keeps the Inbox in the set.
            labelIds = if (labels == listOf(boxes.inbox)) emptyList() else labels,
            updatedAt = Instant.now(),
        )
        saveRules(listOf(rule))
        val waiting = store.messagesFrom(sender, boxes.screener)
        apply(Router.screenIn(waiting, labels, boxes))
    }

    suspend fun screenOut(sender: String, name: String?) = confined {
        val boxes = mailboxes ?: return@confined
        val rule = (store.sender(sender) ?: SenderRecord(email = sender, name = name)).copy(
            status = SenderRecord.Status.SCREENED_OUT, notify = false, badge = false, updatedAt = Instant.now(),
        )
        saveRules(listOf(rule))
        val waiting = store.messagesFrom(sender, boxes.screener)
        apply(Router.screenOut(waiting, boxes))
    }

    /** Saves a rule edited in sender settings. With [refile], the sender's existing mail moves to match. */
    suspend fun updateRule(rule: SenderRecord, refile: Boolean) = confined {
        val boxes = mailboxes ?: return@confined
        val previous = store.sender(rule.email)
        saveRules(listOf(rule))
        if (!refile) return@confined
        val existing = store.messagesFrom(rule.email)
        when (rule.status) {
            SenderRecord.Status.SCREENED_OUT -> {
                // Leave trash and junk alone; everything else moves to Screened Out.
                val untouchable = listOfNotNull(boxes.screenedOut, boxes.trash, boxes.junk).toSet()
                val live = existing.filter { message -> message.mailboxIds.none { it in untouchable } }
                apply(Router.screenOut(live, boxes))
            }
            SenderRecord.Status.SCREENED_IN -> {
                val oldLabels = (previous?.labelIds ?: emptyList()).toSet() + boxes.screener + boxes.screenedOut
                val destinations = rule.labelIds.ifEmpty { listOf(boxes.inbox) }
                val patches = LinkedHashMap<String, EmailPatch>()
                for (message in existing) {
                    val from = message.mailboxIds.filter { it in oldLabels || it == boxes.inbox }
                    if (from.isNotEmpty()) patches[message.id] = Router.move(from, destinations)
                }
                apply(patches)
            }
            SenderRecord.Status.UNKNOWN -> Unit
        }
    }

    private suspend fun saveRules(batch: List<SenderRecord>) {
        val names = store.mailboxes().associate { it.id to it.name }
        // Fastmail first: if it refuses, the local copy must not claim otherwise.
        rules.save(batch, names)
        for (rule in batch) store.save(rule)
    }

    // MARK: - Message actions

    suspend fun setKeyword(keyword: String, on: Boolean, ids: List<String>) =
        apply(ids.associateWith { mapOf("keywords/$keyword" to if (on) ON else OFF) })

    /** Adds and removes mailboxes (labels) on messages. */
    suspend fun relabel(ids: List<String>, add: List<String>, remove: List<String>) =
        apply(ids.associateWith { Router.move(remove, add) })

    /**
     * Archive in Fastmail's labels model: drop the current label; if nothing is
     * left, the message lives in Archive. Returns where each message was, so
     * it can be undone exactly.
     */
    suspend fun archive(ids: List<String>, fromMailbox: String?): Map<String, List<String>> = confined {
        val boxes = mailboxes ?: return@confined emptyMap()
        val messages = store.messages(ids)
        val patches = LinkedHashMap<String, EmailPatch>()
        for (message in messages) {
            val removing = listOf(fromMailbox ?: boxes.inbox)
            val remaining = message.mailboxIds.toSet() - removing.toSet()
            val patch = Router.move(removing, emptyList()).toMutableMap()
            if (remaining.isEmpty() && boxes.archive != null) patch["mailboxIds/${boxes.archive}"] = ON
            patches[message.id] = patch
        }
        apply(patches)
        messages.associate { it.id to it.mailboxIds }
    }

    suspend fun moveToTrash(ids: List<String>): Map<String, List<String>> =
        mailboxes?.trash?.let { replaceMailboxes(ids, it) } ?: emptyMap()

    suspend fun moveToJunk(ids: List<String>): Map<String, List<String>> =
        mailboxes?.junk?.let { replaceMailboxes(ids, it) } ?: emptyMap()

    private suspend fun replaceMailboxes(ids: List<String>, mailboxId: String): Map<String, List<String>> = confined {
        val messages = store.messages(ids)
        apply(messages.associate { it.id to Router.move(it.mailboxIds, listOf(mailboxId)) })
        messages.associate { it.id to it.mailboxIds }
    }

    /** Undo: puts messages back exactly where they were. */
    suspend fun restore(placement: Map<String, List<String>>) = confined {
        val messages = store.messages(placement.keys.toList())
        apply(messages.mapNotNull { message -> placement[message.id]?.let { message.id to Router.move(message.mailboxIds, it) } }.toMap())
    }

    /**
     * Changes sent to Fastmail but not yet confirmed, per message. Copies
     * fetched meanwhile get them re-applied, so a sync that races a change (an
     * EventSource push mid-request) can't flip it back on screen.
     */
    private val pending = mutableMapOf<String, MutableList<Pair<UUID, EmailPatch>>>()

    private fun clearPending(token: UUID, ids: Iterable<String>) {
        for (id in ids) {
            pending[id]?.removeAll { it.first == token }
            if (pending[id]?.isEmpty() == true) pending -= id
        }
    }

    /**
     * Sends patches to Fastmail and mirrors them locally right away. If
     * Fastmail refuses or the request fails, the local copy is put back.
     */
    suspend fun apply(patches: Map<String, EmailPatch>) = confined {
        if (patches.isEmpty()) return@confined
        val accountId = client.accountId()
        val token = UUID.randomUUID()
        for ((id, patch) in patches) pending.getOrPut(id) { mutableListOf() } += token to patch
        try {
            val current = store.messages(patches.keys.toList())
            store.upsert(current.mapNotNull { message -> patches[message.id]?.let { message.applying(it) } })
            try {
                for (chunk in patches.entries.chunked(200)) {
                    val update = JsonObject(chunk.associate { it.key to JsonObject(it.value) })
                    val response = client.perform(listOf(MethodCall("Email/set", obj("accountId" to accountId, "update" to update), "set")))
                    val result = response.result<SetResponse>("set")
                    val failed = result.notUpdated
                    if (!failed.isNullOrEmpty()) {
                        // Roll the optimistic copy back to the server's truth.
                        clearPending(token, failed.keys)
                        storeServerEmails(getEmails(failed.keys.toList(), accountId).list)
                        result.throwIfFailed("update ${failed.size} message${if (failed.size == 1) "" else "s"}")
                    }
                }
            } catch (error: Throwable) {
                // Never leave the screen claiming a change Fastmail didn't make.
                clearPending(token, patches.keys)
                runCatching { store.upsert(current) }
                throw error
            }
        } finally {
            clearPending(token, patches.keys)
        }
    }

    /** Stores messages fetched from Fastmail, keeping in-flight changes. */
    private suspend fun storeServerEmails(emails: List<Email>) {
        if (emails.isEmpty()) return
        store.upsert(emails.map { email ->
            (pending[email.id] ?: emptyList()).fold(MessageRecord(email)) { record, (_, patch) -> record.applying(patch) }
        })
    }

    // MARK: - Bodies & attachments

    suspend fun body(messageId: String): BodyRecord = confined {
        store.body(messageId)?.let { return@confined it }
        val response = client.perform(listOf(MethodCall("Email/get", obj(
            "accountId" to client.accountId(),
            "ids" to arr(messageId),
            "properties" to strings(Email.bodyProperties),
            "bodyProperties" to strings(listOf("partId", "blobId", "size", "name", "type", "charset", "disposition", "cid")),
            "fetchHTMLBodyValues" to true,
            "fetchTextBodyValues" to true,
        ), "body")))
        val email = response.result<GetResponse<Email>>("body").list.firstOrNull()
            ?: throw JmapException.MissingResponse("Email/get body")
        val body = BodyAssembler.assemble(email)
        store.save(body)
        body
    }

    suspend fun download(blobId: String, name: String, type: String): ByteArray = client.download(blobId, name, type)

    // MARK: - Learning from existing mail

    /** The user's own folders: no system role, not Sift's piles. */
    private suspend fun userLabelIds(): Set<String> {
        val boxes = mailboxes ?: return emptySet()
        return store.mailboxes().filter { it.role == null && it.id != boxes.screener && it.id != boxes.screenedOut }.map { it.id }.toSet()
    }

    /**
     * Rules implied by where the user already files each sender's mail.
     * [ignored] holds folders with no filing signal (an unsorted import).
     */
    suspend fun suggestRules(ignored: Set<String> = emptySet()): List<RuleSuggestion> = confined {
        val boxes = mailboxes ?: return@confined emptyList()
        val inputs = SortingInference.Inputs(boxes, userLabelIds() - ignored, ignored, identities.map { it.email.lowercase() }.toSet())
        SortingInference.suggestions(store.allMessages(), inputs, store.senders().associateBy { it.email })
    }

    /** Saves accepted suggestions as screening rules (future mail only). */
    suspend fun applySuggestions(suggestions: List<RuleSuggestion>) = confined { saveRules(suggestions.map { it.rule }) }

    // MARK: - Sorting a folder

    data class FolderSortPlan(
        val sourceId: String,
        val buckets: List<Bucket>,
        /** Addresses treated as the user's own (their mail goes to Sent). */
        val ownAddresses: List<String>,
    ) {
        /** One message, and why it's going where it is. */
        data class Item(
            val id: String, val subject: String, val senderName: String?, val senderEmail: String,
            val receivedAt: Instant?, val reason: SortReason,
        )

        data class Bucket(val destination: List<String>, val items: List<Item>) {
            val id: String get() = destination.joinToString("+")
            val messageIds: List<String> get() = items.map { it.id }
        }

        val total: Int get() = buckets.sumOf { it.items.size }
    }

    /**
     * Works out where every message in [sourceId] belongs, without moving
     * anything. Reads the whole folder from Fastmail, not just the cache.
     */
    suspend fun planFolderSort(
        sourceId: String, ignored: Set<String> = emptySet(),
        progress: (Int, Int) -> Unit = { _, _ -> },
    ): FolderSortPlan = confined {
        val boxes = mailboxes ?: throw JmapException.MissingResponse("mailboxes")
        val emails = fetchAll(sourceId, client.accountId(), listOf("id", "from", "to", "cc", "mailboxIds", "subject", "receivedAt"), progress)

        val own = identities.map { it.email.lowercase() }.toMutableSet()
        SortingInference.dominantRecipient(emails)?.let { own += it }

        val suggestions = suggestRules(ignored + sourceId).associateBy { it.email }
        val rules = store.senders().associateBy { it.email }
        val fallback = listOf(boxes.inbox)

        val buckets = LinkedHashMap<String, MutableList<FolderSortPlan.Item>>()
        val destinations = HashMap<String, List<String>>()
        for (email in emails) {
            val sender = email.from?.firstOrNull()?.normalized ?: ""
            val elsewhere = (email.mailboxIds ?: emptyMap()).filter { it.value && it.key != sourceId }.keys.sorted()
            // Already filed somewhere else too: just drop it from the source folder.
            val (destination, reason) = if (elsewhere.isEmpty()) {
                SortingInference.decide(sender, rules[sender], suggestions[sender], sender in own, boxes, fallback)
            } else {
                emptyList<String>() to SortReason.AlreadyFiled(elsewhere)
            }
            val key = destination.joinToString("+")
            destinations[key] = destination
            buckets.getOrPut(key) { mutableListOf() } += FolderSortPlan.Item(
                email.id, email.subject ?: "", email.from?.firstOrNull()?.name, sender, email.receivedAt, reason,
            )
        }
        FolderSortPlan(
            sourceId,
            buckets.map { (key, items) -> FolderSortPlan.Bucket(destinations[key] ?: emptyList(), items) }.sortedByDescending { it.items.size },
            own.sorted(),
        )
    }

    /** Moves every message out of the plan's source folder into its destination. */
    suspend fun execute(plan: FolderSortPlan, progress: (Int, Int) -> Unit = { _, _ -> }) = confined {
        var done = 0
        for (bucket in plan.buckets) {
            for (chunk in bucket.messageIds.chunked(500)) {
                // Already sorted: keeps recent mail moved into the Inbox out of the Screener.
                val patch = Router.move(listOf(plan.sourceId), bucket.destination) + ("keywords/${Keyword.ROUTED}" to ON)
                apply(chunk.associateWith { patch })
                done += chunk.size
                progress(done, plan.total)
            }
        }
        syncMailboxes()
    }

    /** Deletes a folder, refusing if it still holds mail. */
    suspend fun deleteMailbox(id: String) = confined {
        val response = client.perform(listOf(MethodCall("Mailbox/set", obj(
            "accountId" to client.accountId(), "destroy" to arr(id), "onDestroyRemoveEmails" to false,
        ), "destroy")))
        response.result<SetResponse>("destroy").throwIfFailed("delete the folder")
        store.setValue(null, Key.MAILBOX_STATE)
        syncMailboxes()
    }

    private suspend fun fetchAll(mailboxId: String, accountId: String, properties: List<String>, progress: (Int, Int) -> Unit): List<Email> {
        val ids = mutableListOf<String>()
        var total: Int
        do {
            val page = client.perform(listOf(MethodCall("Email/query", obj(
                "accountId" to accountId,
                "filter" to obj("inMailbox" to mailboxId),
                "sort" to arr(obj("property" to "receivedAt", "isAscending" to false)),
                "position" to ids.size, "limit" to 1000, "calculateTotal" to true,
            ), "q"))).result<QueryResponse>("q")
            total = page.total ?: (ids.size + page.ids.size)
            ids += page.ids
            if (page.ids.isEmpty()) break
        } while (ids.size < total)

        val emails = mutableListOf<Email>()
        for (chunk in ids.chunked(500)) {
            emails += client.perform(listOf(MethodCall("Email/get", obj(
                "accountId" to accountId, "ids" to strings(chunk), "properties" to strings(properties),
            ), "get"))).result<GetResponse<Email>>("get").list
            progress(emails.size, ids.size)
        }
        return emails
    }

    // MARK: - Search

    data class SearchResult(val messages: List<MessageRecord>, val snippets: Map<String, SearchSnippet>, val total: Int?)

    /** Server-side search. Results are cached locally so they can be opened. */
    suspend fun search(query: SearchQuery, limit: Int = 100): SearchResult = confined {
        val byName = store.mailboxes().associateBy({ it.name.lowercase() }, { it.id })
        val filter = query.jmapFilter(byName) ?: return@confined SearchResult(emptyList(), emptyMap(), 0)
        val accountId = client.accountId()
        val response = client.perform(listOf(
            MethodCall("Email/query", obj(
                "accountId" to accountId, "filter" to filter,
                "sort" to arr(obj("property" to "receivedAt", "isAscending" to false)),
                "limit" to limit, "calculateTotal" to true,
            ), "q"),
            MethodCall("Email/get", obj(
                "accountId" to accountId,
                "#ids" to MethodCall.reference("q", "Email/query", "/ids"),
                "properties" to strings(Email.listProperties),
            ), "get"),
            MethodCall("SearchSnippet/get", obj(
                "accountId" to accountId, "filter" to filter,
                "#emailIds" to MethodCall.reference("q", "Email/query", "/ids"),
            ), "snip"),
        ))
        val result = response.result<QueryResponse>("q")
        val emails = response.result<GetResponse<Email>>("get").list
        storeServerEmails(emails)
        val snippets = runCatching { response.result<GetResponse<SearchSnippet>>("snip").list }.getOrDefault(emptyList())
        val byId = emails.associate { it.id to MessageRecord(it) }
        SearchResult(result.ids.mapNotNull { byId[it] }, snippets.associateBy { it.emailId }, result.total)
    }

    // MARK: - Sending and drafts

    /**
     * The longest Fastmail will hold a message before delivering it (its
     * FUTURERELEASE support), which is what lets Undo Send call it back.
     */
    suspend fun maxDelayedSend(): Int {
        val session = runCatching { client.session() }.getOrNull() ?: return 0
        return ((session.capabilities[JmapCapability.SUBMISSION] as? JsonObject)?.get("maxDelayedSend") as? JsonPrimitive)?.intOrNull ?: 0
    }

    /**
     * Saves (or re-saves) a draft in Drafts and returns its new id. Fastmail
     * messages can't be edited, so a new version replaces the old one.
     */
    suspend fun saveDraft(message: OutgoingMessage): String = confined {
        val (accountId, email) = draftObject(message)
        val arguments = linkedMapOf<String, JsonValue>("accountId" to JsonPrimitive(accountId), "create" to obj("draft" to email))
        message.draftId?.let { arguments["destroy"] = arr(it) }
        val result = client.perform(listOf(MethodCall("Email/set", JsonObject(arguments), "save"))).result<SetResponse>("save")
        result.throwIfFailed("save the draft")
        val id = result.createdId("draft") ?: throw JmapException.MissingResponse("Email/set draft")
        // The old version is gone from Fastmail; drop it here too so no one reads it.
        message.draftId?.let { store.delete(listOf(it)) }
        id
    }

    suspend fun discardDraft(id: String) = confined {
        val response = client.perform(listOf(MethodCall("Email/set", obj("accountId" to client.accountId(), "destroy" to arr(id)), "discard")))
        response.result<SetResponse>("discard").throwIfFailed("delete the draft")
        store.delete(listOf(id))
    }

    /**
     * Sends a message. With [holdFor] (seconds, up to [maxDelayedSend]),
     * Fastmail keeps it that long first, so [cancel] can still stop it.
     */
    suspend fun send(message: OutgoingMessage, holdFor: Int = 0): Sending = confined {
        val boxes = mailboxes
        val drafts = boxes?.drafts
        val sent = boxes?.sent
        if (drafts == null || sent == null) throw JmapException.MissingResponse("drafts or sent mailbox")
        val identity = identities.firstOrNull { it.id == message.identityId } ?: throw SendException.NoIdentity
        if (message.recipients.isEmpty()) throw SendException.NoRecipients
        val (accountId, email) = draftObject(message)
        val create = linkedMapOf<String, JsonValue>("accountId" to JsonPrimitive(accountId), "create" to obj("draft" to email))
        message.draftId?.let { create["destroy"] = arr(it) }

        val submission = linkedMapOf<String, JsonValue>("identityId" to JsonPrimitive(identity.id), "emailId" to JsonPrimitive("#draft"))
        val held = if (holdFor > 0) minOf(holdFor, maxDelayedSend()) else 0
        if (held > 0) {
            submission["envelope"] = obj(
                "mailFrom" to obj("email" to identity.email, "parameters" to obj("HOLDFOR" to held.toString())),
                "rcptTo" to JsonArray(message.recipients.map { obj("email" to (it.email ?: ""), "parameters" to null) }),
            )
        }
        val calls = mutableListOf(
            MethodCall("Email/set", JsonObject(create), "draft"),
            MethodCall("EmailSubmission/set", obj(
                "accountId" to accountId,
                "create" to obj("send" to JsonObject(submission)),
                "onSuccessUpdateEmail" to obj("#send" to obj(
                    "mailboxIds/$drafts" to null,
                    "mailboxIds/$sent" to true,
                    "keywords/${Keyword.DRAFT}" to null,
                )),
            ), "submit"),
        )
        message.answering?.let { answering ->
            calls += MethodCall("Email/set", obj(
                "accountId" to accountId,
                "update" to obj(answering to obj("keywords/${Keyword.ANSWERED}" to true)),
            ), "answered")
        }
        val response = client.perform(calls, listOf(JmapCapability.CORE, JmapCapability.MAIL, JmapCapability.SUBMISSION))
        val saved = response.result<SetResponse>("draft", "Email/set")
        saved.throwIfFailed("save the outgoing message")
        val submitted = response.result<SetResponse>("submit", "EmailSubmission/set")
        submitted.throwIfFailed("send the message")
        val emailId = saved.createdId("draft")
        val submissionId = submitted.createdId("send")
        if (emailId == null || submissionId == null) throw JmapException.MissingResponse("EmailSubmission/set")
        store.recordSentRecipients(message.recipients.map { it.normalized })
        runCatching { refresh() }
        Sending(emailId, submissionId, held)
    }

    /** Undo Send: stops a held message and puts it back in Drafts. */
    suspend fun cancel(sending: Sending) = confined {
        val boxes = mailboxes
        val drafts = boxes?.drafts
        if (sending.heldFor <= 0 || drafts == null) throw SendException.TooLateToUndo
        val response = client.perform(
            listOf(MethodCall("EmailSubmission/set", obj(
                "accountId" to client.accountId(),
                "update" to obj(sending.submissionId to obj("undoStatus" to "canceled")),
            ), "cancel")),
            listOf(JmapCapability.CORE, JmapCapability.MAIL, JmapCapability.SUBMISSION),
        )
        val result = response.result<SetResponse>("cancel")
        if (result.notUpdated?.get(sending.submissionId) != null) throw SendException.TooLateToUndo
        result.throwIfFailed("undo sending")
        val patch = linkedMapOf<String, JsonValue>("mailboxIds/$drafts" to ON, "keywords/${Keyword.DRAFT}" to ON)
        boxes.sent?.let { patch["mailboxIds/$it"] = OFF }
        apply(mapOf(sending.emailId to patch))
    }

    /** A saved draft (or a message brought back by Undo Send), ready to edit. */
    suspend fun outgoingMessage(draftId: String): OutgoingMessage = confined {
        val response = client.perform(listOf(MethodCall("Email/get", obj(
            "accountId" to client.accountId(),
            "ids" to arr(draftId),
            "properties" to strings(listOf("id", "from", "to", "cc", "bcc", "subject", "inReplyTo", "references", "textBody", "attachments", "bodyValues")),
            "bodyProperties" to strings(listOf("partId", "blobId", "size", "name", "type", "disposition")),
            "fetchTextBodyValues" to true,
        ), "draft")))
        val email = response.result<GetResponse<Email>>("draft").list.firstOrNull()
            ?: throw JmapException.MissingResponse("Email/get draft")
        val fromAddress = email.from?.firstOrNull()?.normalized
        val identity = identities.firstOrNull { it.email.lowercase() == fromAddress } ?: identities.firstOrNull()
        val text = (email.textBody ?: emptyList()).mapNotNull { part -> part.partId?.let { email.bodyValues?.get(it)?.value } }.joinToString("\n")
        OutgoingMessage(
            identityId = identity?.id ?: "",
            to = email.to ?: emptyList(), cc = email.cc ?: emptyList(), bcc = email.bcc ?: emptyList(),
            subject = email.subject ?: "", body = text,
            attachments = (email.attachments ?: emptyList()).mapNotNull { part ->
                part.blobId?.let { OutgoingMessage.Attachment(it, part.name ?: "Attachment", part.type ?: "application/octet-stream", part.size ?: 0) }
            },
            inReplyTo = email.inReplyTo ?: emptyList(), references = email.references ?: emptyList(),
            draftId = draftId,
        )
    }

    /** Uploads a file to attach. Fastmail keeps unreferenced uploads for a day. */
    suspend fun upload(data: ByteArray, name: String, type: String): OutgoingMessage.Attachment =
        OutgoingMessage.Attachment(client.upload(data, type), name, type, data.size)

    /** The largest file Fastmail accepts in one upload, when it says. */
    suspend fun maxUploadSize(): Int? {
        val session = runCatching { client.session() }.getOrNull() ?: return null
        return ((session.capabilities[JmapCapability.CORE] as? JsonObject)?.get("maxSizeUpload") as? JsonPrimitive)?.intOrNull
    }

    /** The Email/set create object for a message: in Drafts, marked $draft. */
    private suspend fun draftObject(message: OutgoingMessage): Pair<String, JsonObject> {
        val drafts = mailboxes?.drafts ?: throw JmapException.MissingResponse("drafts mailbox")
        val accountId = client.accountId()
        val identity = identities.firstOrNull { it.id == message.identityId } ?: identities.firstOrNull()
        fun addresses(list: List<EmailAddress>) = JsonArray(list.map { obj("name" to it.name, "email" to (it.email ?: "")) })
        val email = linkedMapOf<String, JsonValue>(
            "mailboxIds" to obj(drafts to true),
            "keywords" to obj(Keyword.DRAFT to true, Keyword.SEEN to true),
            "subject" to JsonPrimitive(message.subject),
            "bodyValues" to obj("body" to obj("value" to message.body)),
            "textBody" to arr(obj("partId" to "body", "type" to "text/plain")),
        )
        identity?.let { email["from"] = arr(obj("name" to it.name, "email" to it.email)) }
        if (message.to.isNotEmpty()) email["to"] = addresses(message.to)
        if (message.cc.isNotEmpty()) email["cc"] = addresses(message.cc)
        if (message.bcc.isNotEmpty()) email["bcc"] = addresses(message.bcc)
        if (message.inReplyTo.isNotEmpty()) email["inReplyTo"] = strings(message.inReplyTo)
        if (message.references.isNotEmpty()) email["references"] = strings(message.references)
        if (message.attachments.isNotEmpty()) {
            email["attachments"] = JsonArray(message.attachments.map {
                obj("blobId" to it.blobId, "type" to it.type, "name" to it.name, "disposition" to "attachment")
            })
        }
        return accountId to JsonObject(email)
    }
}

