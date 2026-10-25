package com.markschmidt.sift.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.markschmidt.sift.AppModel
import com.markschmidt.sift.ComposeRequest
import java.util.UUID

/** Where you are. Sift's screens form one stack, like the iPhone app's navigation. */
sealed interface Screen {
    data object Home : Screen
    /** A label or system mailbox; null [mailboxId] is Everything. */
    data class Mailbox(val mailboxId: String?, val title: String) : Screen
    data object Screener : Screen
    data class ScreenerSender(val email: String) : Screen
    /** [sourceMailbox] is the folder it was opened from; Archive removes it. */
    data class Thread(val threadId: String, val sourceMailbox: String?) : Screen
    data object Search : Screen
    data class Compose(val request: ComposeRequest) : Screen
    data class SenderSettings(val email: String) : Screen
    data object Senders : Screen
    data object Settings : Screen
    data class IconPicker(val mailboxId: String) : Screen
    data object Suggestions : Screen
}

class Navigator {
    data class Entry(val screen: Screen, val key: String = UUID.randomUUID().toString())

    val stack = mutableStateListOf(Entry(Screen.Home))
    val top: Entry get() = stack.last()

    fun push(screen: Screen) {
        stack += Entry(screen)
    }

    fun pop() {
        if (stack.size > 1) stack.removeAt(stack.lastIndex)
    }

    /** Leaves [screen] if it's showing (a thread that was archived, a sent message). */
    fun close(screen: Screen) {
        val index = stack.indexOfLast { it.screen == screen }
        if (index > 0) stack.removeAt(index)
    }

    fun resetTo(screen: Screen) {
        stack.clear()
        stack += Entry(Screen.Home)
        if (screen != Screen.Home) stack += Entry(screen)
    }
}

@Composable
fun SiftRoot(model: AppModel) {
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        when (val phase = model.phase) {
            AppModel.Phase.Launching -> Centered { CircularProgressIndicator() }
            AppModel.Phase.SignedOut, AppModel.Phase.Connecting, is AppModel.Phase.Failed -> OnboardingScreen(model)
            AppModel.Phase.Syncing -> Centered {
                CircularProgressIndicator()
                Spacer(Modifier.height(12.dp))
                Text("Syncing with Fastmail…", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            AppModel.Phase.Ready -> MainScreen(model)
        }
        ErrorDialog(model)
    }
}

@Composable
private fun Centered(content: @Composable () -> Unit) {
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        content()
    }
}

@Composable
private fun MainScreen(model: AppModel) {
    val navigator = remember { Navigator() }
    val saveable = rememberSaveableStateHolder()

    // A notification tap: show the conversation, wherever it's filed.
    LaunchedEffect(model.threadToOpen) {
        val id = model.threadToOpen ?: return@LaunchedEffect
        model.threadToOpen = null
        navigator.resetTo(Screen.Thread(id, null))
    }
    // A mailto: link, or a message brought back by Undo Send.
    LaunchedEffect(model.composeToOpen) {
        val request = model.composeToOpen ?: return@LaunchedEffect
        model.composeToOpen = null
        navigator.push(Screen.Compose(request))
    }

    BackHandler(enabled = navigator.stack.size > 1) { navigator.pop() }

    Box(Modifier.fillMaxSize()) {
        AnimatedContent(
            targetState = navigator.top,
            transitionSpec = {
                val forward = navigator.stack.contains(initialState)
                if (forward) {
                    (slideInHorizontally { it / 3 } + fadeIn()) togetherWith (slideOutHorizontally { -it / 6 } + fadeOut())
                } else {
                    (slideInHorizontally { -it / 6 } + fadeIn()) togetherWith (slideOutHorizontally { it / 3 } + fadeOut())
                }
            },
            label = "navigation",
        ) { entry ->
            saveable.SaveableStateProvider(entry.key) {
                ScreenContent(model, navigator, entry.screen)
            }
        }
        ToastHost(model, Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 88.dp))
    }
}

@Composable
private fun ScreenContent(model: AppModel, navigator: Navigator, screen: Screen) {
    when (screen) {
        Screen.Home -> HomeScreen(model, navigator)
        is Screen.Mailbox -> ThreadListScreen(model, navigator, screen.mailboxId, screen.title)
        Screen.Screener -> ScreenerScreen(model, navigator)
        is Screen.ScreenerSender -> ScreenerSenderScreen(model, navigator, screen.email)
        is Screen.Thread -> ThreadScreen(model, navigator, screen.threadId, screen.sourceMailbox) { navigator.close(screen) }
        Screen.Search -> SearchScreen(model, navigator)
        is Screen.Compose -> ComposeScreen(model, screen.request) { navigator.close(screen) }
        is Screen.SenderSettings -> SenderSettingsScreen(model, navigator, screen.email)
        Screen.Senders -> SendersScreen(model, navigator)
        Screen.Settings -> SettingsScreen(model, navigator)
        is Screen.IconPicker -> LabelIconPickerScreen(model, navigator, screen.mailboxId)
        Screen.Suggestions -> RuleSuggestionsScreen(model, navigator)
    }
}
