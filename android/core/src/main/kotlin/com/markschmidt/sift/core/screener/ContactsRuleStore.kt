package com.markschmidt.sift.core.screener

import com.markschmidt.sift.core.jmap.GetResponse
import com.markschmidt.sift.core.jmap.JmapCapability
import com.markschmidt.sift.core.jmap.JmapClient
import com.markschmidt.sift.core.jmap.JsonValue
import com.markschmidt.sift.core.jmap.MethodCall
import com.markschmidt.sift.core.jmap.SetFailure
import com.markschmidt.sift.core.jmap.SetResponse
import com.markschmidt.sift.core.jmap.get
import com.markschmidt.sift.core.jmap.obj
import com.markschmidt.sift.core.jmap.strings
import com.markschmidt.sift.core.labels.LabelIcon
import com.markschmidt.sift.core.store.SenderRecord
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.security.MessageDigest

/**
 * Persists sender rules in Fastmail Contacts (JMAP Contacts, RFC 9610) so every
 * device, and Fastmail itself, sees the same screening decisions.
 *
 * Fastmail doesn't let apps create address books, so Sift keeps a handful of
 * group cards in the user's default address book: "Sift: Screened In",
 * "Sift: Screened Out", "Sift: Notify", "Sift: Badge", and one
 * "Sift label: <name>" group per label. Senders are stored as `mailto:`
 * members (vCard MEMBER URIs), so no contact card is created per sender.
 * Members the user adds as real contacts in Fastmail's UI are honoured too. A
 * label's custom icon is a note on its group ("Sift icon: airplane").
 *
 * The uids, names, member keys and note format are shared with the iPhone and
 * Mac apps byte for byte; change none of them.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ContactsRuleStore(private val client: JmapClient) {
    sealed class Group {
        data object ScreenedIn : Group()
        data object ScreenedOut : Group()
        data object Notify : Group()
        data object Badge : Group()
        data class Label(val mailboxId: String) : Group()

        val uid: String
            get() = when (this) {
                ScreenedIn -> ContactsRuleStore.uid("group:screened-in")
                ScreenedOut -> ContactsRuleStore.uid("group:screened-out")
                Notify -> ContactsRuleStore.uid("group:notify")
                Badge -> ContactsRuleStore.uid("group:badge")
                is Label -> ContactsRuleStore.uid("group:label:$mailboxId")
            }

        fun displayName(labelName: String?): String = when (this) {
            ScreenedIn -> "Sift: Screened In"
            ScreenedOut -> "Sift: Screened Out"
            Notify -> "Sift: Notify"
            Badge -> "Sift: Badge"
            is Label -> "Sift label: ${labelName ?: "Label"}"
        }

        companion object {
            val fixed: List<Group> get() = listOf(ScreenedIn, ScreenedOut, Notify, Badge)
        }
    }

    @Serializable
    data class Card(
        val id: String,
        val uid: String,
        val kind: String? = null,
        val name: Name? = null,
        val emails: Map<String, EmailEntry>? = null,
        val members: Map<String, Boolean>? = null,
        val addressBookIds: Map<String, Boolean>? = null,
        val notes: Map<String, Note>? = null,
    ) {
        @Serializable data class Name(val full: String? = null)
        @Serializable data class EmailEntry(val address: String)
        @Serializable data class Note(val note: String)
    }

    @Serializable
    data class AddressBook(val id: String, val name: String = "", val isDefault: Boolean? = null)

    /** Behaves like a Swift actor: one thing at a time, interleaving only at suspension points. */
    private val confined = Dispatchers.Default.limitedParallelism(1)

    private var addressBookId: String? = null
    /** Sift's groups as last fetched: uid → group, card id, and raw member keys. */
    private var groups = mutableMapOf<String, Group>()
    private var groupCardIds = mutableMapOf<String, String>()
    private var groupMembers = mutableMapOf<String, MutableSet<String>>()
    /** Group uid → the keys of its notes, and which one holds Sift's icon. */
    private var groupNoteKeys = mutableMapOf<String, Set<String>>()
    private var groupIconNoteKey = mutableMapOf<String, String>()
    /** Contact card uid → its addresses and name, to resolve contacts put in a Sift group by hand. */
    private var cardAddresses = mutableMapOf<String, List<String>>()
    private var cardNames = mutableMapOf<String, String>()

    /** Everyone in the user's address books; they skip the Screener. */
    var contactAddresses: Set<String> = emptySet()
        private set
    /** Mailbox id → SF Symbol name chosen for that label. */
    var labelIcons: Map<String, String> = emptyMap()
        private set
    var state: String? = null
        private set

    // MARK: - Loading

    /**
     * Fetches every card and returns the decoded sender rules. [mailboxIds]
     * are the account's mailboxes, used to recognise label groups by uid.
     */
    suspend fun load(mailboxIds: List<String>): List<SenderRecord> = withContext(confined) {
        val accountId = contactsAccountId()
        defaultAddressBook(accountId)

        val allCards = mutableListOf<Card>()
        val pageSize = 500
        var firstState: String? = null
        while (true) {
            val response = client.perform(
                listOf(
                    MethodCall("ContactCard/query", obj(
                        "accountId" to accountId, "position" to allCards.size, "limit" to pageSize,
                    ), "query"),
                    MethodCall("ContactCard/get", obj(
                        "accountId" to accountId,
                        "#ids" to MethodCall.reference("query", "ContactCard/query", "/ids"),
                        "properties" to strings(listOf("id", "uid", "kind", "name", "emails", "members", "addressBookIds", "notes")),
                    ), "cards"),
                ),
                CAPABILITIES,
            )
            val page = response.result<GetResponse<Card>>("cards")
            if (allCards.isEmpty()) firstState = page.state
            allCards += page.list
            if (page.list.size < pageSize) break
        }
        state = firstState

        val known = Group.fixed + mailboxIds.map { Group.Label(it) }
        val byUid = known.associateBy { it.uid }
        groups = mutableMapOf()
        groupCardIds = mutableMapOf()
        groupMembers = mutableMapOf()
        groupNoteKeys = mutableMapOf()
        groupIconNoteKey = mutableMapOf()
        cardAddresses = mutableMapOf()
        cardNames = mutableMapOf()
        val icons = mutableMapOf<String, String>()
        val contacts = mutableSetOf<String>()

        for (card in allCards) {
            if (card.kind == "group") {
                val group = byUid[card.uid] ?: continue
                groups[card.uid] = group
                groupCardIds[card.uid] = card.id
                groupMembers[card.uid] = (card.members ?: emptyMap()).filterValues { it }.keys.toMutableSet()
                groupNoteKeys[card.uid] = (card.notes ?: emptyMap()).keys
                for ((key, note) in card.notes ?: emptyMap()) {
                    val symbol = LabelIcon.parse(note.note) ?: continue
                    groupIconNoteKey[card.uid] = key
                    if (group is Group.Label) icons[group.mailboxId] = symbol
                }
            } else {
                val addresses = (card.emails ?: emptyMap()).values.map { it.address.lowercase() }
                cardAddresses[card.uid] = addresses
                card.name?.full?.let { cardNames[card.uid] = it }
                contacts += addresses
            }
        }
        labelIcons = icons
        contactAddresses = contacts

        val rules = LinkedHashMap<String, SenderRecord>()
        for ((uid, members) in groupMembers) {
            val group = groups[uid] ?: continue
            for (key in members) {
                for (address in addresses(key)) {
                    var rule = rules[address] ?: SenderRecord(email = address, name = cardNames[key])
                    rule = when (group) {
                        Group.ScreenedIn -> if (rule.status != SenderRecord.Status.SCREENED_OUT) rule.copy(status = SenderRecord.Status.SCREENED_IN) else rule
                        Group.ScreenedOut -> rule.copy(status = SenderRecord.Status.SCREENED_OUT)
                        Group.Notify -> rule.copy(notify = true)
                        Group.Badge -> rule.copy(badge = true)
                        is Group.Label -> rule.copy(labelIds = rule.labelIds + group.mailboxId)
                    }
                    rules[address] = rule
                }
            }
        }
        rules.values.map { it.copy(labelIds = it.labelIds.sorted()) }
    }

    private fun addresses(memberKey: String): List<String> {
        if (memberKey.lowercase().startsWith("mailto:")) return listOf(memberKey.drop(7).lowercase())
        return cardAddresses[memberKey] ?: emptyList()
    }

    // MARK: - Saving

    /**
     * Writes many rules in one `ContactCard/set`. [labelNames] maps mailbox id
     * → display name, used when a label group has to be created.
     */
    suspend fun save(rules: List<SenderRecord>, labelNames: Map<String, String>) = withContext(confined) {
        if (rules.isEmpty()) return@withContext
        val accountId = contactsAccountId()
        val bookId = defaultAddressBook(accountId)

        val updates = LinkedHashMap<String, LinkedHashMap<String, JsonValue>>()  // group card id → patch
        val newGroups = LinkedHashMap<Group, LinkedHashMap<String, JsonValue>>()  // group → members
        data class Change(val group: Group, val add: List<String>, val remove: List<String>)
        val membership = mutableListOf<Change>()

        for (rule in rules) {
            val key = memberKey(rule.email)
            // Contacts the user added to a Sift group by hand, for this address.
            val cardKeys = cardAddresses.filterValues { rule.email in it }.keys.toList()

            val desired = LinkedHashMap<Group, Boolean>()
            desired[Group.ScreenedIn] = rule.status == SenderRecord.Status.SCREENED_IN
            desired[Group.ScreenedOut] = rule.status == SenderRecord.Status.SCREENED_OUT
            desired[Group.Notify] = rule.notify
            desired[Group.Badge] = rule.badge
            // Every label group the sender is in or should be in.
            for (group in groups.values) if (group is Group.Label) desired[group] = false
            for (group in newGroups.keys) if (group is Group.Label) desired.putIfAbsent(group, false)
            for (mailboxId in rule.labelIds) desired[Group.Label(mailboxId)] = true

            for ((group, shouldBeMember) in desired) {
                val members = groupMembers[group.uid] ?: emptySet()
                val isMember = key in members || cardKeys.any { it in members }
                val cardId = groupCardIds[group.uid]
                if (cardId != null) {
                    if (isMember == shouldBeMember) continue
                    if (shouldBeMember) {
                        updates.getOrPut(cardId) { linkedMapOf() }["members/${pointerEscape(key)}"] = JsonPrimitive(true)
                        membership += Change(group, listOf(key), emptyList())
                    } else {
                        val stale = (listOf(key) + cardKeys).filter { it in members }
                        for (member in stale) updates.getOrPut(cardId) { linkedMapOf() }["members/${pointerEscape(member)}"] = JsonNull
                        membership += Change(group, emptyList(), stale)
                    }
                } else if (shouldBeMember) {
                    newGroups.getOrPut(group) { linkedMapOf() }[key] = JsonPrimitive(true)
                    membership += Change(group, listOf(key), emptyList())
                }
            }
        }
        if (newGroups.isEmpty() && updates.isEmpty()) return@withContext

        val create = LinkedHashMap<String, JsonValue>()
        newGroups.entries.forEachIndexed { index, (group, members) ->
            val labelName = (group as? Group.Label)?.let { labelNames[it.mailboxId] }
            create["group-$index"] = obj(
                "@type" to "Card", "version" to "1.0", "kind" to "group",
                "uid" to group.uid,
                "addressBookIds" to obj(bookId to true),
                "name" to obj("full" to group.displayName(labelName)),
                "members" to JsonObject(members),
            )
        }
        val arguments = linkedMapOf<String, JsonValue>("accountId" to JsonPrimitive(accountId))
        if (create.isNotEmpty()) arguments["create"] = JsonObject(create)
        if (updates.isNotEmpty()) arguments["update"] = JsonObject(updates.mapValues { JsonObject(it.value) })
        val response = client.perform(listOf(MethodCall("ContactCard/set", JsonObject(arguments), "set")), CAPABILITIES)
        val result = response.result<SetResponse>("set")
        val what = if (rules.size == 1) "save the screening rule for ${rules[0].email}" else "save ${rules.size} screening rules"
        try {
            result.throwIfFailed(what)
        } catch (failure: SetFailure) {
            if (failure.error.type == "invalidProperties" && "members" in (failure.error.properties ?: emptyList())) {
                throw ContactsRuleStoreException.AddressMembersRejected(failure.error.toString())
            }
            throw failure
        }
        state = result.newState

        // Mirror the write locally so the next save diffs correctly.
        for ((createKey, value) in result.created ?: emptyMap()) {
            val id = (value["id"] as? JsonPrimitive)?.content ?: continue
            val uid = ((create[createKey] as? JsonObject)?.get("uid") as? JsonPrimitive)?.content ?: continue
            groupCardIds[uid] = id
        }
        for (change in membership) {
            groups[change.group.uid] = change.group
            val members = groupMembers.getOrPut(change.group.uid) { mutableSetOf() }
            members += change.add
            members -= change.remove.toSet()
        }
    }

    // MARK: - Label icons

    /**
     * Sets (or, with null, clears) a label's icon. Creates the label's group
     * if the label has no screening rules yet.
     */
    suspend fun setIcon(symbol: String?, mailboxId: String, labelName: String) = withContext(confined) {
        val accountId = contactsAccountId()
        val bookId = defaultAddressBook(accountId)
        val group = Group.Label(mailboxId)
        val note: JsonValue = symbol?.let { obj("@type" to "Note", "note" to LabelIcon.note(it)) } ?: JsonNull

        val arguments = linkedMapOf<String, JsonValue>("accountId" to JsonPrimitive(accountId))
        val cardId = groupCardIds[group.uid]
        if (cardId != null) {
            val iconKey = groupIconNoteKey[group.uid]
            val patch: JsonObject = when {
                iconKey != null -> obj("notes/${pointerEscape(iconKey)}" to note)
                symbol == null -> return@withContext
                groupNoteKeys[group.uid].isNullOrEmpty() -> obj("notes" to obj("sift-icon" to note))
                else -> obj("notes/sift-icon" to note)
            }
            arguments["update"] = obj(cardId to patch)
        } else {
            if (symbol == null) return@withContext
            arguments["create"] = obj("icon-group" to obj(
                "@type" to "Card", "version" to "1.0", "kind" to "group",
                "uid" to group.uid,
                "addressBookIds" to obj(bookId to true),
                "name" to obj("full" to group.displayName(labelName)),
                "notes" to obj("sift-icon" to note),
            ))
        }
        val response = client.perform(listOf(MethodCall("ContactCard/set", JsonObject(arguments), "set")), CAPABILITIES)
        val result = response.result<SetResponse>("set")
        result.throwIfFailed("save the icon for “$labelName”")
        state = result.newState

        // Mirror the write locally.
        result.createdId("icon-group")?.let { id ->
            groupCardIds[group.uid] = id
            groups[group.uid] = group
            groupMembers[group.uid] = mutableSetOf()
        }
        labelIcons = if (symbol != null) labelIcons + (mailboxId to symbol) else labelIcons - mailboxId
        // Read the notes back: the server may store them under keys of its own,
        // and the next change has to patch the right one.
        val id = groupCardIds[group.uid] ?: return@withContext
        val readBack = client.perform(
            listOf(MethodCall("ContactCard/get", obj(
                "accountId" to accountId, "ids" to strings(listOf(id)), "properties" to strings(listOf("id", "uid", "notes")),
            ), "get")),
            CAPABILITIES,
        )
        runCatching { readBack.result<GetResponse<Card>>("get").list.firstOrNull() }.getOrNull()?.let { card ->
            val notes = card.notes ?: emptyMap()
            groupNoteKeys[group.uid] = notes.keys
            val key = notes.entries.firstOrNull { LabelIcon.parse(it.value.note) != null }?.key
            if (key != null) groupIconNoteKey[group.uid] = key else groupIconNoteKey -= group.uid
        }
    }

    // MARK: - Helpers

    private suspend fun contactsAccountId(): String =
        client.session().primaryAccounts[JmapCapability.CONTACTS] ?: throw ContactsRuleStoreException.ContactsUnavailable

    private suspend fun defaultAddressBook(accountId: String): String {
        addressBookId?.let { return it }
        val response = client.perform(listOf(MethodCall("AddressBook/get", obj("accountId" to accountId), "books")), CAPABILITIES)
        val books = response.result<GetResponse<AddressBook>>("books").list
        val book = books.firstOrNull { it.isDefault == true } ?: books.firstOrNull() ?: throw ContactsRuleStoreException.NoAddressBook
        addressBookId = book.id
        return book.id
    }

    companion object {
        private val CAPABILITIES = listOf(JmapCapability.CORE, JmapCapability.CONTACTS)

        /** The group member key for an address: a vCard MEMBER URI. */
        fun memberKey(email: String) = "mailto:${email.lowercase()}"

        /** JSON Pointer escaping for a key inside a JMAP patch path. */
        fun pointerEscape(key: String) = key.replace("~", "~0").replace("/", "~1")

        /** Stable `urn:uuid:` identifiers so devices agree on card uids without coordinating. */
        fun uid(key: String): String {
            val bytes = MessageDigest.getInstance("SHA-256").digest("sift:$key".toByteArray(Charsets.UTF_8)).copyOf(16)
            bytes[6] = ((bytes[6].toInt() and 0x0F) or 0x80).toByte()  // version 8 (custom)
            bytes[8] = ((bytes[8].toInt() and 0x3F) or 0x80).toByte()  // RFC 4122 variant
            val hex = bytes.joinToString("") { "%02x".format(it.toInt() and 0xFF) }
            return "urn:uuid:${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}"
        }
    }
}

sealed class ContactsRuleStoreException(message: String) : Exception(message) {
    object ContactsUnavailable : ContactsRuleStoreException(
        "Your Fastmail API token doesn't include the Contacts scope, which Sift uses to sync screening decisions. " +
            "Create a token with Email, Email submission and Contacts access."
    )

    object NoAddressBook : ContactsRuleStoreException(
        "Your Fastmail account has no address book Sift can keep its screening groups in."
    )

    class AddressMembersRejected(detail: String) : ContactsRuleStoreException(
        "Fastmail wouldn't store an email address in a Sift contact group ($detail). Nothing was moved; this screening decision wasn't saved."
    )
}
