#!/usr/bin/env node
/**
 * 校验 supabase/migrations 下的迁移文件名，防止 CLI 静默跳过或漏推迁移。
 *
 * Supabase CLI 从文件名提取版本号的正则是 `^([0-9]+)_(.*)\.sql$`——只取第一个
 * 下划线之前的数字。`supabase_migrations.schema_migrations.version` 是主键，
 * 因此两个文件解析出同一版本号时，后者会被判定为「已应用」而永远不执行，
 * db push 依然返回成功。本脚本在 CI 中把这类问题变成显式失败。
 *
 * 校验项：
 *   1. 文件名匹配 <数字>_<名称>.sql
 *   2. 版本号恰好 14 位（CLI 约定的时间戳格式）
 *   3. 版本号唯一
 *   4. 不命中 CLI 的首文件跳过规则 ([0-9]{14})_init\.sql
 *   5. 字典序与版本号顺序一致（CLI 按 readdir 字典序加载，不额外排序）
 */

import { readdirSync } from 'node:fs';
import { join } from 'node:path';

const MIGRATIONS_DIR = join('supabase', 'migrations');

/** CLI 提取版本号的正则，与 pkg/migration/list.go 的 migrateFilePattern 一致。 */
const MIGRATE_FILE_PATTERN = /^([0-9]+)_(.*)\.sql$/;

/** CLI 跳过首个迁移文件的规则，与 CLI 二进制中的 `([0-9]{14})_init\.sql` 一致。 */
const INIT_SKIP_PATTERN = /([0-9]{14})_init\.sql/;

const EXPECTED_VERSION_LENGTH = 14;

function collectProblems(files) {
  const problems = [];
  const versionToFile = new Map();

  files.forEach((file, index) => {
    const match = file.match(MIGRATE_FILE_PATTERN);

    if (!match) {
      problems.push(
        `${file}: 文件名不匹配 <timestamp>_name.sql，CLI 会静默跳过该文件。`,
      );
      return;
    }

    const version = match[1];

    if (version.length !== EXPECTED_VERSION_LENGTH) {
      problems.push(
        `${file}: 解析出的版本号为 "${version}"（${version.length} 位），` +
          `应为 ${EXPECTED_VERSION_LENGTH} 位时间戳。CLI 只取第一个下划线前的数字。`,
      );
    }

    const collidesWith = versionToFile.get(version);
    if (collidesWith) {
      problems.push(
        `${file}: 版本号 "${version}" 与 ${collidesWith} 重复。` +
          `schema_migrations.version 是主键，后者会被当作已应用而永不执行。`,
      );
    } else {
      versionToFile.set(version, file);
    }

    // CLI 只对目录中的首个文件应用跳过规则。
    if (index === 0 && INIT_SKIP_PATTERN.test(file)) {
      problems.push(
        `${file}: 作为首个迁移文件命中 CLI 的 init 跳过规则，将不会被应用。` +
          `请改用 _init 之外的名称，例如 _baseline_extensions.sql。`,
      );
    }
  });

  return problems;
}

function checkOrdering(files) {
  const sorted = [...files].sort();
  const isOrdered = files.every((file, index) => file === sorted[index]);
  return isOrdered
    ? []
    : ['迁移文件的字典序与版本号顺序不一致，CLI 会按错误顺序应用迁移。'];
}

function main() {
  let entries;
  try {
    entries = readdirSync(MIGRATIONS_DIR, { withFileTypes: true });
  } catch (error) {
    console.error(`无法读取 ${MIGRATIONS_DIR}: ${error.message}`);
    process.exit(1);
  }

  const files = entries
    .filter((entry) => entry.isFile() && entry.name.endsWith('.sql'))
    .map((entry) => entry.name)
    .sort();

  if (files.length === 0) {
    console.error(`${MIGRATIONS_DIR} 下没有 .sql 迁移文件。`);
    process.exit(1);
  }

  const problems = [...collectProblems(files), ...checkOrdering(files)];

  if (problems.length > 0) {
    console.error('迁移文件名校验失败：\n');
    for (const problem of problems) {
      console.error(`  - ${problem}`);
    }
    console.error('');
    process.exit(1);
  }

  console.log(`迁移文件名校验通过（${files.length} 个文件）：`);
  for (const file of files) {
    const version = file.match(MIGRATE_FILE_PATTERN)[1];
    console.log(`  ${version}  ${file}`);
  }
}

main();
