allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// Forzar Java 17 / jvmTarget 17 en todos los módulos (app y plugins).
// Se usa "state.executed" para no fallar si el proyecto ya fue evaluado.
subprojects {
    val aplicarJava17: Project.() -> Unit = {
        extensions.findByName("android")?.let { androidExt ->
            try {
                val compileOptions = androidExt.javaClass.getMethod("getCompileOptions").invoke(androidExt)
                compileOptions.javaClass
                    .getMethod("setSourceCompatibility", JavaVersion::class.java)
                    .invoke(compileOptions, JavaVersion.VERSION_17)
                compileOptions.javaClass
                    .getMethod("setTargetCompatibility", JavaVersion::class.java)
                    .invoke(compileOptions, JavaVersion.VERSION_17)
            } catch (e: Exception) {
                // Módulo sin extensión android compatible: se omite.
            }
        }
    }

    if (state.executed) {
        aplicarJava17()
    } else {
        afterEvaluate { aplicarJava17() }
    }

    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
}