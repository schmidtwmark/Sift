package com.markschmidt.sift.ui

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.AutoFixHigh
import androidx.compose.material.icons.outlined.Badge
import androidx.compose.material.icons.outlined.Notifications
import androidx.compose.material.icons.outlined.People
import androidx.compose.material.icons.outlined.UnfoldMore
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.markschmidt.sift.AppModel
import com.markschmidt.sift.core.jmap.formattedList
import com.markschmidt.sift.core.screener.RuleSuggestion
import com.markschmidt.sift.core.store.MailStore.Companion.messageCount
import com.markschmidt.sift.core.store.MailStore.Companion.senderList
import com.markschmidt.sift.core.store.MailStore.Companion.senderName
import com.markschmidt.sift.core.store.MailStore.Companion.senderRule
import com.markschmidt.sift.core.store.SenderRecord
import com.markschmidt.sift.core.store.SenderRecord.Status
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.launch
import java.time.Instant

/** Everything Sift knows and decides about one sender: screening, folders, alerts and badge. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SenderSettingsScreen(model: AppModel, navigator: Navigator, email: String) {
    val scope = rememberCoroutineScope()
    val store = model.store
    val rule by remember(store, email) { store?.observe { senderRule(email) } ?: emptyFlow() }.collectAsState(initial = null)
    var loaded by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf(SenderRecord(email = email)) }
    var labels by remember { mutableStateOf(setOf<String>()) }
    var refile by remember { mutableStateOf(true) }
    var saving by remember { mutableStateOf(false) }
    var picking by remember { mutableStateOf(false) }
    var count by remember { mutableStateOf(0) }
    var fallbackName by remember { mutableStateOf<String?>(null) }
    val inbox = model.special?.inbox

    LaunchedEffect(store, email) {
        store ?: return@LaunchedEffect
        count = store.read { messageCount(email) }
        fallbackName = store.read { senderName(email) }
        val existing = store.sender(email)
        draft = existing ?: SenderRecord(email = email)
        labels = if (draft.labelIds.isEmpty()) setOfNotNull(inbox) else draft.labelIds.toSet()
        loaded = true
    }

    // Alerts and the badge need permission to post notifications; asked the first time either is turned on.
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
    fun askToNotify() {
        if (Build.VERSION.SDK_INT >= 33 && !model.notifier.canPost) permission.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    val resolvedLabels = model.labels.map { it.id }.filter { it in labels }.let { if (it == listOfNotNull(inbox)) emptyList() else it }
    val current = rule
    val hasChanges = if (current == null) draft.status != Status.UNKNOWN || draft.notify || draft.badge else
        current.status != draft.status || current.notify != draft.notify || current.badge != draft.badge ||
            (draft.status == Status.SCREENED_IN && current.labelIds.toSet() != resolvedLabels.toSet())
    val displayName = draft.name ?: fallbackName ?: email

    Scaffold(
        topBar = {
            TopAppBar(
                title = { OneLine(displayName, style = MaterialTheme.typography.titleMedium, weight = FontWeight.SemiBold) },
                navigationIcon = { IconButton(onClick = navigator::pop) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") } },
                actions = {
                    TextButton(
                        enabled = loaded && hasChanges && !saving && !(draft.status == Status.SCREENED_IN && labels.isEmpty()),
                        onClick = {
                            scope.launch {
                                saving = true
                                var updated = draft.copy(
                                    name = draft.name ?: fallbackName,
                                    labelIds = if (draft.status == Status.SCREENED_IN) resolvedLabels else emptyList(),
                                    updatedAt = Instant.now(),
                                )
                                if (updated.status == Status.SCREENED_OUT) updated = updated.copy(notify = false, badge = false)
                                if (model.save(updated, refile)) draft = updated
                                saving = false
                            }
                        },
                    ) { if (saving) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp) else Text("Save") }
                },
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())) {
            Row(Modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
                Avatar(displayName, email, 48.dp)
                Spacer(Modifier.width(14.dp))
                Column {
                    Text(displayName, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text(email, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text("$count message${if (count == 1) "" else "s"} cached", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            SectionHeader("Screening")
            val options = listOf(Status.SCREENED_IN to "Screened in", Status.SCREENED_OUT to "Screened out", Status.UNKNOWN to "Not decided")
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
                options.forEachIndexed { index, (status, title) ->
                    SegmentedButton(
                        selected = draft.status == status,
                        onClick = { draft = draft.copy(status = status) },
                        shape = SegmentedButtonDefaults.itemShape(index, options.size),
                    ) { Text(title, maxLines = 1) }
                }
            }
            if (draft.status == Status.SCREENED_IN) {
                val names = model.labels.filter { it.id in labels }.map { it.name }
                ListItem(
                    headlineContent = { Text("New mail goes to") },
                    trailingContent = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(if (names.isEmpty()) "Choose" else names.formattedList(), color = MaterialTheme.colorScheme.primary)
                            Icon(Icons.Outlined.UnfoldMore, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.primary)
                        }
                    },
                    modifier = Modifier.clickable { picking = true },
                )
            }
            SectionHeader("Notifications")
            val disabled = draft.status == Status.SCREENED_OUT
            SwitchRow("Notify me about new mail", Icons.Outlined.Notifications, draft.notify, !disabled) {
                draft = draft.copy(notify = it)
                if (it) askToNotify()
            }
            SwitchRow("Count in the app icon badge", Icons.Outlined.Badge, draft.badge, !disabled) {
                draft = draft.copy(badge = it)
                if (it) askToNotify()
            }
            Footnote("Off by default for everyone. On Android, alerts arrive while Sift is open and when Android lets it refresh in the background, which can be late.")
            SectionHeader("Existing mail")
            SwitchRow("Move existing mail to match", null, refile, true) { refile = it }
            Footnote("Saved in Sift's contact groups in Fastmail, so every device follows the same rule.")
            Spacer(Modifier.size(32.dp))
        }
    }

    if (picking) {
        FolderPickerSheet(model, initial = labels, applyTitle = { if (it == 1) "Use 1 Folder" else "Use $it Folders" }, onDismiss = { picking = false }) {
            labels = it
            picking = false
        }
    }
}

@Composable
fun SwitchRow(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector?, checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    ListItem(
        headlineContent = { Text(title) },
        leadingContent = icon?.let { { Icon(it, null) } },
        trailingContent = { Switch(checked = checked, onCheckedChange = onChange, enabled = enabled) },
        modifier = Modifier.clickable(enabled = enabled) { onChange(!checked) },
    )
}

@Composable
fun Footnote(text: String) {
    Text(text, Modifier.padding(horizontal = 20.dp, vertical = 4.dp), style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant)
}

/** All senders with a decision, for reviewing and changing them. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SendersScreen(model: AppModel, navigator: Navigator) {
    val store = model.store
    val senders by remember(store) { store?.observe { senderList() } ?: emptyFlow() }.collectAsState(initial = null)
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Senders", fontWeight = FontWeight.SemiBold) },
                navigationIcon = { IconButton(onClick = navigator::pop) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") } },
                actions = { IconButton(onClick = { navigator.push(Screen.Suggestions) }) { Icon(Icons.Outlined.AutoFixHigh, "Suggest Rules") } },
            )
        },
    ) { padding ->
        val list = senders
        when {
            list == null -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            list.none { it.status != Status.UNKNOWN } -> EmptyState("No decisions yet", Icons.Outlined.People,
                "Senders you screen in or out appear here. Tap the wand to learn rules from mail you've already filed.", Modifier.padding(padding))
            else -> LazyColumn(Modifier.fillMaxSize().padding(padding)) {
                for ((status, title) in listOf(Status.SCREENED_IN to "Screened in", Status.SCREENED_OUT to "Screened out")) {
                    val matching = list.filter { it.status == status }
                    if (matching.isEmpty()) continue
                    item(key = title) { SectionHeader(title) }
                    items(matching, key = { it.email }) { sender ->
                        ListItem(
                            headlineContent = { OneLine(sender.name ?: sender.email) },
                            supportingContent = {
                                val detail = if (sender.status != Status.SCREENED_IN) sender.email else
                                    sender.labelIds.map { model.name(it) }.ifEmpty { listOf("Inbox") }.joinToString(", ")
                                OneLine(detail, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            },
                            leadingContent = { Avatar(sender.name ?: sender.email, sender.email, 34.dp) },
                            trailingContent = {
                                Row {
                                    if (sender.notify) Icon(Icons.Outlined.Notifications, "Alerts on", tint = MaterialTheme.colorScheme.onSurfaceVariant)
                                    if (sender.badge) Icon(Icons.Outlined.Badge, "Badge on", tint = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                            },
                            modifier = Modifier.clickable { navigator.push(Screen.SenderSettings(sender.email)) },
                        )
                    }
                }
            }
        }
    }
}

/** Rules implied by where you've already filed each sender's mail, grouped by folder. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RuleSuggestionsScreen(model: AppModel, navigator: Navigator) {
    val scope = rememberCoroutineScope()
    var suggestions by remember { mutableStateOf<List<RuleSuggestion>?>(null) }
    var chosen by remember { mutableStateOf(setOf<String>()) }
    var saving by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        val found = runCatching { model.suggestRules() }.getOrElse { model.errorMessage = it.message; emptyList() }
        suggestions = found
        chosen = found.map { it.email }.toSet()
    }
    fun destination(suggestion: RuleSuggestion) = when (suggestion.status) {
        Status.SCREENED_OUT -> "Screen out"
        else -> "Screen in to " + suggestion.labelIds.map { model.name(it) }.ifEmpty { listOf("Inbox") }.formattedList()
    }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Suggested Rules", fontWeight = FontWeight.SemiBold) },
                navigationIcon = { IconButton(onClick = navigator::pop) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") } },
                actions = {
                    TextButton(enabled = chosen.isNotEmpty() && !saving, onClick = {
                        scope.launch {
                            saving = true
                            if (model.apply(suggestions.orEmpty().filter { it.email in chosen })) navigator.pop()
                            saving = false
                        }
                    }) { Text("Save ${chosen.size}") }
                },
            )
        },
    ) { padding ->
        val list = suggestions
        when {
            list == null -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            list.isEmpty() -> EmptyState("Nothing to suggest", Icons.Outlined.AutoFixHigh,
                "Every sender with filed mail already has a rule, or there isn't enough filed mail to go on.", Modifier.padding(padding))
            else -> LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(bottom = 24.dp)) {
                item { Footnote("A sender is suggested for a folder when at least half their mail is there. Rules apply to new mail only.") }
                for ((group, items) in list.groupBy(::destination)) {
                    item(key = "h-$group") {
                        val all = items.all { it.email in chosen }
                        Row(Modifier.fillMaxWidth().clickable {
                            chosen = if (all) chosen - items.map { it.email }.toSet() else chosen + items.map { it.email }
                        }.padding(end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                            SectionHeader(group, Modifier.weight(1f))
                            Checkbox(checked = all, onCheckedChange = null)
                        }
                    }
                    items(items, key = { it.email }) { suggestion ->
                        ListItem(
                            headlineContent = { OneLine(suggestion.name ?: suggestion.email) },
                            supportingContent = { Text("${suggestion.evidence} message${if (suggestion.evidence == 1) "" else "s"} · ${suggestion.email}",
                                color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1) },
                            leadingContent = { Avatar(suggestion.name ?: suggestion.email, suggestion.email, 32.dp) },
                            trailingContent = { Checkbox(checked = suggestion.email in chosen, onCheckedChange = null) },
                            modifier = Modifier.clickable {
                                chosen = if (suggestion.email in chosen) chosen - suggestion.email else chosen + suggestion.email
                            },
                        )
                    }
                    item(key = "d-$group") { HorizontalDivider() }
                }
            }
        }
    }
}
