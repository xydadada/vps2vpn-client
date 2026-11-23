// A UiAutomator driver for Firebase Test Lab: it installs next to the release
// APK and drives that app on real phones (see .github/workflows/android-testlab.yaml).
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}
plugins {
    id("com.android.application") version "9.4.1" apply false
}
rootProject.name = "vps2vpn-testlab"
include(":driver")
