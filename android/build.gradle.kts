plugins {
  id("com.android.application") version "8.9.1" apply false
  id("org.jetbrains.kotlin.android") version "2.0.21" apply false
  id("org.jetbrains.kotlin.plugin.compose") version "2.0.21" apply false
  // Uploads to Google Play through the Publishing API (play-release.sh).
  id("com.github.triplet.play") version "3.12.1" apply false
}
