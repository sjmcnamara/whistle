plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.google.dagger.hilt.android")
    id("com.google.devtools.ksp")
}

android {
    namespace = "org.findmyfam"
    compileSdk = 36

    defaultConfig {
        applicationId = "org.getwhistle.whistle"
        minSdk = 26
        targetSdk = 34
        versionCode = 50
        versionName = "1.8.8"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

    }

    signingConfigs {
        create("release") {
            // Populated from env vars in CI (.github/workflows/release-android.yml).
            // Local release builds without these env vars produce an unsigned APK
            // (warning at build time); the release buildType only wires this
            // config when ANDROID_KEYSTORE_PATH is present.
            val keystorePath = System.getenv("ANDROID_KEYSTORE_PATH")
            if (keystorePath != null) {
                storeFile = file(keystorePath)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        debug {
            // Required for Jacoco to instrument unit tests and produce .exec data
            enableUnitTestCoverage = true
        }
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            if (System.getenv("ANDROID_KEYSTORE_PATH") != null) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    compileOptions {
        // With AGP 9 built-in Kotlin, kotlin.compilerOptions.jvmTarget defaults
        // to android.compileOptions.targetCompatibility, so JVM_17 is inherited.
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }

    lint {
        // androidx.lifecycle lint detector crashes on MDK-generated mdk_uniffi.kt
        // (KaCallableMemberCall class/interface mismatch in NullSafeMutableLiveDataDetector)
        disable += "NullSafeMutableLiveData"
    }
}

dependencies {
    // Shared core library
    implementation(project(":shared"))

    // Compose BOM
    val composeBom = platform("androidx.compose:compose-bom:2026.05.00")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material")
    implementation("androidx.compose.material:material-icons-extended")
    debugImplementation("androidx.compose.ui:ui-tooling")

    // Activity + Lifecycle
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.10.0")

    // Navigation
    implementation("androidx.navigation:navigation-compose:2.9.7")

    // Hilt DI
    implementation("com.google.dagger:hilt-android:2.60.1")
    ksp("com.google.dagger:hilt-compiler:2.60.1")
    implementation("androidx.hilt:hilt-navigation-compose:1.3.0")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")

    // DataStore (replaces SharedPreferences)
    implementation("androidx.datastore:datastore-preferences:1.2.1")

    // Biometric
    implementation("androidx.biometric:biometric:1.1.0")

    // OpenStreetMap (no Google Play Services dependency)
    implementation("org.osmdroid:osmdroid-android:6.1.20")

    // Accompanist (permissions)
    implementation("com.google.accompanist:accompanist-permissions:0.37.3")

    // Activity Recognition (motion-adaptive location intervals)
    implementation("com.google.android.gms:play-services-location:21.3.0")

    // Security / Encrypted SharedPreferences
    implementation("androidx.security:security-crypto:1.1.0")

    // NostrSDK (Kotlin bindings via rust-nostr UniFFI)
    implementation("org.rust-nostr:nostr-sdk:0.44.2")

    // JNA (required by UniFFI-generated Kotlin bindings for MDK)
    implementation("net.java.dev.jna:jna:5.18.1@aar")

    // QR code generation, styled (dark-grey dot modules + center logo badge) —
    // Compose-native painter, no Drawable/Bitmap interop needed. Sibling of
    // iOS's dagronf/QRCode by the same author; ZXing had no styling hooks.
    implementation("io.github.alexzhirkevich:qrose:1.1.2")

    // CameraX + ML Kit barcode scanning
    implementation("androidx.camera:camera-core:1.6.1")
    implementation("androidx.camera:camera-camera2:1.6.1")
    implementation("androidx.camera:camera-lifecycle:1.6.1")
    implementation("androidx.camera:camera-view:1.6.1")
    implementation("com.google.mlkit:barcode-scanning:17.3.0")

    // Timber (logging)
    implementation("com.jakewharton.timber:timber:5.0.1")

    // Testing
    testImplementation("junit:junit:4.13.2")
    testImplementation("io.mockk:mockk:1.14.9")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
    testImplementation("org.json:json:20251224")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
}
