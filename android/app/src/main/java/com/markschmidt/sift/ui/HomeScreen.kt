package com.markschmidt.sift.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowDownward
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.FilterList
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Inventory2
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.Badge
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.markschmidt.sift.AppModel
import com.markschmidt.sift.ComposeRequest
import com.markschmidt.sift.core.store.MailStore.Companion.screener
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.launch

@Composable
fun OnboardingScreen(model: AppModel) {
    var token by rememberSaveable { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val connecting = model.phase == AppModel.Phase.Connecting

    // Pasted tokens sometimes carry line breaks, spaces, or a "Bearer " prefix.
    val cleaned = token.trim().let { if (it.lowercase().startsWith("bearer ")) it.drop(7) else it }.filterNot { it.isWhitespace() }
    val hint = if (cleaned.isNotEmpty() && !cleaned.lowercase().startsWith("fmu")) {
        "Fastmail API tokens start with “fmu1-”. An app password (for IMAP, SMTP or CalDAV) won't work here."
    } else null

    fun connect() {
        if (cleaned.isEmpty() || connecting) return
        scope.launch { model.connect(cleaned) }
    }

    Column(
        Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState()).padding(28.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Icons.Outlined.FilterList, null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.primary)
            Text("Sift", style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold)
            Text(
                "A calmer front end for Fastmail. New senders wait in the Screener until you say yes; spy pixels are stripped; nothing buzzes unless you ask it to.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Connect your Fastmail account", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(
                "In Fastmail's Settings → Privacy & Security, create an API token (not an app password) with Email, Email submission, and Contacts access. Sift keeps it encrypted with a key in this phone's Android Keystore.",
                style = MaterialTheme.typography.bodyMedium,
            )
            TextButton(onClick = {
                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://www.fastmail.help/hc/en-us/articles/5254602856719")))
            }, contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp)) { Text("How to create a Fastmail API token") }
            OutlinedTextField(
                token, { token = it }, Modifier.fillMaxWidth(),
                label = { Text("API token (fmu1-…)") }, singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Go, autoCorrectEnabled = false),
                keyboardActions = KeyboardActions(onGo = { connect() }),
            )
            hint?.let {
                Row(verticalAlignment = Alignment.Top) {
                    Icon(Icons.Outlined.Info, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.width(6.dp))
                    Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Button(onClick = ::connect, enabled = cleaned.isNotEmpty() && !connecting, modifier = Modifier.fillMaxWidth().height(48.dp)) {
                if (connecting) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp) else Text("Connect")
            }
        }
        (model.phase as? AppModel.Phase.Failed)?.let { failed ->
            Row {
                Icon(Icons.Outlined.Warning, null, tint = MaterialTheme.colorScheme.error)
                Spacer(Modifier.width(8.dp))
                Text(failed.message, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("What Sift changes in Fastmail", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            InfoLine(Icons.Outlined.Inventory2, "Adds “Screener” and “Screened Out” mailboxes.")
            InfoLine(Icons.Outlined.FilterList, "Keeps your screening decisions in a few “Sift: …” contact groups. No contact is created for each sender.")
            InfoLine(Icons.Outlined.History, "Only mail that arrives after you connect is screened. Older mail stays where it is.")
        }
        OutlinedButton(onClick = { model.startDemo() }, enabled = !connecting) { Text("Explore with sample mail") }
    }
}

@Composable
private fun InfoLine(icon: ImageVector, text: String) {
    Row(verticalAlignment = Alignment.Top) {
        Icon(icon, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(10.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** The mailbox list: Screener (when someone's waiting), Inbox, your labels, and More. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(model: AppModel, navigator: Navigator) {
    val scope = rememberCoroutineScope()
    val special = model.special ?: return
    val store = model.store
    val screenerEntries by remember(store, special.screener) {
        store?.observe { screener(special.screener) } ?: emptyFlow()
    }.collectAsState(initial = emptyList())
    var labelsExpanded by rememberSaveable { mutableStateOf(true) }
    var moreExpanded by rememberSaveable { mutableStateOf(true) }
    var editingOrder by rememberSaveable { mutableStateOf(false) }

    val folders = model.labels.filter { it.id != special.inbox }
    val inbox = model.mailbox(special.inbox)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Sift", fontWeight = FontWeight.SemiBold) },
                navigationIcon = {
                    IconButton(onClick = { navigator.push(Screen.Settings) }) { Icon(Icons.Outlined.Settings, "Settings") }
                },
                actions = {
                    IconButton(onClick = { navigator.push(Screen.Search) }) { Icon(Icons.Outlined.Search, "Search all mail") }
                },
            )
        },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = { navigator.push(Screen.Compose(ComposeRequest())) },
                icon = { Icon(Icons.Outlined.Edit, null) },
                text = { Text("New Message") },
            )
        },
    ) { padding ->
        PullToRefreshBox(
            isRefreshing = model.isSyncing,
            onRefresh = { scope.launch { model.refresh() } },
            modifier = Modifier.padding(padding),
        ) {
            LazyColumn(Modifier.fillMaxSize()) {
                // Only there when someone is waiting.
                if (screenerEntries.isNotEmpty()) {
                    item {
                        MailboxRow(Symbols.icon("person.crop.circle.badge.questionmark"), "Screener", screenerEntries.size, highlight = true) {
                            navigator.push(Screen.Screener)
                        }
                    }
                }
                if (inbox != null) {
                    item { MailboxRow(Symbols.icon("tray"), "Inbox", inbox.unreadEmails) { navigator.push(Screen.Mailbox(inbox.id, "Inbox")) } }
                }

                item {
                    CollapsibleHeader("Labels", labelsExpanded, { labelsExpanded = !labelsExpanded }) {
                        TextButton(onClick = { editingOrder = !editingOrder }) { Text(if (editingOrder) "Done" else "Reorder") }
                    }
                }
                if (labelsExpanded) {
                    items(folders, key = { it.id }) { label ->
                        val index = folders.indexOf(label)
                        LabelRow(
                            model, label.id, label.name, label.unreadEmails, editingOrder,
                            onOpen = { navigator.push(Screen.Mailbox(label.id, label.name)) },
                            onChangeIcon = { navigator.push(Screen.IconPicker(label.id)) },
                            onMove = { offset ->
                                val ids = folders.map { it.id }.toMutableList()
                                val target = (index + offset).coerceIn(0, ids.lastIndex)
                                ids.add(target, ids.removeAt(index))
                                model.reorderFolders(ids)
                            },
                            canMoveUp = index > 0, canMoveDown = index < folders.lastIndex,
                        )
                    }
                }

                // System piles: no unread counts, by design.
                item { CollapsibleHeader("More", moreExpanded, { moreExpanded = !moreExpanded }) }
                if (moreExpanded) {
                    item { MailboxRow(Symbols.icon("square.stack.3d.up"), "Everything", null) { navigator.push(Screen.Mailbox(null, "Everything")) } }
                    val system = listOfNotNull(
                        special.screenedOut.let { Triple(it, "Screened Out", "hand.raised") },
                        special.sent?.let { Triple(it, "Sent", "paperplane") },
                        special.drafts?.let { Triple(it, "Drafts", "doc") },
                        special.archive?.let { Triple(it, "Archive", "archivebox") },
                        special.junk?.let { Triple(it, "Spam", "xmark.bin") },
                        special.trash?.let { Triple(it, "Trash", "trash") },
                    )
                    items(system, key = { it.first }) { (id, name, icon) ->
                        MailboxRow(Symbols.icon(icon), name, null) { navigator.push(Screen.Mailbox(id, name)) }
                    }
                    item { MailboxRow(Symbols.icon("person.2"), "Senders", null) { navigator.push(Screen.Senders) } }
                }
                item { Spacer(Modifier.height(96.dp)) }
            }
        }
    }
}

@Composable
private fun CollapsibleHeader(title: String, expanded: Boolean, onToggle: () -> Unit, trailing: @Composable () -> Unit = {}) {
    Row(
        Modifier.fillMaxWidth().combinedClickableCompat(onToggle).padding(start = 20.dp, end = 8.dp, top = 14.dp, bottom = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (expanded) trailing()
        Icon(if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, if (expanded) "Collapse" else "Expand",
            tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(8.dp))
    }
}

@OptIn(ExperimentalFoundationApi::class)
private fun Modifier.combinedClickableCompat(onClick: () -> Unit, onLongClick: (() -> Unit)? = null) =
    combinedClickable(onClick = onClick, onLongClick = onLongClick)

@Composable
private fun MailboxRow(icon: ImageVector, title: String, count: Int?, highlight: Boolean = false, onLongClick: (() -> Unit)? = null, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().combinedClickableCompat(onClick, onLongClick).padding(horizontal = 20.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.width(18.dp))
        Text(title, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge,
            fontWeight = if (highlight) FontWeight.SemiBold else FontWeight.Normal)
        if (count != null && count > 0) {
            if (highlight) Badge(containerColor = MaterialTheme.colorScheme.primary) { Text("$count") }
            else Text("$count", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

/** A label: tap to open; long-press (or ⋮ while reordering) to change its icon or move it. */
@Composable
private fun LabelRow(
    model: AppModel, id: String, name: String, unread: Int, editing: Boolean,
    onOpen: () -> Unit, onChangeIcon: () -> Unit, onMove: (Int) -> Unit, canMoveUp: Boolean, canMoveDown: Boolean,
) {
    var menu by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            MailboxRow(Symbols.icon(model.icon(id)), name, unread, onLongClick = { menu = true }, onClick = onOpen)
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text("Change Icon…") }, onClick = { menu = false; onChangeIcon() },
                    leadingIcon = { Icon(Symbols.icon(model.icon(id)), null) })
            }
        }
        if (editing) {
            IconButton(onClick = { onMove(-1) }, enabled = canMoveUp) { Icon(Icons.Outlined.ArrowUpward, "Move up") }
            IconButton(onClick = { onMove(1) }, enabled = canMoveDown) { Icon(Icons.Outlined.ArrowDownward, "Move down") }
        }
    }
}
