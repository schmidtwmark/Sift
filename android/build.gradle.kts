plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.serialization) apply false
}

// Build output lives outside the repo. ~/Documents is iCloud-synced, and
// iCloud "resolves" races by duplicating files with " 2" suffixes, which breaks
// Gradle in ways that look like code errors. ~/Library/Caches is never synced.
val buildRoot = file("${System.getProperty("user.home")}/Library/Caches/Sift/android-build")
allprojects {
    layout.buildDirectory.set(File(buildRoot, project.path.replace(":", "-").trim('-').ifEmpty { "root" }))
}
