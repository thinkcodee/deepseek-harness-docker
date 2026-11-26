#!/usr/bin/env bash
# 解析「要打包的 DSH 版本」→ 具体版本号（可复现、可追溯）
#
# 用法：
#   scripts/resolve-dsh-version.sh <输入>            # 只打印解析结果
#   scripts/resolve-dsh-version.sh <输入> --github-output   # 追加写入 $GITHUB_OUTPUT
#
# 输入可以是：
#   auto                取 npm 上**发布最新**的版本（含 alpha / beta / rc 等预发布通道）
#   latest / next / alpha / beta / <任意 dist-tag>   取该 dist-tag 指向的版本
#   0.2.3-alpha.2       具体版本号，直接使用
#   empty               等同 auto
#
# 为什么要有 auto：
#   dist-tag 是「官方推荐位」，会随官方策略移动。next/latest 指向的版本并不总是最新发布的，
#   例如官方可能只给 alpha 通道打 tag，而更高版本的 rc/正式版还没被任何 tag 指向。
#   定时构建若只跟 next，就会漏掉官方已发布的新版本。auto 直接按 semver 优先级 + 发布时间
#   取最新，保证「官方一发版就自动跟上」，同时仍然解析成具体版本号以保证可复现。
#
# 输出（--github-output 时）：
#   version=<具体版本号>
#   channel=<auto|dist-tag|exact>       解析方式，便于日志与回填
#   dist_tag=<解析时命中的 dist-tag>    auto / 具体版本时为空
#
# 退出码：0 成功；1 解析失败 / 版本不存在。

set -euo pipefail

PKG="${DSH_PACKAGE:-@deepseek-ai/dsh}"
REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"

input="${1:-auto}"
mode="stdout"
case "${2:-}" in
  "") mode="stdout" ;;
  --github-output) mode="github-output" ;;
  *) echo "用法: $0 <auto|dist-tag|具体版本> [--github-output]" >&2; exit 1 ;;
esac

input="$(printf '%s' "$input" | tr -d '[:space:]')"
[ -z "$input" ] && input="auto"

fetch_pkg_meta() {
  curl -fsSL --max-time 60 "$REGISTRY/$PKG"
}

# 从 npm packument 里挑出「发布最新」的版本：
#   1) 排除 deprecated 版本；
#   2) 排除 0.0.0-* / 0.0.0 之类的占位版本；
#   3) 按 semver 优先级比较（正式版 > rc > beta > alpha），同 core 时发布时间新的优先。
resolve_latest() {
  fetch_pkg_meta | node -e '
    let s = "";
    process.stdin.on("data", d => s += d).on("end", () => {
      const j = JSON.parse(s);
      const versions = j.versions || {};
      const time = j.time || {};
      const parse = (v) => {
        const m = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/.exec(v);
        if (!m) return null;
        return { core: [Number(m[1]), Number(m[2]), Number(m[3])], pre: m[4] ? m[4].split(".") : [] };
      };
      // 预发布通道优先级：正式版 > rc > beta > alpha > 其它
      const rank = (pre) => {
        if (!pre.length) return 0;
        const head = pre[0].toLowerCase();
        if (head.startsWith("rc")) return 1;
        if (head.startsWith("beta")) return 2;
        if (head.startsWith("alpha")) return 3;
        return 4;
      };
      const cmp = (a, b) => {
        for (let i = 0; i < 3; i++) {
          if (a.core[i] !== b.core[i]) return a.core[i] - b.core[i];
        }
        if (!a.pre.length && b.pre.length) return 1;
        if (a.pre.length && !b.pre.length) return -1;
        const ra = rank(a.pre), rb = rank(b.pre);
        if (ra !== rb) return rb - ra;
        for (let i = 0; i < Math.max(a.pre.length, b.pre.length); i++) {
          const x = a.pre[i], y = b.pre[i];
          if (x === undefined) return -1;
          if (y === undefined) return 1;
          const nx = /^\d+$/.test(x) ? Number(x) : null;
          const ny = /^\d+$/.test(y) ? Number(y) : null;
          if (nx !== null && ny !== null) { if (nx !== ny) return nx - ny; continue; }
          if (nx !== null) return -1;
          if (ny !== null) return 1;
          if (x !== y) return x < y ? -1 : 1;
        }
        return 0;
      };
      const candidates = Object.keys(versions)
        .filter(v => !versions[v].deprecated)
        .filter(v => parse(v))
        .filter(v => !/^0\.0\.0(-|$)/.test(v));
      if (!candidates.length) { console.error("没有可用版本"); process.exit(1); }
      candidates.sort((a, b) => {
        const c = cmp(parse(a), parse(b));
        if (c !== 0) return c;
        const ta = time[a] || "", tb = time[b] || "";
        if (ta !== tb) return ta < tb ? -1 : 1;
        return a < b ? -1 : 1;
      });
      process.stdout.write(candidates[candidates.length - 1]);
    });
  '
}

resolve_dist_tag() {
  local tag="$1"
  fetch_pkg_meta | node -e '
    let s = "";
    process.stdin.on("data", d => s += d).on("end", () => {
      const j = JSON.parse(s);
      const tag = process.argv[1];
      const v = (j["dist-tags"] || {})[tag];
      if (!v) { console.error("npm 上没有 dist-tag: " + tag); process.exit(1); }
      process.stdout.write(v);
    });
  ' "$tag"
}

version_exists() {
  local v="$1"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 "$REGISTRY/$PKG/$v")"
  [ "$code" = "200" ]
}

channel=""
dist_tag=""

case "$input" in
  auto|latest-published|newest)
    version="$(resolve_latest)"
    channel="auto"
    ;;
  *)
    # 具体版本号（含预发布后缀）优先按版本处理
    if printf '%s' "$input" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
      version="$input"
      channel="exact"
    else
      version="$(resolve_dist_tag "$input")"
      channel="dist-tag"
      dist_tag="$input"
    fi
    ;;
esac

if ! version_exists "$version"; then
  echo "::error::DSH 版本不存在：$version（$REGISTRY/$PKG 返回非 200）" >&2
  exit 1
fi

case "$channel" in
  auto)     echo "auto（npm 上发布最新的版本，含 alpha/beta/rc）→ $version" ;;
  dist-tag) echo "npm dist-tag '$dist_tag' → $version" ;;
  exact)    echo "指定具体版本 → $version" ;;
esac

if [ "$mode" = "github-output" ]; then
  {
    echo "version=$version"
    echo "channel=$channel"
    echo "dist_tag=$dist_tag"
  } >> "$GITHUB_OUTPUT"
fi

echo "$version"
