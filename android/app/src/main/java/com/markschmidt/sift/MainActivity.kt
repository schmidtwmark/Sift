package com.markschmidt.sift

import android.content.Intent
import android.content.res.Configuration
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.markschmidt.sift.core.compose.MailtoLink
import com.markschmidt.sift.ui.SiftRoot
import com.markschmidt.sift.ui.SiftTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // `adb shell am start -n com.markschmidt.sift/.MainActivity --ez demo true`
        // is the counterpart of launching the Apple apps with `-demo`.
        model.launch(demo = intent.getBooleanExtra("demo", false))
        handle(intent)
        setContent {
            SiftTheme { SiftRoot(model) }
        }
    }

    /** Light/dark changes don't restart the activity (so you keep your place); restyle the bars. */
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        enableEdgeToEdge()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent?) {
        intent ?: return
        intent.getStringExtra(Notifier.EXTRA_THREAD)?.let { model.threadToOpen = it }
        val data = intent.dataString
        if (data != null && data.startsWith("mailto:", ignoreCase = true)) {
            MailtoLink.parse(data)?.let { model.composeToOpen = ComposeRequest(mailto = it) }
        }
    }
}
