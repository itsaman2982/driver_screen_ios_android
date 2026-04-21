allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
    project.evaluationDependsOn(":app")
}

// 🚀 CRITICAL INFRASTRUCTURE FIXES (Namespace & JVM Harmonization)
subprojects {
    val proj = this
    proj.plugins.all {
        if (this.javaClass.name.startsWith("com.android.build.gradle") ||
            this.javaClass.name.startsWith("com.android.build.api.variant.impl")) {
            
            val fixProject = {
                if (proj.hasProperty("android")) {
                    val android = proj.extensions.getByName("android")
                    try {
                        // 1. 🔍 Namespace Injection (for AGP 8.0+)
                        var ns: String? = null
                        val manifestFile = proj.file("src/main/AndroidManifest.xml")
                        if (manifestFile.exists()) {
                            val manifestContent = manifestFile.readText()
                            val packageMatch = Regex("package=\"([^\"]+)\"").find(manifestContent)
                            if (packageMatch != null) {
                                ns = packageMatch.groupValues[1]
                            }
                        }
                        if (ns == null) ns = "com.kiosk.fix.${proj.name.replace("-", "_")}"
                        val nsMethod = android.javaClass.getMethod("setNamespace", String::class.java)
                        nsMethod.invoke(android, ns)

                        // 2. ☕ JVM Target Enforcement (Synchronize Java & Kotlin)
                        val compileOptions = android.javaClass.getMethod("getCompileOptions").invoke(android)
                        val setSource = compileOptions.javaClass.getMethod("setSourceCompatibility", JavaVersion::class.java)
                        val setTarget = compileOptions.javaClass.getMethod("setTargetCompatibility", JavaVersion::class.java)
                        setSource.invoke(compileOptions, JavaVersion.VERSION_17)
                        setTarget.invoke(compileOptions, JavaVersion.VERSION_17)
                    } catch (e: Exception) { }
                }
            }

            if (proj.state.executed) {
                fixProject()
            } else {
                proj.afterEvaluate { fixProject() }
            }
        }
    }
}

// Global Task Configuration
subprojects {
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile> {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
    tasks.withType<JavaCompile> {
        sourceCompatibility = "17"
        targetCompatibility = "17"
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
