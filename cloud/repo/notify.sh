#!/usr/bin/env bash
# ============================================================
# WorkBuddy 签到结果通知 —— 多通道，可只配一个，也可同时配多个
#
# 由 .github/workflows/checkin.yml 在签到后调用：
#   bash notify.sh "<标题>" "<正文>"
#
# 支持的渠道（未配置的渠道自动跳过，任一渠道失败只告警、不使 job 失败）：
#   NOTIFY_ROBOT_URL       钉钉群机器人 或 企业微信群机器人 Webhook
#                          （两者 JSON 报文格式相同，故共用一条通路）
#   NOTIFY_ROBOT_SECRET    可选：钉钉机器人安全设置选「加签」时的密钥
#                          （若安全设置选的是「自定义关键词」，把关键词写进正文即可，此项留空）
#   NOTIFY_SERVERCHAN_KEY  Server酱 SendKey → 推送到微信（个人微信最省事的通路）
#   SMTP_HOST/SMTP_PORT/SMTP_USER/SMTP_PASS/SMTP_TO
#                          邮件；SMTP_PASS 填邮箱「授权码」而非登录密码
#                          （QQ邮箱 smtp.qq.com:465；163邮箱 smtp.163.com:465；企业微信邮箱 smtp.exmail.qq.com:465）
#
# 依赖：curl + openssl（ubuntu-latest 与 Git Bash 均自带）。不依赖 jq/python。
# ============================================================
set -uo pipefail

TITLE="${1:-WorkBuddy 每日签到}"
MSG="${2:-（无内容）}"
CHANNELS_USED=0
FAILED=0

say() { printf '%s\n' "$*"; }

# 把纯文本转成 JSON 字符串内容（仅需转义 \ " 换行 制表，避免依赖 jq/python）
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# 钉钉加签用：RFC3986 百分号编码
urlencode() {
  local s="$1" out="" c i
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

# ---------- 渠道 1：群机器人（钉钉 / 企业微信） ----------
notify_robot() {
  [ -n "${NOTIFY_ROBOT_URL:-}" ] || return 0
  CHANNELS_USED=$((CHANNELS_USED+1))
  local url="$NOTIFY_ROBOT_URL" content payload resp http body errcode
  if [ -n "${NOTIFY_ROBOT_SECRET:-}" ]; then
    local ts sign
    ts="$(( $(date +%s) * 1000 ))"
    sign="$(printf '%s\n%s' "$ts" "$NOTIFY_ROBOT_SECRET" \
      | openssl dgst -sha256 -hmac "$NOTIFY_ROBOT_SECRET" -binary | base64 | tr -d '\n')"
    url="${url}&timestamp=${ts}&sign=$(urlencode "$sign")"
  fi
  # ⚠️ 必须先拼成单个字符串再整体转义：若在模板里直接换行，会留下裸换行 → JSON 非法。
  #    实测教训：钉钉/企业微信用非法 JSON 时**可能仍返回 HTTP 200**，body 里才带 errcode≠0。
  content="$(printf '%s\n%s' "$TITLE" "$MSG")"
  payload="{\"msgtype\":\"text\",\"text\":{\"content\":\"$(json_escape "$content")\"}}"
  resp="$(curl -sS -m 20 -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d "$payload" "$url" 2>&1)" || true
  http="$(printf '%s' "$resp" | tail -n 1)"
  body="$(printf '%s' "$resp" | sed '$d')"
  errcode="$(printf '%s' "$body" | tr -d ' \n' | sed -n 's/.*"errcode":\(-\?[0-9]\+\).*/\1/p')"
  say "  [群机器人] HTTP=${http:-无} errcode=${errcode:-未知} $(printf '%s' "$body" | head -c 200)"
  if [ "$http" = "200" ] && [ "$errcode" = "0" ]; then
    :
  else
    echo "::warning::群机器人通知发送失败（HTTP ${http:-无} errcode=${errcode:-未知}）"
    FAILED=1
  fi
}

# ---------- 渠道 2：Server酱 → 微信 ----------
# ⚠️ Server酱有两版，**SendKey 不通用、端点也不同**，故按前缀自动识别（防「注册错版本 → 静默失败」）：
#     SCT…   → Server酱·Turbo(SCT)：https://sctapi.ftqq.com/<key>.send          —— 推送到**微信**（服务号）
#     sctp…  → Server酱³(SC3)      ：https://<uid>.push.ft07.com/send/<key>.send —— 推送到**独立 App**（非微信）
#              （uid 取自 sctp{uid}t… 的 {uid} 段，例如 sctp123tXXXX → uid=123）
#   只想在**个人微信**里收 → 必须用 Turbo(SCT)，注册入口 https://sct.ftqq.com （微信扫码，免费 5 条/天，仅显示标题）。
sc_mask() { # 脱敏：只留首尾，绝不打印完整 key
  local s="$1"
  if [ "${#s}" -le 12 ]; then printf '***'; else printf '%s…%s' "${s:0:6}" "${s: -4}"; fi
}

sc_endpoint() { # 成功则输出端点，失败（格式无法识别）无输出
  local key="$1" uid
  case "$key" in
    sctp*)
      uid="${key#sctp}"; uid="${uid%%t*}"
      case "$uid" in ''|*[!0-9]*) return 1 ;; esac
      printf 'https://%s.push.ft07.com/send/%s.send' "$uid" "$key"
      ;;
    *) printf 'https://sctapi.ftqq.com/%s.send' "$key" ;;
  esac
}

notify_serverchan() {
  [ -n "${NOTIFY_SERVERCHAN_KEY:-}" ] || return 0
  CHANNELS_USED=$((CHANNELS_USED+1))
  local url host kind
  case "$NOTIFY_SERVERCHAN_KEY" in
    sctp*) kind="Server酱³(SC3，推送到独立 App，非微信)" ;;
    *)     kind="Server酱·Turbo(SCT，推送到微信)" ;;
  esac
  if ! url="$(sc_endpoint "$NOTIFY_SERVERCHAN_KEY")" || [ -z "$url" ]; then
    say "  [Server酱] ✗ SendKey 形如 sctp{uid}t… 但 {uid} 段不是数字，无法拼端点（key=$(sc_mask "$NOTIFY_SERVERCHAN_KEY")）"
    echo "::warning::Server酱通知发送失败（SendKey 格式无法识别）"
    FAILED=1
    return 0
  fi
  host="$(printf '%s' "$url" | sed -E 's#^https://([^/]+).*#\1#')"
  # 自检用：只打印「识别成哪一版 + 端点主机 + 脱敏 key」，绝不打印完整 URL/key，也不发请求
  if [ "${WB_NOTIFY_DRY:-}" = "1" ]; then
    say "  [Server酱] DRY：识别为 $kind；host=${host}；key=$(sc_mask "$NOTIFY_SERVERCHAN_KEY")；未发送"
    return 0
  fi
  local resp
  resp="$(curl -sS -m 20 -w '\n%{http_code}' -X POST \
    "$url" \
    --data-urlencode "title=$TITLE" --data-urlencode "desp=$MSG" 2>&1)" || true
  local http; http="$(printf '%s' "$resp" | tail -n 1)"
  # ⚠️ 响应体里含 `readkey`（Server酱 用它读取推送内容，同属凭据）→ 落到日志前必须脱敏。
  say "  [Server酱→微信] HTTP=${http:-无} $(printf '%s' "$resp" | sed '$d' | sed -E 's/"readkey":"[^"]*"/"readkey":"***"/g; s/"pushid":"[0-9]+"/"pushid":"***"/g' | head -c 200)"
  if [ "${http:-}" != "200" ] || printf '%s' "$resp" | grep -q '"code":1'; then
    echo "::warning::Server酱通知发送失败（HTTP ${http:-无}；识别为 ${kind}）"
    FAILED=1
  fi
}

# ---------- 渠道 3：邮件（curl 直连 SMTP，无需额外依赖） ----------
notify_mail() {
  [ -n "${SMTP_HOST:-}" ] && [ -n "${SMTP_TO:-}" ] || return 0
  CHANNELS_USED=$((CHANNELS_USED+1))
  local port="${SMTP_PORT:-465}"
  local from="${SMTP_FROM:-${SMTP_USER:-}}"
  local scheme="smtps" extra=""
  if [ "$port" != "465" ]; then scheme="smtp"; extra="--ssl-reqd"; fi
  local mailfile="/tmp/wb_notify_mail.$$.txt"
  {
    printf 'From: %s\r\n' "$from"
    printf 'To: %s\r\n' "$SMTP_TO"
    printf 'Subject: =?UTF-8?B?%s?=\r\n' "$(printf '%s' "$TITLE" | base64 | tr -d '\n')"
    printf 'MIME-Version: 1.0\r\n'
    printf 'Content-Type: text/plain; charset=UTF-8\r\n'
    printf 'Content-Transfer-Encoding: 8bit\r\n'
    printf '\r\n%s\r\n\r\n' "$MSG"
  } > "$mailfile"
  local err rc
  err="$(curl -sS -m 30 $extra --url "${scheme}://${SMTP_HOST}:${port}" \
    --user "${SMTP_USER:-}:${SMTP_PASS:-}" \
    --mail-from "$from" --mail-rcpt "$SMTP_TO" \
    --upload-file "$mailfile" 2>&1)"; rc=$?
  rm -f "$mailfile"
  if [ "$rc" = "0" ]; then
    say "  [邮件] 已投递至 ${SMTP_TO}"
  else
    say "  [邮件] 失败：$(printf '%s' "$err" | tail -c 200)"
    echo "::warning::邮件通知发送失败（rc=$rc）"
    FAILED=1
  fi
}

say "▶ 通知：$TITLE"
notify_robot
notify_serverchan
notify_mail

if [ "$CHANNELS_USED" = "0" ]; then
  say "  （未配置任何通知渠道，跳过发送；下方为本次通知正文，便于在日志中查看）"
  say "  ---- 通知正文 ----"
  say "  ${TITLE}"
  printf '%s\n' "$MSG" | sed 's/^/  /'
  say "  ------------------"
  say "  想开启：钉钉/企业微信群机器人 → Secret 名 NOTIFY_ROBOT_URL（钉钉勾了「加签」再加 NOTIFY_ROBOT_SECRET）"
  say "          微信（Server酱）→ Secret 名 NOTIFY_SERVERCHAN_KEY"
  say "          邮件 → Secret 名 SMTP_HOST / SMTP_PORT / SMTP_USER / SMTP_PASS / SMTP_TO"
elif [ "$FAILED" = "0" ]; then
  say "✓ 通知已发出（共 ${CHANNELS_USED} 个渠道）"
else
  say "⚠️ 部分渠道发送失败（见上方 ::warning::，不影响签到本身）"
fi

# 通知失败不使 workflow 失败：签到成功才是关键
exit 0
