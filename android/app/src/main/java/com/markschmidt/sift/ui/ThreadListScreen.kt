package com.markschmidt.sift.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.MarkEmailRead
import androidx.compose.material.icons.outlined.MarkEmailUnread
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.markschmidt.sift.AppModel
import com.markschmidt.sift.core.store.MailStore.Companion.threadSummaries
import com.markschmidt.sift.core.store.ThreadSummary
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.launch

/** Conversations in one label, or across the whole account (Everything). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ThreadListScreen(model: AppModel, navigator: Navigator, mailboxId: String?, title: String) {
    val scope = rememberCoroutineScope()
    var limit by rememberSaveable { mutableIntStateOf(100) }
    var loadingOlder by remember { mutableStateOf(false) }
    var reachedEnd by rememberSaveable { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    val store = model.store
    val threads by remember(store, mailboxId, limit) {
        store?.observe { threadSummaries(mailboxId, limit) } ?: emptyFlow()
    }.collectAsState(initial = null)
    val isLabel = mailboxId != null && model.mailbox(mailboxId)?.role == null && mailboxId != model.special?.screenedOut
    val isDrafts = mailboxId != null && mailboxId == model.special?.drafts

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title, fontWeight = FontWeight.SemiBold) },
                navigationIcon = { IconButton(onClick = navigator::pop) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") } },
                actions = {
                    if (isLabel && mailboxId != null) {
                        IconButton(onClick = { menu = true }) { Icon(Icons.Outlined.MoreVert, "More") }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            DropdownMenuItem(
                                text = { Text("Change Icon…") },
                                leadingIcon = { Icon(Symbols.icon(model.icon(mailboxId)), null) },
                                onClick = { menu = false; navigator.push(Screen.IconPicker(mailboxId)) },
                            )
                        }
                    }
                },
            )
        },
    ) { padding ->
        PullToRefreshBox(model.isSyncing, { scope.launch { model.refresh() } }, Modifier.padding(padding)) {
            val list = threads
            when {
                list == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                list.isEmpty() -> EmptyState("Nothing here", Icons.Outlined.Inbox,
                    if (mailboxId == null) "No mail synced yet." else "No conversations in $title.")
                else -> LazyColumn(Modifier.fillMaxSize()) {
                    items(list, key = { it.id }) { thread ->
                        SwipeableThreadRow(
                            model, thread, showLabels = mailboxId == null, canArchive = mailboxId != null,
                            onOpen = {
                                if (isDrafts && thread.latest.isDraft) {
                                    scope.launch {
                                        model.openDraft(thread.latest.id)?.let { navigator.push(Screen.Compose(com.markschmidt.sift.ComposeRequest(draft = it))) }
                                    }
                                } else {
                                    navigator.push(Screen.Thread(thread.id, mailboxId))
                                }
                            },
                            onArchive = { model.archive(listOf(thread.id), mailboxId) },
                            onTrash = { model.trash(listOf(thread.id)) },
                        )
                        HorizontalDivider(Modifier.padding(start = 72.dp), color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))
                    }
                    if (!reachedEnd) {
                        item {
                            Row(Modifier.fillMaxWidth().padding(20.dp), horizontalArrangement = Arrangement.Center) {
                                if (loadingOlder) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                                else Text("Loading older mail…", color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            LaunchedEffect(list.size) {
                                if (loadingOlder) return@LaunchedEffect
                                loadingOlder = true
                                val before = list.size
                                if (list.size >= limit) {
                                    limit += 100
                                } else {
                                    // Local cache exhausted: ask Fastmail for older mail.
                                    model.loadOlder(mailboxId, list.last().latest.receivedAt)
                                    delay(300)
                                    if ((threads?.size ?: 0) == before) reachedEnd = true
                                }
                                loadingOlder = false
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Swipe right to toggle read; swipe left to archive (from a folder) or trash. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SwipeableThreadRow(
    model: AppModel, thread: ThreadSummary, showLabels: Boolean, canArchive: Boolean,
    onOpen: () -> Unit, onArchive: () -> Unit, onTrash: () -> Unit,
) {
    val unread = thread.unreadCount > 0
    val state = rememberSwipeToDismissBoxState(confirmValueChange = { value ->
        when (value) {
            SwipeToDismissBoxValue.StartToEnd -> { model.markThread(thread.id, read = unread); false }
            SwipeToDismissBoxValue.EndToStart -> { if (canArchive) onArchive() else onTrash(); true }
            SwipeToDismissBoxValue.Settled -> false
        }
    })
    SwipeToDismissBox(
        state = state,
        backgroundContent = {
            val direction = state.dismissDirection
            val (color, icon, label) = when (direction) {
                SwipeToDismissBoxValue.StartToEnd -> Triple(Color(0xFF2F7DE1), if (unread) Icons.Outlined.MarkEmailRead else Icons.Outlined.MarkEmailUnread, if (unread) "Read" else "Unread")
                SwipeToDismissBoxValue.EndToStart -> if (canArchive) Triple(Color(0xFF2A9D8F), Icons.Outlined.Archive, "Archive") else Triple(Color(0xFFD64545), Icons.Outlined.Delete, "Trash")
                SwipeToDismissBoxValue.Settled -> Triple(Color.Transparent, Icons.Outlined.Archive, "")
            }
            Row(
                Modifier.fillMaxSize().background(color).padding(horizontal = 24.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = if (direction == SwipeToDismissBoxValue.StartToEnd) Arrangement.Start else Arrangement.End,
            ) {
                if (direction != SwipeToDismissBoxValue.Settled) {
                    Icon(icon, null, tint = Color.White)
                    Spacer(Modifier.width(8.dp))
                    Text(label, color = Color.White, fontWeight = FontWeight.SemiBold)
                }
            }
        },
    ) {
        ThreadRow(model, thread, showLabels, onOpen)
    }
}

@Composable
fun ThreadRow(model: AppModel, thread: ThreadSummary, showLabels: Boolean, onClick: () -> Unit) {
    val message = thread.latest
    val unread = thread.unreadCount > 0
    val names = thread.participants.split(",").map { it.trim() }.filter { it.isNotEmpty() }
    val participants = if (names.size > 1) names.joinToString(", ") else message.senderDisplayName
    Row(
        Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.background).clickable(onClick = onClick)
            .padding(start = 8.dp, end = 16.dp, top = 12.dp, bottom = 12.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Box(Modifier.width(12.dp).padding(top = 14.dp), contentAlignment = Alignment.Center) {
            if (unread) Box(Modifier.size(7.dp).clip(CircleShape).background(MaterialTheme.colorScheme.primary))
        }
        Avatar(message.senderDisplayName, message.fromEmail, 38.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
                    OneLine(participants, Modifier.weight(1f, fill = false), MaterialTheme.typography.bodyLarge,
                        weight = if (unread) FontWeight.SemiBold else FontWeight.Normal)
                    if (thread.messageCount > 1) {
                        Spacer(Modifier.width(6.dp))
                        Text("${thread.messageCount}", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                if (message.isFlagged) Icon(Icons.Filled.PushPin, "Pinned", Modifier.size(14.dp), tint = Warning)
                Spacer(Modifier.width(4.dp))
                Text(message.receivedAt.listLabel(), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            OneLine(message.subject.ifEmpty { "(no subject)" }, style = MaterialTheme.typography.bodyMedium,
                weight = if (unread) FontWeight.Medium else FontWeight.Normal)
            Text(message.preview, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
            if (showLabels) {
                Spacer(Modifier.size(2.dp))
                FolderChips(model, message.mailboxIds, small = true)
            }
        }
    }
}
