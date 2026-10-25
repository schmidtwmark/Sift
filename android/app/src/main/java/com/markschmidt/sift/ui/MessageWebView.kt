package com.markschmidt.sift.ui

import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Build
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import com.markschmidt.sift.AppModel
import com.markschmidt.sift.ComposeRequest
import com.markschmidt.sift.core.compose.MailtoLink
import com.markschmidt.sift.core.privacy.HtmlText
import com.markschmidt.sift.core.privacy.SanitizedMessage
import com.markschmidt.sift.core.privacy.TrackerDetector
import com.markschmidt.sift.core.store.BodyRecord
import com.markschmidt.sift.core.sync.BodyAssembler
import kotlinx.coroutines.runBlocking
import java.io.ByteArrayInputStream

/**
 * Builds the document a message is rendered from: trackers removed, active
 * content stripped, and a color treatment for dark mode.
 */
object MessageHtml {
    /** How a message's colors are handled. */
    enum class Style {
        /** Plain text or simple HTML: system text colors, light or dark. */
        SYSTEM,
        /** Designed HTML with its own dark-mode styles: left alone. */
        SELF_STYLED,
        /** Designed HTML built for white: recolored in dark mode by WebView's darkening. */
        RECOLORED,
    }

    data class Prepared(val sanitized: SanitizedMessage, val style: Style)

    /** Inline (`cid:`) images are served from this host, intercepted before any network. */
    const val BLOB_HOST = "sift-blob.invalid"

    fun prepare(body: BodyRecord): Prepared {
        val html = body.html
        if (html != null) {
            val sanitized = TrackerDetector.sanitize(html)
            val style = when {
                isSimple(sanitized.html) -> Style.SYSTEM
                hasOwnDarkMode(sanitized.html) -> Style.SELF_STYLED
                else -> Style.RECOLORED
            }
            // Android's WebView only intercepts http(s) subresources reliably, so
            // inline parts ride on a reserved .invalid host instead of sift-blob://.
            val rewritten = sanitized.html.replace("${BodyAssembler.BLOB_SCHEME}://blob/", "https://$BLOB_HOST/blob/")
            return Prepared(sanitized.copy(html = document(rewritten, style)), style)
        }
        return Prepared(SanitizedMessage(document(plainTextHtml(body.text ?: ""), Style.SYSTEM), emptyList(), 0), Style.SYSTEM)
    }

    /**
     * No layout tables, colors or embedded styles: the kind of HTML a person's
     * mail client sends, as opposed to a designed newsletter.
     */
    fun isSimple(html: String): Boolean {
        val lower = html.lowercase()
        return listOf("<table", "background", "bgcolor", "color:", "color=", "<style", "<img").none { lower.contains(it) }
    }

    /** Senders that ship dark-mode CSS know their design better than a recolor does. */
    fun hasOwnDarkMode(html: String): Boolean {
        val compact = html.lowercase().replace(" ", "")
        return compact.contains("prefers-color-scheme:dark") || compact.contains("supported-color-schemes") ||
            Regex("name=\"color-scheme\"content=\"[^\"]*dark").containsMatchIn(compact)
    }

    private val link = Regex("""(?i)\b(https?://[^\s<>"']+[^\s<>"'.,;:!?)\]])""")

    fun plainTextHtml(text: String): String {
        val lines = text.split("\n").map { line ->
            val escaped = HtmlText.escape(line).replace(link) { "<a href=\"${it.value}\">${it.value}</a>" }
            if (line.startsWith(">")) "<span class=\"quote\">$escaped</span>" else escaped
        }
        return "<div class=\"plain\">${lines.joinToString("\n")}</div>"
    }

    fun document(body: String, style: Style): String {
        val scheme = if (style == Style.RECOLORED) "light" else "light dark"
        val darkText = if (style == Style.SYSTEM) {
            "@media (prefers-color-scheme: dark) { body { color: #f2f2f7; } a { color: #6ac4cf; } blockquote { color: #aeaeb2; border-color: #48484a; } }"
        } else ""
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="color-scheme" content="$scheme">
            <style>
            html, body { margin: 0; padding: 0; background: transparent; }
            body { font-family: system-ui, sans-serif; font-size: 16px; line-height: 1.45; overflow-wrap: anywhere; }
            body > p:first-child { margin-top: 0; }
            body > p:last-child { margin-bottom: 0; }
            img { max-width: 100%; height: auto; }
            table { max-width: 100%; }
            blockquote { margin: 0 0 0 .4em; padding-left: .8em; border-left: 3px solid #c7c7cc; color: #6e6e73; }
            .plain { white-space: pre-wrap; }
            .quote { color: #8e8e93; }
            a { color: #1f6f7a; }
            $darkText
            </style></head><body>$body</body></html>
        """.trimIndent()
    }
}

/**
 * A message body sized to its content, so the reader around it does the
 * scrolling. JavaScript is off, known trackers are refused at the network
 * layer, remote loads are refused unless allowed, and links open outside.
 */
@Composable
fun MessageWebView(model: AppModel, prepared: MessageHtml.Prepared, allowRemote: Boolean, modifier: Modifier = Modifier) {
    val dark = isSystemInDarkTheme()
    val state = remember { LoadState() }
    AndroidView(
        modifier = modifier.fillMaxWidth(),
        factory = { context ->
            WebView(context).apply {
                layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                setBackgroundColor(android.graphics.Color.TRANSPARENT)
                isVerticalScrollBarEnabled = false
                isHorizontalScrollBarEnabled = false
                overScrollMode = WebView.OVER_SCROLL_NEVER
                with(settings) {
                    javaScriptEnabled = false
                    javaScriptCanOpenWindowsAutomatically = false
                    domStorageEnabled = false
                    allowFileAccess = false
                    allowContentAccess = false
                    setGeolocationEnabled(false)
                    loadWithOverviewMode = true
                    useWideViewPort = true
                    setSupportZoom(false)
                    textZoom = 100
                    cacheMode = WebSettings.LOAD_NO_CACHE
                    setSupportMultipleWindows(false)
                }
                CookieManager.getInstance().setAcceptThirdPartyCookies(this, false)
                webViewClient = MessageClient(model, state)
            }
        },
        update = { webView ->
            val key = "${prepared.sanitized.html.hashCode()}|$allowRemote|$dark"
            if (state.loadedKey == key) return@AndroidView
            state.loadedKey = key
            state.allowRemote = allowRemote
            // Light-designed mail is darkened by WebView itself in dark mode; mail
            // with its own dark styles (or none at all) is left to them.
            val darken = prepared.style == MessageHtml.Style.RECOLORED
            if (Build.VERSION.SDK_INT >= 33) {
                webView.settings.isAlgorithmicDarkeningAllowed = darken
            } else {
                @Suppress("DEPRECATION")
                webView.settings.forceDark = if (dark && darken) WebSettings.FORCE_DARK_ON else WebSettings.FORCE_DARK_OFF
            }
            webView.loadDataWithBaseURL("about:blank", prepared.sanitized.html, "text/html", "utf-8", null)
        },
    )
}

private class LoadState {
    var loadedKey: String? = null
    @Volatile var allowRemote = false
}

private class MessageClient(private val model: AppModel, private val state: LoadState) : WebViewClient() {
    private val blocked get() = WebResourceResponse("text/plain", "utf-8", 403, "Blocked", emptyMap(), ByteArrayInputStream(ByteArray(0)))

    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
        val url = request.url
        if (url.host == MessageHtml.BLOB_HOST) {
            val blobId = url.pathSegments.getOrNull(1) ?: return blocked
            val type = url.getQueryParameter("type") ?: "application/octet-stream"
            val name = url.getQueryParameter("name") ?: "inline"
            val data = runCatching { runBlocking { model.download(blobId, name, type) } }.getOrNull() ?: return blocked
            return WebResourceResponse(type, null, ByteArrayInputStream(data))
        }
        if (TrackerDetector.shouldBlock(url.toString(), state.allowRemote)) return blocked
        return null
    }

    /** The message itself is the only page this view ever shows; links open outside. */
    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
        val url = request.url
        when (url.scheme?.lowercase()) {
            "mailto" -> MailtoLink.parse(url.toString())?.let { model.composeToOpen = ComposeRequest(mailto = it) }
            "http", "https", "tel" -> try {
                view.context.startActivity(Intent(Intent.ACTION_VIEW, url).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            } catch (_: ActivityNotFoundException) {
            }
        }
        return true
    }
}
