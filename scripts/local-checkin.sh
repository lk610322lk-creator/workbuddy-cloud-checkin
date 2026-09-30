#!/usr/bin/env bash
# ============================================================
# WorkBuddy 签到 · 本机直连（不经云端）
#
# 用途：**GitHub 完全不可用**时的兜底签到路径，效果与云端签到等价。
#   用本机登录态里的令牌直接调用官方签到接口，不依赖任何云端服务。
#
# 与云端的关系：两者**互不冲突、可以都用**。签到接口幂等 ——
#   谁先签上就算谁的，后到的会拿到 code=10001「今日已签到」，不会重复领取。
#
# 依赖：Node（或 WorkBuddy 桌面端自带的 Electron，自动回退）+ curl
#
# 用法：
#   bash scripts/local-checkin.sh            # 查状态 → 需要就签到
#   bash scripts/local-checkin.sh --status   # 只查状态，不签到
#   bash scripts/local-checkin.sh --quiet    # 静默模式（适合挂定时任务，只输出结论行）
#
# ⚠️ 安全：令牌仅在内存与请求头中使用，不打印、不落盘。
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
. "$SCRIPT_DIR/lib-common.sh"

MODE="run"
QUIET=0
for a in "$@"; do
  case "$a" in
    --status) MODE="status" ;;
    --quiet)  QUIET=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

log() { [ "$QUIET" = "1" ] || printf '%s\n' "$*"; }
out() { printf '%s\n' "$*"; }

API="https://copilot.tencent.com"
NODE_BIN="$(wb_find_node 2>/dev/null || true)"

# ---------- JSON 解析（用 node，避免额外依赖 python3） ----------
# 输出：code|credit|streak_days|today_checked_in
parse_resp() {
  if [ -z "$NODE_BIN" ]; then out "PARSE_ERR"; return 0; fi
  printf '%s' "$1" | "$NODE_BIN" -e '
let s = "";
process.stdin.on("data", c => s += c).on("end", () => {
  try {
    const d = JSON.parse(s);
    const dd = d.data || {};
    const v = x => (x === undefined || x === null) ? "" : String(x);
    console.log([v(d.code), v(dd.credit), v(dd.streak_days), v(dd.today_checked_in)].join("|"));
  } catch (e) {
    console.log("PARSE_ERR||||");
  }
});' 2>/dev/null
}

# ---------- 1. 取令牌 ----------
TOKEN="$(bash "$SCRIPT_DIR/extract-token-cloud.sh" --raw 2>/dev/null || true)"
UID_VAL="$(bash "$SCRIPT_DIR/extract-token-cloud.sh" --uid-only 2>/dev/null || true)"
if [ -z "$TOKEN" ] || [ "${#TOKEN}" -lt 100 ]; then
  log "❌ 未能读取本机令牌。请确认 WorkBuddy 桌面端已登录（可先跑 bash scripts/preflight.sh）。"
  exit 1
fi

HDR=(-H "Content-Type: application/json" -H "Accept: application/json" -H "Authorization: Bearer $TOKEN")
[ -n "$UID_VAL" ] && HDR+=(-H "X-User-Id: $UID_VAL")

call_api() { # $1 = 端点路径；stdout: body，末行 HTTP 码
  curl -s -m 15 -w '\n%{http_code}' -X POST "$API$1" "${HDR[@]}" -d '{}' 2>/dev/null || echo ""
}

# ---------- 2. 查状态 ----------
# ⚠️ 鉴权结论**只按真实 HTTP 状态码**判定，绝不用 grep 扫响应体子串 ——
#    响应体带随机 UUID 的 requestId，UUID 里恰好出现 "401" 会被误判为令牌过期，
#    从而在本该签到的日子提前退出（实测约 0.57%/次，每天跑一年有很高概率踩中）。
RESP="$(call_api "/billing/meter/checkin-status")"
HTTP_CODE="$(printf '%s' "$RESP" | tail -n 1)"
BODY="$(printf '%s' "$RESP" | sed '$d')"

if [ -z "$RESP" ] || [ "$HTTP_CODE" = "000" ]; then
  log "❌ 网络异常：连不上签到接口（$API）"
  exit 1
fi
case "$HTTP_CODE" in
  401|403)
    log "❌ 令牌已过期或无权限（HTTP $HTTP_CODE）"
    log "   → 打开 WorkBuddy 桌面端刷新登录态后重试；云端那份同步用 push-token-to-cloud.sh --force"
    exit 1 ;;
  200) ;;
  *)
    log "❌ 查询签到状态失败（HTTP $HTTP_CODE）"
    exit 1 ;;
esac

IFS='|' read -r _c _cr _st CHECKED <<<"$(parse_resp "$BODY")"
if [ "$CHECKED" = "True" ]; then
  log "✅ 今日已签到，无需重复领取"
  out "ALREADY"
  exit 0
fi

if [ "$MODE" = "status" ]; then
  log "ℹ️ 状态字段显示「未签到」——但该字段**不可靠**（实测签到成功后仍可能为 false），"
  log "   仅用于快速短路；要确认请直接跑一次不带 --status 的签到（幂等，不会重复领取）。"
  out "NOT_CHECKED_IN"
  exit 0
fi

# ---------- 3. 执行签到（幂等） ----------
RESP2="$(call_api "/billing/meter/daily-checkin")"
HTTP_CODE2="$(printf '%s' "$RESP2" | tail -n 1)"
BODY2="$(printf '%s' "$RESP2" | sed '$d')"

if [ -z "$RESP2" ] || [ "$HTTP_CODE2" = "000" ]; then
  log "❌ 网络异常：签到请求未送达"
  exit 1
fi
case "$HTTP_CODE2" in
  401|403)
    log "❌ 令牌已过期或无权限（HTTP $HTTP_CODE2）"
    exit 1 ;;
esac
if [ -z "$BODY2" ]; then
  log "❌ 签到请求失败（响应为空，HTTP $HTTP_CODE2）"
  exit 1
fi

IFS='|' read -r CODE CREDIT STREAK _x <<<"$(parse_resp "$BODY2")"
case "$CODE" in
  0)
    log "🎉 签到成功！领取 ${CREDIT:-?} 积分，连续 ${STREAK:-?} 天"
    out "SUCCESS credit=${CREDIT:-?} streak=${STREAK:-?}" ;;
  10001)
    log "✅ 今日已签到，无需重复领取（接口返回已签到）"
    out "ALREADY" ;;
  PARSE_ERR|"")
    # 无法解析时不能误报失败：请求可能已成功（缺 node 时会走到这里）
    log "⚠️ 签到请求已提交，但结果无法解析（请打开 WorkBuddy 确认）"
    out "UNKNOWN" ;;
  *)
    log "⚠️ 签到未成功：code=$CODE"
    out "FAIL code=$CODE" ;;
esac
