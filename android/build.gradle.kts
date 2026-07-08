// ============================================================
// Root Android build — subproject compile-SDK override
// ============================================================
// Some plugins ship with compileSdk=34 but their transitive deps
// require 36. We force every Android library subproject up. The
// override MUST be registered BEFORE the `evaluationDependsOn(":app")`
// block (see .cursor/rules/gray_part_pitfalls.md §2 + §7).

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

    // Force every Android library plugin to compile against 36.
    afterEvaluate {
        extensions
            .findByType(com.android.build.gradle.LibraryExtension::class.java)
            ?.apply {
                if ((compileSdk ?: 0) < 36) {
                    compileSdk = 36
                }
            }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
