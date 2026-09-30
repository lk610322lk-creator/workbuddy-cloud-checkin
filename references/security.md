# 安全边界与凭据生命周期

本方案要搬运一个**等同账号密码**的凭据（accessToken）到云端。这份文档说明它的边界、约束，以及出事时怎么办。

## 一、核心红线

1. **accessToken 等同账号密码。** 它只能存在于两处：
   - 本机 WorkBuddy 登录态文件（客户端自己管理）
   - **私有**仓库的 GitHub Actions Secrets（加密存储）
2. **不要截图、不要贴进任何 AI 对话 / 工单 / 聊天窗口。** 若已发生，立即按第「四」节轮换。
3. **仓库必须私有，不要加 collaborator。** 私有仓库的 Secret 对其他人不可见；公开仓库则不成立。
4. **不要把令牌写进代码、日志、commit 或 issue。**

## 二、本技能如何保证"不泄露"

| 措施 | 实现 |
|---|---|
| 不打印令牌原文 | `extract-token-cloud.sh` 只在**你显式运行**且不带 `--raw` 时打印（且带醒目安全提示，供人工复制）；其余脚本一律走 `--raw` 管道 |
| 不落盘 | 令牌从不写文件；`state/token-push.state` 只存 **SHA-256 指纹**与时间戳 |
| 管道而非参数 | 写 Secret 时用 stdin 喂入（`retry_stdin`），**不经过 argv**，避免进程列表可见 |
| 输入不回显 | `set-secret.sh` 用 `read -rs` 隐藏输入，不进命令行历史 |
| 日志脱敏 | `notify.sh` 只打印 key 的掩码；Server酱响应体里的 `readkey`（同属凭据）也会脱敏后才落日志 |
| 存在性佐证 | 推送前打印令牌**长度**（如 `令牌长度 1319 字符`）作为非敏感的成功证据，替代"打印令牌确认" |
| 推送前校验 | 令牌长度 > 100、uid 非空，任一异常直接中止，**云端保持原值**（不会写成中间态/空值） |
| 幂等记账 | 指纹未变时零网络请求直接退出，减少凭据在网络上暴露的次数 |

**验证脚本自身是否泄露**：把终端输出贴进 `grep` 搜 `eyJ`（JWT 固定开头）应无命中。

## 三、凭据生命周期

| 阶段 | 说明 |
|---|---|
| 获取 | `extract-token-cloud.sh` 从本机登录态解密取出（支持明文态 / 加密态 / 旧版 Electron 三种存储形态） |
| 存储 | GitHub Actions Secrets（加密），Secret 名 `WB_CHECKIN_TOKEN` / `WB_CHECKIN_UID` |
| 使用 | 仅 Actions runner 在运行时注入环境变量，用于 `Authorization: Bearer` 头 |
| 寿命 | 约 **55 天**（`exp - iat`），每次桌面端运行都会刷新并重置 |
| 续期 | 本机 `push-token-to-cloud.sh` 每周镜像新令牌（幂等） |
| 轮换 | 见下节 |
| 销毁 | 删除仓库 → Secret 随之消失；或在仓库 Settings 里删除该 Secret |

## 四、怀疑凭据泄露时怎么办（轮换流程）

1. **改密码 / 重新登录 WorkBuddy 桌面端** —— 这会换发一把全新的 accessToken，
   同时使旧令牌在服务端失去意义（若服务端支持凭据吊销）。
2. 在 GitHub 仓库里**删除**旧 Secret：
   ```bash
   bash scripts/set-secret.sh --delete WB_CHECKIN_TOKEN
   ```
3. 重新推送当前令牌：
   ```bash
   bash scripts/push-token-to-cloud.sh --force
   ```
4. 清空本机状态文件（消除旧指纹记录）：
   ```bash
   rm -f state/token-push.state
   ```
5. 若怀疑通知渠道凭据也泄露，按同样方式删除并重建
   （钉钉/企微机器人 Webhook 可在群设置里"重置"；Server酱 SendKey 可在后台重置；邮箱授权码可在邮箱设置里吊销）。

> **顺序很重要**：先换令牌（使旧的失效），再更新云端；否则中间窗口期云端会持续用旧令牌调用并报错。

## 五、Actions 侧的权限面

工作流已按最小权限配置：

```yaml
permissions:
  contents: read      # 只需读取仓库内的 notify.sh / diag-token.sh
```

- 不申请 `write` 权限，不使用 PAT，不回写仓库。
- 不引第三方 action（`actions/checkout` 之外无外部依赖），降低供应链风险。
- 邮件走 `curl` 直连 SMTP，不引第三方依赖。

## 六、GitHub Secret 的性质（需要知道的事实）

- Secret **只能写、不能读回** —— 连你自己在网页上也看不到原值，只能覆盖或删除。（这是安全设计，不是缺陷。）
- Secret 值会出现在 runner 的环境变量里；若工作流被改成 `echo` 它，日志里会被 GitHub 自动打码 `***`
  —— **但不要依赖这个保护**（打码是基于值匹配的尽力而为）。
- Fork 的仓库、PR 来自 fork 时 Secret 不会注入（这是 GitHub 的保护机制）。

## 七、公开仓库的额外风险

若把仓库设为 public：

1. **Secret 仍加密**，不会直接暴露；但
2. GitHub 的"60 天不活跃自动停用定时工作流"规则**只针对 public 仓库**，会给本方案带来额外失败模式；
3. 工作流日志、运行记录对所有人可见，社交工程与探测面变大。

**结论：没有理由用 public。保持 private。**

## 八、给"分享这套技能给他人"的提示

本技能刻意不含任何个人凭据与仓库名，复制给他人是安全的。但请注意：

- **不要连带分享 `state/` 目录**：它记录了你自己的目标仓库名（`state/cloud-repo.txt`）
  与令牌指纹（`state/token-push.state`）。指纹无法反推令牌，但仓库名属于个人信息。
- 对方需要**自己的** GitHub 账号与**自己的** WorkBuddy 登录态 —— 令牌不能共用、也不该共用。
- 对方按 `SKILL.md` 的「三步上手」跑一遍即可，全程约 10 分钟。
