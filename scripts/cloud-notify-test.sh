#!/usr/bin/env bash
# ============================================================
# WorkBuddy 签到 · 通知渠道测试（只发测试通知，跳过签到）
#
# 做什么：触发一次云端运行（workflow_dispatch + notify_test=true）。
#   工作流会**跳过签到**，直接调 notify.sh 发一条「测试」通知，
#   然后把各渠道的发送结果（HTTP 码 / 成功失败）取回来。
#
# 什么时候用：刚配好某个通知渠道（Server酱 / 群机器人 / 邮件）后验证。
#   ⚠️ 真正的验证标准是**你的微信/手机收到消息**，日志只是辅助证据。
#
# 用法：
#   bash scripts/cloud-notify-test.sh            # 触发并等待结果（约 30~90s）
#   bash scripts/cloud-notify-test.sh --no-wait  # 只触发，不等结果
#
# ⚠️ 安全：只读日志，不打印任何 Secret 的值；notify.sh 自身也只打印脱敏 key。
# ============================================================
set -uo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib-common.sh
. "$SCRIPT_DIR/lib-common.sh"
WORKFLOW_NAME="${WB_WORKFLOW:-WorkBuddy Daily Checkin}"
NOWAIT=0
[ "${1:-}" = "--no-wait" ] && NOWAIT=1

say() { printf '%s\n' "$*"; }

GH="$(wb_find_gh || true)"
[ -n "$GH" ] || { wb_need_gh_msg; exit 1; }

# 目标仓库：WB_REPO 环境变量 → state/cloud-repo.txt → 按 gh 登录账号自动推断
REPO="$(wb_resolve_repo "$SKILL_DIR" "$GH" 2>/dev/null || true)"
if [ -z "$REPO" ]; then
  say "❌ 无法确定目标仓库。请先跑一次 bash scripts/setup-cloud-repo.sh 完成配置；"
  say "   或显式指定：WB_REPO=<账号>/<仓库名> bash scripts/$(basename "$0")"
  exit 1
fi

net_retry() { # $1 = 描述; 其余 = 命令
  local desc="$1"; shift
  local i=1
  while [ "$i" -le 5 ]; do
    if "$@" 2>/tmp/cn_err.$$; then rm -f /tmp/cn_err.$$; return 0; fi
    say "  ⚠️ $desc 第 $i/5 次失败（疑似网络抖动），$((4*i))s 后重试…"
    i=$((i+1)); sleep $((4*i))
  done
  say "❌ $desc 失败：$(tail -1 /tmp/cn_err.$$ 2>/dev/null | cut -c1-160)"
  rm -f /tmp/cn_err.$$
  return 1
}

retry_stdin() { # $1 = 描述, $2 = 内容, 其余 = 命令（重试须重建管道，否则喂空输入）
  local desc="$1" input="$2"; shift 2
  local i=1
  while [ "$i" -le 5 ]; do
    if ( set +o pipefail; printf '%s' "$input" | "$@" ) >/tmp/cn_out.$$ 2>/tmp/cn_err.$$; then
      cat /tmp/cn_out.$$; rm -f /tmp/cn_out.$$ /tmp/cn_err.$$; return 0
    fi
    say "  ⚠️ $desc 第 $i/5 次失败（疑似网络抖动），$((4*i))s 后重试…"
    i=$((i+1)); sleep $((4*i))
  done
  say "❌ $desc 失败：$(tail -1 /tmp/cn_err.$$ 2>/dev/null | cut -c1-160)"
  rm -f /tmp/cn_out.$$ /tmp/cn_err.$$
  return 1
}

WID="$(net_retry "查询工作流 id" "$GH" api "repos/$REPO/actions/workflows" --jq \
  ".workflows[] | select(.name==\"$WORKFLOW_NAME\") | .id")" || exit 1
[ -n "$WID" ] || { say "❌ 未找到名为「$WORKFLOW_NAME」的工作流"; exit 1; }

say "▶ 触发一次「只测通知」运行（跳过签到，不影响当日签到状态）…"
INPUT_JSON='{"ref":"main","inputs":{"notify_test":"true"}}'
retry_stdin "触发通知测试" "$INPUT_JSON" "$GH" api --method POST \
  "repos/$REPO/actions/workflows/$WID/dispatches" --input - || exit 1
say "  ✓ 已触发"

if [ "$NOWAIT" = "1" ]; then
  say "ℹ️  --no-wait：未等待结果。查看：https://github.com/$REPO/actions"
  exit 0
fi

say "▶ 等待运行完成 …"
RID=""
for i in $(seq 1 20); do
  sleep 8
  RID="$("$GH" run list -R "$REPO" --workflow "$WID" --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)"
  if [ -n "$RID" ]; then
    CONCL="$("$GH" run view "$RID" -R "$REPO" --json status,conclusion --jq '.status+" "+(.conclusion//"")' 2>/dev/null)"
    case "$CONCL" in
      completed*) say "  ✓ 运行 #$RID 已完成（$CONCL）"; break ;;
    esac
  fi
done
[ -n "$RID" ] || { say "⚠️ 未能取到运行 id，请到 Actions 页查看"; exit 1; }

say ""
say "=========== 通知测试结果（运行 #$RID）==========="
# ⚠️ 日志里会带回各渠道的原始响应，其中 Server酱 的响应含 `readkey`（可用于读取推送内容）。
#    它虽不是 SendKey，但同属凭据，一律脱敏，避免它被复制进对话/工单。
# ⚠️ 同时剔除 GitHub 回显的 run 块**源码行**（它们被着色）：本机 gh.exe 实测输出的是
#    字面串 `^[[36;1m` 而非真实 ESC 字节，故两种形态都过滤（跨平台通用）。
"$GH" run view "$RID" -R "$REPO" --log 2>/dev/null \
  | command grep -vF -e '^[[' -e $'\033' \
  | awk -F'\t' '{print $NF}' \
  | sed -E $'s/\033\\[[0-9;]*m//g; s/\\^\\[\\[[0-9;]*m//g' \
  | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z //' \
  | command grep -E '\[群机器人\]|\[Server酱|\[邮件\]|通知已发出|未配置任何通知渠道|::warning::' \
  | sed -E 's/"readkey":"[^"]*"/"readkey":"***"/g; s/"pushid":"[0-9]+"/"pushid":"***"/g' \
  || say "（未能取到日志，请到 Actions 页查看）"
say ""
say "判读："
say "  [Server酱→微信] HTTP=200 → 已投递（★ 以手机/微信真的收到为准）"
say "  ::warning::…发送失败 → 看该行原因（key 错 / 未关注方糖服务号 / 额度用尽）"
say "  未配置任何通知渠道 → 对应 Secret 名没配或值为空"
say "详情：https://github.com/$REPO/actions/runs/$RID"
