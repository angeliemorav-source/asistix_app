allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Configuración moderna compatible con Gradle y AGP recientes
subprojects {
    afterEvaluate { p ->
        if (p.hasProperty("android")) {
            p.extensions.configure<com.android.build.gradle.BaseExtension> {
                compileOptions {
                    sourceCompatibility = JavaVersion.VERSION_17
                    targetCompatibility = JavaVersion.VERSION_17
                }
            }
        }
    }
}

tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}