plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Firebase configuration is optional for local builds. When the team adds its
// untracked google-services.json, generate the Firebase resources automatically.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

android {
    namespace = "ai.futurepath.pairdesk"
    compileSdk = 35
    defaultConfig {
        applicationId = "ai.futurepath.pairdesk"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-compose:1.10.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("androidx.work:work-runtime-ktx:2.12.0")
    implementation(platform("androidx.compose:compose-bom:2025.01.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.google.code.gson:gson:2.11.0")
    implementation("io.livekit:livekit-android:2.29.0")
    implementation("io.livekit:livekit-android-compose-components:2.4.2")
    // FCM stays optional until the team registers an Android app in Firebase.
    implementation("com.google.firebase:firebase-messaging:24.1.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    debugImplementation("androidx.compose.ui:ui-tooling")
}
