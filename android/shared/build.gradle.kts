plugins {
    id("com.android.library")
}

android {
    namespace = "org.findmyfam.shared"
    compileSdk = 36

    defaultConfig {
        minSdk = 26
    }

    compileOptions {
        // jvmTarget is inherited from targetCompatibility under AGP 9 built-in Kotlin.
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    // kotlin-test-junit binds kotlin.test.* to JUnit 4 explicitly. Under AGP 9
    // built-in Kotlin the plain kotlin-test artifact's framework auto-selection
    // isn't wired for the Android unit-test source set, so name the backend directly.
    testImplementation("org.jetbrains.kotlin:kotlin-test-junit:2.3.21")
    // Pure-Java org.json so unit tests can run without Android framework stubs
    testImplementation("org.json:json:20251224")
}
