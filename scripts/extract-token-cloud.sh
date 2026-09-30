#!/usr/bin/env bash
# ============================================================
# 提取 accessToken（仅用于配置云端签到，如 GitHub Actions Secret）
#
# 跨平台：Windows / macOS / Linux 均可（登录态路径探测与解密全在 decrypt-token.js 内完成）
# 依赖：Node（优先）或 WorkBuddy 桌面端自带的 Electron（无 Node 时自动回退）
#
# ⚠️ 安全红线：
#   - 本脚本输出等同 WorkBuddy 账号密码，仅在你显式运行时打印到终端，
#     供手动复制进云端加密 Secret。不写日志、不落盘。
#   - 复制完成后立即关闭该终端窗口；不要截图、不要粘贴给任何人/任何 AI 对话。
#   - 云端仅限存入 GitHub Actions Secrets（加密）或云函数环境变量（加密）。
#
# 用法：
#   bash scripts/extract-token-cloud.sh            # 打印带安全提示的 token 与 uid（人工复制用）
#   bash scripts/extract-token-cloud.sh --raw      # 仅输出 token 原文（供管道使用，勿直接显示）
#   bash scripts/extract-token-cloud.sh --uid-only # 只打印 uid
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-common.sh
. "$SCRIPT_DIR/lib-common.sh"

DECRYPT_JS="$SCRIPT_DIR/decrypt-token.js"
ATREST_JS="$SCRIPT_DIR/decrypt-atrest.js"

# 转成原生路径（Windows 上的 node / WorkBuddy.exe 不认 Git Bash 的 /c/... 路径）
to_native_path() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$p" 2>/dev/null || printf '%s' "$p"
  else
    printf '%s' "$p"
  fi
}

find_workbuddy_exe() {
  local c
  if [ -n "${WB_WORKBUDDY_EXE:-}" ] && [ -x "$WB_WORKBUDDY_EXE" ]; then printf '%s' "$WB_WORKBUDDY_EXE"; return 0; fi
  for c in \
      "$LOCALAPPDATA/Programs/WorkBuddy/WorkBuddy.exe" \
      "${PROGRAMFILES:-/c/Program Files}/WorkBuddy/WorkBuddy.exe" \
      "$HOME/AppData/Local/Programs/WorkBuddy/WorkBuddy.exe" \
      "/Applications/WorkBuddy.app/Contents/MacOS/WorkBuddy"; do
    if [ -n "$c" ] && [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
  done
  return 1
}

# ---------- 解析与判定 ----------
# ⚠️ 判定陷阱（第一版就踩了）：解密失败时脚本输出的是 `DECRYPT_RESULT:ERR …`，
#    它也匹配 `^DECRYPT_RESULT:`。只按前缀判断会把失败当成功、从而**不再回退**，
#    最终表现为「明明登录着却读不到令牌」。必须同时要求值非空且不以 ERR 开头。
_dr_tok() { printf '%s\n' "$1" | grep '^DECRYPT_RESULT:' | head -1 | sed 's/^DECRYPT_RESULT://' | tr -d '\r'; }
_dr_uid() { printf '%s\n' "$1" | grep '^ACCOUNT_UID:'   | head -1 | sed 's/^ACCOUNT_UID://'   | tr -d '\r'; }
_dr_ok()  { [ -n "$1" ] && [ "${1#ERR}" = "$1" ]; }

# ---------- 读取登录态：输出 "token<TAB>uid" ----------
# 解密链（逐级回退，任一步拿到有效 token 即停）：
#   ① Node 跑 decrypt-token.js                    —— 明文登录态（v5.3.8+）直接读，最轻
#   ② WorkBuddy.exe 跑 decrypt-atrest.js          —— 加密登录态（v5.4+），需客户端内置静态钥
#   ③ WorkBuddy.exe 跑 decrypt-token.js           —— 无 Node 时的等价回退
#   ④ 独立的 Electron 跑 decrypt-token.js          —— 开发环境兜底
# 注：② 是当前主流客户端形态下的实际生效路径，不要因为 ① 存在就跳过它。
read_login_state() {
  local out="" tok="" uid="" node_bin wb_exe js atrest electron_bin

  js="$(to_native_path "$DECRYPT_JS")"
  atrest="$(to_native_path "$ATREST_JS")"

  # ① Node + decrypt-token.js
  node_bin="$(wb_find_node 2>/dev/null || true)"
  if [ -n "$node_bin" ] && [ -f "$DECRYPT_JS" ]; then
    out="$("$node_bin" "$js" 2>/dev/null || true)"
    tok="$(_dr_tok "$out")"
    if _dr_ok "$tok"; then uid="$(_dr_uid "$out")"; printf '%s\t%s' "$tok" "$uid"; return 0; fi
  fi

  wb_exe="$(find_workbuddy_exe 2>/dev/null || true)"

  # ② WorkBuddy.exe + decrypt-atrest.js（加密登录态的真实通路）
  if [ -n "$wb_exe" ] && [ -f "$ATREST_JS" ]; then
    out="$(env ELECTRON_RUN_AS_NODE=1 "$wb_exe" "$atrest" 2>/dev/null || true)"
    tok="$(_dr_tok "$out")"
    if _dr_ok "$tok"; then uid="$(_dr_uid "$out")"; printf '%s\t%s' "$tok" "$uid"; return 0; fi
  fi

  # ③ WorkBuddy.exe + decrypt-token.js
  if [ -n "$wb_exe" ] && [ -f "$DECRYPT_JS" ]; then
    out="$(env ELECTRON_RUN_AS_NODE=1 "$wb_exe" "$js" 2>/dev/null || true)"
    tok="$(_dr_tok "$out")"
    if _dr_ok "$tok"; then uid="$(_dr_uid "$out")"; printf '%s\t%s' "$tok" "$uid"; return 0; fi
  fi

  # ④ 独立 Electron
  for electron_bin in \
      "${WB_ELECTRON:-}" \
      "$HOME/.workbuddy/tools/electron/electron.exe" \
      "$SCRIPT_DIR/../.runtime/electron/electron.exe" \
      "$(command -v electron 2>/dev/null || true)"; do
    [ -n "$electron_bin" ] && [ -x "$electron_bin" ] || continue
    out="$(env -u ELECTRON_RUN_AS_NODE "$electron_bin" "$js" 2>/dev/null || true)"
    tok="$(_dr_tok "$out")"
    if _dr_ok "$tok"; then uid="$(_dr_uid "$out")"; printf '%s\t%s' "$tok" "$uid"; return 0; fi
  done

  printf '\t'
}

STATE_RAW="$(read_login_state)"
TOKEN="${STATE_RAW%%	*}"
UID_VAL="${STATE_RAW#*	}"
[ "$TOKEN" = "$UID_VAL" ] && UID_VAL=""   # 无制表符（整体为空）时，别把 token 当成 uid

if [ "${1:-}" = "--uid-only" ]; then
  printf '%s' "$UID_VAL"
  exit 0
fi

if [ "${1:-}" = "--raw" ]; then
  # 仅供管道消费（如 gh secret set）。不打印任何提示，避免污染管道。
  if [ -z "$TOKEN" ] || [[ "$TOKEN" == ERR* ]]; then
    echo "ERR_TOKEN_UNAVAILABLE" >&2
    exit 1
  fi
  printf '%s' "$TOKEN"
  exit 0
fi

if [ -z "$TOKEN" ] || [[ "$TOKEN" == ERR* ]]; then
  echo "❌ 令牌提取失败（${TOKEN:-空}）。请依次确认：" >&2
  echo "   ① 已安装并**登录** WorkBuddy 桌面端（先打开它，确认界面里是已登录状态）" >&2
  echo "   ② 终端能执行 node —— 跑 bash scripts/preflight.sh 可一次看清缺什么" >&2
  exit 1
fi

echo "================ ⚠️ 安全提示 ================"
echo "下面是等同账号密码的 accessToken（有效期约 55 天）。"
echo "复制后请立即粘贴到 GitHub Secrets / 云函数环境变量，"
echo "然后关闭本终端窗口，不要留存在剪贴板历史。"
echo "============================================="
echo ""
echo "WB_CHECKIN_TOKEN:"
echo "$TOKEN"
echo ""
echo "WB_CHECKIN_UID:"
echo "${UID_VAL:-（空，老式请求头可不带）}"
