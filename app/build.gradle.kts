import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

// Read the release signing config from local.properties (gitignored). When
// the file is missing or the keys are absent, release builds fall back to
// debug-signed — useful for CI / new contributors, but NOT what we ship to
// customers. See keystore/README.md.
val localProps = Properties().apply {
    val f = rootProject.file("local.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val releaseStoreFile = localProps.getProperty("RELEASE_STORE_FILE")
val releaseStorePassword = localProps.getProperty("RELEASE_STORE_PASSWORD")
val releaseKeyAlias = localProps.getProperty("RELEASE_KEY_ALIAS")
val releaseKeyPassword = localProps.getProperty("RELEASE_KEY_PASSWORD")
val hasReleaseSigning = listOf(releaseStoreFile, releaseStorePassword,
                               releaseKeyAlias, releaseKeyPassword)
    .all { !it.isNullOrBlank() } &&
    rootProject.file(releaseStoreFile!!).exists()

android {
    namespace = "com.panoculon.trinet.app"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.panoculon.trinet.app"
        minSdk = 28
        targetSdk = 34
        versionCode = 4
        versionName = "0.1.3"
        vectorDrawables.useSupportLibrary = true
    }

    if (hasReleaseSigning) {
        signingConfigs {
            create("release") {
                storeFile = rootProject.file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
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

    sourceSets {
        getByName("main").kotlin.srcDirs("src/main/kotlin")
    }
}

dependencies {
    implementation(project(":trinet-sdk"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.activity.compose)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.kotlinx.coroutines.android)

    debugImplementation(libs.androidx.compose.ui.tooling)

    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.espresso.core)
}
