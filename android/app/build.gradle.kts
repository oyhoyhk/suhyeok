plugins {
  id("com.android.application")
  id("org.jetbrains.kotlin.android")
  id("org.jetbrains.kotlin.plugin.compose")
}

android {
  namespace = "com.pickuma.suhyeok"
  compileSdk = 34

  defaultConfig {
    applicationId = "com.pickuma.suhyeok"
    minSdk = 26
    targetSdk = 34
    // publish.sh passes these; a plain build stays at 1 / 0.1.0.
    versionCode = (project.findProperty("versionCode") as String?)?.toInt() ?: 1
    versionName = (project.findProperty("versionName") as String?) ?: "0.1.0"
  }
  buildFeatures { compose = true; buildConfig = true }
  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
  }
  kotlinOptions { jvmTarget = "17" }
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
}
