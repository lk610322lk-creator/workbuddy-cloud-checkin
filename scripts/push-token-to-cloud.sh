#!/usr/bin/env bash
# ============================================================
# WorkBuddy 签到 · 云端令牌「无感续期」
#
# 做什么：把本机 WorkBuddy 桌面端当前的 accessToken 镜像到 GitHub Secrets。
# 为什么这样就能无感续期：
#   桌面端每次运行都会用 refreshToken 换发一把**全新的** accessToken
#   （实测：iat 2026-09-29 15:52:57，exp = iat + 55.00 天，即每次打开都续命 55 天）。
#   因此只要本机令牌一变就推到云端，云端手里永远是「刚签发的、够用 55 天」的令牌，
#   永远不会走到过期那一步 —— 你不需要任何手动操作。
#
# 幂等：本地令牌指纹未变时直接跳过（默认行为），跑 100 次也不会产生多余动作。
#
# 用法：
#   bash scripts/push-token-to-cloud.sh            # 令牌变了才推（推荐，日常就这一条）
#   bash scripts/push-token-to-cloud.sh --check    # 只看状态，不推送
#   bash scripts/push-token-to-cloud.sh --force    # 无条件推送
#   bash scripts/push-token-to-cloud.sh --verify   # 推送后触发一次云端运行验证
#
# ⚠️ 安全：令牌全程不显示、不落盘（状态文件只存 SHA-256 指纹与时间）。
# ============================================================
set -uo pipefail

# Git Bash/MSYS 不转换以 / 开头的 API 端点参数
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib-common.sh
. "$SCRIPT_DIR/lib-common.sh"
STATE_DIR="$SKILL_DIR/state"
STATE_FILE="$STATE_DIR/token-push.state"
MODE="auto"
DO_VERIFY=0
for a in "$@"; do
  case "$a" in
    --check)  MODE="check" ;;
    --force)  MODE="force" ;;
    --verify) DO_VERIFY=1 ;;
  esac
done

say() { printf '%s\n' "$*"; }

# ---------- 找 gh ----------
GH="$(wb_find_gh || true)"
[ -n "$GH" ] || { wb_need_gh_msg; exit 1; }

# ---------- 解析目标仓库（免手工配置） ----------
REPO="$(wb_resolve_repo "$SKILL_DIR" "$GH" 2>/dev/null || true)"
if [ -z "$REPO" ]; then
  say "❌ 无法确定目标仓库。请先跑一次 bash scripts/setup-cloud-repo.sh 完成配置；"
  say "   或显式指定：WB_REPO=<你的账号>/<仓库名> bash scripts/push-token-to-cloud.sh"
  exit 1
fi
NODE_BIN="$(wb_find_node || true)"

# ---------- 带 stdin 的重试（绝不能用 `printf ... | retry`：管道只够第一次尝试用，
#            重试时喂空 stdin 会让 gh secret set「成功地」写入空值） ----------
retry_stdin() { # $1 = 描述, $2 = 内容, 其余 = 命令
  local desc="$1" input="$2"; shift 2
  local i=1 max=5 delay=4
  while [ "$i" -le "$max" ]; do
    if ( set +o pipefail; printf '%s' "$input" | "$@" ) >/tmp/wbpush_out.$$ 2>/tmp/wbpush_err.$$; then
      cat /tmp/wbpush_out.$$; rm -f /tmp/wbpush_out.$$ /tmp/wbpush_err.$$
      return 0
    fi
    say "  ⚠️ $desc 第 $i/$max 次失败：$(tail -1 /tmp/wbpush_err.$$ 2>/dev/null | cut -c1-140)"
    i=$((i+1))
    [ "$i" -le "$max" ] && sleep $((delay*i))
  done
  rm -f /tmp/wbpush_out.$$ /tmp/wbpush_err.$$
  return 1
}

# ---------- 1. 取本机令牌 ----------
TOKEN="$(bash "$SCRIPT_DIR/extract-token-cloud.sh" --raw 2>/dev/null)"
if [ -z "$TOKEN" ] || [ "$TOKEN" = "ERR_TOKEN_UNAVAILABLE" ] || [ "${#TOKEN}" -lt 100 ]; then
  say "❌ 未能从本机取到有效令牌（长度 ${#TOKEN}）。请确认 WorkBuddy 桌面端已登录后重试。"
  exit 1
fi
UID_VAL="$(bash "$SCRIPT_DIR/extract-token-cloud.sh" --uid-only 2>/dev/null)"
if [ -z "$UID_VAL" ]; then
  say "❌ 未能取到 uid。请确认 WorkBuddy 桌面端已登录后重试。"
  exit 1
fi

# ---------- 2. 指纹与剩余寿命（只算不打印令牌本体） ----------
HASH="$(printf '%s' "$TOKEN" | wb_sha256)"
LEFT_DAYS="$(
  printf '%s' "$TOKEN" | "$NODE_BIN" -e "
let s='';process.stdin.on('data',c=>s+=c).on('end',()=>{
  const p=s.trim().split('.');
  if(p.length!==3){console.log('?');return;}
  try{
    const j=JSON.parse(Buffer.from(p[1].replace(/-/g,'+').replace(/_/g,'/'),'base64').toString('utf8'));
    console.log(((j.exp*1000-Date.now())/86400000).toFixed(1));
  }catch(e){console.log('?');}
});" 2>/dev/null
)"
[ -z "$LEFT_DAYS" ] && LEFT_DAYS="?"

PREV_HASH=""
PREV_AT=""
if [ -f "$STATE_FILE" ]; then
  PREV_HASH="$(grep '^HASH=' "$STATE_FILE" 2>/dev/null | cut -d= -f2-)"
  PREV_AT="$(grep '^PUSHED_AT=' "$STATE_FILE" 2>/dev/null | cut -d= -f2-)"
fi

say "▶ 本机令牌：长度 ${#TOKEN} 字符，剩余有效期 ${LEFT_DAYS} 天"
say "▶ 指纹：$(printf '%s' "$HASH" | cut -c1-16)…"

if [ "$MODE" = "check" ]; then
  if [ "$HASH" = "$PREV_HASH" ]; then
    say "✅ 与云端已推版本一致（上次推送：${PREV_AT:-未知}）"
  else
    say "🔄 与云端已推版本不同，运行不带参数的脚本即可推送（上次推送：${PREV_AT:-从未}）"
  fi
  exit 0
fi

if [ "$HASH" = "$PREV_HASH" ] && [ "$MODE" = "auto" ]; then
  say "✅ 本地令牌未变化，云端已是最新（上次推送：${PREV_AT:-未知}）— 跳过"
  exit 0
fi

# ---------- 3. 检查 gh 登录 ----------
# 注意：gh auth status 会联网校验令牌，网络抖一下会返回非 0 —— 若直接判定「未登录」会误报。
# 故此处重试，并区分「真未登录」与「网络不通」两种情况。
AUTH_STATE=""
for __i in 1 2 3 4 5; do
  __out="$("$GH" auth status 2>&1)"
  if printf '%s' "$__out" | grep -q 'Logged in to'; then
    AUTH_STATE="ok"; break
  fi
  if printf '%s' "$__out" | grep -q 'not logged into any GitHub hosts'; then
    AUTH_STATE="nologin"; break
  fi
  say "  ⚠️ 登录状态检查第 $__i/5 次未通过（疑似网络抖动），$((4*__i))s 后重试…"
  sleep $((4*__i))
done
if [ "$AUTH_STATE" = "nologin" ]; then
  say "❌ gh 未登录。请按 references/cloud-checkin-github-actions.md 重新登录后再试；本次未改动云端。"
  exit 1
fi
if [ "$AUTH_STATE" != "ok" ]; then
  say "❌ 无法确认 gh 登录状态（连不上 api.github.com，常见于未开 VPN）。"
  say "   请打开 VPN 后重跑；本次未改动云端（令牌仍是原值，不会写坏）。"
  exit 1
fi

# ---------- 4. 推送 ----------
say "▶ 推送新令牌到 $REPO 的 Secrets ..."
retry_stdin "写入 WB_CHECKIN_TOKEN" "$TOKEN" "$GH" secret set WB_CHECKIN_TOKEN -R "$REPO" || {
  say "❌ 令牌推送失败，云端保持原值（未产生中间态）。"
  exit 1
}
retry_stdin "写入 WB_CHECKIN_UID" "$UID_VAL" "$GH" secret set WB_CHECKIN_UID -R "$REPO" || {
  say "❌ uid 推送失败，请重跑本脚本（幂等）。"
  exit 1
}
unset TOKEN UID_VAL

# ---------- 5. 记账（只存指纹，不存令牌） ----------
# 北京时间用 UTC+8 直接算：Git Bash 不认 TZ=Asia/Shanghai（无 tzdata），会静默给出 UTC，
# 导致记账时间看似北京时间实则 UTC。用 node（本 skill 必需依赖）换算，跨平台一致。
NOW_CN="$(wb_now_cn)"
mkdir -p "$STATE_DIR"
{
  printf 'HASH=%s\n' "$HASH"
  printf 'PUSHED_AT=%s\n' "$NOW_CN"
  printf 'TOKEN_LEFT_DAYS=%s\n' "$LEFT_DAYS"
  printf 'REPO=%s\n' "$REPO"
} > "$STATE_FILE"
say "✓ 已推送（北京时间 ${NOW_CN}，指纹记账于 state/token-push.state）"

# ---------- 6. 可选：触发一次云端验证 ----------
if [ "$DO_VERIFY" = "1" ]; then
  say "▶ 触发云端运行验证 ..."
  WID="$("$GH" api "repos/$REPO/actions/workflows" --jq '.workflows[0].id' 2>/dev/null || true)"
  if [ -n "$WID" ] && "$GH" api --method POST "repos/$REPO/actions/workflows/$WID/dispatches" -f ref=main >/dev/null 2>&1; then
    say "  已触发，等待结果（最多约 60s）…"
    sleep 25
    RID="$("$GH" run list -R "$REPO" --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)"
    CONCL="$("$GH" run view "$RID" -R "$REPO" --json conclusion --jq '.conclusion' 2>/dev/null)"
    say "  运行 #$RID 结论：${CONCL:-未取到}"
    [ "$CONCL" = "success" ] && say "  ✅ 云端链路正常" || say "  ⚠️ 结论非 success，请到 Actions 页查看"
  else
    say "  ⚠️ 触发失败（不影响已推送的令牌），可稍后在 Actions 页手动 Run"
  fi
fi
