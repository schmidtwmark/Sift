package com.markschmidt.sift.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.markschmidt.sift.AppModel
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.temporal.ChronoUnit

/** A colored circle with initials, the same color for a sender on every device. */
@Composable
fun Avatar(name: String, email: String, size: Dp = 36.dp, modifier: Modifier = Modifier) {
    val palette = listOf(
        Color(0xFF30B0C7), Color(0xFF5856D6), Color(0xFFFF9500), Color(0xFFFF2D55), Color(0xFF00C7BE),
        Color(0xFFAF52DE), Color(0xFFA2845E), Color(0xFF32ADE6), Color(0xFF34C759), Color(0xFF007AFF),
    )
    // The Apple apps' djb2 hash over the address, so avatars match.
    var hash = 5381L
    for (char in email) hash = hash * 33 + char.code
    val color = palette[(Math.abs(hash) % palette.size).toInt()]
    val words = name.split(Regex("[^\\p{L}]+")).filter { it.isNotEmpty() }.take(2)
    val initials = words.joinToString("") { it.first().uppercase() }.ifEmpty { email.take(1).uppercase() }
    Box(
        modifier
            .size(size)
            .clip(CircleShape)
            .background(Brush.verticalGradient(listOf(color.copy(alpha = 0.85f), color))),
        contentAlignment = Alignment.Center,
    ) {
        Text(initials, color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = (size.value * 0.4f).sp)
    }
}

/** "9:41 AM" today, "Tue" this week, "Mar 4" this year, otherwise "3/4/24". */
fun Instant.listLabel(): String {
    val zone = ZoneId.systemDefault()
    val date = atZone(zone)
    val today = LocalDate.now(zone)
    return when {
        date.toLocalDate() == today -> DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).format(date)
        ChronoUnit.DAYS.between(date.toLocalDate(), today) < 6 -> DateTimeFormatter.ofPattern("EEE").format(date)
        date.year == today.year -> DateTimeFormatter.ofPattern("MMM d").format(date)
        else -> DateTimeFormatter.ofLocalizedDate(FormatStyle.SHORT).format(date)
    }
}

fun Instant.fullLabel(): String =
    DateTimeFormatter.ofLocalizedDateTime(FormatStyle.FULL, FormatStyle.SHORT).format(atZone(ZoneId.systemDefault()))

@Composable
fun EmptyState(title: String, icon: ImageVector, message: String, modifier: Modifier = Modifier) {
    Column(
        modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(icon, null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(12.dp))
        Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(6.dp))
        Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** A label shown on a message or conversation: its icon and name, in a capsule. */
@Composable
fun FolderChip(model: AppModel, mailboxId: String, small: Boolean = false) {
    Row(
        Modifier
            .clip(RoundedCornerShape(50))
            .background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f))
            .padding(horizontal = if (small) 6.dp else 8.dp, vertical = if (small) 2.dp else 3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Symbols.icon(model.icon(mailboxId)), null, Modifier.size(if (small) 12.dp else 14.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.width(3.dp))
        Text(
            model.name(mailboxId),
            style = if (small) MaterialTheme.typography.labelSmall else MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1,
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun FolderChips(model: AppModel, mailboxIds: List<String>, small: Boolean = false) {
    val shown = mailboxIds.filter { model.mailbox(it) != null }
    if (shown.isEmpty()) return
    FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        shown.forEach { FolderChip(model, it, small) }
    }
}

/**
 * Tick one or more folders, optionally create one, then apply with the
 * button at the bottom. Used to screen senders in, to file conversations and
 * to pick where a sender's mail goes.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FolderPickerSheet(
    model: AppModel,
    initial: Set<String> = emptySet(),
    applyTitle: (Int) -> String,
    onDismiss: () -> Unit,
    onApply: (Set<String>) -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var chosen by remember { mutableStateOf(initial) }
    var naming by remember { mutableStateOf(false) }
    var newName by remember { mutableStateOf("") }
    var creating by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val canApply = chosen.isNotEmpty() && !(chosen == initial && initial.isNotEmpty())

    fun create() {
        val name = newName.trim()
        if (name.isEmpty() || creating) return
        creating = true
        scope.launch {
            model.createLabel(name)?.let { chosen = chosen + it }
            creating = false
            naming = false
            newName = ""
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(Modifier.navigationBarsPadding().imePadding()) {
            LazyColumn(Modifier.weight(1f, fill = false)) {
                items(model.labels, key = { it.id }) { folder ->
                    val isOn = folder.id in chosen
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable { chosen = if (isOn) chosen - folder.id else chosen + folder.id }
                            .padding(horizontal = 20.dp, vertical = 13.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Symbols.icon(model.icon(folder.id)), null, tint = MaterialTheme.colorScheme.primary)
                        Spacer(Modifier.width(16.dp))
                        Text(folder.name, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
                        // Always there, so ticking a folder never moves anything.
                        Icon(
                            Icons.Outlined.Check, if (isOn) "Selected" else null,
                            tint = if (isOn) MaterialTheme.colorScheme.primary else Color.Transparent,
                        )
                    }
                }
            }
            HorizontalDivider()
            if (naming) {
                Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        newName, { newName = it }, Modifier.weight(1f),
                        placeholder = { Text("New folder name") }, singleLine = true,
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { create() }),
                    )
                    TextButton(onClick = ::create, enabled = newName.isNotBlank() && !creating) { Text("Add") }
                }
            } else {
                TextButton(onClick = { naming = true }, Modifier.padding(horizontal = 8.dp)) {
                    Icon(Icons.Outlined.Add, null)
                    Spacer(Modifier.width(8.dp))
                    Text("New Folder…")
                }
            }
            HorizontalDivider()
            Button(
                onClick = { onApply(chosen) },
                enabled = canApply,
                modifier = Modifier.fillMaxWidth().padding(16.dp).height(48.dp),
            ) {
                Text(if (chosen.isEmpty()) "Pick Folders Above" else applyTitle(chosen.size))
            }
        }
    }
}

/** "Archived · Undo", floating above the content for a few seconds. */
@Composable
fun ToastHost(model: AppModel, modifier: Modifier = Modifier) {
    val scope = rememberCoroutineScope()
    val toast = model.toast
    AnimatedVisibility(
        visible = toast != null,
        modifier = modifier,
        enter = slideInVertically { it } + fadeIn(),
        exit = slideOutVertically { it } + fadeOut(),
    ) {
        val shown = remember(toast?.id) { toast } ?: return@AnimatedVisibility
        Surface(
            shape = RoundedCornerShape(50),
            color = MaterialTheme.colorScheme.inverseSurface,
            contentColor = MaterialTheme.colorScheme.inverseOnSurface,
            shadowElevation = 6.dp,
        ) {
            Row(Modifier.padding(start = 20.dp, end = 8.dp, top = 4.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(shown.message, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium,
                    modifier = Modifier.padding(vertical = 10.dp).padding(end = 12.dp))
                shown.undo?.let { undo ->
                    TextButton(onClick = {
                        model.dismissToast()
                        scope.launch { undo() }
                    }) { Text("Undo", color = MaterialTheme.colorScheme.inversePrimary, fontWeight = FontWeight.SemiBold) }
                }
            }
        }
    }
}

@Composable
fun ErrorDialog(model: AppModel) {
    val message = model.errorMessage ?: return
    AlertDialog(
        onDismissRequest = { model.errorMessage = null },
        confirmButton = { TextButton(onClick = { model.errorMessage = null }) { Text("OK") } },
        title = { Text("Something went wrong") },
        text = { Text(message) },
    )
}

@Composable
fun SectionHeader(title: String, modifier: Modifier = Modifier) {
    Text(
        title,
        modifier.padding(start = 20.dp, end = 20.dp, top = 20.dp, bottom = 6.dp),
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        fontWeight = FontWeight.SemiBold,
    )
}

@Composable
fun OneLine(text: String, modifier: Modifier = Modifier, style: androidx.compose.ui.text.TextStyle = MaterialTheme.typography.bodyMedium,
            color: Color = Color.Unspecified, weight: FontWeight? = null) {
    Text(text, modifier, style = style, color = color, fontWeight = weight, maxLines = 1, overflow = TextOverflow.Ellipsis)
}
