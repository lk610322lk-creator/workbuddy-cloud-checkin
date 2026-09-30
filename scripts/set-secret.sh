#!/usr/bin/env bash
# ============================================================
# WorkBuddy 签到 · 安全录入云端 Secret（隐藏输入，不进命令行历史、不进对话）
#
# 用法：
#   bash scripts/set-secret.sh --list                     # 列出已有 Secret 名（不显示值）
#   bash scripts/set-secret.sh NOTIFY_ROBOT_URL           # 交互输入（屏幕不回显），写入仓库 Secret
#   bash scripts/set-secret.sh --from-env MY_VAR NAME     # 从环境变量取值写入（适合脚本化）
#   bash scripts/set-secret.sh --delete NAME              # 删除某个 Secret
#
# 说明：GitHub Secrets 只可写、不可读回，因此这里只做「写入」与「列名」。
# ============================================================
set -uo pipefail

# Git Bash/MSYS 不转换以 / 开头的 API 端点参数
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib-common.sh
. "$SCRIPT_DIR/lib-common.sh"

say() { printf '%s\n' "$*"; }

GH="$(wb_find_gh || true)"
[ -n "$GH" ] || { wb_need_gh_msg; exit 1; }

# 目标仓库：WB_REPO 环境变量 → state/cloud-repo.txt → 自动推断
REPO="$(wb_resolve_repo "$SKILL_DIR" "$GH" 2>/dev/null || true)"
if [ -z "$REPO" ]; then
  say "❌ 无法确定目标仓库。请先跑一次 bash scripts/setup-cloud-repo.sh 完成配置，"
  say "   或用 WB_REPO=<你的账号>/<仓库名> 指定。"
  exit 1
fi

retry_stdin() { # $1 = 描述, $2 = 内容, 其余 = 命令
  local desc="$1" input="$2"; shift 2
  local i=1 max=5 delay=3
  while [ "$i" -le "$max" ]; do
    if ( set +o pipefail; printf '%s' "$input" | "$@" ) >/tmp/wbsec_out.$$ 2>/tmp/wbsec_err.$$; then
      cat /tmp/wbsec_out.$$; rm -f /tmp/wbsec_out.$$ /tmp/wbsec_err.$$
      return 0
    fi
    say "  ⚠️ $desc 第 $i/$max 次失败：$(tail -1 /tmp/wbsec_err.$$ 2>/dev/null | cut -c1-140)"
    i=$((i+1))
    [ "$i" -le "$max" ] && sleep $((delay*i))
  done
  rm -f /tmp/wbsec_out.$$ /tmp/wbsec_err.$$
  return 1
}

case "${1:-}" in
  ""|-h|--help)
    say "用法："
    say "  bash scripts/set-secret.sh --list"
    say "  bash scripts/set-secret.sh <SECRET_NAME>"
    say "  bash scripts/set-secret.sh --from-env <ENV_VAR> <SECRET_NAME>"
    say "  bash scripts/set-secret.sh --delete <SECRET_NAME>"
    say ""
    say "常用通知相关 Secret："
    say "  NOTIFY_ROBOT_URL       钉钉/企业微信群机器人 Webhook"
    say "  NOTIFY_ROBOT_SECRET    钉钉「加签」密钥（可选）"
    say "  NOTIFY_SERVERCHAN_KEY  Server酱 SendKey（微信推送）"
    say "  SMTP_HOST / SMTP_PORT / SMTP_USER / SMTP_PASS / SMTP_TO   邮件"
    exit 0
    ;;
  --list)
    "$GH" secret list -R "$REPO" 2>&1 | head -30
    exit 0
    ;;
  --delete)
    NAME="${2:-}"
    [ -n "$NAME" ] || { say "❌ 缺少 Secret 名"; exit 1; }
    # 注意：gh 2.101.0 的 `gh secret delete` **没有** -y/--yes 这个 flag
    # （传了会报 "unknown flag" 并打印 help、退出码非 0）；非交互环境下它也不弹确认，直接删。
    "$GH" secret delete "$NAME" -R "$REPO" 2>&1 || exit 1
    say "✓ 已删除 $NAME（签到若依赖它会立即失效，请确认）"
    exit 0
    ;;
  --from-env)
    VAR="${2:-}"; NAME="${3:-}"
    [ -n "$VAR" ] && [ -n "$NAME" ] || { say "❌ 用法：--from-env <ENV_VAR> <SECRET_NAME>"; exit 1; }
    VAL="${!VAR:-}"
    [ -n "$VAL" ] || { say "❌ 环境变量 $VAR 为空或未设置"; exit 1; }
    retry_stdin "写入 $NAME" "$VAL" "$GH" secret set "$NAME" -R "$REPO" || exit 1
    unset VAL
    say "✓ 已写入 Secret：$NAME（值来自环境变量，未回显）"
    exit 0
    ;;
esac

NAME="$1"
say "即将为仓库 $REPO 设置 Secret：$NAME"
printf '请粘贴值后回车（输入不回显）：'
IFS= read -rs VALUE
printf '\n'
if [ -z "$VALUE" ]; then
  say "❌ 值为空，已中止（不会写入空值）"
  exit 1
fi
say "已收到 ${#VALUE} 个字符，开始写入…"
retry_stdin "写入 $NAME" "$VALUE" "$GH" secret set "$NAME" -R "$REPO" || {
  say "❌ 写入失败；云端保持原值（不会产生中间态）"
  exit 1
}
unset VALUE
say "✓ 已写入 Secret：$NAME"
say "  验证：Actions → WorkBuddy Daily Checkin → Run workflow（勾选 notify_test 可只测通知；在网页上勾选）"
