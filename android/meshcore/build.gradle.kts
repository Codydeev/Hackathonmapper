// Platform-independent port of ios/MeshCore: models, wire format, dedup and
// positioning. No Android APIs here, so `gradlew :meshcore:test` runs on any JVM.
plugins {
    kotlin("jvm")
    kotlin("plugin.serialization")
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    api("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    testImplementation("junit:junit:4.13.2")
}

tasks.test {
    // SignalMapTests replays the golden file the Swift tests use (single source).
    systemProperty("signalmap.golden", rootProject.file("../ios/MeshCore/Tests/MeshCoreTests/signalmap-golden.json").absolutePath)
    testLogging { events("failed"); exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL }
}
