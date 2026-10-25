package com.markschmidt.sift.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.filled.BackHand
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.BackHand
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.Verified
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.VerticalDivider
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.markschmidt.sift.AppModel
import com.markschmidt.sift.core.jmap.formattedList
import com.markschmidt.sift.core.store.MailStore.Companion.messagesById
import com.markschmidt.sift.core.store.MailStore.Companion.screener
import com.markschmidt.sift.core.store.ScreenerEntry
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.launch

/** First-time senders wait here until you decide: screen them in (to one or more labels) or out. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScreenerScreen(model: AppModel, navigator: Navigator) {
    val scope = rememberCoroutineScope()
    val special = model.special ?: return
    val store = model.store
    val entries by remember(store, special.screener) { store?.observe { screener(special.screener) } ?: emptyFlow() }
        .collectAsState(initial = null)

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Screener", fontWeight = FontWeight.SemiBold) },
                navigationIcon = { IconButton(onClick = navigator::pop) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") } },
            )
        },
    ) { padding ->
        PullToRefreshBox(model.isSyncing, { scope.launch { model.refresh() } }, Modifier.padding(padding)) {
            val list = entries
            when {
                list == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                list.isEmpty() -> EmptyState("All clear", Icons.Outlined.Verified, "New senders show up here before they reach your labels.")
                else -> LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
                    items(list, key = { it.email }) { entry ->
                        ScreenerCard(model, entry) { navigator.push(Screen.ScreenerSender(entry.email)) }
                        HorizontalDivider(Modifier.padding(horizontal = 16.dp), color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))
                    }
                    item {
                        Text(
                            "Your choice applies to future mail from each sender, on every device and in Fastmail.",
                            Modifier.padding(20.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ScreenerCard(model: AppModel, entry: ScreenerEntry, onOpen: () -> Unit) {
    val scope = rememberCoroutineScope()
    var working by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().clickable(onClick = onOpen).padding(horizontal = 16.dp, vertical = 14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Avatar(entry.name ?: entry.email, entry.email, 40.dp)
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                OneLine(entry.name ?: entry.email, style = MaterialTheme.typography.titleMedium, weight = FontWeight.SemiBold)
                OneLine(entry.email, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (entry.messages.size > 1) {
                Text("${entry.messages.size} emails", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        entry.messages.firstOrNull()?.let { latest ->
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                OneLine(latest.subject.ifEmpty { "(no subject)" }, style = MaterialTheme.typography.bodyMedium, weight = FontWeight.Medium)
                Text(latest.preview, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            ScreenOutButton(enabled = !working) {
                scope.launch { working = true; model.screenOut(entry); working = false }
            }
            Spacer(Modifier.weight(1f))
            if (working) CircularProgressIndicator(Modifier.size(18.dp).padding(end = 8.dp), strokeWidth = 2.dp)
            ScreenInButton(model, enabled = !working) { labels ->
                scope.launch { working = true; model.screenIn(entry, labels); working = false }
            }
        }
    }
}

@Composable
fun ScreenOutButton(enabled: Boolean = true, onClick: () -> Unit) {
    OutlinedButton(
        onClick = onClick, enabled = enabled,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.error.copy(alpha = 0.5f)),
        contentPadding = PaddingValues(horizontal = 14.dp),
    ) {
        Icon(Icons.Outlined.BackHand, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.error)
        Spacer(Modifier.width(6.dp))
        Text("Screen Out", color = MaterialTheme.colorScheme.error, fontWeight = FontWeight.Medium)
    }
}

/**
 * A split capsule: the main half screens the sender in to the Inbox; the
 * chevron opens the folder picker, applied by its button.
 */
@Composable
fun ScreenInButton(model: AppModel, enabled: Boolean = true, onScreenIn: (Set<String>) -> Unit) {
    var picking by remember { mutableStateOf(false) }
    val tint = if (enabled) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.12f)
    val content = if (enabled) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
    Surface(shape = RoundedCornerShape(50), color = tint, contentColor = content) {
        Row(Modifier.height(IntrinsicSize.Min), verticalAlignment = Alignment.CenterVertically) {
            Row(
                Modifier.clickable(enabled) { model.special?.inbox?.let { onScreenIn(setOf(it)) } }
                    .padding(start = 16.dp, end = 12.dp, top = 9.dp, bottom = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Outlined.Check, null, Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text("Screen In", fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.labelLarge)
            }
            VerticalDivider(Modifier.fillMaxHeight().padding(vertical = 9.dp), color = content.copy(alpha = 0.4f))
            Box(
                Modifier.clickable(enabled) { picking = true }.padding(start = 10.dp, end = 13.dp, top = 9.dp, bottom = 9.dp),
            ) {
                Icon(Icons.Outlined.KeyboardArrowDown, "Choose folders", Modifier.size(20.dp))
            }
        }
    }
    if (picking) {
        FolderPickerSheet(
            model,
            applyTitle = { if (it == 1) "Screen In to 1 Folder" else "Screen In to $it Folders" },
            onDismiss = { picking = false },
        ) { folders ->
            picking = false
            onScreenIn(folders)
        }
    }
}

/**
 * A sender waiting in the Screener, read like any other email, with the
 * decision at the bottom. Deciding files their mail and keeps you here, so
 * you see where it went.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScreenerSenderScreen(model: AppModel, navigator: Navigator, email: String) {
    val scope = rememberCoroutineScope()
    val special = model.special ?: return
    val store = model.store
    val waiting by remember(store, special.screener) { store?.observe { screener(special.screener) } ?: emptyFlow() }
        .collectAsState(initial = null)
    // Captured once: the sender's messages are then followed by id, so they stay after they're filed.
    var opened by remember { mutableStateOf<ScreenerEntry?>(null) }
    LaunchedEffect(waiting) {
        if (opened == null) waiting?.firstOrNull { it.email == email }?.let { opened = it }
    }
    val ids = opened?.messages?.map { it.id } ?: emptyList()
    val live by remember(store, ids) { if (ids.isEmpty() || store == null) emptyFlow() else store.observe { messagesById(ids) } }
        .collectAsState(initial = null)
    var expanded by rememberSaveable { mutableStateOf(setOf<String>()) }
    var decision by rememberSaveable { mutableStateOf<String?>(null) }
    var outcome by rememberSaveable { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }

    LaunchedEffect(opened) {
        opened?.messages?.firstOrNull()?.let { if (expanded.isEmpty()) expanded = setOf(it.id) }
    }

    val shown = (live ?: opened?.messages ?: emptyList()).sortedByDescending { it.receivedAt }

    fun decide(entry: ScreenerEntry, screenIn: Set<String>?) {
        scope.launch {
            working = true
            val ok = if (screenIn != null) model.screenIn(entry, screenIn) else model.screenOut(entry)
            working = false
            // Stay on the email; the folder chips above update as it moves.
            if (ok) {
                decision = if (screenIn == null) "out" else "in"
                outcome = if (screenIn == null) "Screened out" else {
                    val names = model.labels.filter { it.id in screenIn }.map { it.name }
                    "Screened in to ${if (names.isEmpty()) "Inbox" else names.formattedList()}"
                }
            }
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { OneLine(opened?.name ?: email, style = MaterialTheme.typography.titleMedium, weight = FontWeight.SemiBold) },
                navigationIcon = { IconButton(onClick = navigator::pop) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") } },
            )
        },
        bottomBar = {
            val entry = opened ?: return@Scaffold
            Surface(color = MaterialTheme.colorScheme.surfaceContainerHigh) {
                AnimatedContent(decision, label = "decision", modifier = Modifier.navigationBarsPadding()) { made ->
                    if (made != null) {
                        Row(Modifier.fillMaxWidth().padding(vertical = 18.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                            val color = if (made == "out") MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary
                            Icon(if (made == "out") Icons.Filled.BackHand else Icons.Filled.CheckCircle, null, tint = color, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text(outcome, color = color, fontWeight = FontWeight.SemiBold)
                        }
                    } else {
                        Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                            ScreenOutButton(enabled = !working) { decide(entry, null) }
                            Spacer(Modifier.weight(1f))
                            if (working) CircularProgressIndicator(Modifier.size(18.dp).padding(end = 8.dp), strokeWidth = 2.dp)
                            ScreenInButton(model, enabled = !working) { decide(entry, it) }
                        }
                    }
                }
            }
        },
        containerColor = MaterialTheme.colorScheme.surfaceContainer,
    ) { padding ->
        val entry = opened
        when {
            entry != null -> LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                item {
                    Row(Modifier.padding(horizontal = 20.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(if (entry.messages.size == 1) "1 Email" else "${entry.messages.size} Emails",
                            style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Spacer(Modifier.weight(1f))
                        // Where the newest message is now: the Screener, then wherever it was filed.
                        FolderChips(model, shown.firstOrNull()?.mailboxIds ?: emptyList())
                    }
                }
                items(shown, key = { it.id }) { message ->
                    MessageCard(model, message, isExpanded = message.id in expanded,
                        onToggle = { expanded = if (message.id in expanded) expanded - message.id else expanded + message.id },
                        onSender = { navigator.push(Screen.SenderSettings(message.fromEmail)) })
                }
            }
            waiting == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            else -> EmptyState("Already Screened", Icons.Outlined.CheckCircle, "This sender isn't waiting in the Screener any more.", Modifier.padding(padding))
        }
    }
}
