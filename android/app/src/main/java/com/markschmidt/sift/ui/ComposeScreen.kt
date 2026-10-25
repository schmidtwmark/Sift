package com.markschmidt.sift.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import android.provider.OpenableColumns
import android.text.format.Formatter
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.outlined.AttachFile
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.markschmidt.sift.AppModel
import com.markschmidt.sift.ComposeDraft
import com.markschmidt.sift.ComposeDraft.Field
import com.markschmidt.sift.ComposeRequest
import com.markschmidt.sift.core.jmap.EmailAddress
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

/** Writing a message: new, reply, forward, a mailto: link, or a saved draft. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun ComposeScreen(model: AppModel, request: ComposeRequest, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val draft = remember(request.id) { ComposeDraft() }
    var prepared by remember(request.id) { mutableStateOf(false) }
    var focusedField by remember { mutableStateOf<Field?>(null) }
    var askToClose by remember { mutableStateOf(false) }
    var suggestions by remember { mutableStateOf<List<EmailAddress>>(emptyList()) }
    val focus = remember { Field.entries.associateWith { FocusRequester() } }

    LaunchedEffect(request.id) {
        val start = draft.prepare(request, model)
        prepared = true
        delay(100)
        runCatching { focus.getValue(start).requestFocus() }
    }

    // Saves after a pause in typing.
    LaunchedEffect(prepared) {
        if (!prepared) return@LaunchedEffect
        snapshotFlow { draft.message.content }.drop(1).collectLatest {
            delay(2_500)
            draft.save(model)
        }
    }

    // And when the app goes to the background.
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) model.scope.launch { draft.save(model) }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }

    // People to suggest for the field being typed in.
    val typing = focusedField?.takeIf { it == Field.TO || it == Field.CC || it == Field.BCC }
    val typed = typing?.let { draft.text(it) } ?: ""
    LaunchedEffect(typing, typed) {
        suggestions = if (typing == null || typed.isBlank()) emptyList() else {
            val added = (draft.to + draft.cc + draft.bcc).map { it.normalized }.toSet()
            model.addressSuggestions(typed).filter { it.normalized !in added }
        }
    }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.GetMultipleContents()) { uris ->
        uris.forEach { uri ->
            scope.launch {
                val file = withContext(Dispatchers.IO) { readAttachment(context, uri) }
                if (file == null) model.errorMessage = "Couldn't read that file."
                else draft.attach(file.third, file.first, file.second, model)
            }
        }
    }

    fun close() {
        if (draft.isFinished || (!draft.hasEdits && draft.draftId == null)) onClose() else askToClose = true
    }
    BackHandler { close() }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { OneLine(draft.title, style = MaterialTheme.typography.titleMedium, weight = FontWeight.SemiBold) },
                navigationIcon = { IconButton(onClick = ::close) { Icon(Icons.Outlined.Close, "Close") } },
                actions = {
                    IconButton(onClick = { picker.launch("*/*") }) { Icon(Icons.Outlined.AttachFile, "Attach files") }
                    IconButton(
                        onClick = { scope.launch { if (draft.send(model)) onClose() } },
                        enabled = draft.canSend,
                    ) {
                        if (draft.isSending) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                        else Icon(Icons.AutoMirrored.Filled.Send, "Send", tint = if (draft.message.recipients.isNotEmpty()) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline)
                    }
                },
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).imePadding().verticalScroll(rememberScrollState())) {
            RecipientField(draft, Field.TO, "To", focus.getValue(Field.TO), { focusedField = it }, suggestions.takeIf { typing == Field.TO })
            if (draft.showsAllHeaders) {
                RecipientField(draft, Field.CC, "Cc", focus.getValue(Field.CC), { focusedField = it }, suggestions.takeIf { typing == Field.CC })
                RecipientField(draft, Field.BCC, "Bcc", focus.getValue(Field.BCC), { focusedField = it }, suggestions.takeIf { typing == Field.BCC })
                FromField(model, draft)
            } else {
                // Cc, Bcc and From fold into one line until you tap it.
                val from = model.identities.firstOrNull { it.id == draft.identityId }?.email ?: ""
                HeaderRow("Cc/Bcc, From:", Modifier.clickable { draft.showsAllHeaders = true }) {
                    Text(from, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            HeaderRow("Subject:") {
                PlainField(draft.subject, { draft.subject = it }, Modifier.focusRequester(focus.getValue(Field.SUBJECT)).onFocusChanged { if (it.isFocused) focusedField = Field.SUBJECT },
                    capitalization = KeyboardCapitalization.Sentences)
            }
            if (draft.attachments.isNotEmpty()) {
                FlowRow(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    draft.attachments.forEach { file -> AttachmentChip(context, file) { draft.remove(file.id) } }
                }
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f))
            }
            PlainField(
                draft.body, { draft.body = it },
                Modifier.fillMaxWidth().heightIn(min = 320.dp).padding(16.dp).focusRequester(focus.getValue(Field.BODY))
                    .onFocusChanged { if (it.isFocused) focusedField = Field.BODY },
                singleLine = false, capitalization = KeyboardCapitalization.Sentences,
            )
        }
    }

    if (askToClose) {
        AlertDialog(
            onDismissRequest = { askToClose = false },
            title = { Text("Save this message?") },
            text = { Text("Drafts are saved in Fastmail, so you can finish it on any device.") },
            confirmButton = {
                TextButton(onClick = {
                    askToClose = false
                    scope.launch { draft.save(model); onClose() }
                }) { Text("Save Draft") }
            },
            dismissButton = {
                Row {
                    TextButton(onClick = { askToClose = false }) { Text("Keep Editing") }
                    TextButton(onClick = {
                        askToClose = false
                        scope.launch { draft.discard(model); onClose() }
                    }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
                }
            },
        )
    }
}

@Composable
private fun HeaderRow(label: String, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Column(modifier) {
        Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.width(8.dp))
            Box(Modifier.weight(1f)) { content() }
        }
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f))
    }
}

@Composable
private fun PlainField(
    value: String, onChange: (String) -> Unit, modifier: Modifier = Modifier, singleLine: Boolean = true,
    capitalization: KeyboardCapitalization = KeyboardCapitalization.None, keyboardType: KeyboardType = KeyboardType.Text,
    imeAction: ImeAction = ImeAction.Default, onDone: () -> Unit = {},
) {
    BasicTextField(
        value, onChange, modifier.fillMaxWidth(), singleLine = singleLine,
        textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface),
        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
        keyboardOptions = KeyboardOptions(capitalization = capitalization, keyboardType = keyboardType, imeAction = imeAction,
            autoCorrectEnabled = keyboardType != KeyboardType.Email),
        keyboardActions = KeyboardActions(onAny = { onDone() }),
    )
}

/** Addresses as tokens, then the one being typed, with suggestions underneath. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun RecipientField(
    draft: ComposeDraft, field: Field, label: String, focus: FocusRequester,
    onFocus: (Field?) -> Unit, suggestions: List<EmailAddress>?,
) {
    val list = draft.list(field)
    Column {
        Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).padding(horizontal = 16.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("$label:", color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.width(8.dp))
            FlowRow(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                list.toList().forEach { address ->
                    Row(
                        Modifier.clip(RoundedCornerShape(50)).background(MaterialTheme.colorScheme.primaryContainer)
                            .clickable { list.remove(address) }.padding(start = 10.dp, end = 6.dp, top = 4.dp, bottom = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(address.displayName, color = MaterialTheme.colorScheme.onPrimaryContainer, style = MaterialTheme.typography.bodyMedium)
                        Icon(Icons.Outlined.Close, "Remove ${address.displayName}", Modifier.padding(start = 2.dp).size(14.dp),
                            tint = MaterialTheme.colorScheme.onPrimaryContainer)
                    }
                }
                Box(Modifier.widthIn(min = 120.dp).weight(1f).align(Alignment.CenterVertically)) {
                    PlainField(
                        draft.text(field),
                        { value ->
                            draft.setText(field, value)
                            if (value.endsWith(",") || value.endsWith(";")) draft.commit(field)
                        },
                        Modifier.focusRequester(focus).onFocusChanged { state ->
                            if (state.isFocused) onFocus(field) else draft.commit(field)
                        },
                        keyboardType = KeyboardType.Email, imeAction = ImeAction.Next,
                        onDone = {
                            val first = suggestions?.firstOrNull()
                            if (first != null && draft.text(field).isNotBlank()) draft.add(first, field) else draft.commit(field)
                        },
                    )
                }
            }
        }
        if (!suggestions.isNullOrEmpty()) {
            Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainerHigh)) {
                suggestions.forEach { address ->
                    Row(Modifier.fillMaxWidth().clickable { draft.add(address, field) }.padding(horizontal = 16.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Avatar(address.displayName, address.email ?: "", 30.dp)
                        Spacer(Modifier.width(12.dp))
                        Column {
                            Text(address.displayName, style = MaterialTheme.typography.bodyMedium)
                            if (!address.name.isNullOrEmpty()) {
                                Text(address.email ?: "", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
        }
        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.6f))
    }
}

@Composable
private fun FromField(model: AppModel, draft: ComposeDraft) {
    var open by remember { mutableStateOf(false) }
    val current = model.identities.firstOrNull { it.id == draft.identityId }
    HeaderRow("From:", Modifier.clickable(enabled = model.identities.size > 1) { open = true }) {
        Text(current?.let { ComposeDraft.format(EmailAddress(it.name, it.email)) } ?: "Choose an address")
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            model.identities.forEach { identity ->
                DropdownMenuItem(text = { Text(ComposeDraft.format(EmailAddress(identity.name, identity.email))) }, onClick = {
                    draft.identityId = identity.id
                    open = false
                })
            }
        }
    }
}

@Composable
private fun AttachmentChip(context: Context, file: ComposeDraft.PendingAttachment, onRemove: () -> Unit) {
    Row(
        Modifier.clip(RoundedCornerShape(50)).background(MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f))
            .padding(start = 12.dp, end = 4.dp, top = 2.dp, bottom = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        when {
            file.isUploading -> CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
            file.failure != null -> Icon(Icons.Outlined.ErrorOutline, file.failure, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.error)
            else -> Icon(Icons.Outlined.AttachFile, null, Modifier.size(16.dp))
        }
        Spacer(Modifier.width(6.dp))
        OneLine(file.name, Modifier.widthIn(max = 180.dp), MaterialTheme.typography.labelLarge)
        Spacer(Modifier.width(6.dp))
        Text(file.failure ?: Formatter.formatShortFileSize(context, file.size.toLong()), style = MaterialTheme.typography.labelMedium,
            color = if (file.failure != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
        IconButton(onClick = onRemove, Modifier.size(32.dp)) { Icon(Icons.Outlined.Close, "Remove ${file.name}", Modifier.size(16.dp)) }
    }
}

/** Name, MIME type and bytes of a picked file. HEIC photos are sent as JPEG, which every mail app can show. */
private fun readAttachment(context: Context, uri: Uri): Triple<String, String, ByteArray>? = runCatching {
    val resolver = context.contentResolver
    var name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
        if (cursor.moveToFirst()) cursor.getString(0) else null
    } ?: uri.lastPathSegment ?: "Attachment"
    var type = resolver.getType(uri) ?: "application/octet-stream"
    var data = resolver.openInputStream(uri)?.use { it.readBytes() } ?: return null
    if (type == "image/heic" || type == "image/heif") {
        val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(data))
        data = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it) }.toByteArray()
        type = "image/jpeg"
        name = name.substringBeforeLast('.') + ".jpg"
    }
    Triple(name, type, data)
}.getOrNull()
