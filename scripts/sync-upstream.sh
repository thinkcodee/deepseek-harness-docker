#!/usr/bin/env bash
# 上游同步 + 版本漂移检查（供每日自动化调用，也可手工执行）
#
# 做三件事：
#   1. 拉取 smanx/deepseek-harness-docker 的 main，报告本地 fork 是领先 / 落后 / 一致；
#   2. 若落后且工作区干净，自动快进合并（--ff-only，不会产生多余 merge 提交）；
#   3. 查询 npm 上 @deepseek-ai/dsh 的 next / latest 版本，与本仓库记录版本比对，报告是否落后。
#
# 用法：
#   scripts/sync-upstream.sh            # 同步 + 报告
#   scripts/sync-upstream.sh --no-pull  # 只报告，不改动仓库
# 退出码：0 正常（无论是否落后）；1 同步失败；2 工作区不干净无法合并。

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR" || exit 1

UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/smanx/deepseek-harness-docker.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
VERSION_DOC="$REPO_DIR/MAINTENANCE.md"
DO_PULL=1
[ "${1:-}" = "--no-pull" ] && DO_PULL=0

echo "=== [1/3] 上游同步检查 ==="
if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  echo "添加上游远端 $UPSTREAM_REMOTE -> $UPSTREAM_URL"
  git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL" || exit 1
fi

if ! git fetch --quiet "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"; then
  echo "!! 拉取上游失败（网络或权限问题）"; exit 1
fi

LOCAL_SHA=$(git rev-parse HEAD)
UPSTREAM_SHA=$(git rev-parse "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH")
BEHIND=$(git rev-list --count "HEAD..$UPSTREAM_REMOTE/$UPSTREAM_BRANCH")
AHEAD=$(git rev-list --count "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH..HEAD")
echo "本地 HEAD      : ${LOCAL_SHA:0:8}"
echo "上游 $UPSTREAM_BRANCH  : ${UPSTREAM_SHA:0:8}"
echo "落后 $BEHIND 个提交，领先 $AHEAD 个提交"

if [ "$BEHIND" -gt 0 ]; then
  echo "--- 待同步提交 ---"
  git log --oneline "HEAD..$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" | head -20
  if [ "$DO_PULL" -eq 0 ]; then
    echo "(--no-pull：跳过合并)"
  elif [ -n "$(git status --porcelain)" ]; then
    echo "!! 工作区有未提交改动，跳过自动合并（请先提交或 stash）"; exit 2
  else
    if git merge --ff-only "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"; then
      echo "已快进合并到 ${UPSTREAM_SHA:0:8}"
    else
      echo "!! 无法快进（本地有分叉提交），需人工 merge/rebase"; exit 2
    fi
  fi
else
  echo "已与上游一致，无需同步。"
fi

echo
echo "=== [2/3] 官方 DSH 版本检查 ==="
NEXT_VER=$(curl -sS --max-time 20 https://registry.npmjs.org/@deepseek-ai/dsh/next \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).version)}catch{console.log("")}})')
LATEST_VER=$(curl -sS --max-time 20 https://registry.npmjs.org/@deepseek-ai/dsh/latest \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).version)}catch{console.log("")}})')
echo "npm next   : ${NEXT_VER:-查询失败}"
echo "npm latest : ${LATEST_VER:-查询失败}"

RECORDED=""
if [ -f "$VERSION_DOC" ]; then
  RECORDED=$(grep -m1 '已核对版本' "$VERSION_DOC" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?' | head -1)
fi
echo "本仓库记录 : ${RECORDED:-未记录}"

echo
echo "=== [3/3] 结论 ==="
if [ -n "$RECORDED" ] && [ -n "$NEXT_VER" ] && [ "$RECORDED" != "$NEXT_VER" ]; then
  echo "★ 版本落后：仓库记录 $RECORDED，官方 next 已是 $NEXT_VER"
  echo "  处理：1) 更新 MAINTENANCE.md 的「已核对版本」；"
  echo "        2) 重新构建镜像（见 MAINTENANCE.md 的构建命令，可传 --build-arg DSH_VERSION=$NEXT_VER 锁定）；"
  echo "        3) 推送新 tag 到 Docker Hub / GHCR。"
else
  echo "版本无需处理（记录与官方 next 一致，或查询失败）。"
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "工作区当前有未提交改动："
  git status --short | head -20
fi
exit 0
