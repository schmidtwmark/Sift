import Foundation
import GRDB

/// A parsed search, Gmail-style:
///
///     invoice from:stripe -subject:"payment failed" has:attachment after:30d in:receipts
///     from:alex OR from:sam climbing
///
/// Clauses are ANDed; `OR` joins its neighbours into one alternative.
/// The same query runs against the local full-text index (instant, cached
/// mail only) and against Fastmail's server-side search (complete).
public struct SearchQuery: Sendable, Hashable {
    public enum Field: String, Sendable, Hashable, CaseIterable {
        case text, from, to, cc, subject, body
    }

    public indirect enum Term: Sendable, Hashable {
        case match(Field, String)
        /// Any of the clauses (`a OR b OR c`).
        case anyOf([Clause])
        case inMailbox(String)
        case hasAttachment
        case unread
        case flagged
        case before(Date)
        case after(Date)
    }

    public struct Clause: Sendable, Hashable {
        public var term: Term
        public var negated: Bool
    }

    public var clauses: [Clause]
    public let raw: String

    public var isEmpty: Bool { clauses.isEmpty }

    /// Words worth highlighting in results.
    public var highlightTerms: [String] {
        func terms(_ clauses: [Clause]) -> [String] {
            clauses.flatMap { clause -> [String] in
                guard !clause.negated else { return [] }
                switch clause.term {
                case .match(_, let value): return [value]
                case .anyOf(let nested): return terms(nested)
                default: return []
                }
            }
        }
        return terms(clauses)
    }

    public init(_ raw: String, now: Date = .now, calendar: Calendar = .current) {
        self.raw = raw
        var clauses: [Clause] = []
        var joinNext = false
        for token in Self.tokenize(raw) {
            if token.key == nil, !token.quoted, !token.negated, token.value == "OR" {
                joinNext = !clauses.isEmpty
                continue
            }
            guard let clause = Self.clause(for: token, now: now, calendar: calendar) else { continue }
            if joinNext, let previous = clauses.popLast() {
                if case .anyOf(let group) = previous.term, !previous.negated {
                    clauses.append(Clause(term: .anyOf(group + [clause]), negated: false))
                } else {
                    clauses.append(Clause(term: .anyOf([previous, clause]), negated: false))
                }
            } else {
                clauses.append(clause)
            }
            joinNext = false
        }
        self.clauses = clauses
    }

    // MARK: - Parsing

    struct Token: Equatable {
        var negated: Bool
        var key: String?
        var value: String
        var quoted: Bool
    }

    static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var index = input.startIndex
        while index < input.endIndex {
            while index < input.endIndex, input[index].isWhitespace { index = input.index(after: index) }
            guard index < input.endIndex else { break }

            var negated = false
            if input[index] == "-" {
                negated = true
                index = input.index(after: index)
            }
            var key: String?
            var value = ""
            var quoted = false
            while index < input.endIndex, !input[index].isWhitespace {
                let char = input[index]
                if char == "\"" {
                    quoted = true
                    index = input.index(after: index)
                    while index < input.endIndex, input[index] != "\"" {
                        value.append(input[index])
                        index = input.index(after: index)
                    }
                    if index < input.endIndex { index = input.index(after: index) }
                    continue
                }
                if char == ":", key == nil, !quoted, !value.isEmpty {
                    key = value.lowercased()
                    value = ""
                } else {
                    value.append(char)
                }
                index = input.index(after: index)
            }
            if value.isEmpty && key == nil { continue }
            tokens.append(Token(negated: negated, key: key, value: value, quoted: quoted))
        }
        return tokens
    }

    static func clause(for token: Token, now: Date, calendar: Calendar) -> Clause? {
        let value = token.value
        let lower = value.lowercased()
        let term: Term?
        switch token.key {
        case nil:
            term = value.isEmpty ? nil : .match(.text, value)
        case "from": term = .match(.from, value)
        case "to": term = .match(.to, value)
        case "cc": term = .match(.cc, value)
        case "subject": term = .match(.subject, value)
        case "body": term = .match(.body, value)
        case "in", "label", "folder": term = .inMailbox(value)
        case "has":
            term = lower.hasPrefix("attach") ? .hasAttachment : nil
        case "is":
            switch lower {
            case "unread": term = .unread
            case "read": return Clause(term: .unread, negated: !token.negated)
            case "flagged", "starred", "pinned": term = .flagged
            default: term = nil
            }
        case "before", "older_than", "older":
            term = parseDate(value, now: now, calendar: calendar).map(Term.before)
        case "after", "newer_than", "newer", "since":
            term = parseDate(value, now: now, calendar: calendar).map(Term.after)
        default:
            // Unknown key ("re:", a URL, a time like 10:30) — search it literally.
            term = .match(.text, "\(token.key ?? ""):\(value)")
        }
        return term.map { Clause(term: $0, negated: token.negated) }
    }

    /// Absolute dates (`2026-03-01`, `2026/03/01`) or relative ages (`7d`, `2w`, `3m`, `1y`).
    static func parseDate(_ value: String, now: Date, calendar: Calendar) -> Date? {
        let lower = value.lowercased()
        if let unit = lower.last, let amount = Int(lower.dropLast()) {
            let component: Calendar.Component? = switch unit {
            case "d": .day
            case "w": .weekOfYear
            case "m": .month
            case "y": .year
            default: nil
            }
            if let component { return calendar.date(byAdding: component, value: -amount, to: now) }
        }
        let parts = lower.split(whereSeparator: { $0 == "-" || $0 == "/" }).compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    // MARK: - Server (JMAP) filter

    public func jmapFilter(mailboxIdsByName: [String: String]) -> JSONValue? {
        Self.combine(clauses.compactMap { Self.jmapCondition($0, mailboxIdsByName: mailboxIdsByName) }, with: "AND")
    }

    static func combine(_ conditions: [JSONValue], with op: String) -> JSONValue? {
        switch conditions.count {
        case 0: nil
        case 1: conditions[0]
        default: ["operator": .string(op), "conditions": .array(conditions)]
        }
    }

    static func jmapCondition(_ clause: Clause, mailboxIdsByName: [String: String]) -> JSONValue? {
        let condition: JSONValue
        switch clause.term {
        case .match(let field, let value): condition = [field.rawValue: .string(value)]
        case .anyOf(let nested):
            guard let any = combine(nested.compactMap { jmapCondition($0, mailboxIdsByName: mailboxIdsByName) }, with: "OR") else {
                return nil
            }
            condition = any
        case .inMailbox(let name):
            guard let id = mailboxIdsByName[name.lowercased()] else { return nil }
            condition = ["inMailbox": .string(id)]
        case .hasAttachment: condition = ["hasAttachment": true]
        case .unread:
            // Negated unread is simply "read"; no NOT operator needed.
            return [clause.negated ? "hasKeyword" : "notKeyword": .string(Keyword.seen)]
        case .flagged:
            return [clause.negated ? "notKeyword" : "hasKeyword": .string(Keyword.flagged)]
        case .before(let date): condition = ["before": .string(JMAPCoding.formatUTCDate(date))]
        case .after(let date): condition = ["after": .string(JMAPCoding.formatUTCDate(date))]
        }
        return clause.negated ? ["operator": "NOT", "conditions": [condition]] : condition
    }

    // MARK: - Local (SQLite FTS5) query

    func localSQL(limit: Int, mailboxIdsByName: [String: String]) -> (String, StatementArguments)? {
        var arguments = StatementArguments()
        let conditions = clauses.compactMap { Self.sqlCondition($0, mailboxIdsByName: mailboxIdsByName, arguments: &arguments) }
        guard !conditions.isEmpty else { return nil }
        _ = arguments.append(contentsOf: [limit])
        let sql = """
            SELECT message.* FROM message
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY message.receivedAt DESC
            LIMIT ?
            """
        return (sql, arguments)
    }

    static func sqlCondition(_ clause: Clause, mailboxIdsByName: [String: String],
                             arguments: inout StatementArguments) -> String? {
        let sql: String
        switch clause.term {
        case .match(let field, let value):
            guard let match = ftsExpression(field: field, value: value) else { return nil }
            sql = "message.rowid IN (SELECT rowid FROM messageFTS WHERE messageFTS MATCH ?)"
            _ = arguments.append(contentsOf: [match])
        case .anyOf(let nested):
            let parts = nested.compactMap { sqlCondition($0, mailboxIdsByName: mailboxIdsByName, arguments: &arguments) }
            guard !parts.isEmpty else { return nil }
            sql = "(\(parts.joined(separator: " OR ")))"
        case .inMailbox(let name):
            if let id = mailboxIdsByName[name.lowercased()] {
                sql = "EXISTS (SELECT 1 FROM messageMailbox mm WHERE mm.messageId = message.id AND mm.mailboxId = ?)"
                _ = arguments.append(contentsOf: [id])
            } else {
                sql = "0"
            }
        case .hasAttachment: sql = "message.hasAttachment"
        case .unread: sql = "message.isUnread"
        case .flagged: sql = "message.isFlagged"
        case .before(let date):
            sql = "message.receivedAt < ?"
            _ = arguments.append(contentsOf: [date])
        case .after(let date):
            sql = "message.receivedAt >= ?"
            _ = arguments.append(contentsOf: [date])
        }
        return clause.negated ? "NOT (\(sql))" : sql
    }

    /// Builds an FTS5 expression where every word is a prefix match, so
    /// results appear while the user is still typing.
    static func ftsExpression(field: Field, value: String) -> String? {
        let words = value
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        let phrase = words.map { "\"\($0)\"" }.joined(separator: " + ") + " *"
        let column: String? = switch field {
        case .text: nil
        case .from: "sender"
        case .to, .cc: "recipients"
        case .subject: "subject"
        case .body: "body"
        }
        return column.map { "\($0) : (\(phrase))" } ?? "(\(phrase))"
    }
}
