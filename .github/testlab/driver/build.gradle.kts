plugins {
    id("com.android.application")
}

android {
    namespace = "com.vps2vpn.testlab"
    compileSdk = 37
    defaultConfig {
        applicationId = "com.vps2vpn.testlab"
        minSdk = 26
        targetSdk = 37
        versionCode = 1
        versionName = "1"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")
}
