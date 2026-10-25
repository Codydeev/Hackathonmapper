plugins {
    id("com.android.application") version "8.7.3" apply false
    kotlin("android") version "2.0.21" apply false
    kotlin("jvm") version "2.0.21" apply false
    kotlin("plugin.serialization") version "2.0.21" apply false
    kotlin("plugin.compose") version "2.0.21" apply false
}

// Parallel work: `-PbuildDirName=build-x --project-cache-dir .gradle-x` keeps one build's outputs
// apart from another's in the same checkout.
providers.gradleProperty("buildDirName").orNull?.let { name ->
    allprojects { layout.buildDirectory.set(file(name)) }
}
