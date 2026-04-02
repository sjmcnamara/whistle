plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.google.dagger.hilt.android")
    id("com.google.devtools.ksp")
}

android {
    namespace = "org.findmyfam"
    compileSdk = 35

    defaultConfig {
        applicationId = "org.findmyfam"
        minSdk = 26
        targetSdk = 34
        versionCode = 11
        versionName = "0.9.4"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
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
    // Shared core library
    implementation(project(":shared"))

    // Compose BOM
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material")
    implementation("androidx.compose.material:material-icons-extended")
    debugImplementation("androidx.compose.ui:ui-tooling")

    // Activity + Lifecycle
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.10.0")

    // Navigation
    implementation("androidx.navigation:navigation-compose:2.8.5")

    // Hilt DI
    implementation("com.google.dagger:hilt-android:2.54")
    ksp("com.google.dagger:hilt-compiler:2.54")
    implementation("androidx.hilt:hilt-navigation-compose:1.2.0")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    // DataStore (replaces SharedPreferences)
    implementation("androidx.datastore:datastore-preferences:1.1.1")

    // Biometric
    implementation("androidx.biometric:biometric:1.1.0")

    // OpenStreetMap (no Google Play Services dependency)
    implementation("org.osmdroid:osmdroid-android:6.1.20")

    // Accompanist (permissions)
    implementation("com.google.accompanist:accompanist-permissions:0.36.0")

    // Security / Encrypted SharedPreferences
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // NostrSDK (Kotlin bindings via rust-nostr UniFFI)
    implementation("org.rust-nostr:nostr-sdk:0.44.2")

    // JNA (required by UniFFI-generated Kotlin bindings for MDK)
    implementation("net.java.dev.jna:jna:5.16.0@aar")

    // QR code generation (ZXing)
    implementation("com.google.zxing:core:3.5.3")

    // CameraX + ML Kit barcode scanning
    implementation("androidx.camera:camera-core:1.4.1")
    implementation("androidx.camera:camera-camera2:1.4.1")
    implementation("androidx.camera:camera-lifecycle:1.4.1")
    implementation("androidx.camera:camera-view:1.4.1")
    implementation("com.google.mlkit:barcode-scanning:17.3.0")

    // Timber (logging)
    implementation("com.jakewharton.timber:timber:5.0.1")

    // Testing
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.6.1")
}
