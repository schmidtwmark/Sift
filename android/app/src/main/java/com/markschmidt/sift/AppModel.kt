package com.markschmidt.sift

import android.content.Context
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.markschmidt.sift.core.compose.MailtoLink
import com.markschmidt.sift.core.compose.OutgoingMessage
import com.markschmidt.sift.core.compose.Sending
import com.markschmidt.sift.core.demo.DemoSeed
import com.markschmidt.sift.core.demo.DemoServer
import com.markschmidt.sift.core.jmap.EmailAddress
import com.markschmidt.sift.core.jmap.Identity
import com.markschmidt.sift.core.jmap.JmapClient
import com.markschmidt.sift.core.jmap.JmapDates
import com.markschmidt.sift.core.jmap.JmapException
import com.markschmidt.sift.core.jmap.formattedList
import com.markschmidt.sift.core.jmap.isTransientNetworkFailure
import com.markschmidt.sift.core.labels.LabelIcon
import com.markschmidt.sift.core.screener.RuleSuggestion
import com.markschmidt.sift.core.screener.SpecialMailboxes
import com.markschmidt.sift.core.search.SearchQuery
import com.markschmidt.sift.core.store.BodyRecord
import com.markschmidt.sift.core.store.MailStore
import com.markschmidt.sift.core.store.MailStore.Companion.labelIconMap
import com.markschmidt.sift.core.store.MailStore.Companion.mailboxList
import com.markschmidt.sift.core.store.MailStore.Companion.unreadBadgeCount
import com.markschmidt.sift.core.store.MailboxRecord
import com.markschmidt.sift.core.store.MessageRecord
import com.markschmidt.sift.core.store.ScreenerEntry
import com.markschmidt.sift.core.store.SenderRecord
import com.markschmidt.sift.core.sync.SyncEngine
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File
import java.time.Instant
import java.util.UUID

/** What a compose screen starts from. */
data class ComposeRequest(
    val id: String = UUID.randomUUID().toString(),
    val replyTo: MessageRecord? = null,
    val replyAll: Boolean = false,
    val forward: MessageRecord? = null,
    /** A mailto: link opened from another app or a web page. */
    val mailto: MailtoLink? = null,
    /** A saved draft, or a message brought back by Undo Send. */
    val draft: OutgoingMessage? = null,
)

/**
 * App-wide state: the account connection, mailboxes, and every user action,
 * which it forwards to [SyncEngine] and turns into user-facing errors.
 */
class AppModel(private val context: Context) {
    sealed interface Phase {
        data object Launching : Phase
        data object SignedOut : Phase
        /** Checking the token; onboarding stays up. */
        data object Connecting : Phase
        /** The first sync. */
        data object Syncing : Phase
        data object Ready : Phase
        data class Failed(val message: String) : Phase
    }

    data class Toast(
        val id: String = UUID.randomUUID().toString(),
        val message: String,
        /** How long it stays up, in seconds. */
        val duration: Int = 6,
        val undo: (suspend () -> Unit)? = null,
    )

    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val tokens = TokenStore(context)
    val preferences = Preferences(context)
    val notifier = Notifier(context)

    var phase by mutableStateOf<Phase>(Phase.Launching)
        private set
    var isDemo by mutableStateOf(false)
        private set
    var engine by mutableStateOf<SyncEngine?>(null)
        private set
    var store by mutableStateOf<MailStore?>(null)
        private set

    var mailboxes by mutableStateOf<List<MailboxRecord>>(emptyList())
        private set
    /** Icons you picked for labels (mailbox id → SF Symbol name), synced via Fastmail. */
    var labelIcons by mutableStateOf<Map<String, String>>(emptyMap())
        private set
    var special by mutableStateOf<SpecialMailboxes?>(null)
        private set
    var identities by mutableStateOf<List<Identity>>(emptyList())
        private set
    var username by mutableStateOf("")
        private set
    var screenerStartedAt by mutableStateOf<Instant?>(null)
        private set
    var isSyncing by mutableStateOf(false)
        private set

    var errorMessage by mutableStateOf<String?>(null)
    var toast by mutableStateOf<Toast?>(null)
        private set
    /** A conversation to bring up (from a notification). */
    var threadToOpen by mutableStateOf<String?>(null)
    /** A compose screen to open: from a mailto: link, or brought back by Undo Send. */
    var composeToOpen by mutableStateOf<ComposeRequest?>(null)

    private var jobs = mutableListOf<Job>()
    private var listenJob: Job? = null
    private var isForeground = false

    // MARK: - Connection

    fun launch(demo: Boolean = false) {
        if (phase != Phase.Launching) return
        val token = tokens.token
        when {
            demo -> startDemo()
            token != null -> scope.launch { connect(token, saving = false) }
            else -> phase = Phase.SignedOut
        }
    }

    suspend fun connect(token: String, saving: Boolean = true) {
        phase = Phase.Connecting
        try {
            val client = JmapClient(token)
            val session = client.session(refresh = true)
            // Check scopes before touching the account, so a partial token
            // fails cleanly instead of halfway through setup.
            val missing = session.missingScopes
            if (missing.isNotEmpty()) throw JmapException.MissingScopes(missing)
            val store = MailStore.open(File(context.filesDir, "Sift-${session.username}.sqlite"))
            if (saving) tokens.token = token
            username = session.username
            phase = Phase.Syncing
            start(SyncEngine(client, store), store, activatedAt = null)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            Log.w("Sift", "Couldn't connect", error)
            phase = Phase.Failed(describe(error))
        }
    }

    fun startDemo() {
        phase = Phase.Syncing
        isDemo = true
        scope.launch {
            try {
                val server = DemoServer()
                val client = JmapClient("demo", DemoServer.SESSION_URL, server.httpClient())
                val store = MailStore.inMemory()
                username = "you@fastmail.com (demo)"
                start(SyncEngine(client, store), store, Instant.now().minus(DemoSeed.activationAge))
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                phase = Phase.Failed(describe(error))
            }
        }
    }

    private suspend fun start(engine: SyncEngine, store: MailStore, activatedAt: Instant?) {
        this.engine = engine
        this.store = store
        engine.onNewMail { messages -> handleNewMail(messages) }
        isSyncing = true
        try {
            engine.start(activatedAt)
        } finally {
            isSyncing = false
        }
        special = engine.mailboxes
        identities = engine.identities
        screenerStartedAt = store.value(SyncEngine.Key.ACTIVATED_AT)?.let(JmapDates::parse)
        phase = Phase.Ready
        observe(store)
        if (isForeground) startListening()
        // Mailbox counts were read before the first sort; bring them up to date.
        refreshSoon()
    }

    fun signOut() {
        jobs.forEach { it.cancel() }
        jobs.clear()
        listenJob?.cancel()
        listenJob = null
        heldSends.values.forEach { it.cancel() }
        heldSends.clear()
        if (!isDemo) tokens.token = null
        engine = null
        store?.close()
        store = null
        mailboxes = emptyList()
        labelIcons = emptyMap()
        special = null
        identities = emptyList()
        isDemo = false
        notifier.setBadge(0)
        phase = Phase.SignedOut
    }

    private fun observe(store: MailStore) {
        jobs += scope.launch { store.observe { labelIconMap() }.collect { labelIcons = it } }
        jobs += scope.launch { store.observe { mailboxList() }.collect { mailboxes = it } }
        special?.quarantined?.let { quarantined ->
            jobs += scope.launch { store.observe { unreadBadgeCount(quarantined) }.collect { notifier.setBadge(it) } }
        }
    }

    /** The app came to the front: catch up, and hold Fastmail's push connection while it's there. */
    fun onForeground() {
        isForeground = true
        if (phase == Phase.Ready) {
            startListening()
            scope.launch { refresh(RefreshTrigger.AUTOMATIC) }
        }
    }

    fun onBackground() {
        isForeground = false
        listenJob?.cancel()
        listenJob = null
    }

    private fun startListening() {
        val engine = engine ?: return
        if (listenJob?.isActive == true || isDemo) return
        listenJob = scope.launch(Dispatchers.Default) { engine.listen() }
    }

    /**
     * A quiet refresh after a change Fastmail made that the cache doesn't
     * mirror yet (a held send's draft, new unread counts). With a real account
     * the push connection would bring it too; the demo has no push.
     */
    private fun refreshSoon() {
        val engine = engine ?: return
        // Straight to the engine, which folds overlapping refreshes into one; no spinner.
        scope.launch {
            try {
                engine.refresh()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                Log.i("Sift", "Quiet refresh failed: ${error.message}")
            }
        }
    }

    enum class RefreshTrigger {
        /** Pull to refresh: say so if it fails. */
        USER,
        /** Coming to the front, or background work. Nobody's waiting, so no alert. */
        AUTOMATIC,
    }

    suspend fun refresh(trigger: RefreshTrigger = RefreshTrigger.USER) {
        val engine = engine ?: return
        if (phase != Phase.Ready || isSyncing) return
        isSyncing = true
        try {
            // Syncing is safe to repeat, so a network hiccup gets one quiet retry.
            for (attempt in 1..2) {
                try {
                    engine.refresh()
                    return
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    if (!error.isTransientNetworkFailure) {
                        if (trigger == RefreshTrigger.USER) errorMessage = describe(error)
                        return
                    }
                    if (attempt == 1) delay(3_000)
                }
            }
            // Still unreachable: the next sync (or a push from Fastmail) catches up.
            if (trigger == RefreshTrigger.USER) show(Toast(message = "Couldn't reach Fastmail. Try again in a moment."))
        } finally {
            isSyncing = false
        }
    }

    // MARK: - Mailboxes

    /** User-facing labels (Fastmail mailboxes without a system role), Inbox first, in Fastmail's order. */
    val labels: List<MailboxRecord>
        get() {
            val special = special ?: return emptyList()
            val inbox = mailboxes.filter { it.id == special.inbox }
            val custom = mailboxes.filter { it.role == null && it.id != special.screener && it.id != special.screenedOut }
            return inbox + custom
        }

    fun mailbox(id: String) = mailboxes.firstOrNull { it.id == id }

    fun name(mailboxId: String) = mailbox(mailboxId)?.name ?: "Label"

    /**
     * The SF Symbol name for any mailbox: fixed ones for system folders; for
     * labels, your pick, or a guess from the name.
     */
    fun icon(mailboxId: String): String {
        special?.let { special ->
            val system = listOf(
                special.inbox to "tray", special.screener to "person.crop.circle.badge.questionmark",
                special.screenedOut to "hand.raised", special.archive to "archivebox", special.sent to "paperplane",
                special.drafts to "doc", special.junk to "xmark.bin", special.trash to "trash",
            )
            system.firstOrNull { it.first == mailboxId }?.let { return it.second }
        }
        return labelIcons[mailboxId] ?: LabelIcon.suggested(name(mailboxId))
    }

    fun setIcon(symbol: String?, mailboxId: String) = perform { engine?.setLabelIcon(symbol, mailboxId) }

    suspend fun createLabel(name: String): String? {
        val engine = engine ?: return null
        var id: String? = null
        performNow { id = engine.createMailbox(name) }
        return id
    }

    /** Puts your folders in this order everywhere: here, your other devices and Fastmail. */
    fun reorderFolders(ids: List<String>) = perform { engine?.reorderMailboxes(ids) }

    // MARK: - Screener

    suspend fun screenIn(entry: ScreenerEntry, labels: Set<String>): Boolean {
        val engine = engine ?: return false
        val ordered = this.labels.map { it.id }.filter { it in labels }
        return performNow { engine.screenIn(entry.email, entry.name, ordered) }
    }

    suspend fun screenOut(entry: ScreenerEntry): Boolean {
        val engine = engine ?: return false
        return performNow { engine.screenOut(entry.email, entry.name) }
    }

    suspend fun save(rule: SenderRecord, refile: Boolean): Boolean {
        val engine = engine ?: return false
        return performNow { engine.updateRule(rule, refile) }
    }

    // MARK: - Message actions

    fun markRead(messages: List<MessageRecord>, read: Boolean = true) {
        val ids = messages.filter { it.isUnread == read }.map { it.id }
        if (ids.isEmpty()) return
        perform { engine?.setKeyword(com.markschmidt.sift.core.store.Keyword.SEEN, read, ids) }
    }

    /** Read marks every message in the conversation; unread marks just the newest. */
    fun markThread(threadId: String, read: Boolean) = scope.launch {
        val thread = messages(listOf(threadId))
        markRead(if (read) thread else thread.takeLast(1), read)
    }

    fun togglePin(message: MessageRecord) =
        perform { engine?.setKeyword(com.markschmidt.sift.core.store.Keyword.FLAGGED, !message.isFlagged, listOf(message.id)) }

    /** Every message in the given conversations, oldest first. */
    suspend fun messages(threadIds: List<String>): List<MessageRecord> {
        val store = store ?: return emptyList()
        return threadIds.flatMap { store.thread(it) }
    }

    // Conversation-level moves: every message in the thread goes, not just the newest.

    fun archive(threads: List<String>, from: String?) = scope.launch {
        val ids = messages(threads).map { it.id }
        move("Archived") { engine?.archive(ids, from) ?: emptyMap() }
    }

    fun trash(threads: List<String>) = scope.launch {
        val ids = messages(threads).map { it.id }
        move("Moved to Trash") { engine?.moveToTrash(ids) ?: emptyMap() }
    }

    fun junk(threads: List<String>) = scope.launch {
        val ids = messages(threads).map { it.id }
        move("Moved to Spam") { engine?.moveToJunk(ids) ?: emptyMap() }
    }

    /**
     * Files whole conversations into exactly [folders] (Inbox and your labels;
     * your own sent copies stay in Sent).
     */
    fun refile(threads: List<String>, folders: Set<String>) = scope.launch {
        val engine = engine ?: return@launch
        val all = labels.map { it.id }.toSet()
        val sent = special?.sent
        val messages = messages(threads).filter { sent == null || sent !in it.mailboxIds }
        val names = labels.filter { it.id in folders }.map { it.name }.formattedList()
        move("Moved to $names") {
            val placement = mutableMapOf<String, List<String>>()
            for (message in messages) {
                val current = message.mailboxIds.toSet().intersect(all)
                val add = folders - current
                val remove = current - folders
                if (add.isEmpty() && remove.isEmpty()) continue
                engine.relabel(listOf(message.id), add.toList(), remove.toList())
                placement[message.id] = message.mailboxIds
            }
            placement
        }
    }

    /** Runs a reversible move and confirms it with a toast that can undo it. */
    private suspend fun move(done: String, work: suspend () -> Map<String, List<String>>) {
        var placement: Map<String, List<String>> = emptyMap()
        performNow { placement = work() }
        if (placement.isEmpty()) return
        show(Toast(message = done) { restore(placement) })
    }

    private suspend fun restore(placement: Map<String, List<String>>) {
        val engine = engine ?: return
        performNow { engine.restore(placement) }
    }

    // MARK: - Learning from existing mail

    /** Folders whose contents say nothing about where mail belongs yet (an unsorted import). */
    val unsortedFolderIds: Set<String>
        get() = labels.filter { it.name.contains("import", ignoreCase = true) }.map { it.id }.toSet()

    suspend fun suggestRules(): List<RuleSuggestion> = engine?.suggestRules(unsortedFolderIds) ?: emptyList()

    suspend fun apply(suggestions: List<RuleSuggestion>): Boolean {
        val engine = engine ?: return false
        val ok = performNow { engine.applySuggestions(suggestions) }
        if (ok) show(Toast(message = "Saved ${suggestions.size} rule${if (suggestions.size == 1) "" else "s"}"))
        return ok
    }

    // MARK: - Toasts

    fun show(toast: Toast) {
        this.toast = toast
        scope.launch {
            delay(toast.duration * 1000L)
            if (this@AppModel.toast?.id == toast.id) this@AppModel.toast = null
        }
    }

    fun dismissToast() {
        toast = null
    }

    // MARK: - Sending and drafts

    private val heldSends = mutableMapOf<String, Job>()

    /**
     * Sends [message], held for the Undo Send delay. Returns false (with an
     * alert) only if it couldn't be handed off at all.
     */
    suspend fun send(message: OutgoingMessage): Boolean {
        val engine = engine ?: return false
        val delaySeconds = preferences.undoSendDelay
        return try {
            when {
                delaySeconds == 0 -> {
                    engine.send(message)
                    show(Toast(message = "Sent"))
                }
                engine.maxDelayedSend() >= delaySeconds -> {
                    // Fastmail holds it, so it still goes out if Sift is closed meanwhile.
                    val sending = engine.send(message, holdFor = delaySeconds)
                    show(Toast(message = "Sending…", duration = delaySeconds) { undoSend(sending, message) })
                }
                else -> {
                    // Fastmail can't hold it: keep it in Drafts for the delay, then send.
                    val held = message.copy(draftId = engine.saveDraft(message))
                    val id = UUID.randomUUID().toString()
                    heldSends[id] = scope.launch {
                        delay(delaySeconds * 1000L)
                        finishHeldSend(id, held)
                    }
                    show(Toast(message = "Sending…", duration = delaySeconds) { cancelHeldSend(id, held) })
                }
            }
            refreshSoon()
            true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            errorMessage = if (error.isTransientNetworkFailure) {
                "Couldn't reach Fastmail, so the message wasn't sent. Check your connection and try again."
            } else {
                describe(error)
            }
            false
        }
    }

    private suspend fun undoSend(sending: Sending, message: OutgoingMessage) {
        val engine = engine ?: return
        try {
            engine.cancel(sending)
            composeToOpen = ComposeRequest(draft = message.copy(draftId = sending.emailId))
            refreshSoon()
        } catch (error: Throwable) {
            errorMessage = describe(error)
        }
    }

    private suspend fun finishHeldSend(id: String, message: OutgoingMessage) {
        heldSends -= id
        val engine = engine ?: return
        try {
            engine.send(message)
            show(Toast(message = "Sent"))
            refreshSoon()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            errorMessage = "Couldn't send “${message.subject.ifEmpty { "(no subject)" }}”. It's saved in Drafts. ${describe(error)}"
        }
    }

    private fun cancelHeldSend(id: String, message: OutgoingMessage) {
        heldSends.remove(id)?.cancel()
        composeToOpen = ComposeRequest(draft = message)
        refreshSoon()
    }

    /** Saves a draft to Fastmail and returns its id (null, with an alert, on failure). */
    suspend fun saveDraft(message: OutgoingMessage): String? {
        val engine = engine ?: return null
        var id: String? = null
        performNow { id = engine.saveDraft(message) }
        // Bring the new version into Drafts now rather than at the next sync.
        if (id != null) refreshSoon()
        return id
    }

    suspend fun discardDraft(id: String) {
        val engine = engine ?: return
        performNow { engine.discardDraft(id) }
    }

    suspend fun openDraft(id: String): OutgoingMessage? {
        val engine = engine ?: return null
        var message: OutgoingMessage? = null
        performNow { message = engine.outgoingMessage(id) }
        return message
    }

    suspend fun upload(data: ByteArray, name: String, type: String): OutgoingMessage.Attachment {
        val engine = engine ?: throw CancellationException()
        val limit = engine.maxUploadSize()
        if (limit != null && data.size > limit) {
            throw IllegalArgumentException("Too large: Fastmail takes files up to ${android.text.format.Formatter.formatShortFileSize(context, limit.toLong())}.")
        }
        return engine.upload(data, name, type)
    }

    /** Addresses to offer while typing a recipient (never your own). */
    suspend fun addressSuggestions(text: String): List<EmailAddress> {
        val store = store ?: return emptyList()
        val own = identities.map { it.email.lowercase() }.toSet()
        return runCatching { store.addressSuggestions(text, 8) }.getOrDefault(emptyList()).filter { it.normalized !in own }
    }

    suspend fun body(message: MessageRecord): BodyRecord {
        val engine = engine ?: throw CancellationException()
        return engine.body(message.id)
    }

    suspend fun download(blobId: String, name: String, type: String): ByteArray {
        val engine = engine ?: throw CancellationException()
        return engine.download(blobId, name, type)
    }

    suspend fun loadOlder(mailboxId: String?, before: Instant) {
        val engine = engine ?: return
        performNow { engine.loadOlder(mailboxId, before) }
    }

    suspend fun search(query: SearchQuery): SyncEngine.SearchResult {
        val engine = engine ?: throw CancellationException()
        return engine.search(query)
    }

    // MARK: - Errors

    private fun perform(work: suspend () -> Unit) = scope.launch { performNow(work) }

    /** Runs [work], turning failures into an alert. Returns whether it succeeded. */
    private suspend fun performNow(work: suspend () -> Unit): Boolean = try {
        work()
        // No push in the demo: catch up on what Fastmail would have pushed (unread counts).
        if (isDemo) refreshSoon()
        true
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Throwable) {
        Log.w("Sift", "Action failed", error)
        errorMessage = if (error.isTransientNetworkFailure) {
            "Couldn't reach Fastmail (${error.message ?: error::class.simpleName}). Check your connection and try again."
        } else {
            describe(error)
        }
        false
    }

    private fun describe(error: Throwable): String = error.message?.takeIf { it.isNotBlank() } ?: error.toString()

    // MARK: - Notifications

    private fun handleNewMail(messages: List<MessageRecord>) {
        val store = store ?: return
        val special = special ?: return
        scope.launch {
            val notifying = store.senders().filter { it.notify }.map { it.email }.toSet()
            val quarantined = special.quarantined.toSet()
            val cutoff = Instant.now().minusSeconds(3600)
            val recent = messages.filter { message ->
                message.fromEmail in notifying && message.isUnread &&
                    message.mailboxIds.none { it in quarantined } && message.receivedAt > cutoff
            }
            notifier.post(recent)
        }
    }
}
