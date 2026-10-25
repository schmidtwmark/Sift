package com.markschmidt.sift.ui

import android.content.ActivityNotFoundException
import android.content.Intent
import android.text.format.Formatter
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Forward
import androidx.compose.material.icons.automirrored.outlined.Reply
import androidx.compose.material.icons.automirrored.outlined.ReplyAll
import androidx.compose.material.icons.outlined.Archive
import androidx.compose.material.icons.outlined.AttachFile
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.MarkEmailUnread
import androidx.compose.material.icons.outlined.MoreHoriz
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material.icons.outlined.Report
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.BottomAppBar
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import com.markschmidt.sift.AppModel
import com.markschmidt.sift.ComposeRequest
import com.markschmidt.sift.core.jmap.EmailAddress
import com.markschmidt.sift.core.jmap.EmailBodyPart
import com.markschmidt.sift.core.jmap.formattedList
import com.markschmidt.sift.core.privacy.DetectedTracker
import com.markschmidt.sift.core.store.BodyRecord
import com.markschmidt.sift.core.store.MailStore.Companion.threadMessages
import com.markschmidt.sift.core.store.MessageRecord
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** A conversation: every message as a panel, newest and unread ones open. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ThreadScreen(model: AppModel, navigator: Navigator, threadId: String, sourceMailbox: String?, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    val store = model.store
    val live by remember(store, threadId) { store?.observe { threadMessages(threadId) } ?: emptyFlow() }.collectAsState(initial = null)
    var expanded by rememberSaveable { mutableStateOf(setOf<String>()) }
    var known by remember { mutableStateOf<Set<String>?>(null) }
    var showFolders by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    val messages = live ?: emptyList()

    LaunchedEffect(live) {
        val value = live ?: return@LaunchedEffect
        val previous = known
        // The conversation went away (a draft saved as a new version, or deleted elsewhere).
        if (previous != null && previous.isNotEmpty() && value.isEmpty()) {
            onClose()
            return@LaunchedEffect
        }
        val last = value.lastOrNull() ?: return@LaunchedEffect
        expanded = if (previous == null) {
            if (expanded.isEmpty()) value.filter { it.isUnread }.map { it.id }.toSet() + last.id else expanded
        } else {
            // Open messages that arrive while you're reading the thread.
            expanded + value.map { it.id }.filter { it !in previous }
        }
        known = value.map { it.id }.toSet()
    }

    val latest = messages.lastOrNull()
    fun reply(all: Boolean = false) = latest?.let { navigator.push(Screen.Compose(ComposeRequest(replyTo = it, replyAll = all))) }
    val currentFolders = messages.flatMap { it.mailboxIds }.toSet().intersect(model.labels.map { it.id }.toSet())

    Scaffold(
        topBar = {
            TopAppBar(
                title = {},
                navigationIcon = { IconButton(onClick = navigator::pop) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") } },
            )
        },
        bottomBar = {
            if (latest != null) {
                // Mail-style: actions sit at the bottom, within thumb reach.
                BottomAppBar {
                    IconButton(onClick = { onClose(); model.archive(listOf(threadId), sourceMailbox) }) { Icon(Icons.Outlined.Archive, "Archive") }
                    IconButton(onClick = { showFolders = true }) { Icon(Icons.Outlined.Folder, "Folders") }
                    IconButton(onClick = { reply() }) { Icon(Icons.AutoMirrored.Outlined.Reply, "Reply") }
                    Spacer(Modifier.weight(1f))
                    Box {
                        IconButton(onClick = { menu = true }) { Icon(Icons.Outlined.MoreHoriz, "More") }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            MenuItem("Reply All", Icons.AutoMirrored.Outlined.ReplyAll) { menu = false; reply(all = true) }
                            MenuItem("Forward", Icons.AutoMirrored.Outlined.Forward) {
                                menu = false; navigator.push(Screen.Compose(ComposeRequest(forward = latest)))
                            }
                            HorizontalDivider()
                            MenuItem("Mark as Unread", Icons.Outlined.MarkEmailUnread) { menu = false; model.markThread(threadId, read = false) }
                            MenuItem(if (latest.isFlagged) "Unpin" else "Pin", Icons.Outlined.PushPin) { menu = false; model.togglePin(latest) }
                            MenuItem("Sender Settings…", Icons.Outlined.Person) { menu = false; navigator.push(Screen.SenderSettings(latest.fromEmail)) }
                            HorizontalDivider()
                            MenuItem("Move to Spam", Icons.Outlined.Report) { menu = false; onClose(); model.junk(listOf(threadId)) }
                            MenuItem("Move to Trash", Icons.Outlined.Delete, destructive = true) { menu = false; onClose(); model.trash(listOf(threadId)) }
                        }
                    }
                }
            }
        },
        containerColor = MaterialTheme.colorScheme.surfaceContainer,
    ) { padding ->
        if (live == null) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            return@Scaffold
        }
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (latest != null && latest.isDraft) {
                item {
                    Button(
                        onClick = { scope.launch { model.openDraft(latest.id)?.let { navigator.push(Screen.Compose(ComposeRequest(draft = it))) } } },
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                    ) {
                        Icon(Icons.Outlined.Edit, null)
                        Spacer(Modifier.width(8.dp))
                        Text("Edit Draft")
                    }
                }
            }
            if (latest != null) {
                item {
                    Row(Modifier.padding(horizontal = 20.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(if (messages.size == 1) "1 Message" else "${messages.size} Messages",
                            style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Spacer(Modifier.weight(1f))
                        FolderChips(model, latest.mailboxIds)
                    }
                }
            }
            items(messages, key = { it.id }) { message ->
                MessageCard(
                    model, message,
                    isExpanded = message.id in expanded,
                    showsSubject = message.id == messages.first().id,
                    onToggle = { expanded = if (message.id in expanded) expanded - message.id else expanded + message.id },
                    onSender = { navigator.push(Screen.SenderSettings(message.fromEmail)) },
                )
            }
        }
    }

    if (showFolders) {
        FolderPickerSheet(
            model, initial = currentFolders,
            applyTitle = { if (it == 1) "Move to 1 Folder" else "File in $it Folders" },
            onDismiss = { showFolders = false },
        ) { folders ->
            showFolders = false
            model.refile(listOf(threadId), folders)
        }
    }
}

@Composable
private fun MenuItem(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector, destructive: Boolean = false, onClick: () -> Unit) {
    val color = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface
    DropdownMenuItem(text = { Text(title, color = color) }, leadingIcon = { Icon(icon, null, tint = color) }, onClick = onClick)
}

/**
 * One message, Mail-style: a full-width panel with the sender, a To: line
 * (tap for addresses), the subject on the first message, then the body.
 */
@Composable
fun MessageCard(
    model: AppModel, message: MessageRecord, isExpanded: Boolean, showsSubject: Boolean = true,
    onToggle: () -> Unit = {}, onSender: (() -> Unit)? = null,
) {
    var body by remember(message.id) { mutableStateOf<BodyRecord?>(null) }
    var prepared by remember(message.id) { mutableStateOf<MessageHtml.Prepared?>(null) }
    var loadError by remember(message.id) { mutableStateOf<String?>(null) }
    var allowRemoteOnce by remember(message.id) { mutableStateOf(false) }
    var showTrackers by remember { mutableStateOf(false) }
    var showAddresses by remember { mutableStateOf(false) }
    val allowRemote = model.preferences.loadRemoteImages || allowRemoteOnce

    LaunchedEffect(isExpanded, message.id) {
        if (!isExpanded || prepared != null) return@LaunchedEffect
        try {
            val loaded = model.body(message)
            body = loaded
            prepared = withContext(Dispatchers.Default) { MessageHtml.prepare(loaded) }
            // Read as soon as it's on screen.
            if (message.isUnread) model.markRead(listOf(message))
        } catch (error: Throwable) {
            if (error is kotlinx.coroutines.CancellationException) throw error
            loadError = "Couldn't load this message. ${error.message ?: ""}"
        }
    }

    Surface(
        Modifier.fillMaxWidth().padding(horizontal = 8.dp).animateContentSize(),
        shape = RoundedCornerShape(26.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
    ) {
        Column {
            // Header
            Row(Modifier.fillMaxWidth().clickable(onClick = onToggle).padding(16.dp), verticalAlignment = Alignment.Top) {
                Avatar(message.senderDisplayName, message.fromEmail, 44.dp,
                    Modifier.clip(RoundedCornerShape(50)).clickable(enabled = onSender != null) { onSender?.invoke() })
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        OneLine(message.senderDisplayName, Modifier.weight(1f), MaterialTheme.typography.titleMedium, weight = FontWeight.SemiBold)
                        Spacer(Modifier.width(8.dp))
                        Text(message.receivedAt.listLabel(), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        val trackers = prepared?.sanitized?.trackers.orEmpty()
                        if (isExpanded && trackers.isNotEmpty()) {
                            IconButton(onClick = { showTrackers = true }, Modifier.size(32.dp)) {
                                Icon(Icons.Outlined.VisibilityOff, "Spy pixels blocked", Modifier.size(18.dp), tint = Warning)
                            }
                        }
                    }
                    if (isExpanded) {
                        Row(Modifier.clickable { showAddresses = !showAddresses }.padding(top = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                            val names = (message.to + message.cc).map { it.displayName }
                            OneLine("To: ${if (names.isEmpty()) "(no recipients)" else names.formattedList()}", Modifier.weight(1f, fill = false),
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Icon(if (showAddresses) Icons.Outlined.KeyboardArrowDown else Icons.Outlined.KeyboardArrowRight, null,
                                Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        if (showAddresses) Addresses(message)
                    } else {
                        Text(message.preview, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2,
                            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                    }
                }
            }
            if (showsSubject) {
                HorizontalDivider(Modifier.padding(start = 16.dp), color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f))
                Text(
                    message.subject.ifEmpty { "(no subject)" },
                    Modifier.padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = if (isExpanded) 6.dp else 16.dp),
                    style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold,
                )
            }
            if (isExpanded) {
                Column(Modifier.padding(start = 16.dp, end = 16.dp, top = 10.dp, bottom = 18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    val ready = prepared
                    when {
                        ready != null -> {
                            if (!allowRemote && ready.sanitized.remoteImageCount > 0) {
                                val count = ready.sanitized.remoteImageCount
                                TextButton(onClick = { allowRemoteOnce = true }, contentPadding = PaddingValues(0.dp)) {
                                    Text("Load $count remote image${if (count == 1) "" else "s"}", style = MaterialTheme.typography.labelLarge)
                                }
                            }
                            MessageWebView(model, ready, allowRemote, Modifier.heightIn(min = 24.dp))
                            body?.attachments?.takeIf { it.isNotEmpty() }?.let { AttachmentList(model, it) }
                        }
                        loadError != null -> Row {
                            Icon(Icons.Outlined.Warning, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                            Spacer(Modifier.width(8.dp))
                            Text(loadError ?: "", color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        else -> Box(Modifier.fillMaxWidth().heightIn(min = 80.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                    }
                }
            }
        }
    }

    if (showTrackers) {
        TrackerDetails(prepared?.sanitized?.trackers.orEmpty()) { showTrackers = false }
    }
}

@Composable
private fun Addresses(message: MessageRecord) {
    @Composable
    fun line(label: String, list: List<EmailAddress>) {
        Text(buildAnnotatedString {
            withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append("$label: ") }
            append(list.joinToString(", ") { formatAddress(it) })
        }, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    Column(Modifier.padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        line("From", listOf(message.sender))
        line("To", message.to)
        if (message.cc.isNotEmpty()) line("Cc", message.cc)
        if (message.replyTo.isNotEmpty() && message.replyTo.map { it.normalized } != listOf(message.fromEmail)) line("Reply-To", message.replyTo)
        Text(message.receivedAt.fullLabel(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

fun formatAddress(address: EmailAddress): String =
    if (!address.name.isNullOrEmpty()) "${address.name} <${address.email ?: ""}>" else address.email ?: ""

/** What the eye icon reveals: which trackers were removed and why. */
@Composable
fun TrackerDetails(trackers: List<DetectedTracker>, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
        icon = { Icon(Icons.Outlined.VisibilityOff, null, tint = Warning) },
        title = { Text("Spy pixel${if (trackers.size == 1) "" else "s"} blocked") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    "Sift removed ${if (trackers.size == 1) "a tracking image" else "${trackers.size} tracking images"} that would have told the sender when, where and how often you opened this.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                trackers.forEach { tracker ->
                    Column {
                        Text(tracker.name, fontWeight = FontWeight.SemiBold)
                        Text(tracker.reason.explanation.replaceFirstChar { it.uppercase() }, style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(tracker.url, style = MaterialTheme.typography.labelSmall, fontFamily = FontFamily.Monospace, maxLines = 2,
                            color = MaterialTheme.colorScheme.outline, overflow = androidx.compose.ui.text.style.TextOverflow.MiddleEllipsis)
                    }
                }
            }
        },
    )
}

/** Attachments as capsules; tapping one downloads it and opens it in another app. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun AttachmentList(model: AppModel, parts: List<EmailBodyPart>) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var downloading by remember { mutableStateOf<String?>(null) }
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        parts.forEach { part ->
            Row(
                Modifier.clip(RoundedCornerShape(50)).background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f))
                    .clickable {
                        val blobId = part.blobId ?: return@clickable
                        scope.launch {
                            downloading = blobId
                            try {
                                val name = part.name ?: "attachment"
                                val type = part.type ?: "application/octet-stream"
                                val data = model.download(blobId, name, type)
                                val file = withContext(Dispatchers.IO) {
                                    File(context.cacheDir, "attachments/$blobId").apply { mkdirs() }.resolve(name.replace("/", "_")).apply { writeBytes(data) }
                                }
                                val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
                                val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, type).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                try {
                                    context.startActivity(Intent.createChooser(intent, name))
                                } catch (_: ActivityNotFoundException) {
                                    model.errorMessage = "No app on this phone opens $type files."
                                }
                            } catch (error: Throwable) {
                                if (error is kotlinx.coroutines.CancellationException) throw error
                                model.errorMessage = error.message
                            } finally {
                                downloading = null
                            }
                        }
                    }
                    .padding(horizontal = 12.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (downloading == part.blobId) CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                else Icon(Icons.Outlined.AttachFile, null, Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                OneLine(part.name ?: "Attachment", Modifier.weight(1f, fill = false), MaterialTheme.typography.labelLarge)
                part.size?.let {
                    Spacer(Modifier.width(6.dp))
                    Text(Formatter.formatShortFileSize(context, it.toLong()), style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}
