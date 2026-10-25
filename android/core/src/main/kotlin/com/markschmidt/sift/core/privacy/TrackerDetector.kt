package com.markschmidt.sift.core.privacy

import com.markschmidt.sift.core.jmap.formattedList

data class DetectedTracker(val name: String, val url: String, val reason: Reason) {
    enum class Reason(val explanation: String) {
        KNOWN_SERVICE("known tracking service"),
        TINY_IMAGE("invisible 1×1 image"),
        HIDDEN_IMAGE("hidden image"),
        BEACON_PATH("tracking beacon URL"),
    }
}

data class SanitizedMessage(
    val html: String,
    val trackers: List<DetectedTracker>,
    /** Remote images left in the message (not trackers). */
    val remoteImageCount: Int,
) {
    /** "Mailchimp", "HubSpot and Litmus", … */
    val trackerSummary: String?
        get() = trackers.map { it.name }.distinct().takeIf { it.isNotEmpty() }?.formattedList()
}

/** The parts of a URL the tracker rules look at, kept percent-encoded as written. */
data class UrlParts(val host: String, val path: String, val query: String?) {
    val pathAndQuery: String get() = path + (query?.let { "?$it" } ?: "")

    companion object {
        /** Parses `https://host/path?query` and protocol-relative `//host/path`. */
        fun parse(raw: String): UrlParts? {
            val text = raw.trim()
            val rest = when {
                text.startsWith("//") -> text.drop(2)
                text.contains("://") -> text.substringAfter("://")
                else -> return null
            }
            val authorityEnd = rest.indexOfFirst { it == '/' || it == '?' || it == '#' }.let { if (it < 0) rest.length else it }
            val authority = rest.substring(0, authorityEnd).substringAfterLast('@')
            val host = (if (authority.startsWith("[")) authority.substringBefore("]") + "]" else authority.substringBefore(':')).lowercase()
            if (host.isEmpty() || host.any { it.isWhitespace() }) return null
            val remainder = rest.substring(authorityEnd).substringBefore('#')
            val path = remainder.substringBefore('?')
            val query = if (remainder.contains('?')) remainder.substringAfter('?') else null
            return UrlParts(host, path, query)
        }
    }
}

/**
 * Finds and removes spy pixels, HEY-style: known services first, then generic
 * heuristics (tiny, hidden, or beacon-shaped images). Also strips active and
 * remote-loading content that has no business in an email.
 */
object TrackerDetector {
    private val imgTag = Regex("(?is)<img\\b[^>]*>")
    private val attribute = Regex("(?is)([a-z_:][-a-z0-9_:.]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))")
    private val pairedDangerous = Regex("(?is)<(script|iframe|object|embed|frameset|applet)\\b.*?</\\1\\s*>")
    private val loneDangerous = Regex("(?is)<(script|iframe|object|embed|link|base|meta\\s+http-equiv)\\b[^>]*>")

    fun sanitize(html: String): SanitizedMessage {
        val trackers = mutableListOf<DetectedTracker>()
        var remoteImages = 0

        var output = html.replace(pairedDangerous, "")
        output = output.replace(loneDangerous, "")
        output = imgTag.replace(output) { match ->
            val tag = match.value
            val verdict = inspect(tag)
            if (verdict == null) {
                if (isRemote(attributes(tag)["src"])) remoteImages += 1
                tag
            } else {
                trackers += verdict
                ""
            }
        }
        return SanitizedMessage(output, trackers, remoteImages)
    }

    /** A tracker verdict for one `<img>` tag, or null if it looks legitimate. */
    fun inspect(tag: String): DetectedTracker? {
        val attrs = attributes(tag)
        val src = attrs["src"] ?: return null
        if (!isRemote(src)) return null
        val url = UrlParts.parse(src) ?: return null
        TrackerList.match(url)?.let { return DetectedTracker(it.name, src, DetectedTracker.Reason.KNOWN_SERVICE) }

        val style = (attrs["style"] ?: "").lowercase().replace(" ", "")
        val width = dimension(attrs["width"]) ?: styleDimension("width", style)
        val height = dimension(attrs["height"]) ?: styleDimension("height", style)
        val name = companyName(url.host)

        val isTiny = when {
            width != null && height != null -> width <= 2 && height <= 2
            width != null -> width <= 1
            height != null -> height <= 1
            else -> false
        }
        if (isTiny) return DetectedTracker(name, src, DetectedTracker.Reason.TINY_IMAGE)

        val hidden = listOf("display:none", "visibility:hidden", "opacity:0;", "max-height:0", "max-width:0")
            .any { style.contains(it) } || style.endsWith("opacity:0")
        if (hidden) return DetectedTracker(name, src, DetectedTracker.Reason.HIDDEN_IMAGE)

        val path = url.path.lowercase() + (url.query?.let { "?" + it.lowercase() } ?: "")
        if (width == null && height == null && TrackerList.suspiciousPaths.any { path.contains(it) }) {
            return DetectedTracker(name, src, DetectedTracker.Reason.BEACON_PATH)
        }
        return null
    }

    fun attributes(tag: String): Map<String, String> {
        val result = mutableMapOf<String, String>()
        for (match in attribute.findAll(tag)) {
            val name = match.groupValues[1].lowercase()
            val value = match.groups[2]?.value ?: match.groups[3]?.value ?: match.groups[4]?.value ?: ""
            if (name !in result) result[name] = HtmlText.decodeEntities(value)
        }
        return result
    }

    fun isRemote(src: String?): Boolean {
        val value = src?.trim()?.lowercase() ?: return false
        return value.startsWith("http://") || value.startsWith("https://") || value.startsWith("//")
    }

    private fun dimension(value: String?): Double? {
        val text = value?.trim()?.lowercase() ?: return null
        if (text.endsWith("%")) return null
        return text.replace("px", "").toDoubleOrNull()
    }

    private fun styleDimension(property: String, style: String): Double? {
        // `style` is lowercased with spaces removed; look for "width:1px" but not "max-width".
        for (declaration in style.split(";")) {
            val parts = declaration.split(":", limit = 2)
            if (parts.size != 2 || parts[0] != property) continue
            return dimension(parts[1])
        }
        return null
    }

    /**
     * "email.news.acme.co.uk" → "acme.co.uk"; a readable stand-in when the
     * tracking service isn't one we know by name.
     */
    fun companyName(host: String): String {
        if (host.isEmpty()) return "Unknown tracker"
        val labels = host.lowercase().split(".")
        if (labels.size <= 2) return host.lowercase()
        val secondLevel = listOf("co", "com", "org", "net", "ac", "gov")
        val keep = if (labels[labels.size - 2] in secondLevel) 3 else 2
        return labels.takeLast(keep).joinToString(".")
    }

    /**
     * Whether the reader should refuse to load [url] at the network layer
     * (Android's stand-in for WebKit's content blocker): known trackers
     * always, and every remote load when remote images are off.
     */
    fun shouldBlock(url: String, allowRemote: Boolean): Boolean {
        val lower = url.trim().lowercase()
        val isRemote = lower.startsWith("http://") || lower.startsWith("https://")
        if (!isRemote) return false
        if (!allowRemote) return true
        val parts = UrlParts.parse(url) ?: return true
        return TrackerList.match(parts) != null
    }
}
