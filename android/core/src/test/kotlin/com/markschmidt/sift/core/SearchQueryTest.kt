package com.markschmidt.sift.core

import com.markschmidt.sift.core.jmap.obj
import com.markschmidt.sift.core.search.SearchQuery
import com.markschmidt.sift.core.search.SearchQuery.Clause
import com.markschmidt.sift.core.search.SearchQuery.Field
import com.markschmidt.sift.core.search.SearchQuery.Term
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class SearchQueryTest {
    private val now = Instant.ofEpochSecond(2_000_000_000)
    private val utc = ZoneOffset.UTC

    @Test fun parsesOperatorsPhrasesAndNegation() {
        val query = SearchQuery("""invoice from:stripe -subject:"payment failed" has:attachment is:unread in:Receipts""", now, utc)
        assertEquals(
            listOf(
                Clause(Term.Match(Field.TEXT, "invoice")),
                Clause(Term.Match(Field.FROM, "stripe")),
                Clause(Term.Match(Field.SUBJECT, "payment failed"), negated = true),
                Clause(Term.HasAttachment),
                Clause(Term.Unread),
                Clause(Term.InMailbox("Receipts")),
            ),
            query.clauses,
        )
        assertEquals(listOf("invoice", "stripe"), query.highlightTerms)
    }

    @Test fun parsesRelativeAndAbsoluteDates() {
        val relative = SearchQuery("after:7d", now, utc)
        assertEquals(Term.After(now.minusSeconds(7 * 86_400)), relative.clauses.first().term)
        val absolute = SearchQuery("before:2026-03-01", now, utc)
        assertEquals(Term.Before(LocalDate.of(2026, 3, 1).atStartOfDay(utc).toInstant()), absolute.clauses.first().term)
        assertEquals(Term.Before(LocalDate.of(2026, 3, 1).atStartOfDay(utc).toInstant()), SearchQuery("before:2026/03/01", now, utc).clauses.first().term)
        assertEquals(Term.After(now.atZone(utc).minusWeeks(2).toInstant()), SearchQuery("after:2w", now, utc).clauses.first().term)
        assertEquals(Term.After(now.atZone(utc).minusMonths(3).toInstant()), SearchQuery("newer_than:3m", now, utc).clauses.first().term)
        assertEquals(Term.Before(now.atZone(utc).minusYears(1).toInstant()), SearchQuery("older:1y", now, utc).clauses.first().term)
        // Not a date: the clause is dropped rather than searched for.
        assertEquals(emptyList(), SearchQuery("before:soon", now, utc).clauses)
    }

    @Test fun orJoinsNeighbours() {
        val query = SearchQuery("climbing from:alex OR from:sam OR from:kim -is:unread")
        assertEquals(
            listOf(
                Clause(Term.Match(Field.TEXT, "climbing")),
                Clause(Term.AnyOf(listOf(
                    Clause(Term.Match(Field.FROM, "alex")),
                    Clause(Term.Match(Field.FROM, "sam")),
                    Clause(Term.Match(Field.FROM, "kim")),
                ))),
                Clause(Term.Unread, negated = true),
            ),
            query.clauses,
        )
        assertEquals(
            obj("operator" to "OR", "conditions" to listOf(obj("text" to "tacos"), obj("text" to "climbing"))),
            SearchQuery("tacos OR climbing").jmapFilter(emptyMap()),
        )
        // A lowercase "or" is just a word.
        assertEquals(3, SearchQuery("this or that").clauses.size)
    }

    @Test fun isReadIsNegatedUnread() {
        assertEquals(listOf(Clause(Term.Unread, negated = true)), SearchQuery("is:read").clauses)
        assertEquals(listOf(Clause(Term.Flagged)), SearchQuery("is:pinned").clauses)
    }

    @Test fun unknownKeysAreSearchedLiterally() {
        assertEquals(listOf(Clause(Term.Match(Field.TEXT, "re:lunch"))), SearchQuery("re:lunch").clauses)
    }

    @Test fun buildsJmapFilter() {
        val filter = SearchQuery("from:stripe -is:unread in:receipts").jmapFilter(mapOf("receipts" to "M1"))
        assertEquals(
            obj("operator" to "AND", "conditions" to listOf(
                obj("from" to "stripe"),
                obj("hasKeyword" to "\$seen"),
                obj("inMailbox" to "M1"),
            )),
            filter,
        )
        assertEquals(
            obj("operator" to "NOT", "conditions" to listOf(obj("subject" to "payment failed"))),
            SearchQuery("-subject:\"payment failed\"").jmapFilter(emptyMap()),
        )
        // Dates go to Fastmail as UTC, to the second.
        assertEquals(obj("after" to "2033-05-18T03:33:20Z"), SearchQuery("after:0d", now, utc).jmapFilter(emptyMap()))
        // An unknown label can't narrow the server search.
        assertNull(SearchQuery("in:nowhere").jmapFilter(emptyMap()))
    }

    @Test fun ftsExpressionsArePrefixPhrases() {
        assertEquals("""sender : ("john" + "smith" *)""", SearchQuery.ftsExpression(Field.FROM, "john.smith@"))
        assertEquals("""("café" *)""", SearchQuery.ftsExpression(Field.TEXT, "café"))
        assertNull(SearchQuery.ftsExpression(Field.TEXT, "!!!"))
    }
}
