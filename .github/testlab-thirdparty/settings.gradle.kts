// A UiAutomator driver for Firebase Test Lab that imports the test subscription into
// third-party apps (Hiddify, Karing); see .github/workflows/android-thirdparty.yaml.
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
rootProject.name = "vps2vpn-thirdparty"
include(":driver")
