package com.markschmidt.sift.core.store

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.SQLiteStatement
import androidx.sqlite.execSQL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * One SQLite connection, used by one coroutine at a time. Every write bumps
 * [version], which is what observed queries re-run on (GRDB's
 * ValueObservation, simplified: any write invalidates every query).
 */
class Database(private val connection: SQLiteConnection) {
    private val lock = Mutex()
    private val version = MutableStateFlow(0L)

    suspend fun <T> read(block: Scope.() -> T): T = lock.withLock {
        withContext(Dispatchers.IO) { Scope(connection).block() }
    }

    suspend fun <T> write(block: Scope.() -> T): T {
        val result = lock.withLock {
            withContext(Dispatchers.IO) {
                connection.execSQL("BEGIN IMMEDIATE")
                try {
                    Scope(connection).block().also { connection.execSQL("COMMIT") }
                } catch (error: Throwable) {
                    runCatching { connection.execSQL("ROLLBACK") }
                    throw error
                }
            }
        }
        version.value += 1
        return result
    }

    /** Emits the query's current value, then again whenever a write changes it. */
    @OptIn(ExperimentalCoroutinesApi::class)
    fun <T> observe(query: Scope.() -> T): Flow<T> =
        version.mapLatest { read(query) }.distinctUntilChanged().flowOn(Dispatchers.IO)

    fun close() = connection.close()

    class Scope(private val connection: SQLiteConnection) {
        fun execute(sql: String, vararg arguments: Any?) {
            connection.prepare(sql).use { statement ->
                statement.bindAll(arguments.toList())
                while (statement.step()) { /* drain */ }
            }
        }

        fun <T> query(sql: String, arguments: List<Any?> = emptyList(), map: (Row) -> T): List<T> =
            connection.prepare(sql).use { statement ->
                statement.bindAll(arguments)
                val row = Row(statement)
                buildList { while (statement.step()) add(map(row)) }
            }

        fun <T> query(sql: String, vararg arguments: Any?, map: (Row) -> T): List<T> = query(sql, arguments.toList(), map)

        fun <T> queryOne(sql: String, vararg arguments: Any?, map: (Row) -> T): T? =
            query(sql, arguments.toList(), map).firstOrNull()

        fun string(sql: String, vararg arguments: Any?): String? = queryOne(sql, *arguments) { it.stringOrNull(0) }
        fun long(sql: String, vararg arguments: Any?): Long? = queryOne(sql, *arguments) { if (it.isNull(0)) null else it.long(0) }
        fun strings(sql: String, vararg arguments: Any?): List<String> = query(sql, *arguments) { it.string(0) }

        private fun SQLiteStatement.bindAll(arguments: List<Any?>) {
            arguments.forEachIndexed { index, value ->
                val position = index + 1
                when (value) {
                    null -> bindNull(position)
                    is String -> bindText(position, value)
                    is Boolean -> bindLong(position, if (value) 1 else 0)
                    is Int -> bindLong(position, value.toLong())
                    is Long -> bindLong(position, value)
                    is Double -> bindDouble(position, value)
                    is ByteArray -> bindBlob(position, value)
                    else -> error("Can't bind ${value::class}")
                }
            }
        }
    }

    /** The current row of a statement, readable by column name or index. */
    class Row(private val statement: SQLiteStatement) {
        private val columns: Map<String, Int> by lazy {
            (0 until statement.getColumnCount()).associateBy { statement.getColumnName(it) }
        }

        private fun index(name: String) = columns[name] ?: error("No column $name")

        fun isNull(index: Int) = statement.isNull(index)
        fun string(index: Int): String = statement.getText(index)
        fun stringOrNull(index: Int): String? = if (statement.isNull(index)) null else statement.getText(index)
        fun long(index: Int): Long = statement.getLong(index)

        fun string(name: String): String = string(index(name))
        fun stringOrNull(name: String): String? = stringOrNull(index(name))
        fun long(name: String): Long = long(index(name))
        fun longOrNull(name: String): Long? = index(name).let { if (statement.isNull(it)) null else statement.getLong(it) }
        fun int(name: String): Int = long(name).toInt()
        fun bool(name: String): Boolean = long(name) != 0L
    }
}
