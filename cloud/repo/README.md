# WorkBuddy Daily Checkin（云端自动签到）

这个仓库由 `workbuddy-cloud-checkin` 技能自动创建与维护，作用是：**每天在 GitHub 的服务器上替你完成 WorkBuddy 每日签到**，因此你的电脑可以不开机。

> ⚠️ 本仓库**必须保持私有**。它会存放一个等同账号密码的令牌（仅以加密 Secret 形式存在）。

## 它是怎么跑的

```
GitHub Actions（每天 北京 08:30 主干 + 20:30 兜底）
  └─ curl 签到 API（Bearer <Secret 里的令牌>）
       ├─ code=0      → 签到成功 → 发通知
       ├─ code=10001  → 今日已签到（幂等）→ 静默
       └─ HTTP 401    → 令牌过期 → 发「签到异常」通知
```

签到接口本身**幂等**：重复调用不会重复领取，也不会报错 —— 所以"兜底 cron"和"手动补签"都是零风险的。

## 需要的 Secrets

| Secret | 必需 | 说明 |
|---|---|---|
| `WB_CHECKIN_TOKEN` | ✅ | accessToken。由本机 `push-token-to-cloud.sh` 自动写入，**不要手工维护** |
| `WB_CHECKIN_UID` | ✅ | 账号 uid（用于鉴权头） |
| `NOTIFY_SERVERCHAN_KEY` | 可选 | 微信推送（Server酱·Turbo 版，key 以 `SCT` 开头） |
| `NOTIFY_ROBOT_URL` | 可选 | 钉钉 / 企业微信群机器人 Webhook |
| `NOTIFY_ROBOT_SECRET` | 可选 | 钉钉机器人「加签」密钥（安全设置选加签时才需要） |
| `SMTP_HOST` `SMTP_PORT` `SMTP_USER` `SMTP_PASS` `SMTP_TO` | 可选 | 邮件通知（`SMTP_PASS` 填**授权码**） |
| `WB_TEST_OLD_TOKEN` | 可选 | **仅对照实验用**：一把签发更早的令牌，用于验证"换发新令牌后旧令牌是否失效"。平时不需要 |

未配置的通知渠道会被自动跳过，可同时配多个。

## 触发方式

| 方式 | 何时发生 |
|---|---|
| 定时（主干） | 每天北京时间 **08:30**（UTC 00:30，cron `30 0 * * *`） |
| 定时（兜底） | 每天北京时间 **20:30**（UTC 12:30，cron `30 12 * * *`） |
| 手动 | Actions → **Run workflow**（网页或手机浏览器均可） |

> GitHub 定时任务有 5~30 分钟延迟属正常，高负载时排队中的 job 甚至可能被丢弃 —— 这正是需要兜底那条的原因。
> 想增减时间点：改本机技能里的 `cloud/workflow-checkin.yml` 后跑 `push-cloud-files.sh` 同步（脚本会做 YAML 严格自检）。

## 手动补签（哪天没签上时）

**第一步：分清"真漏签"和"正常静默"** —— 两者都表现为"没收到消息"：

| 现象 | 判定 | 依据 |
|---|---|---|
| 收到「WorkBuddy 签到异常」 | **明确失败** | 走了 `::error::` 分支 |
| 无消息，但当天**有** `schedule` 运行、日志是「今日已签到」 | **正常**（当天已在桌面端签过，云端被静默） | `code=10001` |
| 无消息，且当天**没有** `schedule` 运行 | **真漏签**（GitHub 延迟/丢弃、工作流被停用） | 运行列表缺当天记录 |

**第二步：补签**（推荐手机操作，只要手机能上网）

1. 打开 `https://github.com/<你的账号>/<本仓库>/actions/workflows/checkin.yml`
2. 右上 **Run workflow**
3. Branch 选 `main`
4. ⚠️ **`diag` 与 `notify_test` 两个勾选框都保持不勾**
5. 绿色 **Run workflow**

| 勾选情况 | 实际会跑什么 |
|---|---|
| 都不勾 ✅ | **正常签到**（要的就是这个） |
| 勾了 `diag` | 只跑令牌体检（`if: ${{ inputs.diag }}`），**不签到** |
| 勾了 `notify_test` | 签到步骤被跳过（`if: ${{ !inputs.notify_test }}`），只发一条测试通知 |

> 手机浏览器若看不到按钮，切换成"请求桌面网站"。

**第三步：看结果**

| 日志行（真实输出） | 含义 | 下一步 |
|---|---|---|
| `::notice::签到成功，领取 N 积分，连续 M 天` | 补签成功 | 完成 |
| `本次结果：今日已签到…` | 幂等重复（按策略静默） | 完成 |
| `::error::令牌已失效（HTTP 401/403）` | **补签无用** | 到本机跑 `push-token-to-cloud.sh --force` 后再补 |
| `::error::缺少 Secrets` | Secret 值为空 | 同上 |

> ⚠️ **判读只看纯文本行。** 带颜色的行是 GitHub 回显的 `run:` 块**源码**，
> 其中 `echo "::error::令牌已失效…"` 只是脚本内容、不是结果。

## 令牌续期（正常无需人工）

accessToken 寿命约 **55 天**。本机技能里的 `push-token-to-cloud.sh` 会**每周**把最新令牌镜像到本仓库 Secrets
（桌面端每次运行都会换发新令牌并重置 55 天寿命），因此正常情况下永远不会走到过期。

想确认云端手里是哪把令牌、还有多久（在**本机技能目录**下运行）：

```bash
bash scripts/cloud-diag.sh
```

输出含：指纹（前 16 位）、签发时间、到期时间、剩余天数、`checkin-status` 的真实 HTTP 码，
以及**人为损坏令牌的对照结果**（应 401，用来证明接口确实鉴权）。
与**本机** `bash scripts/token-fingerprint.sh` 的指纹比对一致 → 云端持有的就是这一把。

## 排错

| 症状 | 原因 | 处理 |
|---|---|---|
| Actions 出现 `0s failure`，dispatch 报 422 | 工作流 YAML 缩进错误（块标量内出现顶格行） | 本机用 `push-cloud-files.sh` 重新同步（会先自检） |
| 云端报「缺少 Secrets」 | Secret 被写成空值 | 本机 `push-token-to-cloud.sh --force` |
| 日志报 HTTP 401/403 | 令牌过期 | 打开 WorkBuddy 桌面端 → `push-token-to-cloud.sh --force` |
| 通知没收到，但签到正常 | 当日是 `code=10001`（按策略静默） | 属正常；想验证渠道用 `cloud-notify-test.sh` |
| 网页看不到 Run workflow | 工作流 YAML 解析失败或尚未被注册 | 同上第 1 行处理 |

## 安全

- 令牌只以**加密 Secret** 形式存在，Secret 只能写、不能读回。
- 工作流权限已最小化（`contents: read`），不引第三方 action。
- 通知脚本只打印凭据掩码，日志不泄露 SendKey / Webhook / 授权码。
- **不要把这个仓库设为 public，也不要添加 collaborator。**
