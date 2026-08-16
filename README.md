# SavorSeek

SavorSeek 是一款以地图交互为核心、以智能 Agent 为主要能力的美食旅行应用。项目目标是帮助用户发现值得前往的餐厅、小店、街区和地方特色美食，并结合用户口味偏好、旅行时间、预算、交通方式与实时信息，生成个性化美食推荐和旅行路线。

核心理念：**地图负责呈现真实空间，Agent 负责理解用户需求，长期记忆负责让推荐越来越贴合用户。**

## 技术栈

- **客户端**：Flutter（跨平台移动端 UI、地图、地点详情、对话交互、旅行计划）
- **后端 / BaaS**：Supabase（PostgreSQL、Auth、Storage、Realtime、RLS）
- **Agent 编排层**：Supabase Edge Functions + TypeScript / Deno（后续接入 LangChain）
- **地图服务**：按目标地区、授权情况和合规要求选择
- **内容检索**：仅使用公开许可或授权来源，支持结构化索引和向量检索扩展

## 项目结构

```text
/
├── apps/
│   └── mobile/                  # Flutter 客户端
├── packages/
│   ├── domain/                  # 共享领域模型、类型、约束与纯逻辑
│   ├── contracts/               # API、数据库类型、Agent 结构化输出契约
│   └── test-fixtures/           # 跨端测试数据与场景样例
├── supabase/
│   ├── functions/               # Supabase Edge Functions
│   │   └── agent/               # Agent 编排入口
│   ├── migrations/              # 数据库迁移
│   ├── seed/                    # 演示与测试数据
│   ├── policies/                # RLS 策略说明或脚本
│   └── config.toml              # 本地 Supabase 配置
└── docs/                        # 产品、架构和开发文档
```

> 当前仓库仍处于基础结构阶段，Flutter 客户端和共享包目录已预留，后续会按 MVP 里程碑逐步补充实现。

## 环境要求

建议使用以下工具版本或更新版本：

| 工具 | 用途 | 说明 |
|------|------|------|
| Git | 代码版本管理 | 必需 |
| Flutter SDK | 移动端开发 | 后续初始化 `apps/mobile` 后必需 |
| Supabase CLI | 本地数据库、Auth、Edge Functions | 必需 |
| Docker Desktop | Supabase 本地服务运行环境 | Supabase CLI 本地启动依赖 Docker |
| Node.js LTS | 前端 / 工具链扩展 | 后续共享包、脚本或 LangChain 依赖可能使用 |
| Deno | Edge Functions 本地开发 | Supabase Edge Runtime 使用 Deno |

### Windows 环境提示

本项目可在 Windows 11 下开发。建议：

1. 使用 Git Bash、PowerShell 或 Windows Terminal 作为终端。
2. 确保 Docker Desktop 已启动，并开启 WSL 2 后端。
3. Flutter 需要额外配置 Android Studio、Android SDK 和设备模拟器；完成后运行 `flutter doctor` 检查环境。

## 本地环境配置

### 1. 克隆仓库

```bash
git clone <repository-url>
cd SavorSeek
```

### 2. 安装并检查基础工具

```bash
git --version
supabase --version
docker --version
```

如需进行 Flutter 客户端开发，再检查：

```bash
flutter doctor
```

### 3. 配置环境变量

不要把真实密钥提交到仓库。建议在本地创建 `.env.local` 或各端约定的本地配置文件，并将真实值只保存在本机或密钥管理系统中。

后续开发通常会用到以下配置项：

```bash
# Supabase 客户端公开配置（anon key 仍需依赖 RLS 保护数据）
SUPABASE_URL=http://127.0.0.1:54321
SUPABASE_ANON_KEY=<local-or-project-anon-key>

# 服务端 / Edge Function 私有配置，禁止写入客户端代码
SUPABASE_SERVICE_ROLE_KEY=<service-role-key>

# 地图服务配置
MAP_PROVIDER=<provider-name>
MAP_API_KEY=<map-provider-api-key>

# Agent / LLM 配置
LLM_PROVIDER=<provider-name>
LLM_API_KEY=<llm-api-key>
```

安全要求：

- 不要提交 `.env.local`、服务端密钥、地图密钥、LLM 密钥或任何私有凭据。
- 客户端只能使用公开配置；所有高权限操作必须放在后端或 Edge Functions 中。
- Supabase 私有用户数据必须通过 Auth、RLS 和服务端权限校验保护。

## Supabase 本地开发

### 1. 启动本地 Supabase

```bash
supabase start
```

当前 `supabase/config.toml` 使用的本地端口：

| 服务 | 地址 |
|------|------|
| API | `http://127.0.0.1:54321` |
| Database | `postgresql://postgres:postgres@127.0.0.1:54322/postgres` |
| Studio | `http://127.0.0.1:54323` |
| Inbucket | `http://127.0.0.1:54324` |
| Edge Runtime Inspector | `http://127.0.0.1:8083` |

### 2. 应用数据库迁移

```bash
supabase db reset
```

当前初始迁移位于：

```text
supabase/migrations/20260816_000001_init.sql
```

### 3. 运行 Agent Edge Function

本地启动函数：

```bash
supabase functions serve agent
```

调用示例：

```bash
curl -i \
  --request POST \
  --header "Authorization: Bearer <SUPABASE_ANON_KEY>" \
  --header "Content-Type: application/json" \
  --data '{}' \
  http://127.0.0.1:54321/functions/v1/agent
```

当前 `agent` 函数为健康检查式占位实现，成功时返回：

```json
{
  "ok": true,
  "function": "agent"
}
```

## Flutter 客户端开发

客户端目录预留在：

```text
apps/mobile/
```

Flutter 项目初始化后，常用命令预计为：

```bash
cd apps/mobile
flutter pub get
flutter run
flutter test
```

初始化和开发客户端时需遵守：

- 地图、内容、推荐和路线规划能力通过领域服务抽象，不要让 UI 直接耦合第三方 API。
- 用户输入、外部 API 响应、深链接和 Agent 工具参数必须做边界校验。
- 用户偏好和行程数据属于私有数据，客户端不得绕过后端权限控制。

## 常用开发命令

```bash
# 启动 Supabase 本地服务
supabase start

# 停止 Supabase 本地服务
supabase stop

# 重置本地数据库并应用迁移
supabase db reset

# 本地运行 Agent Edge Function
supabase functions serve agent

# 查看 Flutter 环境状态
flutter doctor
```

## 测试与质量要求

项目目标测试覆盖率不低于 80%。后续实现功能时应覆盖：

1. **单元测试**：领域模型、推荐排序、约束解析、工具函数。
2. **集成测试**：Supabase 数据访问、RLS、Edge Functions、Agent 契约。
3. **端到端测试**：登录、地图浏览、地点收藏、推荐生成、路线规划等关键流程。

开发要求：

- 新功能优先采用测试驱动开发（RED → GREEN → REFACTOR）。
- 关键业务流程必须有测试或文档支撑。
- 涉及用户数据、认证、数据库、外部 API、文件上传或 Agent 工具调用的变更，需要额外进行安全检查。

## 安全与合规

- 禁止在代码仓库、客户端包或日志中硬编码 API Key、数据库密钥、LLM Key 等敏感信息。
- 外部内容来源必须符合平台规则、接口协议、授权范围和相关法律法规，禁止无授权自动化抓取。
- 推荐结果必须标注来源、更新时间和不确定性，不对营业状态、价格、排队情况作无依据的绝对承诺。
- 用户长期记忆遵循“用户可见、用户可控、最小化保存”原则。
- 写入用户记忆、修改行程等高影响操作应保留用户确认或撤销能力。

## 相关文档

- [`CLAUDE.md`](CLAUDE.md)：项目系统提示词、工程规范和交付标准
- [`docs/项目计划书.md`](docs/项目计划书.md)：产品背景、目标、范围、架构和 MVP 规划

## 当前状态

- 已创建基础目录结构。
- 已添加 Supabase 本地配置。
- 已添加初始数据库迁移。
- 已添加 `agent` Edge Function 占位入口。

后续重点将围绕 Flutter 客户端初始化、Supabase 数据模型、RLS 策略、Agent 结构化契约和 MVP 核心流程逐步推进。
