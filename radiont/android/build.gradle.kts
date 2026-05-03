allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    val fixProject = {
        if (project.hasProperty("android")) {
            val android = project.extensions.getByName("android")
            
            // Fix namespace for all libraries (needed for AGP 8+)
            if (android is com.android.build.gradle.LibraryExtension) {
                if (android.namespace == null) {
                    android.namespace = when (project.name) {
                        "on_audio_query_android" -> "com.lucasjosino.on_audio_query"
                        "install_plugin_v2" -> "com.youxiachai.installplugin"
                        else -> project.group.toString().trim()
                    }
                }
            }



            // Force Java compatibility to 11
            if (android is com.android.build.gradle.BaseExtension) {
                android.compileOptions {
                    sourceCompatibility = JavaVersion.VERSION_11
                    targetCompatibility = JavaVersion.VERSION_11
                }
            }
        }
        
        // Force Kotlin compatibility to 11
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            kotlinOptions {
                jvmTarget = "11"
            }
        }
    }
    
    try {
        afterEvaluate { fixProject() }
    } catch (e: Exception) {
        fixProject()
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
