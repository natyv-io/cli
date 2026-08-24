// Real-compiled and verified locally (2026-08-24) with the IntelliJ
// Platform Gradle Plugin 2.x + Gradle 9.7.1 + a JDK 17 toolchain -- the
// legacy `org.jetbrains.intellij` 1.x plugin (originally used here)
// throws `ClassNotFoundException: DefaultArtifactPublicationSet` against
// Gradle 9, since it reaches into a Gradle-internal class removed in
// Gradle 9 -- a real toolchain incompatibility, not a plugin.xml/Kotlin
// bug, found by actually running the build.
plugins {
    id("org.jetbrains.kotlin.jvm") version "1.9.24"
    id("org.jetbrains.intellij.platform") version "2.9.0"
}

group = "dev.natyv"
version = "0.1.0"

repositories {
    mavenCentral()
    intellijPlatform {
        defaultRepositories()
    }
}

// Targets IntelliJ IDEA Community for the dev sandbox (runIde) since it's
// free and always resolvable -- the resulting plugin has no dependency on
// the bundled Go plugin at all (just com.intellij.modules.platform), so
// it installs into GoLand identically. Bump this version to match
// whatever GoLand/IntelliJ build you're actually running if the build
// fails to resolve it.
dependencies {
    intellijPlatform {
        create("IC", "2023.3.6")
    }
}

intellijPlatform {
    pluginConfiguration {
        ideaVersion {
            sinceBuild = "233"
            untilBuild = "252.*"
        }
    }
}

kotlin {
    jvmToolchain(17)
}
