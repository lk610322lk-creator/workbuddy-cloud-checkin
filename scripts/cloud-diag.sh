#!/usr/bin/env bash
# ============================================================
# WorkBuddy 签到 · 云端令牌体检触发器
#
# 做什么：触发一次云端「令牌体检」运行（Actions → diag），并取回结论：
#   - 云端 Secret 里持有的令牌，指纹 / 签发时间 / 到期时间 / 剩余天数
#   - 该令牌当前 checkin-status 的真实 HTTP 码（200=鉴权通过，401/403=失效）
#   - 实验对照组 WB_TEST_OLD_TOKEN（若配了）的同样信息
#   - 人为损坏令牌的对照结果（应 401，用来证明接口确实鉴权）
#
# 为什么需要它：签到日志只能告诉你「签没签到成」，答不了
#   「云端手里到底是哪把令牌、它是否就是本机那把」这类时序问题
#   （典型场景：桌面端换发新令牌后，先前镜像的旧令牌是否仍然有效）。
#   体检运行**不签到、不改状态**，可以随时跑。
#
# 用法：
#   bash scripts/cloud-diag.sh          # 触发并等待结论（约 30~90s）
#   bash scripts/cloud-diag.sh --no-wait  # 只触发，不等结果
#
# 配合本机：bash scripts/token-fingerprint.sh 打印本机令牌指纹，两边一比即知是否同一把。
# ⚠️ 安全：只显示指纹与时间声明，任何情况下不打印令牌原文。
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

# 网络抖动重试（未开 VPN 时 GitHub 会超时）
net_retry() { # $1 = 描述; 其余 = 命令
  local desc="$1"; shift
  local i=1
  while [ "$i" -le 5 ]; do
    if "$@" 2>/tmp/cd_err.$$; then rm -f /tmp/cd_err.$$; return 0; fi
    say "  ⚠️ $desc 第 $i/5 次失败（疑似网络抖动），$((4*i))s 后重试…"
    i=$((i+1)); sleep $((4*i))
  done
  say "❌ $desc 失败：$(tail -1 /tmp/cd_err.$$ 2>/dev/null | cut -c1-160)"
  rm -f /tmp/cd_err.$$
  return 1
}

# 需要往 stdin 灌内容的调用必须用这个：管道只够第一次尝试用，重试时若喂空 stdin，
# 命令会「成功地」按空输入执行（与 gh secret set 写坏 Secret 是同一个坑）。
retry_stdin() { # $1 = 描述, $2 = 内容, 其余 = 命令
  local desc="$1" input="$2"; shift 2
  local i=1
  while [ "$i" -le 5 ]; do
    if ( set +o pipefail; printf '%s' "$input" | "$@" ) >/tmp/cd_out.$$ 2>/tmp/cd_err.$$; then
      cat /tmp/cd_out.$$; rm -f /tmp/cd_out.$$ /tmp/cd_err.$$; return 0
    fi
    say "  ⚠️ $desc 第 $i/5 次失败（疑似网络抖动），$((4*i))s 后重试…"
    i=$((i+1)); sleep $((4*i))
  done
  say "❌ $desc 失败：$(tail -1 /tmp/cd_err.$$ 2>/dev/null | cut -c1-160)"
  rm -f /tmp/cd_out.$$ /tmp/cd_err.$$
  return 1
}

WID="$(net_retry "查询工作流 id" "$GH" api "repos/$REPO/actions/workflows" --jq \
  ".workflows[] | select(.name==\"$WORKFLOW_NAME\") | .id")" || exit 1
[ -n "$WID" ] || { say "❌ 未找到名为「$WORKFLOW_NAME」的工作流"; exit 1; }

say "▶ 触发令牌体检（不签到）…"
# 用 --input - 走 stdin：gh.exe 是原生 Windows 程序，MSYS 的 /tmp/... 路径它读不到
# （本次实测踩到：open /tmp/wbdiag_input.xxxx.json: The system cannot find the file specified）。
INPUT_JSON='{"ref":"main","inputs":{"diag":"true"}}'
retry_stdin "触发体检运行" "$INPUT_JSON" "$GH" api --method POST \
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
say "=========== 体检结论（运行 #$RID）==========="
"$GH" run view "$RID" -R "$REPO" --log 2>/dev/null \
  | grep -E '云端当前令牌|实验对照旧令牌|人为损坏|对照组|##\[error\]' \
  | sed -E 's/^[^|]*\|//' | sed -E 's/\x1b\[[0-9;]*m//g' \
  || say "（未能取到日志，请到 Actions 页查看）"
say "详情：https://github.com/$REPO/actions/runs/$RID"
