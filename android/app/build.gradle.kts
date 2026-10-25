plugins {
    id("com.android.application")
    kotlin("android")
    kotlin("plugin.serialization")
    kotlin("plugin.compose")
}

android {
    namespace = "com.hackathonmapper.meshmapper"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.hackathonmapper.meshmapper"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Demo builds: sign release with the debug key so `assembleRelease` installs directly.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
    }
}

dependencies {
    implementation(project(":meshcore"))

    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")

    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")

    testImplementation("junit:junit:4.13.2")
}

// App JVM tests read the shared goldens in place (ml/export/, contract/) under `repo.root`.
tasks.withType<Test>().configureEach {
    systemProperty("repo.root", rootProject.file("..").absolutePath)
}

// GhostCore scenarios (S0-S6) for the in-app scenario player, bundled from contract/scenarios like
// ios/project.yml does: assets/S0.json … S6.json, read in place so there is one copy.
val scenarioAssets = layout.buildDirectory.dir("generated/scenarioAssets")
val syncScenarios by tasks.registering(Sync::class) {
    from(rootProject.file("../contract/scenarios")) { include("*.json") }
    into(scenarioAssets)
}
android.sourceSets.getByName("main").assets.srcDir(scenarioAssets)
tasks.named("preBuild") { dependsOn(syncScenarios) }
