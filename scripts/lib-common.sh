#!/usr/bin/env bash
# ============================================================
# workbuddy-cloud-checkin · 公共库
#
# 被其它脚本 source 使用（不要单独执行）。给所有脚本提供四件跨平台能力，
# 目的是让这套脚本在**任何人的机器上**开箱可用，不需要改任何路径或仓库名：
#
#   1. wb_find_gh       定位 GitHub CLI
#   2. wb_find_node     定位 Node（解密本机登录态用到）
#   3. wb_resolve_repo  解析目标仓库（环境变量 → 本地状态文件 → 自动推断）
#   4. wb_now_cn        北京时间字符串（不依赖 tzdata）
#
# 支持平台：Windows(Git Bash/MSYS) / macOS / Linux
# ============================================================

# ---------- 0. 通用输出 ----------
wb_say() { printf '%s\n' "$*"; }

# ---------- 1. 定位 GitHub CLI ----------
# 顺序：WB_GH 环境变量 → PATH → 各平台常见安装位置
wb_find_gh() {
  local c cand
  if [ -n "${WB_GH:-}" ] && [ -x "$WB_GH" ]; then printf '%s' "$WB_GH"; return 0; fi
  c="$(command -v gh 2>/dev/null || true)"
  [ -n "$c" ] && { printf '%s' "$c"; return 0; }
  for cand in \
      "/c/Program Files/GitHub CLI/gh.exe" \
      "$LOCALAPPDATA/Programs/GitHub CLI/gh.exe" \
      "$HOME/AppData/Local/Programs/GitHub CLI/gh.exe" \
      "/opt/homebrew/bin/gh" \
      "/usr/local/bin/gh" \
      "$HOME/.local/bin/gh" \
      "/usr/bin/gh"; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then printf '%s' "$cand"; return 0; fi
  done
  return 1
}

# ---------- 2. 定位 Node ----------
# 顺序：WB_NODE 环境变量 → PATH → WorkBuddy 客户端自带 node → 常见安装位置
# 为什么需要：本机登录态解密脚本是 JS，需要 node 执行。
wb_find_node() {
  local c cand
  if [ -n "${WB_NODE:-}" ] && [ -x "$WB_NODE" ]; then printf '%s' "$WB_NODE"; return 0; fi
  c="$(command -v node 2>/dev/null || true)"
  [ -n "$c" ] && { printf '%s' "$c"; return 0; }
  # WorkBuddy 客户端自带（装了客户端就有，无需用户另装 Node）
  for cand in \
      "$HOME"/.workbuddy/binaries/node/current/bin/node \
      "$HOME"/.workbuddy/binaries/node/current/node.exe \
      "$HOME"/.workbuddy/binaries/node/versions/*/bin/node \
      "$HOME"/.workbuddy/binaries/node/versions/*/node.exe \
      "$HOME"/.workbuddy/tools/node/node \
      "$HOME"/.workbuddy/tools/node/node.exe; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then printf '%s' "$cand"; return 0; fi
  done
  for cand in \
      "$HOME/.local/bin/node" "/opt/homebrew/bin/node" "/usr/local/bin/node" "/usr/bin/node" \
      "/c/Program Files/nodejs/node.exe"; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then printf '%s' "$cand"; return 0; fi
  done
  return 1
}

# ---------- 3. 解析目标仓库 ----------
# 优先级：WB_REPO 环境变量 → state/cloud-repo.txt → 用 gh 登录账号自动推断
# 说明：state/cloud-repo.txt 由 setup-cloud-repo.sh 在配置成功时写入，
#       因此「一条命令配好之后」，其余脚本无需任何参数即可找到对应仓库。
wb_resolve_repo() { # $1 = 技能根目录, $2 = gh 路径（可选）
  local skill_dir="$1" gh="${2:-}" r f owner
  if [ -n "${WB_REPO:-}" ]; then printf '%s' "$WB_REPO"; return 0; fi
  f="$skill_dir/state/cloud-repo.txt"
  if [ -f "$f" ]; then
    r="$(grep -v '^[[:space:]]*$' "$f" 2>/dev/null | head -1 | tr -d ' \r\n')"
    if [ -n "$r" ]; then printf '%s' "$r"; return 0; fi
  fi
  if [ -n "$gh" ]; then
    owner="$("$gh" api user --jq .login 2>/dev/null || true)"
    owner="$(printf '%s' "$owner" | tr -d ' \r\n')"
    if [ -n "$owner" ]; then printf '%s/workbuddy-checkin' "$owner"; return 0; fi
  fi
  return 1
}

# 记住配置好的仓库，供后续脚本免参数使用
wb_save_repo() { # $1 = 技能根目录, $2 = owner/repo
  mkdir -p "$1/state" 2>/dev/null || return 1
  printf '%s\n' "$2" > "$1/state/cloud-repo.txt"
}

# ---------- 4. 北京时间 ----------
# 为什么不写 TZ=Asia/Shanghai：Git Bash 等环境没有 tzdata，会静默按 UTC 计算
# 却仍标称北京时间（实测踩到过）。这里用显式 +8 小时偏移，跨平台结果一致。
wb_now_cn() {
  local node_bin out
  node_bin="$(wb_find_node 2>/dev/null || true)"
  if [ -n "$node_bin" ]; then
    out="$("$node_bin" -e \
      "console.log(new Date(Date.now()+8*3600000).toISOString().replace('T',' ').slice(0,19))" \
      2>/dev/null)"
    if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
  fi
  date -u -d '+8 hours' '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
    || date -u -v+8H '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
    || date '+%Y-%m-%d %H:%M:%S'
}

# ---------- 5. 跨平台小工具 ----------
# macOS 没有 sha256sum（用 shasum -a 256），GNU 与 BSD 的 base64 选项也不同，
# 这里统一收口，避免每个脚本各写一遍、各踩一遍。
wb_sha256() { # stdin -> 64 位十六进制
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
  else
    openssl dgst -sha256 | sed 's/^.*= //'
  fi
}

wb_b64_file() { # $1 = 文件路径 -> 单行 base64
  local f="$1" out=""
  if out="$(base64 -w0 "$f" 2>/dev/null)" && [ -n "$out" ]; then
    printf '%s' "$out"; return 0
  fi
  base64 < "$f" 2>/dev/null | tr -d '\n'
}

# ---------- 6. 定位带 pyyaml 的 Python（可选依赖） ----------
# 只用于推送前的 YAML「真解析」自检。找不到**不算错误**：调用方降级为缩进自检即可。
# 覆盖三类：用户显式指定 → WorkBuddy 客户端自带 Python → 系统 python3/python
wb_find_python_yaml() {
  local cand
  for cand in \
      "${WB_PYTHON:-}" \
      "$HOME/.workbuddy/binaries/python/envs/default/Scripts/python.exe" \
      "$HOME"/.workbuddy/binaries/python/envs/*/Scripts/python.exe \
      "$HOME/.workbuddy/binaries/python/envs/default/bin/python" \
      "$HOME"/.workbuddy/binaries/python/versions/*/python.exe \
      "python3" "python"; do
    [ -n "$cand" ] || continue
    if command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ]; then
      if "$cand" -c "import yaml" >/dev/null 2>&1; then printf '%s' "$cand"; return 0; fi
    fi
  done
  return 1
}

# ---------- 7. 统一的「找不到依赖」提示 ----------
wb_need_gh_msg() {
  wb_say "❌ 未找到 GitHub CLI（gh）——它是本方案唯一需要额外安装的工具。"
  wb_say "   Windows : winget install --id GitHub.cli -e"
  wb_say "   macOS   : brew install gh"
  wb_say "   Linux   : 见 https://github.com/cli/cli#installation"
  wb_say "   装好后重开终端，再跑一遍 bash scripts/preflight.sh 体检。"
}

wb_need_node_msg() {
  wb_say "❌ 未找到 Node.js —— 读取本机登录态需要它。"
  wb_say "   Windows : winget install --id OpenJS.NodeJS.LTS -e"
  wb_say "   macOS   : brew install node"
  wb_say "   Linux   : 系统包管理器安装 nodejs"
  wb_say "   （WorkBuddy 客户端通常自带一份，若报此错可加 WB_NODE=<node 完整路径> 重试）"
}
