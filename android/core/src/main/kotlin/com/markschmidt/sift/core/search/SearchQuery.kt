package com.markschmidt.sift.core.search

import com.markschmidt.sift.core.jmap.JsonValue
import com.markschmidt.sift.core.jmap.arr
import com.markschmidt.sift.core.jmap.obj
import com.markschmidt.sift.core.store.Keyword
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/**
 * A parsed search, Gmail-style:
 *
 *     invoice from:stripe -subject:"payment failed" has:attachment after:30d in:receipts
 *     from:alex OR from:sam climbing
 *
 * Clauses are ANDed; `OR` joins its neighbours into one alternative. The same
 * query runs against the local full-text index (instant, cached mail only)
 * and against Fastmail's server-side search (complete).
 */
class SearchQuery(val raw: String, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()) {
    enum class Field(val raw: String) { TEXT("text"), FROM("from"), TO("to"), CC("cc"), SUBJECT("subject"), BODY("body") }

    sealed interface Term {
        data class Match(val field: Field, val value: String) : Term
        /** Any of the clauses (`a OR b OR c`). */
        data class AnyOf(val clauses: List<Clause>) : Term
        data class InMailbox(val name: String) : Term
        data object HasAttachment : Term
        data object Unread : Term
        data object Flagged : Term
        data class Before(val date: Instant) : Term
        data class After(val date: Instant) : Term
    }

    data class Clause(val term: Term, val negated: Boolean = false)

    val clauses: List<Clause>

    val isEmpty: Boolean get() = clauses.isEmpty()

    /** Words worth highlighting in results. */
    val highlightTerms: List<String>
        get() {
            fun terms(clauses: List<Clause>): List<String> = clauses.flatMap { clause ->
                if (clause.negated) return@flatMap emptyList()
                when (val term = clause.term) {
                    is Term.Match -> listOf(term.value)
                    is Term.AnyOf -> terms(term.clauses)
                    else -> emptyList()
                }
            }
            return terms(clauses)
        }

    init {
        val parsed = mutableListOf<Clause>()
        var joinNext = false
        for (token in tokenize(raw)) {
            if (token.key == null && !token.quoted && !token.negated && token.value == "OR") {
                joinNext = parsed.isNotEmpty()
                continue
            }
            val clause = clause(token, now, zone) ?: continue
            if (joinNext && parsed.isNotEmpty()) {
                val previous = parsed.removeAt(parsed.lastIndex)
                val term = previous.term
                parsed += if (term is Term.AnyOf && !previous.negated) {
                    Clause(Term.AnyOf(term.clauses + clause))
                } else {
                    Clause(Term.AnyOf(listOf(previous, clause)))
                }
            } else {
                parsed += clause
            }
            joinNext = false
        }
        clauses = parsed
    }

    override fun equals(other: Any?) = other is SearchQuery && other.raw == raw && other.clauses == clauses
    override fun hashCode() = raw.hashCode()

    // MARK: - Server (JMAP) filter

    fun jmapFilter(mailboxIdsByName: Map<String, String>): JsonValue? =
        combine(clauses.mapNotNull { jmapCondition(it, mailboxIdsByName) }, "AND")

    // MARK: - Local (SQLite FTS5) query

    /** The SQL and arguments for a local search, or null when nothing can match locally. */
    fun localSql(limit: Int, mailboxIdsByName: Map<String, String>): Pair<String, List<Any?>>? {
        val arguments = mutableListOf<Any?>()
        val conditions = clauses.mapNotNull { sqlCondition(it, mailboxIdsByName, arguments) }
        if (conditions.isEmpty()) return null
        arguments += limit
        val sql = """
            SELECT message.* FROM message
            WHERE ${conditions.joinToString(" AND ")}
            ORDER BY message.receivedAt DESC
            LIMIT ?
        """.trimIndent()
        return sql to arguments
    }

    data class Token(val negated: Boolean, val key: String?, val value: String, val quoted: Boolean)

    companion object {
        fun tokenize(input: String): List<Token> {
            val tokens = mutableListOf<Token>()
            var index = 0
            while (index < input.length) {
                while (index < input.length && input[index].isWhitespace()) index++
                if (index >= input.length) break

                var negated = false
                if (input[index] == '-') {
                    negated = true
                    index++
                }
                var key: String? = null
                val value = StringBuilder()
                var quoted = false
                while (index < input.length && !input[index].isWhitespace()) {
                    val char = input[index]
                    if (char == '"') {
                        quoted = true
                        index++
                        while (index < input.length && input[index] != '"') {
                            value.append(input[index])
                            index++
                        }
                        if (index < input.length) index++
                        continue
                    }
                    if (char == ':' && key == null && !quoted && value.isNotEmpty()) {
                        key = value.toString().lowercase()
                        value.clear()
                    } else {
                        value.append(char)
                    }
                    index++
                }
                if (value.isEmpty() && key == null) continue
                tokens += Token(negated, key, value.toString(), quoted)
            }
            return tokens
        }

        fun clause(token: Token, now: Instant, zone: ZoneId): Clause? {
            val value = token.value
            val lower = value.lowercase()
            val term: Term? = when (token.key) {
                null -> if (value.isEmpty()) null else Term.Match(Field.TEXT, value)
                "from" -> Term.Match(Field.FROM, value)
                "to" -> Term.Match(Field.TO, value)
                "cc" -> Term.Match(Field.CC, value)
                "subject" -> Term.Match(Field.SUBJECT, value)
                "body" -> Term.Match(Field.BODY, value)
                "in", "label", "folder" -> Term.InMailbox(value)
                "has" -> if (lower.startsWith("attach")) Term.HasAttachment else null
                "is" -> when (lower) {
                    "unread" -> Term.Unread
                    "read" -> return Clause(Term.Unread, negated = !token.negated)
                    "flagged", "starred", "pinned" -> Term.Flagged
                    else -> null
                }
                "before", "older_than", "older" -> parseDate(value, now, zone)?.let { Term.Before(it) }
                "after", "newer_than", "newer", "since" -> parseDate(value, now, zone)?.let { Term.After(it) }
                // Unknown key ("re:", a URL, a time like 10:30): search it literally.
                else -> Term.Match(Field.TEXT, "${token.key}:$value")
            }
            return term?.let { Clause(it, token.negated) }
        }

        /** Absolute dates (`2026-03-01`, `2026/03/01`) or relative ages (`7d`, `2w`, `3m`, `1y`). */
        fun parseDate(value: String, now: Instant, zone: ZoneId): Instant? {
            val lower = value.lowercase()
            val amount = lower.dropLast(1).toIntOrNull()
            if (lower.isNotEmpty() && amount != null) {
                val start = now.atZone(zone)
                val date = when (lower.last()) {
                    'd' -> start.minusDays(amount.toLong())
                    'w' -> start.minusWeeks(amount.toLong())
                    'm' -> start.minusMonths(amount.toLong())
                    'y' -> start.minusYears(amount.toLong())
                    else -> null
                }
                if (date != null) return date.toInstant()
            }
            val parts = lower.split('-', '/').mapNotNull { it.toIntOrNull() }
            if (parts.size != 3) return null
            return runCatching { LocalDate.of(parts[0], parts[1], parts[2]).atStartOfDay(zone).toInstant() }.getOrNull()
        }

        internal fun combine(conditions: List<JsonValue>, op: String): JsonValue? = when (conditions.size) {
            0 -> null
            1 -> conditions[0]
            else -> obj("operator" to op, "conditions" to conditions)
        }

        internal fun jmapCondition(clause: Clause, mailboxIdsByName: Map<String, String>): JsonValue? {
            val condition: JsonValue = when (val term = clause.term) {
                is Term.Match -> obj(term.field.raw to term.value)
                is Term.AnyOf -> combine(term.clauses.mapNotNull { jmapCondition(it, mailboxIdsByName) }, "OR") ?: return null
                is Term.InMailbox -> obj("inMailbox" to (mailboxIdsByName[term.name.lowercase()] ?: return null))
                Term.HasAttachment -> obj("hasAttachment" to true)
                // Negated unread is simply "read"; no NOT operator needed.
                Term.Unread -> return obj((if (clause.negated) "hasKeyword" else "notKeyword") to Keyword.SEEN)
                Term.Flagged -> return obj((if (clause.negated) "notKeyword" else "hasKeyword") to Keyword.FLAGGED)
                is Term.Before -> obj("before" to term.date)
                is Term.After -> obj("after" to term.date)
            }
            return if (clause.negated) obj("operator" to "NOT", "conditions" to arr(condition)) else condition
        }

        internal fun sqlCondition(clause: Clause, mailboxIdsByName: Map<String, String>, arguments: MutableList<Any?>): String? {
            val sql: String = when (val term = clause.term) {
                is Term.Match -> {
                    val match = ftsExpression(term.field, term.value) ?: return null
                    arguments += match
                    "message.rowid IN (SELECT rowid FROM messageFTS WHERE messageFTS MATCH ?)"
                }
                is Term.AnyOf -> {
                    val parts = term.clauses.mapNotNull { sqlCondition(it, mailboxIdsByName, arguments) }
                    if (parts.isEmpty()) return null
                    "(${parts.joinToString(" OR ")})"
                }
                is Term.InMailbox -> {
                    val id = mailboxIdsByName[term.name.lowercase()]
                    if (id != null) {
                        arguments += id
                        "EXISTS (SELECT 1 FROM messageMailbox mm WHERE mm.messageId = message.id AND mm.mailboxId = ?)"
                    } else {
                        "0"
                    }
                }
                Term.HasAttachment -> "message.hasAttachment"
                Term.Unread -> "message.isUnread"
                Term.Flagged -> "message.isFlagged"
                is Term.Before -> {
                    arguments += term.date.toEpochMilli()
                    "message.receivedAt < ?"
                }
                is Term.After -> {
                    arguments += term.date.toEpochMilli()
                    "message.receivedAt >= ?"
                }
            }
            return if (clause.negated) "NOT ($sql)" else sql
        }

        private val nonWord = Regex("[^\\p{L}\\p{M}\\p{N}]+")

        /**
         * An FTS5 expression where every word is a prefix match, so results
         * appear while the user is still typing.
         */
        fun ftsExpression(field: Field, value: String): String? {
            val words = value.split(nonWord).filter { it.isNotEmpty() }
            if (words.isEmpty()) return null
            val phrase = words.joinToString(" + ") { "\"$it\"" } + " *"
            val column = when (field) {
                Field.TEXT -> null
                Field.FROM -> "sender"
                Field.TO, Field.CC -> "recipients"
                Field.SUBJECT -> "subject"
                Field.BODY -> "body"
            }
            return column?.let { "$it : ($phrase)" } ?: "($phrase)"
        }
    }
}
