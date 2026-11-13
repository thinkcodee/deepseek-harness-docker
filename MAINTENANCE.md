# 上游同步与 DSH 版本维护

本文件记录**打包进镜像的 DSH 版本**与**与上游的同步状态**，并给出落后时的处理步骤。
每日自动化会运行 `scripts/sync-upstream.sh` 检查这两件事。

## 当前状态

| 项目 | 值 |
| --- | --- |
| 上游仓库 | https://github.com/smanx/deepseek-harness-docker （`main`） |
| 本仓库 | https://github.com/thinkcodee/deepseek-harness-docker （fork） |
| 同步状态 | 与上游一致（HEAD `9e87934`，ahead 0 / behind 0） |
| 上游最后提交 | 2026-09-09 |
| 已核对版本 | 0.2.2-rc.2（2026-11-13 核对） |
| npm 标签 | `next` = 0.2.2-rc.2，`latest` = 0.2.2-rc.1 |
| 官方最新 tag | `dsh-v0.2.2-rc.2`（deepseek-harness 仓库，2026-11-11 更新） |

## 为什么会「打包版本落后」

`Dockerfile` 以往固定写 `@deepseek-ai/dsh@next`：**镜像里的 DSH 版本由构建那一刻的 npm `next` 决定**，
仓库本身不记录版本。因此只要不在官方发版后重新构建，已有镜像里的 DSH 就一定落后于官方最新，
而仓库里也看不出它落后——这是「版本无锚点」造成的，不是代码本身陈旧。

现在 `Dockerfile` 增加了 `ARG DSH_VERSION`：

- 不传参 → 默认 `next`，行为与原来完全一致（构建即取当时最新）；
- 传参 → 精确锁定，构建可复现。

## 升级到官方新版本

```bash
# 1) 先查官方最新版本（也可跑 scripts/sync-upstream.sh 自动报告）
curl -sS https://registry.npmjs.org/@deepseek-ai/dsh/next | grep -o '"version":"[^"]*"' | head -1

# 2) 重建镜像并锁定版本（例：0.2.2-rc.2）
docker build \
  --build-arg DSH_VERSION=0.2.2-rc.2 \
  -t <你的仓库>/deepseek-harness:0.2.2-rc.2 \
  -t <你的仓库>/deepseek-harness:latest \
  .

# admin 变体（预装进 /opt/dsh，tag 位数即 DSH 版本）
docker build --build-arg DEV_TOOLS=admin --build-arg DSH_VERSION=0.2.2-rc.2 \
  -t <你的仓库>/deepseek-harness:admin-0.2.2-rc.2 .

# 3) 推送
docker push <你的仓库>/deepseek-harness:0.2.2-rc.2
docker push <你的仓库>/deepseek-harness:latest

# 4) 回填本文件的「已核对版本」与核对日期
```

## 与上游保持同步

```bash
cd /root/CodeSpace/deepseek-harness-docker
git fetch upstream main
git log --oneline HEAD..upstream/main     # 看上游新增了什么
git merge --ff-only upstream/main         # 无分叉时快进；有分叉则人工处理
git push origin main                      # 推到自己的 fork
```

上游仓库是自动化同步的（提交信息形如 `Sync deepseek-harness (<sha>)`），
它跟随官方 `deepseek-harness` 仓库演进，所以「上游有新提交」通常意味着 DSH 有兼容性变化，
合并后应重点回归 `proxy/upstream-token.js`（launch token 换取会话 cookie 的链路）与 `manager/`。
