import java.util.Properties

plugins {
  id("com.android.application")
  id("org.jetbrains.kotlin.android")
  id("org.jetbrains.kotlin.plugin.compose")
  id("com.github.triplet.play")
}

// Upload key and Play service account live outside the repo (see PLAY.md); builds without them still work.
val keyDir = File(System.getProperty("user.home"), "keys")
val releaseProps = Properties().apply {
  File(keyDir, "suhyeok-release.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}

android {
  namespace = "com.pickuma.suhyeok"
  compileSdk = 36

  defaultConfig {
    applicationId = "com.pickuma.suhyeok"
    minSdk = 26
    targetSdk = 36
    // publish.sh passes these; a plain build stays at 1 / 0.1.0.
    versionCode = (project.findProperty("versionCode") as String?)?.toInt() ?: 1
    versionName = (project.findProperty("versionName") as String?) ?: "0.1.0"
  }
  // direct = updates itself from the Mac (publish.sh); play = Google Play, which forbids self-updating apps.
  flavorDimensions += "store"
  productFlavors {
    create("direct") { dimension = "store"; buildConfigField("boolean", "SELF_UPDATE", "true"); buildConfigField("boolean", "BACKGROUND_NOTIFY", "true") }
    create("play") { dimension = "store"; buildConfigField("boolean", "SELF_UPDATE", "false"); buildConfigField("boolean", "BACKGROUND_NOTIFY", "false") }
  }
  signingConfigs {
    if (releaseProps.isNotEmpty()) create("release") {
      storeFile = File(keyDir, releaseProps.getProperty("storeFile"))
      storePassword = releaseProps.getProperty("storePassword")
      keyAlias = releaseProps.getProperty("keyAlias")
      keyPassword = releaseProps.getProperty("keyPassword")
    }
  }
  buildTypes {
    release { signingConfig = signingConfigs.findByName("release") }
  }
  playConfigs { register("play") { enabled.set(true) } }
  buildFeatures { compose = true; buildConfig = true }
  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
  }
  kotlinOptions { jvmTarget = "17" }
}

play {
  enabled.set(false)  // only the play flavor goes to Google Play
  serviceAccountCredentials.set(File(keyDir, "suhyeok-play.json"))
  defaultToAppBundles.set(true)
  track.set("internal")
}
dependencies {
  val composeBom = platform("androidx.compose:compose-bom:2024.10.00")
  implementation(composeBom)
  implementation("androidx.core:core-ktx:1.13.1")
  implementation("androidx.activity:activity-compose:1.9.2")
  implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")
  implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")
  implementation("androidx.compose.ui:ui")
  implementation("androidx.compose.material3:material3")
  implementation("androidx.compose.material:material-icons-extended")
  implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
  // QR scanning for pairing, without Google Play services.
  implementation("com.journeyapps:zxing-android-embedded:4.3.0")
  // Character portraits served by the Mac (/art/…).
  implementation("io.coil-kt:coil-compose:2.7.0")
  // The pairing token is kept encrypted on the phone.
  implementation("androidx.security:security-crypto:1.1.0-alpha06")

  testImplementation("junit:junit:4.13.2")
  testImplementation("org.json:json:20240303")  // real org.json for Demo tests (android.jar only has stubs)
}
