package com.markschmidt.sift.core.labels

/**
 * Icons for labels: a catalog to choose from, a guess from the label's name
 * until you choose, and the contact-group note that syncs your choice.
 *
 * Icons are named with Apple's SF Symbol names, because that's what the
 * iPhone and Mac apps store in Fastmail ("Sift icon: airplane"). Android maps
 * each name to a Material icon when drawing it.
 */
object LabelIcon {
    data class Category(val title: String, val symbols: List<String>)

    const val FALLBACK = "tag"

    val catalog: List<Category> = listOf(
        Category("General", listOf(
            "tag", "folder", "tray.full", "archivebox", "star", "heart", "bookmark", "flag",
            "pin", "bell", "lightbulb", "sparkles", "bolt", "flame", "leaf", "drop",
        )),
        Category("Money & Shopping", listOf(
            "receipt", "cart", "bag", "creditcard", "banknote", "dollarsign.circle", "building.columns",
            "chart.line.uptrend.xyaxis", "percent", "giftcard", "gift", "storefront", "shippingbox",
        )),
        Category("Work & School", listOf(
            "briefcase", "building.2", "doc.text", "newspaper", "book", "graduationcap", "pencil",
            "hammer", "wrench.and.screwdriver", "laptopcomputer", "chart.bar", "calendar", "clock",
            "server.rack", "megaphone", "chevron.left.forwardslash.chevron.right",
        )),
        Category("Travel & Places", listOf(
            "airplane", "car", "tram", "bus", "ferry", "bicycle", "suitcase", "map",
            "mappin.and.ellipse", "globe.americas", "house", "bed.double", "tent",
        )),
        Category("People & Fun", listOf(
            "person", "person.2", "figure.2.and.child.holdinghands", "figure.and.child.holdinghands",
            "bubble.left.and.bubble.right", "pawprint", "gamecontroller", "music.note", "film", "tv",
            "camera", "photo", "ticket", "theatermasks", "trophy", "sportscourt", "figure.run", "dumbbell",
        )),
        Category("Health & Home", listOf(
            "cross.case", "pills", "stethoscope", "heart.text.square", "fork.knife", "cup.and.saucer",
            "wineglass", "birthday.cake", "wifi", "phone", "envelope", "paperplane", "lock", "key",
            "shield", "checkmark.seal", "exclamationmark.triangle", "gearshape", "cloud",
        )),
    )

    /** A starting icon from the label's name, so labels don't all look alike before you pick. */
    fun suggested(name: String): String {
        // Match the starts of words, so "Education" isn't about cats.
        val words = name.lowercase().split(Regex("[^\\p{L}]+")).filter { it.isNotEmpty() }
        for ((keywords, symbol) in suggestions) {
            if (words.any { word -> keywords.any { word.startsWith(it) } }) return symbol
        }
        return FALLBACK
    }

    private val suggestions: List<Pair<List<String>, String>> = listOf(
        listOf("receipt", "order", "purchase", "invoice", "paper") to "receipt",
        listOf("bill", "utilit") to "bolt",
        listOf("bank", "financ", "money", "tax", "invest", "credit") to "building.columns",
        listOf("shipping", "package", "deliver") to "shippingbox",
        listOf("shop", "store", "deal") to "bag",
        listOf("promo", "marketing", "offer", "sale") to "megaphone",
        listOf("newsletter", "news", "digest", "reading", "blog", "feed") to "newspaper",
        listOf("github", "gitlab", "code", "dev", "engineering") to "chevron.left.forwardslash.chevron.right",
        listOf("travel", "trip", "flight", "vacation", "holiday") to "airplane",
        listOf("family", "kid", "parent") to "figure.2.and.child.holdinghands",
        listOf("friend", "personal") to "person.2",
        listOf("work", "job", "career", "business") to "briefcase",
        listOf("school", "class", "college", "universit", "course", "educat") to "graduationcap",
        listOf("health", "medical", "doctor", "dental", "insurance") to "cross.case",
        listOf("home", "house", "rent", "mortgage") to "house",
        listOf("car", "auto", "vehicle") to "car",
        listOf("social", "community", "forum") to "bubble.left.and.bubble.right",
        listOf("notification", "alert", "update") to "bell",
        listOf("ticket", "event", "concert") to "ticket",
        listOf("pet", "dog", "cat", "vet") to "pawprint",
        listOf("music") to "music.note",
        listOf("game") to "gamecontroller",
        listOf("fitness", "gym", "run", "sport") to "figure.run",
        listOf("food", "recipe", "restaurant", "cooking") to "fork.knife",
        listOf("security", "account", "login", "password") to "lock",
        listOf("subscription", "membership") to "checkmark.seal",
        listOf("import", "archive", "old", "storage", "keep") to "archivebox",
    )

    // MARK: - Contact-group note

    const val NOTE_PREFIX = "Sift icon: "

    fun note(symbol: String) = NOTE_PREFIX + symbol

    fun parse(note: String): String? {
        val trimmed = note.trim()
        if (!trimmed.startsWith(NOTE_PREFIX)) return null
        return trimmed.removePrefix(NOTE_PREFIX).trim().ifEmpty { null }
    }
}
