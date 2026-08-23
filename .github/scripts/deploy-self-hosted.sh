#!/usr/bin/env bash
#
# 在自建 Supabase 服务器上执行部署。由 .github/workflows/supabase-deploy.yml
# 经 SSH 以 `bash -s` 方式传入执行，不在服务器上留存副本。
#
# 依赖（需预先在服务器上准备）：
#   - supabase CLI（自建实例用 db push --db-url，不需要 link/登录）
#   - docker，且当前用户有权限 restart / inspect EDGE_CONTAINER
#   - node（可选，缺失时降级为文本判定）
#
# 服务器配置文件 /etc/savorseek/deploy.env（root 属主，部署用户组可读，chmod 640）：
#   SUPABASE_DB_URL=postgresql://postgres:PASS@127.0.0.1:5432/postgres
#   EDGE_CONTAINER=supabase-edge-functions
# 放在服务器而非 GitHub Secrets，数据库口令便不经过 CI，也不会出现在
# 进程列表里。口令含 @ : / ? # % & 时必须 percent-encode。
# 必须用直连端口（5432），transaction pooler 不支持迁移所需的事务内 DDL。
#
# 由调用方通过环境变量传入：
#   APP_DIR     服务器上存放 supabase/ 的目录
#   PAYLOAD     ~/.cache/savorseek 下的部署包文件名
#   TARGET_SHA  本次部署的 commit SHA（用于日志与留痕）

set -euo pipefail

log() { printf '\n=== %s ===\n' "$1"; }
fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

CONFIG_FILE=/etc/savorseek/deploy.env
PAYLOAD_DIR="$HOME/.cache/savorseek"

for name in APP_DIR PAYLOAD TARGET_SHA; do
  [ -n "${!name:-}" ] || fail "缺少环境变量 $name"
done

command -v supabase >/dev/null || fail '服务器上未找到 supabase CLI'
command -v docker >/dev/null || fail '服务器上未找到 docker'

log '读取服务器配置'
[ -r "$CONFIG_FILE" ] || fail "无法读取 $CONFIG_FILE，请参照本脚本注释创建"
# shellcheck disable=SC1090
set -a; . "$CONFIG_FILE"; set +a
for name in SUPABASE_DB_URL EDGE_CONTAINER; do
  [ -n "${!name:-}" ] || fail "$CONFIG_FILE 中缺少 $name"
done
echo "APP_DIR=$APP_DIR  EDGE_CONTAINER=$EDGE_CONTAINER  SHA=$TARGET_SHA"

payload_path="$PAYLOAD_DIR/$PAYLOAD"
[ -f "$payload_path" ] || fail "找不到部署包 $payload_path"
stage=''
# 无论成败都清掉部署包与解包目录，避免 ~/.cache 无限堆积。
trap 'rm -rf "$payload_path" ${stage:+"$stage"}' EXIT

log '解包'
stage="$(mktemp -d)"
tar xzf "$payload_path" -C "$stage"
[ -d "$stage/supabase/migrations" ] || fail '部署包缺少 supabase/migrations'

log '校验迁移文件名'
# 与 runner 上同一份脚本，随部署包一起送来。
if command -v node >/dev/null; then
  (cd "$stage" && node .github/scripts/check-migration-names.mjs)
else
  echo '跳过：服务器上未安装 node'
fi

log "同步到 $APP_DIR"
mkdir -p "$APP_DIR" || fail "无法创建 $APP_DIR，请确认目录属主是当前用户"
# --delete 让服务器上的 supabase/ 精确等于本次 commit，删掉的迁移与函数不残留。
# edge-runtime 容器挂载的是这个目录，所以原地覆盖而非换目录软链。
if command -v rsync >/dev/null; then
  rsync -a --delete "$stage/supabase/" "$APP_DIR/supabase/"
else
  rm -rf "$APP_DIR/supabase"
  cp -a "$stage/supabase" "$APP_DIR/supabase"
fi
# 留痕当前部署的版本，排障时不必翻 Actions 日志。
printf '%s\n' "$TARGET_SHA" > "$APP_DIR/.deployed-sha"

cd "$APP_DIR" || fail "无法进入 $APP_DIR"

log '预演迁移'
supabase db push --db-url "$SUPABASE_DB_URL" --dry-run

log '应用迁移'
supabase db push --db-url "$SUPABASE_DB_URL" --yes

log '核对无遗留迁移'
# db push 的结构化输出有两种形态：--output-format json 为扁平对象，
# stream-json 为 {type:"result",data:{...}}。两者都要兼容。
# 同时 stdout 混有非 JSON 的提示行，必须逐行筛选而非整体 parse。
push_state="$(supabase db push --db-url "$SUPABASE_DB_URL" --dry-run --output-format json 2>/dev/null || true)"
printf '%s\n' "$push_state"

if command -v node >/dev/null; then
  printf '%s' "$push_state" | node -e "
    let raw = '';
    process.stdin.on('data', (chunk) => { raw += chunk; });
    process.stdin.on('end', () => {
      const objects = raw
        .split('\n')
        .filter((line) => line.trim().startsWith('{'))
        .map((line) => { try { return JSON.parse(line); } catch { return null; } })
        .filter(Boolean);
      const last = objects.reverse()[0];
      if (!last) {
        console.error('无法解析 db push 输出，跳过核对。');
        process.exit(0);
      }
      const payload = last.type === 'result' ? last.data : last;
      if (payload.upToDate === true) {
        console.log('迁移历史已是最新。');
        process.exit(0);
      }
      console.error('仍有待应用的迁移: ' + (payload.migrations ?? []).join(', '));
      process.exit(1);
    });
  "
else
  # 无 node 时退化为文本判定。CLI 的措辞是 "... is up to date."
  grep -qi 'up to date' <<<"$push_state" || fail 'db push 后仍有待应用的迁移'
fi

log "重启 $EDGE_CONTAINER 加载 Edge Functions"
# 自建实例的 edge-runtime 从挂载的 supabase/functions 读取代码，
# 目录同步后重启容器即可生效；CLI 的 functions deploy 只能用于官方云。
docker inspect "$EDGE_CONTAINER" >/dev/null 2>&1 \
  || fail "找不到容器 $EDGE_CONTAINER，请确认 $CONFIG_FILE 中的 EDGE_CONTAINER"
docker restart "$EDGE_CONTAINER"

# 确认容器重启后真的处于运行状态，而不是起来就崩。
sleep 5
state="$(docker inspect -f '{{.State.Status}}' "$EDGE_CONTAINER")"
echo "容器状态: $state"
if [ "$state" != 'running' ]; then
  docker logs --tail 50 "$EDGE_CONTAINER" 2>&1 || true
  fail "$EDGE_CONTAINER 重启后状态为 $state"
fi

log '部署完成'
