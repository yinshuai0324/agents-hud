plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "com.ooimi.agents.status"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.ooimi.agents.status"
        minSdk = 26
        targetSdk = 35
        versionCode = (project.findProperty("appVersionCode") as String?)?.toIntOrNull() ?: 1
        versionName = (project.findProperty("appVersionName") as String?) ?: "0.1.0"
        vectorDrawables { useSupportLibrary = true }
    }

    // Release signing uses the committed keystore (open-source; fine for a
    // personal LAN tool) with a fixed password, so CI needs no secrets. Env
    // vars override if you ever want to sign with a private key instead.
    val ksFile = file(System.getenv("AGENTSHUD_KEYSTORE_FILE") ?: "agentshud-release.jks")
    val useReleaseSigning = ksFile.exists()
    signingConfigs {
        if (useReleaseSigning) {
            create("release") {
                storeFile = ksFile
                storePassword = System.getenv("AGENTSHUD_KEYSTORE_PASSWORD") ?: "agentshud"
                keyAlias = System.getenv("AGENTSHUD_KEY_ALIAS") ?: "agentshud"
                keyPassword = System.getenv("AGENTSHUD_KEY_PASSWORD") ?: "agentshud"
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (useReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }
    packaging {
        resources { excludes += "/META-INF/{AL2.0,LGPL2.1}" }
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.ui)
    implementation(libs.androidx.ui.graphics)
    implementation(libs.androidx.ui.tooling.preview)
    implementation(libs.androidx.material3)
    debugImplementation(libs.androidx.ui.tooling)

    implementation(libs.kotlinx.serialization.json)
    implementation(libs.okhttp)
    implementation(libs.androidx.datastore.preferences)

    implementation(libs.androidx.camera.core)
    implementation(libs.androidx.camera.camera2)
    implementation(libs.androidx.camera.lifecycle)
    implementation(libs.androidx.camera.view)
    implementation(libs.mlkit.barcode.scanning)
    implementation(libs.accompanist.permissions)
}
