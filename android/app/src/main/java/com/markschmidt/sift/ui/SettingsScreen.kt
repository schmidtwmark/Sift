package com.markschmidt.sift.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Logout
import androidx.compose.material.icons.outlined.AutoFixHigh
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.markschmidt.sift.AppModel
import com.markschmidt.sift.core.labels.LabelIcon
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(model: AppModel, navigator: Navigator) {
    var undoDelay by remember { mutableIntStateOf(model.preferences.undoSendDelay) }
    var remoteImages by remember { mutableStateOf(model.preferences.loadRemoteImages) }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings", fontWeight = FontWeight.SemiBold) },
                navigationIcon = { IconButton(onClick = navigator::pop) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") } },
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState())) {
            SectionHeader("Account")
            ListItem(headlineContent = { Text("Signed in as") }, supportingContent = { Text(model.username.ifEmpty { "—" }) })
            model.screenerStartedAt?.let { started ->
                ListItem(headlineContent = { Text("Screening since") }, supportingContent = {
                    Text(DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).format(started.atZone(ZoneId.systemDefault())))
                })
            }
            ListItem(
                headlineContent = { Text(if (model.isDemo) "Leave Demo" else "Sign Out", color = MaterialTheme.colorScheme.error) },
                leadingContent = { Icon(Icons.AutoMirrored.Outlined.Logout, null, tint = MaterialTheme.colorScheme.error) },
                modifier = Modifier.clickable { model.signOut() },
            )

            SectionHeader("Sending")
            for ((seconds, title) in listOf(0 to "Off", 10 to "10 seconds", 20 to "20 seconds", 30 to "30 seconds")) {
                ListItem(
                    headlineContent = { Text(title) },
                    leadingContent = { RadioButton(selected = undoDelay == seconds, onClick = null) },
                    modifier = Modifier.clickable { undoDelay = seconds; model.preferences.undoSendDelay = seconds },
                )
            }
            Footnote(if (undoDelay == 0) "Messages go as soon as you tap Send." else "Undo Send: after you tap Send, you have $undoDelay seconds to take it back.")

            SectionHeader("Tools")
            ListItem(
                headlineContent = { Text("Suggest Screening Rules…") },
                leadingContent = { Icon(Icons.Outlined.AutoFixHigh, null) },
                modifier = Modifier.clickable { navigator.push(Screen.Suggestions) },
            )
            Footnote("Learn rules from how you've already filed mail.")

            SectionHeader("Privacy")
            SwitchRow("Load remote images", Icons.Outlined.Image, remoteImages, true) {
                remoteImages = it
                model.preferences.loadRemoteImages = it
            }
            Footnote("Spy pixels are always removed, and known tracking services are blocked from loading anything. Turn this off to block every remote image too; you can still load them one message at a time.")

            SectionHeader("Notifications")
            ListItem(headlineContent = { Text("Default") }, supportingContent = { Text("No alerts, no badge") })
            Footnote("Turn on alerts or the badge for individual senders: tap a sender's picture in a message.")
            Spacer(Modifier.height(32.dp))
        }
    }
}

/** Pick a label's icon; it syncs to your other devices through the label's contact group. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LabelIconPickerScreen(model: AppModel, navigator: Navigator, mailboxId: String) {
    val current = model.icon(mailboxId)
    val custom = model.labelIcons[mailboxId]
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Icon for “${model.name(mailboxId)}”", fontWeight = FontWeight.SemiBold, maxLines = 1) },
                navigationIcon = { IconButton(onClick = navigator::pop) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") } },
                actions = {
                    if (custom != null) {
                        TextButton(onClick = { model.setIcon(null, mailboxId); navigator.pop() }) { Text("Use Suggested") }
                    }
                },
            )
        },
    ) { padding ->
        LazyVerticalGrid(
            GridCells.Adaptive(56.dp), Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            for (category in LabelIcon.catalog) {
                item(span = { GridItemSpan(maxLineSpan) }, key = category.title) {
                    Text(category.title, Modifier.padding(top = 12.dp, bottom = 4.dp), style = MaterialTheme.typography.titleSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant, fontWeight = FontWeight.SemiBold)
                }
                items(category.symbols, key = { it }) { symbol ->
                    val selected = symbol == current
                    Surface(
                        onClick = { model.setIcon(symbol, mailboxId); navigator.pop() },
                        shape = RoundedCornerShape(14.dp),
                        color = if (selected) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainerHigh,
                        border = if (selected) BorderStroke(2.dp, MaterialTheme.colorScheme.primary) else null,
                        modifier = Modifier.aspectRatio(1f),
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Icon(Symbols.icon(symbol), symbol, Modifier.size(26.dp),
                                tint = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface)
                        }
                    }
                }
            }
            item(span = { GridItemSpan(maxLineSpan) }) {
                Text("Until you pick one, Sift guesses from the label's name. Your choice is saved in Fastmail and shows on your iPhone and Mac too.",
                    Modifier.fillMaxWidth().padding(top = 16.dp), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
            }
        }
    }
}
