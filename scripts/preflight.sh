#!/usr/bin/env bash
# ============================================================
# WorkBuddy 云端签到 · 环境自检（只读，不改动任何东西）
#
# 用途：第一次接触这套方案时先跑它，一次性看清「差什么、怎么补」。
#   它逐项检查并给出可直接复制的修复命令，不会读取也不会打印任何凭据原文。
#
# 用法：
#   bash scripts/preflight.sh
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib-common.sh
. "$SCRIPT_DIR/lib-common.sh"

PASS=0; WARN=0; FAIL=0
ok()   { printf '  ✅ %s\n' "$*"; PASS=$((PASS+1)); }
warn() { printf '  ⚠️  %s\n' "$*"; WARN=$((WARN+1)); }
bad()  { printf '  ❌ %s\n' "$*"; FAIL=$((FAIL+1)); }
fix()  { printf '      解决：%s\n' "$*"; }

case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) PLATFORM="Windows（Git Bash）" ;;
  Darwin)               PLATFORM="macOS" ;;
  Linux)                PLATFORM="Linux" ;;
  *)                    PLATFORM="未知（$(uname -s)）" ;;
esac

echo "════════════════════════════════════════════════"
echo " WorkBuddy 云端签到 · 环境自检"
echo " 运行环境：$PLATFORM"
echo "════════════════════════════════════════════════"
echo ""
echo "【1/6】运行依赖"
echo ""

# ---------- Node ----------
NODE_BIN="$(wb_find_node 2>/dev/null || true)"
if [ -n "$NODE_BIN" ]; then
  ok "Node 可用：$NODE_BIN  $("$NODE_BIN" -v 2>/dev/null)"
else
  bad "找不到 Node.js（读取本机登录态需要它）"
  fix "Windows: winget install --id OpenJS.NodeJS.LTS -e ｜ macOS: brew install node"
fi

# ---------- GitHub CLI ----------
GH="$(wb_find_gh 2>/dev/null || true)"
if [ -n "$GH" ]; then
  ok "GitHub CLI 可用：$GH  $("$GH" --version 2>/dev/null | head -1)"
else
  bad "找不到 GitHub CLI（gh）——它是唯一需要额外安装的工具"
  fix "Windows: winget install --id GitHub.cli -e ｜ macOS: brew install gh"
fi

# ---------- curl ----------
if command -v curl >/dev/null 2>&1; then
  ok "curl 可用（Windows Git Bash / macOS 一般自带）"
else
  warn "找不到 curl（脚本推送文件时会用到 GitHub API）"
fi

echo ""
echo "【2/6】WorkBuddy 桌面端登录态"
echo ""
TOKEN_LEN="$(bash "$SCRIPT_DIR/extract-token-cloud.sh" --raw 2>/dev/null | wc -c | tr -d ' ')"
UID_LEN="$(bash "$SCRIPT_DIR/extract-token-cloud.sh" --uid-only 2>/dev/null | wc -c | tr -d ' ')"
if [ "${TOKEN_LEN:-0}" -gt 100 ]; then
  ok "已能读取本机令牌（长度 $TOKEN_LEN 字符，此处不显示内容）"
  if [ "${UID_LEN:-0}" -gt 10 ]; then
    ok "已能读取账号 uid（长度 $UID_LEN 字符）"
  else
    warn "未取到 uid（老式鉴权头可不带，通常不影响签到）"
  fi
else
  bad "读不到本机令牌"
  fix "打开 WorkBuddy 桌面端并确认已登录，然后重跑本脚本"
  fix "若已登录仍失败：确认终端能跑 node（上面第 1 项），或稍等几秒重试"
fi

echo ""
echo "【3/6】GitHub 账号"
echo ""
OWNER=""
if [ -n "$GH" ]; then
  if "$GH" auth status >/dev/null 2>&1; then
    for __i in 1 2 3; do
      OWNER="$("$GH" api user --jq .login 2>/dev/null || true)"
      [ -n "$OWNER" ] && break
      sleep 3
    done
    if [ -n "$OWNER" ]; then
      ok "已登录 GitHub：$OWNER"
    else
      warn "已登录，但取不到用户名（网络抖动）"
      fix "稍后重试；若一直失败请检查代理/VPN"
    fi
  else
    warn "GitHub CLI 尚未登录"
    fix "在**你自己的终端**里运行（会显示一次性代码并自动开浏览器）："
    printf '       %s auth login --hostname github.com --git-protocol https --web\n' "$GH"
  fi
else
  warn "跳过（未安装 gh）"
fi

echo ""
echo "【4/6】网络连通性（仅影响本机配置与令牌推送）"
echo ""
CODE=""
if command -v curl >/dev/null 2>&1; then
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://api.github.com 2>/dev/null || true)"
fi
case "$CODE" in
  200|403|401) ok "api.github.com 可达（HTTP $CODE）" ;;
  000|"")      warn "api.github.com 不可达（国内直连常抖动；本机配置阶段建议开代理）"
               fix "开代理/VPN 后重试；日常签到跑在 GitHub 云端，与本机网络无关" ;;
  *)           warn "api.github.com 返回异常 HTTP $CODE" ;;
esac

echo ""
echo "【5/6】云端仓库配置状态"
echo ""
REPO="$(wb_resolve_repo "$SKILL_DIR" "${GH:-}" 2>/dev/null || true)"
if [ -f "$SKILL_DIR/state/cloud-repo.txt" ]; then
  ok "目标仓库（已在本地记录）：$REPO"
  if [ -n "$GH" ]; then
    WSTATE="$("$GH" api "repos/$REPO/actions/workflows" --jq '.workflows[0].state' 2>/dev/null || true)"
    case "$WSTATE" in
      active)   ok "云端工作流状态：active（定时任务已启用）" ;;
      disabled*|"") [ -n "$WSTATE" ] && warn "云端工作流状态：$WSTATE"
                    [ -z "$WSTATE" ] && warn "读取工作流状态失败（网络或仓库名不符）" ;;
      *)        warn "云端工作流状态：$WSTATE" ;;
    esac
  fi
elif [ -n "$REPO" ]; then
  warn "尚未配置云端仓库（已可推断为 $REPO）"
  fix "运行：bash scripts/setup-cloud-repo.sh"
else
  warn "尚未配置云端仓库，且暂时无法推断"
  fix "先完成上面的 gh 登录，再运行：bash scripts/setup-cloud-repo.sh"
fi

echo ""
echo "【6/6】可选：通知渠道与自动续期"
echo ""
if [ -n "$GH" ] && [ -n "$REPO" ] && [ -f "$SKILL_DIR/state/cloud-repo.txt" ]; then
  SECRETS="$("$GH" secret list -R "$REPO" --json name --jq '.[].name' 2>/dev/null || true)"
  if printf '%s' "$SECRETS" | grep -q '^WB_CHECKIN_TOKEN$'; then
    ok "Secret WB_CHECKIN_TOKEN 已存在"
  else
    warn "未发现 WB_CHECKIN_TOKEN（配置未完成）"
  fi
  if printf '%s' "$SECRETS" | grep -qE '^NOTIFY_|^SMTP_HOST$'; then
    ok "已配置通知渠道：$(printf '%s' "$SECRETS" | grep -E '^NOTIFY_|^SMTP_HOST$' | tr '\n' ' ')"
  else
    warn "未配置任何通知渠道（不影响签到，只是收不到结果）"
    fix "见 references/notify-channels.md"
  fi
else
  warn "跳过（云端仓库尚未配好）"
fi

if [ -f "$SKILL_DIR/state/token-push.state" ]; then
  LAST="$(grep '^PUSHED_AT=' "$SKILL_DIR/state/token-push.state" 2>/dev/null | cut -d= -f2-)"
  ok "令牌镜像记录：上次推送 ${LAST:-未知}"
else
  warn "尚无令牌镜像记录（周一自动续期任务或首次 setup 会产生）"
fi

echo ""
echo "════════════════════════════════════════════════"
printf ' 自检结果：%d 项通过，%d 项提醒，%d 项待解决\n' "$PASS" "$WARN" "$FAIL"
echo "════════════════════════════════════════════════"

if [ "$FAIL" -eq 0 ] && [ ! -f "$SKILL_DIR/state/cloud-repo.txt" ]; then
  echo ""
  echo "▶ 下一步：bash scripts/setup-cloud-repo.sh"
elif [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "▶ 请先按上面的「解决」提示处理 ❌ 项，再重跑本脚本"
else
  echo ""
  echo "▶ 一切就绪。日常维护见 SKILL.md「日常怎么用」一节"
fi

[ "$FAIL" -eq 0 ] || exit 1
