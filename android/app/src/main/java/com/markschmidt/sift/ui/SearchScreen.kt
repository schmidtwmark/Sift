package com.markschmidt.sift.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.SearchOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.markschmidt.sift.AppModel
import com.markschmidt.sift.core.jmap.SearchSnippet
import com.markschmidt.sift.core.privacy.HtmlText
import com.markschmidt.sift.core.search.SearchQuery
import com.markschmidt.sift.core.store.MailStore.Companion.localSearch
import com.markschmidt.sift.core.store.MessageRecord
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.emptyFlow

/**
 * Instant results from the local index, then complete results from
 * Fastmail's server-side search (which also covers bodies and attachments).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SearchScreen(model: AppModel, navigator: Navigator) {
    var text by rememberSaveable { mutableStateOf("") }
    val query = remember(text) { SearchQuery(text) }
    val store = model.store
    val local by remember(store, text) {
        if (store == null || query.isEmpty) emptyFlow() else store.observe { localSearch(query) }
    }.collectAsState(initial = emptyList())
    var server by remember { mutableStateOf<List<MessageRecord>>(emptyList()) }
    var snippets by remember { mutableStateOf<Map<String, SearchSnippet>>(emptyMap()) }
    var total by remember { mutableStateOf<Int?>(null) }
    var searching by remember { mutableStateOf(false) }
    var serverError by remember { mutableStateOf<String?>(null) }
    val focus = remember { FocusRequester() }

    LaunchedEffect(Unit) { focus.requestFocus() }
    LaunchedEffect(text) {
        server = emptyList(); snippets = emptyMap(); total = null; serverError = null
        if (query.isEmpty) return@LaunchedEffect
        // Debounce typing, then ask the server.
        delay(350)
        searching = true
        try {
            val result = model.search(query)
            server = result.messages
            snippets = result.snippets
            total = result.total
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            serverError = error.message ?: "Fastmail search failed"
        } finally {
            searching = false
        }
    }

    // Server order wins once it arrives; local hits fill in while waiting. One row per conversation.
    val results = remember(server, local) {
        val seen = mutableSetOf<String>()
        val threads = mutableSetOf<String>()
        (server + local).filter { seen.add(it.id) }.sortedByDescending { it.receivedAt }.filter { threads.add(it.threadId) }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                navigationIcon = { IconButton(onClick = navigator::pop) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") } },
                title = {
                    TextField(
                        text, { text = it }, Modifier.fillMaxWidth().focusRequester(focus),
                        placeholder = { Text("Search all mail") }, singleLine = true,
                        leadingIcon = { Icon(Icons.Outlined.Search, null) },
                        trailingIcon = { if (text.isNotEmpty()) IconButton(onClick = { text = "" }) { Icon(Icons.Outlined.Close, "Clear") } },
                        // Search operators (from:stripe) shouldn't be capitalized or autocorrected.
                        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, imeAction = ImeAction.Search),
                        colors = TextFieldDefaults.colors(
                            focusedContainerColor = Color.Transparent, unfocusedContainerColor = Color.Transparent,
                            focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent,
                        ),
                    )
                },
            )
        },
    ) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding)) {
            if (text.isEmpty() || text.endsWith(" ")) {
                items(operatorHints, key = { it.first }) { (token, description) ->
                    Row(Modifier.fillMaxWidth().clickable { text += token }.padding(horizontal = 20.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Outlined.Search, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        Spacer(Modifier.width(14.dp))
                        Text(token, fontFamily = FontFamily.Monospace)
                        Spacer(Modifier.width(12.dp))
                        Text(description, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            if (!query.isEmpty) {
                item {
                    Row(Modifier.padding(horizontal = 20.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                        val style = MaterialTheme.typography.labelMedium
                        val color = MaterialTheme.colorScheme.onSurfaceVariant
                        when {
                            searching -> {
                                CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
                                Spacer(Modifier.width(8.dp))
                                Text("Searching Fastmail…", style = style, color = color)
                            }
                            total != null -> Text("$total result${if (total == 1) "" else "s"}", style = style, color = color)
                            serverError != null -> OneLine("Showing cached mail only · $serverError", style = style, color = color)
                        }
                    }
                }
                if (results.isEmpty() && !searching) {
                    item { EmptyState("No Results", Icons.Outlined.SearchOff, "Nothing matches “$text”.") }
                }
                items(results, key = { it.id }) { message ->
                    SearchRow(message, snippets[message.id], query.highlightTerms) {
                        navigator.push(Screen.Thread(message.threadId, null))
                    }
                    HorizontalDivider(Modifier.padding(start = 20.dp), color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))
                }
            }
        }
    }
}

private val operatorHints = listOf(
    "from:" to "From a sender",
    "to:" to "Sent to",
    "subject:" to "In the subject",
    "has:attachment" to "Has attachments",
    "is:unread" to "Unread",
    "is:pinned" to "Pinned",
    "in:" to "In a label",
    "after:30d" to "In the last 30 days",
    "before:2026-01-01" to "Before a date",
    "OR " to "Either side matches",
)

@Composable
private fun SearchRow(message: MessageRecord, snippet: SearchSnippet?, terms: List<String>, onClick: () -> Unit) {
    val highlight = SpanStyle(fontWeight = FontWeight.Bold, background = Color(0x59FFD60A))
    Column(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 20.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row {
            OneLine(message.senderDisplayName, Modifier.weight(1f), MaterialTheme.typography.bodyLarge,
                weight = if (message.isUnread) FontWeight.SemiBold else FontWeight.Normal)
            Text(message.receivedAt.listLabel(), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text(highlighted(snippet?.subject, message.subject.ifEmpty { "(no subject)" }, terms, highlight), maxLines = 1,
            style = MaterialTheme.typography.bodyMedium, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
        Text(highlighted(snippet?.preview, message.preview, terms, highlight), maxLines = 2,
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
    }
}

/** Uses Fastmail's `<mark>` snippets when present, else highlights the search terms locally. */
fun highlighted(marked: String?, fallback: String, terms: List<String>, style: SpanStyle): AnnotatedString {
    if (marked != null && marked.contains("<mark>")) {
        return buildAnnotatedString {
            marked.split("<mark>").forEachIndexed { index, piece ->
                val parts = piece.split("</mark>")
                if (index > 0) {
                    withStyle(style) { append(HtmlText.decodeEntities(parts.first())) }
                    append(HtmlText.decodeEntities(parts.drop(1).joinToString("")))
                } else {
                    append(HtmlText.decodeEntities(piece))
                }
            }
        }
    }
    val text = marked?.let(HtmlText::decodeEntities) ?: fallback
    return buildAnnotatedString {
        append(text)
        for (term in terms.filter { it.isNotEmpty() }) {
            var start = text.indexOf(term, ignoreCase = true)
            while (start >= 0) {
                addStyle(style, start, start + term.length)
                start = text.indexOf(term, start + term.length, ignoreCase = true)
            }
        }
    }
}
