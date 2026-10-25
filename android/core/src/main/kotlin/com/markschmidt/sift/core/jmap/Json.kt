package com.markschmidt.sift.core.jmap

import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

/** The JSON configuration every JMAP call and cached column goes through. */
val SiftJson = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    encodeDefaults = true
    coerceInputValues = true
}

/** A loosely typed JSON value, used to build JMAP method arguments (`JSONValue` in SiftKit). */
typealias JsonValue = JsonElement

/** Builds a JSON object from Kotlin values: strings, numbers, booleans, null, lists, maps or JSON. */
fun obj(vararg pairs: Pair<String, Any?>): JsonObject = JsonObject(pairs.associate { it.first to it.second.toJson() })

fun arr(vararg items: Any?): JsonArray = JsonArray(items.map { it.toJson() })

fun strings(values: Iterable<String>): JsonArray = JsonArray(values.map { JsonPrimitive(it) })

fun Any?.toJson(): JsonElement = when (this) {
    null -> JsonNull
    is JsonElement -> this
    is String -> JsonPrimitive(this)
    is Boolean -> JsonPrimitive(this)
    is Number -> JsonPrimitive(this)
    is Instant -> JsonPrimitive(JmapDates.format(this))
    is Map<*, *> -> JsonObject(entries.associate { (k, v) -> k.toString() to v.toJson() })
    is Iterable<*> -> JsonArray(map { it.toJson() })
    is Array<*> -> JsonArray(map { it.toJson() })
    else -> error("Can't encode ${this::class} as JSON")
}

/** Plain Kotlin values (maps, lists, strings, numbers, booleans, null) from JSON. */
fun JsonElement.toAny(): Any? = when (this) {
    JsonNull -> null
    is JsonPrimitive -> if (isString) content else booleanOrNull ?: longOrNull?.let {
        if (it in Int.MIN_VALUE..Int.MAX_VALUE) it.toInt() else it
    } ?: doubleOrNull ?: content
    is JsonObject -> LinkedHashMap<String, Any?>().also { map -> forEach { (k, v) -> map[k] = v.toAny() } }
    is JsonArray -> map { it.toAny() }
}

operator fun JsonElement?.get(key: String): JsonElement? = (this as? JsonObject)?.get(key)

val JsonElement?.stringValue: String? get() = (this as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

/** RFC 3339 dates, with or without fractional seconds and with `Z` or an offset. */
object JmapDates {
    fun parse(text: String): Instant? =
        runCatching { Instant.parse(text) }.getOrNull()
            ?: runCatching { OffsetDateTime.parse(text, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant() }.getOrNull()

    /** `2026-10-16T12:00:00Z`: UTC, whole seconds, as Fastmail expects in filters. */
    fun format(instant: Instant): String = DateTimeFormatter.ISO_INSTANT.format(instant.truncatedTo(ChronoUnit.SECONDS))
}

object InstantSerializer : KSerializer<Instant> {
    override val descriptor = PrimitiveSerialDescriptor("JmapInstant", PrimitiveKind.STRING)
    override fun deserialize(decoder: Decoder): Instant {
        val text = decoder.decodeString()
        return JmapDates.parse(text) ?: throw IllegalArgumentException("Bad JMAP date: $text")
    }
    override fun serialize(encoder: Encoder, value: Instant) = encoder.encodeString(JmapDates.format(value))
}

/** "A", "A and B", "A, B, and C". */
fun List<String>.formattedList(): String = when (size) {
    0 -> ""
    1 -> this[0]
    2 -> "${this[0]} and ${this[1]}"
    else -> dropLast(1).joinToString(", ") + ", and " + last()
}
