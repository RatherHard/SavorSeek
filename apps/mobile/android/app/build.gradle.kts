import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Supabase 连接参数注入（Android）。
//
// SUPABASE_URL / SUPABASE_ANON_KEY 由 Dart 的 String.fromEnvironment 在编译期
// 读取，没有运行期兜底。此前必须手动附加 --dart-define-from-file=supabase.env，
// 漏传就退化成「未注入 Supabase 连接参数」，且现象与服务端故障难以区分。
//
// 这里把参数补进 Flutter 工具链的 `dart-defines` Gradle property，使 IDE 运行、
// flutter run、flutter build 任意方式都生效，无需记住命令行参数。
//
// 编码格式必须与工具链一致：每条 KEY=VALUE 先 UTF-8 再 base64，逗号连接
// （见 flutter_tools/lib/src/build_info.dart 的 encodeDartDefines）。直接拼明文
// 会让 assemble 阶段报 "contains non-base64 encoded data" 而整体失败。
//
// 采用「追加」而非「覆盖」：工具链可能已传入 flavor 等其他 define，覆盖会静默
// 丢掉它们。
val supabaseEnvFile = rootProject.file("../supabase.env")
val supabaseDefines: List<String> =
    if (supabaseEnvFile.exists()) {
        val wanted = listOf("SUPABASE_URL", "SUPABASE_ANON_KEY")
        supabaseEnvFile.readLines()
            .map { it.trim() }
            .filter { line -> wanted.any { line.startsWith("$it=") } }
            .filter { it.substringAfter('=').isNotEmpty() }
    } else {
        emptyList()
    }

if (supabaseDefines.size < 2) {
    logger.warn(
        "[SavorSeek] 未找到完整的 Supabase 连接参数：请复制 supabase.env.example 为 " +
            "apps/mobile/supabase.env 并填入 SUPABASE_URL 与 SUPABASE_ANON_KEY，" +
            "否则行程页无法连接服务端。",
    )
}

if (supabaseDefines.isNotEmpty()) {
    // Flutter 插件在 appProject.afterEvaluate 内才读取该 property，本块位于
    // 配置阶段顶层，因此此处写入对其可见。
    val encoder = Base64.getEncoder()
    val encoded = supabaseDefines.joinToString(",") {
        encoder.encodeToString(it.toByteArray(Charsets.UTF_8))
    }
    val existing = project.findProperty("dart-defines")?.toString()
    // 命令行显式传入的值放在后面：工具链侧同名 key 以靠后者为准，从而保留
    // `--dart-define-from-file=supabase.env` 手动覆盖本注入的能力。
    project.extensions.extraProperties["dart-defines"] =
        if (existing.isNullOrEmpty()) encoded else "$encoded,$existing"
    // 只报告条数，不打印取值，避免 anon key 进入构建日志与 CI 输出。
    logger.lifecycle("[SavorSeek] 已注入 ${supabaseDefines.size} 项 Supabase dart-define。")
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
