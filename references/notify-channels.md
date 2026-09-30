# 签到结果通知 · 渠道配置

通知逻辑在仓库里的 `notify.sh`（由 `setup-cloud-repo.sh` 一并推送），工作流签到后调用。

**渠道由 Secret 是否配置决定**：未配的自动跳过，**可同时配多个**，互不影响。

| 渠道 | 需要的 Secret | 怎么建 |
|---|---|---|
| 钉钉群机器人 | `NOTIFY_ROBOT_URL`（+ 可选 `NOTIFY_ROBOT_SECRET`） | 群设置 → 智能群助手 → 添加机器人 → 自定义（Webhook）。安全设置建议选「自定义关键词」填 `WorkBuddy`，比「加签」简单 |
| 企业微信群机器人 | `NOTIFY_ROBOT_URL` | 群 → 群机器人 → 添加 → 复制 Webhook（与钉钉**报文格式相同**，故共用一条通路） |
| 微信（个人） | `NOTIFY_SERVERCHAN_KEY` | Server酱·**Turbo 版**（sct.ftqq.com）微信扫码取 SendKey，key 以 `SCT` 开头；免费 5 条/天、卡片仅显示标题 |
| 邮件 | `SMTP_HOST` `SMTP_PORT` `SMTP_USER` `SMTP_PASS` `SMTP_TO` | `SMTP_PASS` 填**邮箱授权码**（非登录密码）。QQ `smtp.qq.com:465`、163 `smtp.163.com:465`、企业微信邮箱 `smtp.exmail.qq.com:465` |

## 录入方式（隐藏输入，不进命令行历史、不进对话）

```bash
bash scripts/set-secret.sh NOTIFY_SERVERCHAN_KEY   # 交互输入，屏幕不回显
bash scripts/set-secret.sh NOTIFY_ROBOT_URL
bash scripts/set-secret.sh --list                  # 列出已有 Secret 名（值不可读回）
bash scripts/set-secret.sh --delete NOTIFY_ROBOT_URL
```

> GitHub Secrets 只可写、不可读回，因此工具只做「写入」与「列名」。

## 验证渠道

```bash
bash scripts/cloud-notify-test.sh
```

它触发一次云端运行（`workflow_dispatch` + `notify_test=true`）：工作流会**跳过签到**、直接发一条测试通知，
然后把各渠道的发送结果（HTTP 码/成功失败）取回来。

> ⚠️ **真正的验证标准是你的微信/手机收到消息**，日志只是辅助证据。

## Server酱：两个版本不通用（最容易踩的坑）

| 版本 | 注册入口 | key 前缀 | 推送到 |
|---|---|---|---|
| Server酱·**Turbo** | sct.ftqq.com | `SCT` | **微信**（服务号） |
| Server酱**³ (SC3)** | sc3.ft07.com | `sctp` | **独立 App**（不是微信） |

**key 与端点都不通用。** 想在**个人微信**里收消息 → 必须用 Turbo 版（`SCT` 开头）。

`notify.sh` 按 key 前缀**自动选端点**，并在日志里打印识别结果：

```
SCT…   → https://sctapi.ftqq.com/<key>.send                        （微信）
sctp…  → https://<uid>.push.ft07.com/send/<key>.send               （独立 App）
          （uid 取自 sctp{uid}t… 的 {uid} 段，例如 sctp123tXXXX → uid=123）
```

若 key 形如 `sctp{uid}t…` 但 `{uid}` 段不是数字，脚本会明确报错而不是静默失败。

## 推送策略：只在成功与异常时推

| 签到结果 | 是否推送 |
|---|---|
| `code=0` 签到成功 | ✅ 推「WorkBuddy 签到成功」 |
| 兜底那次才签上 | ✅ 推「WorkBuddy **兜底补签成功**」（并点明主干那次没签上） |
| `code=10001` 今日已签到（幂等） | ❌ **静默**（避免每天骚扰） |
| HTTP 401/403 令牌失效、缺少 Secrets 等 | ✅ 推「WorkBuddy 签到异常」 |

通知正文含北京时间与本次运行链接。

## 设计要点（为什么这么写）

- **通知失败不让签到任务失败**（只记 `::warning::`）：签到成功才是关键。
- **未配渠道时把通知正文打印到日志**，便于核对文案是否正确。
- **判定不只看 HTTP 码**：钉钉/企业微信用非法报文时**可能仍返回 HTTP 200**，
  必须再看 body 里的 `errcode`。
- **邮件走 `curl` 直连 SMTP**（`smtps://` / `--ssl-reqd`），不引第三方 action、不加依赖。
- **北京时间用显式 +8 小时偏移计算**，不依赖 `tzdata` —— 因为 Git Bash 不认 `TZ=Asia/Shanghai`，
  会静默给 UTC 却标成北京时间。
- **凭据脱敏**：日志只打印 key 的掩码；Server酱响应体里含 `readkey`（同属凭据）也会被脱敏后才落日志。

## 加/改时间点

推送规则与签到时间绑定在 `cloud/workflow-checkin.yml` 的 `schedule:` 里
（主干 `30 0 * * *` = 北京 08:30，兜底 `30 12 * * *` = 北京 20:30）。
改完用 `bash scripts/push-cloud-files.sh` 同步上去，脚本会先做 YAML 严格自检。
