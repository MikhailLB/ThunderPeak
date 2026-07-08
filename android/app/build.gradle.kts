import java.util.Properties
import java.io.FileInputStream

// ============================================================
// ThunderPeak — Android app module
// ============================================================
// compileSdk stays at 36 for plugin compatibility (see
// .cursor/rules/gray_part_pitfalls.md §2). targetSdk = 35 and
// minSdk = 30 per TZ / gray-flow guide.
//
// Core library desugaring is enabled for flutter_local_notifications
// 22+ (java.time.* on old API levels). See pitfalls §5.
// ============================================================

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// Apply Google Services only when a real google-services.json ships.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

// Optional release signing.
val storeProps = Properties()
val storePropsFile = rootProject.file("key.properties")
val hasStore = storePropsFile.exists()
if (hasStore) {
    storeProps.load(FileInputStream(storePropsFile))
}

android {
    namespace = "com.zeus.thunderpeak"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.zeus.thunderpeak"
        minSdk = 30
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (hasStore) {
                keyAlias = storeProps["keyAlias"] as String
                keyPassword = storeProps["keyPassword"] as String
                storeFile = file(storeProps["storeFile"] as String)
                storePassword = storeProps["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = if (hasStore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
