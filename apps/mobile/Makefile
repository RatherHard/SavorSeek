# SavorSeek 客户端命令包装。
#
# 存在的唯一理由：SUPABASE_URL / SUPABASE_ANON_KEY 由 Dart 的
# String.fromEnvironment 在编译期读取，没有运行期兜底，也没有任何 Flutter
# 内置机制能让 --dart-define-from-file 自动生效（已核对 Flutter 3.47.1 源码：
# flutter_command.dart:800-808 中该选项无 defaultsTo、无环境变量回退）。漏传
# 参数的启动会退化成「未注入 Supabase 连接参数」，且现象与服务端故障难以区分。
#
# 因此把参数固定在这里，用 `make run` 代替 `flutter run`。
# IDE 启动按钮已由 .vscode/launch.json 与 .idea 运行配置各自覆盖。
#
# 注意：高德 Key 在 Android 上由 Gradle 注入 manifest，本身不依赖 dart-define；
# 但 iOS 侧只能经 Dart 注入，故两个文件一并传，避免两端行为分叉。

ENV_FILES := supabase.env amap.env
DEFINES := $(foreach f,$(ENV_FILES),--dart-define-from-file=$(f))
MISSING := $(filter-out $(wildcard $(ENV_FILES)),$(ENV_FILES))

# 只在需要参数的目标里展开，因此 `make test` / `make analyze` 不受缺文件影响。
require-env = $(if $(MISSING),$(error 缺少 $(MISSING)：请由同名 .example 复制并填入真实值，见 supabase.env.example))

.PHONY: run run-release profile build-apk build-appbundle build-ios \
        test analyze verify config

## 日常开发：调试模式启动
run:
	$(require-env)
	flutter run $(DEFINES)

## 真机验收：release 模式启动
run-release:
	$(require-env)
	flutter run --release $(DEFINES)

## 性能测量
profile:
	$(require-env)
	flutter run --profile $(DEFINES)

build-apk:
	$(require-env)
	flutter build apk --release $(DEFINES)

build-appbundle:
	$(require-env)
	flutter build appbundle --release $(DEFINES)

build-ios:
	$(require-env)
	flutter build ios --release $(DEFINES)

## 测试刻意不传参数：SupabaseConfig 的未配置分支需要在无注入时可测，
## 且 CI 不应依赖含密钥的本地文件。
test:
	flutter test

analyze:
	flutter analyze

verify: analyze test

## 排查用：确认参数是否会被传入，不打印密钥本身。
config:
	@echo "env files:    $(ENV_FILES)"
	@echo "missing:      $(if $(MISSING),$(MISSING),(none))"
	@echo "flutter args: $(DEFINES)"
