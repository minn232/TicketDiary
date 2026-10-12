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
// reactive_ble_mobile 5.5.0은 compileSdk 33인데 의존성(androidx.fragment)이 34+를 요구해서 올려줌
// (5.6.0은 37을 요구하는데 이 PC엔 37이 정식 설치돼 있지 않아 5.5.0으로 고정)
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
