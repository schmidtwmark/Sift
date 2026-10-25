package com.markschmidt.sift

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * The Fastmail API token, encrypted with a key held in the Android Keystore.
 * (The Apple apps keep it in iCloud Keychain.)
 */
class TokenStore(context: Context) {
    private val prefs: SharedPreferences by lazy {
        val key = MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
        EncryptedSharedPreferences.create(
            context, "sift.secure", key,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    var token: String?
        get() = runCatching { prefs.getString(KEY, null) }.getOrNull()
        set(value) {
            prefs.edit().apply { if (value == null) remove(KEY) else putString(KEY, value) }.apply()
        }

    private companion object {
        const val KEY = "fastmail.apiToken"
    }
}

/** Ordinary settings: Undo Send delay and remote images. */
class Preferences(context: Context) {
    private val prefs = context.getSharedPreferences("sift.settings", Context.MODE_PRIVATE)

    /** Seconds a sent message waits so it can be undone; 0 turns Undo Send off. */
    var undoSendDelay: Int
        get() = prefs.getInt("undoSendDelay", 10)
        set(value) = prefs.edit().putInt("undoSendDelay", value).apply()

    var loadRemoteImages: Boolean
        get() = prefs.getBoolean("loadRemoteImages", true)
        set(value) = prefs.edit().putBoolean("loadRemoteImages", value).apply()
}
