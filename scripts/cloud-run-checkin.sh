#!/usr/bin/env bash
# ============================================================
# WorkBuddy 签到 · 手动触发「云端」补签
#
# 场景：某天云端自动签到没成功，想立刻在云端补跑一次。常见成因：
#   · GitHub 定时任务漏跑 / 大幅延迟（schedule 事件本身不保证准时）
#   · runner 抽风、任务被判定失败
#   · 令牌 401/403 失效（会推「签到异常」通知）→ 这种情况补跑也没用，
#     必须在本机打开桌面端后跑 push-token-to-cloud.sh --force（见 SKILL.md 排错表）
#
# 用法：
#   bash scripts/cloud-run-checkin.sh             # 触发补签并等待结果（约 30~90s）
#   bash scripts/cloud-run-checkin.sh --status    # 只看最近 8 次运行，不触发
#   bash scripts/cloud-run-checkin.sh --no-wait   # 只触发，不等结果
#
# 幂等性：签到接口本身幂等 —— 当天已签过会返回 code=10001「今日已签到」，
#         不会重复领取，也不报错。所以「拿不准今天签没签」时直接补跑是安全的。
#
# 等价入口（详见 SKILL.md「手动补签」一节）：
#   · GitHub 网页 / 手机浏览器：仓库 → Actions → WorkBuddy Daily Checkin
#     → Run workflow → 【两个勾选框都不要勾】→ Run workflow
#     （勾了 diag 会只做令牌体检、跳过签到；勾了 notify_test 只发测试通知、也跳过签到）
#   · 本机直接签到、完全不依赖云端：bash scripts/checkin.sh
#
# ⚠️ 安全：只读日志，不打印任何 Secret 的值。
# ============================================================
set -uo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib-common.sh
. "$SCRIPT_DIR/lib-common.sh"
WORKFLOW_NAME="${WB_WORKFLOW:-WorkBuddy Daily Checkin}"

MODE="run"
case "${1:-}" in
  --status)  MODE="status" ;;
  --no-wait) MODE="run-nowait" ;;
  "")        MODE="run" ;;
  -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *)         printf '未知参数：%s（可用 --status / --no-wait / --help）\n' "$1"; exit 2 ;;
esac

say() { printf '%s\n' "$*"; }

# ---------- 定位 gh ----------
GH="$(wb_find_gh || true)"
[ -n "$GH" ] || { wb_need_gh_msg; exit 1; }

# 目标仓库：WB_REPO 环境变量 → state/cloud-repo.txt → 按 gh 登录账号自动推断
REPO="$(wb_resolve_repo "$SKILL_DIR" "$GH" 2>/dev/null || true)"
if [ -z "$REPO" ]; then
  say "❌ 无法确定目标仓库。请先跑一次 bash scripts/setup-cloud-repo.sh 完成配置；"
  say "   或显式指定：WB_REPO=<账号>/<仓库名> bash scripts/$(basename "$0")"
  exit 1
fi

# 网络抖动重试（未开 VPN 时 GitHub 会超时）
net_retry() { # $1 = 描述; 其余 = 命令
  local desc="$1"; shift
  local i=1
  while [ "$i" -le 5 ]; do
    if "$@" 2>/tmp/rc_err.$$; then rm -f /tmp/rc_err.$$; return 0; fi
    say "  ⚠️ $desc 第 $i/5 次失败（疑似网络抖动），$((4*i))s 后重试…"
    i=$((i+1)); sleep $((4*i))
  done
  say "❌ $desc 失败：$(tail -1 /tmp/rc_err.$$ 2>/dev/null | cut -c1-160)"
  rm -f /tmp/rc_err.$$
  return 1
}

retry_stdin() { # $1 = 描述, $2 = 内容, 其余 = 命令（重试须重建管道，否则喂空输入）
  local desc="$1" input="$2"; shift 2
  local i=1
  while [ "$i" -le 5 ]; do
    if ( set +o pipefail; printf '%s' "$input" | "$@" ) >/tmp/rc_out.$$ 2>/tmp/rc_err.$$; then
      cat /tmp/rc_out.$$; rm -f /tmp/rc_out.$$ /tmp/rc_err.$$; return 0
    fi
    say "  ⚠️ $desc 第 $i/5 次失败（疑似网络抖动），$((4*i))s 后重试…"
    i=$((i+1)); sleep $((4*i))
  done
  say "❌ $desc 失败：$(tail -1 /tmp/rc_err.$$ 2>/dev/null | cut -c1-160)"
  rm -f /tmp/rc_out.$$ /tmp/rc_err.$$
  return 1
}

bj() { date -u -d "$1 +8 hours" '+%m-%d %H:%M' 2>/dev/null || printf '%s' "$1"; }

show_status() {
  say "▶ 最近 8 次云端运行（时间为北京时间）"
  say ""
  "$GH" run list -R "$REPO" --limit 8 \
    --json createdAt,event,status,conclusion,databaseId \
    --jq '.[] | [.createdAt, .event, (.status + "/" + (.conclusion // "-")), (.databaseId|tostring)] | @tsv' \
  | while IFS=$'\t' read -r ts ev st rid; do
      printf '  %s  %-16s %-20s #%s\n' "$(bj "$ts")" "$ev" "$st" "$rid"
    done
  say ""
  say "判读："
  say "  event 列 —— schedule=定时触发（正常）／workflow_dispatch=手动触发"
  say "  状态列 —— completed/success 成功；completed/failure 失败（点进去看日志）"
  say "  今天若没有 schedule 记录 → 定时没跑（GitHub 延迟或 workflow 被禁用）"
  say "  failure 且日志是 HTTP 401/403 → 令牌失效，跑 push-token-to-cloud.sh --force"
}

if [ "$MODE" = "status" ]; then
  show_status
  exit 0
fi

WID="$(net_retry "查询工作流 id" "$GH" api "repos/$REPO/actions/workflows" --jq \
  ".workflows[] | select(.name==\"$WORKFLOW_NAME\") | .id")" || exit 1
[ -n "$WID" ] || { say "❌ 未找到名为「$WORKFLOW_NAME」的工作流（可能被停用，见下方提示）"; exit 1; }

# 触发前先看这个工作流是否被 GitHub 停用（停用时 dispatch 会 422/404）
WSTATE="$(net_retry "查询工作流状态" "$GH" api "repos/$REPO/actions/workflows/$WID" --jq '.state')" || true
case "${WSTATE:-}" in
  active) ;;
  "")     say "  ⚠️ 未能确认工作流状态（网络问题），仍尝试触发" ;;
  *)      say "❌ 该工作流当前状态为「$WSTATE」（已被停用），无法触发。"
          say "   到 https://github.com/$REPO/actions 点顶部横幅的「Enable workflow」再回来跑。"
          exit 1 ;;
esac

T0="$(date -u +%s)"
say "▶ 触发一次云端签到（不带任何勾选项 ⇒ 走正常签到路径）…"
INPUT_JSON='{"ref":"main"}'
retry_stdin "触发云端签到" "$INPUT_JSON" "$GH" api --method POST \
  "repos/$REPO/actions/workflows/$WID/dispatches" --input - || exit 1
say "  ✓ 已触发"

if [ "$MODE" = "run-nowait" ]; then
  say "ℹ️  --no-wait：未等待结果。查看：https://github.com/$REPO/actions"
  exit 0
fi

say "▶ 等待运行完成 …"
RID=""
for i in $(seq 1 20); do
  sleep 8
  # 一次拿齐 id / 触发时间 / 状态（jq 输出制表符分隔，避免解析 JSON 字符串）
  ROW="$("$GH" run list -R "$REPO" --workflow "$WID" --limit 1 \
        --json databaseId,createdAt,status,conclusion \
        --jq '.[0] | "\(.databaseId)\t\(.createdAt)\t\(.status)/\(.conclusion // "-")"' 2>/dev/null)"
  [ -n "$ROW" ] || continue
  IFS=$'\t' read -r RID CREATED CONCL <<EOF
$ROW
EOF
  # 排除「触发之前就已存在于列表里」的旧运行
  C_TS="$(date -u -d "$CREATED" +%s 2>/dev/null || echo 0)"
  if [ "${C_TS:-0}" -lt "$T0" ]; then RID=""; continue; fi
  case "$CONCL" in
    completed*) say "  ✓ 运行 #$RID 已完成（$CONCL）"; break ;;
  esac
done
[ -n "$RID" ] || { say "⚠️ 未能取到本次运行 id（可能仍在排队或网络抖动），请到 Actions 页查看："; say "   https://github.com/$REPO/actions"; exit 1; }

say ""
say "=========== 补签结果（运行 #$RID）==========="
# ⚠️ 关键：GitHub 日志会把 run 块的**源码逐行回显**，其中 `echo "::error::令牌已失效…"`
#    只是脚本内容、不是执行结果。判据是**颜色标记**：源码回显行被 GitHub 上了青色，
#    真实输出行是纯文本。
#    ⚠️ 实测坑（2026-09-30）：Windows 下 gh.exe 不输出真实 ESC 字节，而是把 ANSI 序列
#       输出成**字面串** `^[[36;1m`（实测 90 行如此、0 行含 0x1b）。
#       因此这里同时剔除两种形态：字面 `^[[` 与真实 ESC，跨平台都成立。
LOG="$("$GH" run view "$RID" -R "$REPO" --log 2>/dev/null \
  | command grep -vF -e '^[[' -e $'\033' \
  | awk -F'\t' '{print $NF}' \
  | sed -E $'s/\033\\[[0-9;]*m//g; s/\\^\\[\\[[0-9;]*m//g' \
  | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z //' \
  | command grep -E 'checkin-status HTTP|daily-checkin HTTP|::notice::|::error::|>> 查询签到状态|>> 执行签到|通知已发出|本次结果：' \
  | command grep -v '^$' || true)"
if [ -n "$LOG" ]; then printf '%s\n' "$LOG"; else say "（未能取到关键日志行，请到 Actions 页查看）"; fi

say ""
# ---------- 人话结论 ----------
if printf '%s' "$LOG" | command grep -q '签到成功，领取'; then
  say "✅ 结论：本次为当天第一签，补签成功 → 会推「WorkBuddy 签到成功」到微信。"
elif printf '%s' "$LOG" | command grep -q '今日已签到'; then
  say "✅ 结论：当天早已签到成功，本次是幂等重复（按策略静默不推）→ 无需再补。"
elif printf '%s' "$LOG" | command grep -qE '401|403'; then
  say "❌ 结论：令牌失效 —— 补签无用。请先打开 WorkBuddy 桌面端，再跑："
  say "     bash scripts/push-token-to-cloud.sh --force"
  say "   然后重跑本脚本。"
elif printf '%s' "$LOG" | command grep -q '缺少 Secrets'; then
  say "❌ 结论：Secrets 为空 —— 同令牌问题，跑 push-token-to-cloud.sh --force 后重试。"
else
  say "⚠️ 结论：未匹配到明确结果，请人工看日志："
  say "   https://github.com/$REPO/actions/runs/$RID"
fi
say ""
say "判读参考："
say "  ::notice::签到成功…        → 本次是第一签（会推「签到成功」通知）"
say "  ::notice::今日已签到…      → 之前已签过，幂等重复（按当前策略静默不推）"
say "  ::error::令牌已失效(401/403) → 补签无用，须本机打开桌面端后跑 push-token-to-cloud.sh --force"
say "  ::error::缺少 Secrets       → 同上，跑 push-token-to-cloud.sh --force"
say "详情：https://github.com/$REPO/actions/runs/$RID"
