---
name: workbuddy-cloud-checkin
description: >-
  WorkBuddy 每日积分的「云端自动签到」方案（GitHub Actions），完全不依赖本机开机：把本机登录令牌镜像到你的私有仓库，云端每天北京时间 08:30 自动签到、20:30 兜底补签，令牌由本机每周自动续期，结果可推送微信/钉钉/企业微信/邮件，支持手机端手动补签。适用于「电脑不开机也要签到」「周末假期不断签」「多设备共用一套签到」等场景。触发词：云端签到、自动签到、不开电脑签到、GitHub Actions 签到、签到迁移云端、签到通知、签到失败补签、workbuddy cloud checkin。
agent_created: true
version: "1.0.0"
license: MIT
---

# WorkBuddy 云端自动签到

把每日积分签到搬到 **GitHub 的服务器**上跑：你的电脑关机、休眠、出门旅行，都不影响签到。

> 本技能是**自包含、可分享**的实现：脚本不含任何个人账号、仓库名或凭据，把它复制给任何人，对方按下面三步就能跑起来。

## 它做什么

| 能力 | 说明 |
|---|---|
| 云端定时签到 | 北京时间每天 **08:30** 主干 + **20:30** 兜底（两条 cron，幂等） |
| 不依赖本机 | 签到发生在 GitHub Actions 的 runner 上，本机可以一直关着 |
| 令牌自动续期 | 本机每周把最新令牌镜像上去，令牌寿命约 55 天，余量约 8 倍 |
| 结果通知 | 微信 / 钉钉 / 企业微信 / 邮件，只在「签到成功」和「异常」时推 |
| 手机也能补签 | 哪天没签上，手机浏览器点一下 Run workflow 即可 |
| 零成本 | 私有仓库每月免费 2000 分钟 Actions，本方案约用 18 分钟/月 |

**边界（先说清楚）**：签到接口要求 Bearer 令牌，令牌只能从本机 WorkBuddy 登录态里取。因此"完全不碰电脑"成立的前提是**令牌还没过期**（约 55 天）；只要每 55 天内开过一次 WorkBuddy 桌面端，本机镜像任务就会自动续上，用户全程无感。

## 三步上手（约 10 分钟）

> **不想敲命令？** Windows 下直接**双击技能目录里的 `Start.bat`**，会弹出中文菜单
> （环境自检 / 一键配置 / 立即补签 / 查看记录 / 令牌镜像 / 通知测试 / 令牌体检 / 本机兜底签到），
> 输入序号回车即可。它自带 bash 定位逻辑，**优先使用 WorkBuddy 客户端自带的 PortableGit，无需另外安装 Git**。

### 第 1 步：环境自检

```bash
cd <本技能目录>
bash scripts/preflight.sh
```

逐项告诉你缺什么、怎么补。**必须满足**：Node（读登录态）、GitHub CLI（`gh`）、WorkBuddy 桌面端已登录。

若 `gh` 没装：Windows `winget install --id GitHub.cli -e`｜macOS `brew install gh`。

### 第 2 步：登录 GitHub CLI

在**你自己的终端**里运行（会显示一次性代码并自动开浏览器，请勿把链接加粗复制）：

```bash
gh auth login --hostname github.com --git-protocol https --web
```

> 国内直连 `github.com` 时通时断。**首次配置建议开代理/VPN**，一次就能过；日常签到跑在云端，与本机网络无关。

### 第 3 步：一键配置

```bash
bash scripts/setup-cloud-repo.sh
```

它会自动完成：建**私有**仓库 → 写入工作流与脚本（走 GitHub API，不用 `git push`）→ 提取本机令牌灌入 Secrets（**令牌全程不显示、不落盘**）→ 触发一次运行并回读结论。

看到 `✓ 验收通过：云端签到链路已跑通` 就成了。仓库名默认 `workbuddy-checkin`，可用 `WB_REPO_NAME=<名字>` 改。

**验证判据**：打开仓库 Actions 页，日志里出现「签到成功」或「今日已签到」即通。跑通后你会收到一条通知（若已配渠道）。

## 日常怎么用

配好之后**正常情况你不需要做任何事**。以下命令按需使用：

| 我想…… | 命令 |
|---|---|
| 看今天签没签、最近几天什么情况 | `bash scripts/cloud-run-checkin.sh --status` |
| 立刻在云端补签一次 | `bash scripts/cloud-run-checkin.sh` |
| 看云端手里是哪把令牌、还有效吗 | `bash scripts/cloud-diag.sh` |
| 测通知通不通 | `bash scripts/cloud-notify-test.sh` |
| 改完工作流/通知脚本后同步上去 | `bash scripts/push-cloud-files.sh` |
| 本机令牌变了，推到云端 | `bash scripts/push-token-to-cloud.sh` |

**建议再挂一个「令牌镜像」计划任务**（每周一次，让令牌自动续期，见下节）。不挂也能用，只是令牌约 55 天后会过期，需要手动跑一次 `push-token-to-cloud.sh --force`。

### 令牌无感续期（建议配置）

原理：**桌面端每次运行都会换发一把全新的 accessToken，并把寿命重置为 55 天**。所以只要把本机这把新令牌推上去，云端手里永远是"刚签发的、够用 55 天"的令牌。

```bash
bash scripts/push-token-to-cloud.sh          # 令牌变了才推，没变 1 秒内退出（幂等）
bash scripts/push-token-to-cloud.sh --check  # 只看状态
bash scripts/push-token-to-cloud.sh --force  # 无条件推
```

把它挂成**每周一次**的定时任务即可（WorkBuddy 自动化 / Windows 任务计划 / cron / launchd 都行）。**7 天镜像周期 vs 55 天寿命 = 约 8 倍余量**，漏一次也不会过期；指纹未变时脚本零网络请求。

> 常见疑问：**本机换发新令牌后，云端手里的旧令牌会失效吗？** —— 不会。
> accessToken 是**无状态 JWT**，服务端只按它自身的 `exp` 校验，**没有"单会话互踢"**。
> 实测：两把相隔 51 分钟签发的令牌同时被接受（都返回 200），而同场的人为损坏令牌返回 401（证明接口确实鉴权）。
> 复验工具：`token-fingerprint.sh`（本机）+ `cloud-diag.sh`（云端），两边指纹一比即知是不是同一把。

## 判读结果的三条铁律

日志/通知看错会得出完全相反的结论，这三条务必记住：

1. **只看纯文本行，别被"着色行"骗了。** GitHub 会把 YAML `run:` 块的**每一行源码**着色回显到日志里，于是 `echo "::error::令牌已失效…"` 这种**源码行**看起来就像真报了错。判据：**着色行 = 源码回显，纯文本行 = 真实执行输出**。
   > Windows 上 `gh.exe` 把颜色输出成**字面串** `^[[36;1m`（不是 ESC 字节），所以按 ESC 过滤会静默失效。本技能脚本已同时剔除两种形态。
2. **`code=10001`「今日已签到」不能证明令牌有效。** 它只说明"调用之前已经有人签过了"，而那个人可能是桌面端自己。只有 **`code=0`** 才是"本次调用完成的第一签"。
3. **「没收到通知」≠「没签到」。** 本方案策略是"今日已签到"**静默**（避免每天骚扰）。判断真漏签要看：当天**有没有** `schedule` 运行记录（用 `--status` 看）。

## 手动补签（某天云端没签上）

| 现象 | 判定 | 依据 |
|---|---|---|
| 收到「签到异常」通知 | 明确失败 | `::error::` 分支会推异常通知 |
| 没消息，但当天**有** `schedule` 运行、日志「今日已签到」 | **正常**（已在桌面端签过，云端幂等跳过） | `code=10001` 被静默 |
| 没消息，且当天**没有** `schedule` 运行 | **真漏签**（GitHub 延迟/丢弃、工作流被停用） | 运行列表缺当天记录 |

三条补签路径，按场景选：

1. **人在外面/手机操作**（最常用）：手机浏览器打开
   `https://github.com/<你的账号>/<仓库名>/actions/workflows/checkin.yml` → **Run workflow** → Branch 选 `main` → ⚠️ **两个勾选框都不要勾** → 绿色 Run workflow。
   （勾 `diag` 只做令牌体检**不签到**；勾 `notify_test` 只发测试通知**也跳过签到**。手机上看不到按钮就切"请求桌面网站"。）
2. **本机一条命令**：`bash scripts/cloud-run-checkin.sh`
3. **GitHub 完全不可用时**：本机直连签到，不经云端、效果等价
   ```bash
   bash scripts/local-checkin.sh          # 查状态 → 需要就签到
   bash scripts/local-checkin.sh --quiet  # 静默（适合挂本机定时任务）
   ```

**补签是安全的**：签到接口幂等，当天已签过只会返回 `code=10001`，不重复领取、不算失败。**拿不准签没签时，直接补跑即可。**

## 故障排查

完整的踩坑清单（9 个真实故障：YAML 块标量缩进、Secret 被写成空值、重试循环取值时机、日志过滤静默失效等）见 **`references/troubleshooting.md`**，含症状、根因、修法。

最高频的三种：

| 症状 | 先查这里 |
|---|---|
| Actions 出现 `0s failure`，dispatch 报 422 | 工作流 YAML 缩进（块标量内出现顶格行） |
| 云端报「缺少 Secrets」 | 本机重跑 `push-token-to-cloud.sh --force`（多半是 Secret 被写成空值） |
| 日志报 HTTP 401/403 | 令牌过期：开桌面端 → `push-token-to-cloud.sh --force` |

## 安全须知（重要）

- **令牌等同账号密码**。它只能存在于两处：本机登录态、**私有**仓库的加密 Secret。不要截图、不要贴进任何对话或工单。
- 本技能所有脚本**不打印、不落盘**令牌原文；状态文件只存 SHA-256 指纹与时间。
- 仓库**必须私有**，不要加 collaborator。
- 通知渠道的 SendKey / Webhook / 邮箱授权码同样走 Secret 录入：`bash scripts/set-secret.sh NOTIFY_SERVERCHAN_KEY`（隐藏输入，不进命令行历史）。
- 详见 `references/security.md`。

## 通知渠道

支持微信（个人）、钉钉群、企业微信群、邮件，**渠道由是否配置 Secret 决定**，未配的自动跳过，可同时配多个。配置步骤见 **`references/notify-channels.md`**。

一句话版本：

| 渠道 | 需要配的 Secret |
|---|---|
| 个人微信 | `NOTIFY_SERVERCHAN_KEY`（Server酱·**Turbo** 版，key 以 `SCT` 开头） |
| 钉钉 / 企业微信 | `NOTIFY_ROBOT_URL`（群机器人 Webhook；钉钉加签另配 `NOTIFY_ROBOT_SECRET`） |
| 邮件 | `SMTP_HOST` `SMTP_PORT` `SMTP_USER` `SMTP_PASS` `SMTP_TO` |

配好后用 `bash scripts/cloud-notify-test.sh` 验证，**以手机真的收到消息为准**。

## 文件地图

```
workbuddy-cloud-checkin/
├─ SKILL.md                     ← 你正在读的总览
├─ Start.bat                    ★ Windows 双击启动器（菜单式操作，免敲命令）
├─ scripts/
│  ├─ preflight.sh              环境自检（第一次先跑它）
│  ├─ setup-cloud-repo.sh       ★ 一键配置：建仓库 + 写文件 + 灌 Secret + 验收
│  ├─ extract-token-cloud.sh    从本机登录态取令牌/uid（仅人工复制时用）
│  ├─ push-token-to-cloud.sh    ★ 令牌镜像（挂每周定时任务）
│  ├─ cloud-run-checkin.sh      ★ 手动补签 / 查最近运行
│  ├─ cloud-diag.sh             云端令牌体检（指纹/有效期/鉴权码 + 坏令牌对照）
│  ├─ cloud-notify-test.sh      通知渠道测试
│  ├─ set-secret.sh             Secret 安全录入（隐藏输入）
│  ├─ push-cloud-files.sh       同步 cloud/repo/ 下的文件到仓库（含 YAML 自检）
│  ├─ token-fingerprint.sh      本机令牌指纹（与云端体检结果对照用）
│  ├─ local-checkin.sh          本机直连签到（GitHub 不可用时的兜底）
│  ├─ lib-common.sh             公共库：gh/node/python 定位、仓库解析、跨平台工具
│  ├─ _gen_start_bat.py         生成 Start.bat（改菜单请改它再重跑；保证 CRLF+GBK）
│  └─ decrypt-token.js / decrypt-atrest.js   本机登录态解密链
├─ cloud/
│  ├─ workflow-checkin.yml      GitHub Actions 工作流（唯一源文件）
│  └─ repo/                     会被推送到仓库的文件
│     ├─ notify.sh              通知逻辑（多渠道 + 脱敏）
│     ├─ diag-token.sh          云端令牌体检逻辑
│     └─ README.md              仓库自身说明（给未来的你看）
├─ references/
│  ├─ troubleshooting.md        踩坑清单（10 个真实故障 + 网络现实）
│  ├─ notify-channels.md        通知渠道配置详解
│  ├─ how-it-works.md           原理：令牌寿命、幂等、cron 语义、为什么不做云端自续期
│  ├─ security.md               安全边界与凭据生命周期
│  └─ making-a-skill-shareable.md  把「自用技能」改造成可分享版的方法论（本技能的诞生过程）
└─ state/                       运行时状态（指纹、目标仓库名；分享时请勿带上）
```

**关于 `state/`**：`setup-cloud-repo.sh` 会把"目标仓库"记在 `state/cloud-repo.txt`，后续脚本便无需任何参数。反过来，所有脚本都支持 `WB_REPO=<账号>/<仓库名>` 显式指定——**把本技能复制给别人时，删掉 `state/` 即可，对方跑一次 setup 就会生成自己的**。

## 部署到哪些平台

- **目标平台**：GitHub Actions（ubuntu-latest runner）。工作流本身跨平台，无需改动。
- **配置端（运行本技能脚本的机器）**：Windows（Git Bash）/ macOS / Linux 均可。脚本已处理平台差异：`gh`/`node`/`python` 的定位、`sha256sum` 与 `base64` 的参数差异、Git Bash 的路径转换与 ANSI 颜色字面串、无 `tzdata` 时的北京时间计算。
  - **Windows 不需要另外装 Git**：WorkBuddy 客户端自带 PortableGit（`%USERPROFILE%\.workbuddy\binaries\PortableGit\versions\<版本>\bin\bash.exe`，国际版在 `.workbuddy-ai` 下），`Start.bat` 会自动找到它。
  - ⚠️ 该目录下的 `versions\current` 是**版本标记文件**、不是目录，不能拼 `current\bin\bash.exe`，必须遍历版本目录 —— 启动器已按此实现。
- **无代理的备选**：若长期无法访问 GitHub，可改用腾讯云函数 SCF / 阿里云 FC 的定时触发器（国内直连稳定）。本技能的 `cloud/workflow-checkin.yml` 与 `cloud/repo/notify.sh` 逻辑（取令牌 → 调接口 → 通知）可直接移植。
