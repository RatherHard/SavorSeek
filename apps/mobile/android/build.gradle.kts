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

// amap_map 1.0.15 把自身 compileSdk 固定为 35，而它依赖的
// flutter_plugin_android_lifecycle 2.0.35 要求消费方以 API 36+ 编译，
// 直接构建会在 :amap_map:checkDebugAarMetadata 失败。该插件已停更
// （最后发布 2025-03），无法等上游修复，故在此统一提升 Android 库子项目的
// compileSdk。仅影响编译期可用 API，不改变 targetSdk 的运行时行为。
//
// 注意：本块必须位于下方 evaluationDependsOn(":app") 之前。该调用会强制
// 立即求值子项目，之后再注册 afterEvaluate 会抛
// "Cannot run Project.afterEvaluate(Action) when the project is already evaluated"。
subprojects {
    afterEvaluate {
        val androidExt = extensions.findByName("android")
        if (androidExt is com.android.build.api.dsl.LibraryExtension) {
            val current = androidExt.compileSdk
            if (current != null && current < 36) {
                androidExt.compileSdk = 36
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
