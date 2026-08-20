import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 发布签名配置来自 android/key.properties（已被 .gitignore 排除，不得入库）。
// 文件缺失时不报错：调试构建与 CI 的纯分析任务无需发布密钥。
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) {
        file.inputStream().use { load(it) }
    }
}
val hasReleaseKeystore = keystoreProperties.getProperty("storeFile") != null

// 高德 Key 注入。
//
// 高德原生 SDK 从 AndroidManifest 的 <meta-data com.amap.api.v2.apikey> 读取 Key，
// 因此在构建期注入 manifestPlaceholders，使任意启动方式（IDE 运行、flutter run、
// flutter build）都生效。此前依赖 `--dart-define-from-file=amap.env` 手动传参，
// 一旦漏传就会退化成「未配置」，是已修复的缺陷。
//
// Key 来源 apps/mobile/amap.env（已被 .gitignore 排除，不入库）。
val amapEnvFile = rootProject.file("../amap.env")
val amapAndroidKey: String =
    if (amapEnvFile.exists()) {
        amapEnvFile.readLines()
            .map { it.trim() }
            .firstOrNull { it.startsWith("AMAP_ANDROID_KEY=") }
            ?.substringAfter('=')
            ?.trim()
            .orEmpty()
    } else {
        ""
    }

if (amapAndroidKey.isEmpty()) {
    logger.warn(
        "[SavorSeek] 未找到高德 Key：请复制 amap.env.example 为 apps/mobile/amap.env 并填入 " +
            "AMAP_ANDROID_KEY，否则地图无法显示。",
    )
    // 发布包缺少 Key 属于必须阻断的问题，不允许静默产出不可用的包。
    gradle.taskGraph.whenReady {
        if (allTasks.any { it.name.contains("Release") }) {
            throw GradleException(
                "发布构建缺少高德 Key：请在 apps/mobile/amap.env 中配置 AMAP_ANDROID_KEY。",
            )
        }
    }
}

android {
    namespace = "com.savorseek.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 与高德开放平台申请 Key 时登记的 PackageName 保持一致，修改会导致地图鉴权失败。
        applicationId = "com.savorseek.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 供 AndroidManifest 中 com.amap.api.v2.apikey 的 meta-data 占位符使用。
        manifestPlaceholders["amapApiKey"] = amapAndroidKey
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // 缺少发布密钥时回退到调试签名，使 `flutter run --release` 仍可用；
            // 此时产出的包不可分发，签名指纹与高德登记的发布指纹不一致。
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
