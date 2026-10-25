# Sift for Android

The Android version of Sift, the calm, Hey-style client for Fastmail. It shares everything with the iPhone and Mac apps through Fastmail itself: the same Screener and Screened Out mailboxes, the same "Sift: …" contact groups for sender decisions, the same label icons, the same drafts and the same `$siftrouted` marker. See the top-level [README](../README.md) for how Sift maps onto Fastmail.

## Building

You need JDK 17–21 (this Mac has Homebrew's `openjdk@21`) and the Android SDK with platform 35.

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
./gradlew :core:test            # unit tests (JVM, a few seconds)
./gradlew :app:assembleDebug    # the app
./gradlew :app:installDebug     # onto a running emulator or phone
```

Build output goes to `~/Library/Caches/Sift/android-build`, not into the repo: `~/Documents` is iCloud-synced, and iCloud's " 2" duplicate files break Gradle.

To try it without an account, tap **Explore with sample mail**, or launch it in demo mode (the counterpart of `-demo` on the Apple platforms):

```bash
adb shell am start -n com.markschmidt.sift/.MainActivity --ez demo true
```

## Layout

```
core/   Plain Kotlin (JVM), no Android: everything that isn't UI, unit-tested
  jmap/       JMAP client (OkHttp): session, method calls, upload/download, EventSource
  store/      SQLite cache with an FTS5 index (bundled SQLite, so FTS5 is always there)
  sync/       SyncEngine (sync, routing, optimistic changes, search, drafts, sending, Undo Send)
  screener/   Router (pure routing rules), ContactsRuleStore, SortingInference
  search/     Query parser → JMAP filter and SQL
  privacy/    TrackerDetector, tracker list, HTML helpers
  labels/     Label icon catalog, name guesses and the contact-group note
  compose/    mailto: links and outgoing messages
  demo/       Fake Fastmail (an OkHttp interceptor) and the sample mailbox
app/    Jetpack Compose + Material 3 app (min SDK 31)
```

`core` is a line-by-line port of `SiftKit`; its tests (`core/src/test`) port `SiftKit/Tests` and add JMAP-layer tests against a fake server. The group uids are checked against values computed by the Swift code, so both platforms address the same contact cards.

## Android specifics

- **Token:** stored with `EncryptedSharedPreferences`, under a key held in the Android Keystore. It doesn't sync between devices (the Apple apps use iCloud Keychain).
- **Reader:** a `WebView` with JavaScript, file and content access off and no cookies. Known trackers are refused in `shouldInterceptRequest` (the stand-in for WebKit's content blocker), and with **Load remote images** off every remote load is refused. Links open in the browser; nothing navigates inside the reader. Inline `cid:` images are served from Fastmail through a reserved `sift-blob.invalid` host that never reaches the network.
- **Dark mode:** plain mail uses the app's text colors; mail with its own dark styles is left alone; mail designed for white is darkened by WebView's algorithmic darkening (Android 13+; `forceDark` on 12).
- **Push and alerts:** Sift holds Fastmail's EventSource connection while it's in front. In the background, WorkManager refreshes about every 15 minutes (Android's minimum), sorts new mail and posts alerts for senders you turned them on for. Like iOS background refresh, this can be late.
- **Badge:** Android launchers draw badges from notifications, so the badge is a silent, low-priority notification whose number is the unread count from badged senders. Many launchers show only a dot.
- **Default email app:** Sift handles `mailto:` links (`SENDTO`/`VIEW`), so Android offers it when you tap an email link.
