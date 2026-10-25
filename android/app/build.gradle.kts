import java.io.FileInputStream
import java.util.Properties
import org.gradle.api.GradleException

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
    // Adds the build id Crashlytics needs at startup and uploads the R8
    // mapping file for release builds.
    id("com.google.firebase.crashlytics")
}

val appId = (project.findProperty("APP_ID") as String?) ?: "app.sidequest"
val appName = (project.findProperty("APP_NAME") as String?) ?: "SideQuest"
val isReleaseBuildRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true) || it.contains("bundle", ignoreCase = true)
}
// Bundle (.aab) is the Play Store path — that's where the old placeholder id
// must be rejected. google-services.json has to be registered for APP_ID.
val isBundleBuildRequested = gradle.startParameter.taskNames.any {
    it.contains("bundle", ignoreCase = true)
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

val hasReleaseSigning =
    listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
        .all { key -> keystoreProperties.getProperty(key)?.isNotBlank() == true }

if (isBundleBuildRequested && appId == "com.example.nummwe3") {
    throw GradleException(
        "APP_ID is still the placeholder com.example.nummwe3. Set a real package id in android/gradle.properties (and re-register Firebase) before building a Play Store bundle.",
    )
}

if (isReleaseBuildRequested && !hasReleaseSigning) {
    throw GradleException(
        "Release signing is not configured. Fill android/key.properties with a real keystore before building release artifacts.",
    )
}

android {
    namespace = appId
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    defaultConfig {
        applicationId = appId
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["appName"] = appName
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
    implementation(platform("com.google.firebase:firebase-bom:34.6.0"))
    implementation("com.google.firebase:firebase-messaging")
    implementation("androidx.camera:camera-camera2:1.5.3")
    implementation("androidx.camera:camera-lifecycle:1.5.3")
    implementation("androidx.camera:camera-view:1.5.3")
    implementation("androidx.camera:camera-video:1.5.3")
    implementation("com.google.guava:guava:33.5.0-android")

}
