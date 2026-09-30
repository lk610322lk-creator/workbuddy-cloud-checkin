#!/usr/bin/env bash
# ============================================================
# WorkBuddy 云端令牌体检（只读诊断，绝不做签到，绝不打印令牌原文）
#
# 目的：回答两个用签到日志答不了的问题 ——
#   1. 云端 Secret 里这把令牌是「哪一把」（签发时间 / 有效期 / 唯一标识）？
#   2. 它现在还能通过鉴权吗？
# 并且提供**对照实验**能力：同时体检两把令牌（当前令牌 + 实验用旧令牌），
# 用来验证「桌面端换发新令牌后，先前镜像到云端的旧令牌是否仍然有效」。
#
# 输入（环境变量，由工作流从 Secrets 注入）：
#   WB_TOKEN      必填，= secrets.WB_CHECKIN_TOKEN（云端当前令牌）
#   WB_UID        必填，= secrets.WB_CHECKIN_UID
#   WB_OLD_TOKEN  可选，= secrets.WB_TEST_OLD_TOKEN（实验对照组：一把更早签发的令牌）
#   GITHUB_STEP_SUMMARY  GitHub 自动提供，结果同时写入运行摘要页
#
# 输出：markdown 表格（含指纹 / 签发时间 / 到期时间 / 剩余天数 / 鉴权 HTTP 码）
#
# ⚠️ 安全：只打印 sha256 指纹与 JWT 的时间声明，**任何情况下都不打印令牌原文**。
#    对照用的「坏令牌」在内存中篡改生成，不来源于任何 Secret 内容以外的信息。
# ============================================================
set -uo pipefail

API="https://copilot.tencent.com"

say() { printf '%s\n' "$*"; }

# ---------- JWT 载荷解码（只取时间与标识声明，不含签名） ----------
# stdin: token  →  stdout: iat|exp|jti|sid
jwt_claims() {
  python3 -c '
import sys, base64, json
t = sys.stdin.read().strip()
p = t.split(".")
if len(p) != 3:
    print("||||"); sys.exit()
b = p[1] + "=" * (-len(p[1]) % 4)
try:
    j = json.loads(base64.urlsafe_b64decode(b))
except Exception:
    print("||||"); sys.exit()
print("%s|%s|%s|%s" % (j.get("iat", ""), j.get("exp", ""), j.get("jti", ""), j.get("sid", "")))
'
}

# 秒级时间戳 → 北京时间字符串
bj() {
  [ -n "${1:-}" ] || { echo "-"; return; }
  python3 -c "import sys,time;print(time.strftime('%Y-%m-%d %H:%M', time.gmtime(int(sys.argv[1])+28800))+' BJ')" "$1" 2>/dev/null || echo "-"
}

# 查询签到状态，只看 HTTP 码（成功 200；令牌无效 401/403）
probe_status() { # $1 = token
  curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST \
    -H "Content-Type: application/json" -H "Accept: application/json" \
    -H "Authorization: Bearer $1" -H "X-User-Id: ${WB_UID:-}" \
    -d '{}' "${API}/billing/meter/checkin-status" 2>/dev/null || echo "000"
}

# 单把令牌的体检结果 → 追加一行 markdown 表
row() { # $1 = 名称, $2 = token
  local name="$1" tok="${2:-}"
  if [ -z "$tok" ]; then
    say "| $name | （未配置） | - | - | - | - |"
    return
  fi
  local fp iat exp jti sid left http iat_bj exp_bj jti_short
  fp="$(printf '%s' "$tok" | sha256sum | cut -c1-16)"
  IFS='|' read -r iat exp jti sid <<< "$(printf '%s' "$tok" | jwt_claims)"
  iat_bj="$(bj "$iat")"
  exp_bj="$(bj "$exp")"
  if [ -n "$exp" ] && [ "$exp" != "None" ]; then
    left="$(python3 -c "import sys,time;print('%.1f'%((int(sys.argv[1])-time.time())/86400))" "$exp" 2>/dev/null || echo '?')"
  else
    left="?"
  fi
  http="$(probe_status "$tok")"
  jti_short="${jti:0:8}"
  printf '| %s | `%s` | %s | %s | %s | **%s** |\n' \
    "$name" "$fp" "$iat_bj" "$exp_bj" "${left}天" "$http"
}

say "## WorkBuddy 云端令牌体检"
say ""
say "运行时间：$(python3 -c "import time;print(time.strftime('%Y-%m-%d %H:%M', time.gmtime(time.time()+28800))+'（北京时间）')")"
say ""
say "| 令牌 | sha256 指纹(前16) | 签发时间 | 到期时间 | 剩余 | checkin-status |"
say "|---|---|---|---|---|---|"

row "云端当前令牌 \`WB_CHECKIN_TOKEN\`" "${WB_TOKEN:-}"
row "实验对照旧令牌 \`WB_TEST_OLD_TOKEN\`" "${WB_OLD_TOKEN:-}"

# ---------- 对照组：故意损坏的令牌 ----------
# 证明这个接口**确实**在鉴权：若坏令牌也是 200，那前面所有 200 就都不可信了。
if [ -n "${WB_TOKEN:-}" ]; then
  last="$(printf '%s' "$WB_TOKEN" | tail -c 1)"
  body="$(printf '%s' "$WB_TOKEN" | head -c -1)"
  if [ "$last" = "A" ]; then bad="${body}B"; else bad="${body}A"; fi
  bad_http="$(probe_status "$bad")"
  printf '| 对照：人为损坏的令牌 | `(未打印)` | - | - | - | **%s**（预期 401） |\n' "$bad_http"
  say ""
  if [ "$bad_http" = "401" ] || [ "$bad_http" = "403" ]; then
    say "✓ 对照组通过：损坏令牌被拒绝（HTTP ${bad_http}），说明上表 200 是真实鉴权通过，不是接口放行。"
  else
    say "⚠️ 对照组异常：损坏令牌返回 HTTP ${bad_http}（预期 401/403）——上表 200 的含义需要重新评估！"
  fi
  unset bad body
fi

say ""
say "> 判读：同一把令牌的指纹与本机 \`bash scripts/token-fingerprint.sh\` 输出一致 → 云端持有的就是这一把。"

# 同步写入运行摘要页，便于直接在 Actions 页面看到结论
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    say "## WorkBuddy 云端令牌体检"
    say ""
    say "| 令牌 | sha256 指纹(前16) | 签发时间 | 到期时间 | 剩余 | checkin-status |"
    say "|---|---|---|---|---|---|"
    row "当前令牌 WB_CHECKIN_TOKEN" "${WB_TOKEN:-}"
    row "对照旧令牌 WB_TEST_OLD_TOKEN" "${WB_OLD_TOKEN:-}"
  } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
fi

unset WB_TOKEN WB_OLD_TOKEN
