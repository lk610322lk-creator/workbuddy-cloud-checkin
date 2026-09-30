#!/bin/bash
# ============================================================
# WorkBuddy 令牌指纹工具（安全版：只输出摘要，绝不输出令牌原文）
#
# 用途：
#   1. 回答「本机当前令牌 vs 云端 Secret 里的令牌，是不是同一个」——
#      两边各自跑一次，比较 FINGERPRINT 即可（相同则同令牌，不同则已换代）。
#   2. 回答「本机令牌什么时候签发的、还有多久过期」——看 IAT / EXP / LEFT_DAYS。
#   3. 排查「云端 401」时确认本机令牌是否已经换代。
#
# 输出字段：
#   FINGERPRINT     sha256(token) 前 16 位十六进制（非可逆，无法反推令牌）
#   LENGTH          token 字节数（用于确认是否读到完整令牌）
#   IAT / EXP       JWT 签发/过期时间（UTC，ISO8601）
#   IAT_BJ / EXP_BJ 同上，北京时间
#   LEFT_DAYS       距过期的剩余天数（保留 1 位小数）
#   JTI / SID       JWT 唯一标识 / 会话标识（用于判断是否为不同次签发）
#
# 用法：
#   bash scripts/token-fingerprint.sh          # 打印指纹
#   bash scripts/token-fingerprint.sh --json   # 机器可读（便于脚本比较）
#
# ⚠️ 安全：本脚本只用令牌计算哈希、只在内存里解析 JWT 载荷，
#    不打印令牌、不写文件、不发网络请求。
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DECRYPT_JS="$SCRIPT_DIR/decrypt-token.js"
JSON=0
[ "${1:-}" = "--json" ] && JSON=1

find_node() {
  if [ -n "${WB_CHECKIN_NODE:-}" ] && [ -x "$WB_CHECKIN_NODE" ]; then echo "$WB_CHECKIN_NODE"; return; fi
  local c
  for c in "$(command -v node 2>/dev/null)" "$HOME/.local/bin/node" "/opt/homebrew/bin/node" "/usr/local/bin/node"; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return; }
  done
  echo ""
}

find_workbuddy_exe() {
  if [ -n "${WB_CHECKIN_WORKBUDDY_EXE:-}" ] && [ -x "$WB_CHECKIN_WORKBUDDY_EXE" ]; then echo "$WB_CHECKIN_WORKBUDDY_EXE"; return; fi
  local c
  for c in "$LOCALAPPDATA/Programs/WorkBuddy/WorkBuddy.exe" "${PROGRAMFILES:-/c/Program Files}/WorkBuddy/WorkBuddy.exe" "$HOME/AppData/Local/Programs/WorkBuddy/WorkBuddy.exe"; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return; }
  done
  echo ""
}

# 与 checkin.sh 同源的令牌读取链（Node 明文 → WorkBuddy.exe 解密 → Electron 旧版）
read_token() {
  local out="" node_bin wb_exe js_arg atrest_arg electron_bin
  js_arg="$DECRYPT_JS"
  command -v cygpath >/dev/null 2>&1 && js_arg="$(cygpath -m "$DECRYPT_JS" 2>/dev/null || echo "$DECRYPT_JS")"
  node_bin="$(find_node)"
  if [ -n "$node_bin" ]; then
    out=$("$node_bin" "$js_arg" 2>/dev/null | grep "^DECRYPT_RESULT:" | sed 's/^DECRYPT_RESULT://')
  fi
  if [ -z "$out" ] || [[ "$out" == ERR* ]]; then
    wb_exe="$(find_workbuddy_exe)"
    if [ -n "$wb_exe" ] && [ -f "$SCRIPT_DIR/decrypt-atrest.js" ]; then
      atrest_arg="$SCRIPT_DIR/decrypt-atrest.js"
      command -v cygpath >/dev/null 2>&1 && atrest_arg="$(cygpath -m "$SCRIPT_DIR/decrypt-atrest.js" 2>/dev/null || echo "$atrest_arg")"
      out=$(env ELECTRON_RUN_AS_NODE=1 "$wb_exe" "$atrest_arg" 2>/dev/null | grep "^DECRYPT_RESULT:" | sed 's/^DECRYPT_RESULT://')
    fi
  fi
  if [ -z "$out" ] || [[ "$out" == ERR* ]]; then
    for electron_bin in "$HOME/.workbuddy/tools/electron/electron.exe" "$SCRIPT_DIR/../.runtime/electron/electron.exe" "$(command -v electron 2>/dev/null)"; do
      [ -n "$electron_bin" ] && [ -x "$electron_bin" ] || continue
      out=$(env -u ELECTRON_RUN_AS_NODE "$electron_bin" "$js_arg" 2>/dev/null | grep "^DECRYPT_RESULT:" | sed 's/^DECRYPT_RESULT://')
      break
    done
  fi
  echo "$out"
}

TOKEN="$(read_token)"
if [ -z "$TOKEN" ] || [[ "$TOKEN" == ERR* ]]; then
  echo "ERR 读取本地令牌失败${TOKEN:+（$TOKEN）}" >&2
  exit 1
fi

FP="$(printf '%s' "$TOKEN" | sha256sum | cut -c1-16)"
LEN="$(printf '%s' "$TOKEN" | wc -c | tr -d ' ')"

# 只把 JWT 的「载荷段」交给解析器（载荷不含签名，不是可用凭据）
PAYLOAD="$(printf '%s' "$TOKEN" | awk -F. '{print $2}')"

NODE_BIN="$(find_node)"
CLAIMS=$(printf '%s' "$PAYLOAD" | "$NODE_BIN" -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  s=s.trim(); if(!s){console.log("{}");return;}
  s=s.replace(/-/g,"+").replace(/_/g,"/");
  while(s.length%4)s+="=";
  try{const j=JSON.parse(Buffer.from(s,"base64").toString("utf8"));
    console.log(JSON.stringify({iat:j.iat||null,exp:j.exp||null,jti:j.jti||null,sid:j.sid||null,iss:j.iss||null,azp:j.azp||null}));
  }catch(e){console.log("{}")}
});' 2>/dev/null)

if [ -z "$CLAIMS" ]; then CLAIMS="{}"; fi

NOW=$(date +%s)
getf() { printf '%s' "$CLAIMS" | sed -n "s/.*\"$1\":\([0-9]*\).*/\1/p"; }
gets() { printf '%s' "$CLAIMS" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }

IAT=$(getf iat); EXP=$(getf exp); JTI=$(gets jti); SID=$(gets sid)

if [ -n "$EXP" ] && [ "$EXP" -gt 0 ] 2>/dev/null; then
  LEFT=$(awk -v e="$EXP" -v n="$NOW" 'BEGIN{printf "%.1f",(e-n)/86400}')
  EXP_UTC=$(date -u -d "@$EXP" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "?")
  EXP_BJ=$(date -u -d "@$((EXP+28800))" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "?")
else
  LEFT="?"; EXP_UTC="?"; EXP_BJ="?"
fi
if [ -n "$IAT" ] && [ "$IAT" -gt 0 ] 2>/dev/null; then
  IAT_UTC=$(date -u -d "@$IAT" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "?")
  IAT_BJ=$(date -u -d "@$((IAT+28800))" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "?")
else
  IAT_UTC="?"; IAT_BJ="?"
fi

if [ "$JSON" = "1" ]; then
  printf '{"fingerprint":"%s","length":%s,"iat":%s,"exp":%s,"left_days":%s,"jti":"%s","sid":"%s"}\n' \
    "$FP" "$LEN" "${IAT:-null}" "${EXP:-null}" "$( [ "$LEFT" = "?" ] && echo null || echo "$LEFT")" "$JTI" "$SID"
else
  echo "FINGERPRINT  : $FP"
  echo "LENGTH       : $LEN"
  echo "IAT          : ${IAT_UTC}  (BJ ${IAT_BJ})"
  echo "EXP          : ${EXP_UTC}  (BJ ${EXP_BJ})"
  echo "LEFT_DAYS    : ${LEFT}"
  echo "JTI          : ${JTI:-—}"
  echo "SID          : ${SID:-—}"
fi
