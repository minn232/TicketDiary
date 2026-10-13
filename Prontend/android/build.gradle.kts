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
}
// [백엔드 수정] reactive_ble_mobile 5.5.0의 compileSdk 33을 36으로 올림 (androidx 의존성이 34+ 요구)
subprojects {
    if (name == "reactive_ble_mobile") {
        afterEvaluate {
            extensions.getByType<com.android.build.gradle.LibraryExtension>().compileSdk = 36
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
