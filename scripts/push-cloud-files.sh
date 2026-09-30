#!/usr/bin/env bash
# ============================================================
# WorkBuddy 签到 · 把 cloud/repo/ 下的文件同步到云端仓库
#
# 什么时候用：改了工作流（cloud/workflow-checkin.yml）或仓库脚本（notify.sh / diag-token.sh）
# 之后，用它把改动推上去。只碰文件，**不碰 Secrets、不碰仓库设置**，
# 因此可以随时重复运行（幂等）。要连 Secrets 一起重灌时用 setup-cloud-repo.sh。
#
# 用法：
#   bash scripts/push-cloud-files.sh            # 同步全部文件
#   bash scripts/push-cloud-files.sh --dry-run  # 只做本地自检与差异提示，不推送
#
# 推送前会做两道 YAML 自检（顶格行 + 真解析），因为历史上一次缩进事故
# 让整份工作流失效（表现为 0s failure 的运行 + dispatch 报 422）。
# ============================================================
set -uo pipefail

# Git Bash/MSYS 不转换以 / 开头的 API 端点参数
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib-common.sh
. "$SCRIPT_DIR/lib-common.sh"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

say() { printf '%s\n' "$*"; }

# ---------- 找 gh ----------
GH="$(wb_find_gh || true)"
[ -n "$GH" ] || { wb_need_gh_msg; exit 1; }

# 目标仓库：WB_REPO 环境变量 → state/cloud-repo.txt → 按 gh 登录账号自动推断
REPO="$(wb_resolve_repo "$SKILL_DIR" "$GH" 2>/dev/null || true)"
if [ -z "$REPO" ]; then
  say "❌ 无法确定目标仓库。请先跑一次 bash scripts/setup-cloud-repo.sh 完成配置；"
  say "   或显式指定：WB_REPO=<账号>/<仓库名> bash scripts/$(basename "$0")"
  exit 1
fi

# ---------- 1. 生成待推送文件（工作流源 → 仓库路径） ----------
mkdir -p "$SKILL_DIR/cloud/repo/.github/workflows"
cp -f "$SKILL_DIR/cloud/workflow-checkin.yml" "$SKILL_DIR/cloud/repo/.github/workflows/checkin.yml" \
  || { say "❌ 拷贝工作流模板失败"; exit 1; }

FILES=(
  ".github/workflows/checkin.yml:$SKILL_DIR/cloud/repo/.github/workflows/checkin.yml"
  "notify.sh:$SKILL_DIR/cloud/repo/notify.sh"
  "diag-token.sh:$SKILL_DIR/cloud/repo/diag-token.sh"
  "README.md:$SKILL_DIR/cloud/repo/README.md"
)
for pair in "${FILES[@]}"; do
  src="${pair#*:}"
  [ -f "$src" ] || { say "❌ 本地源文件缺失：$src"; exit 1; }
done

# ---------- 2. YAML 自检 ①：run: | 块标量内不得出现顶格行 ----------
lint_workflow() {
  local f="$1" bad
  bad="$(awk '/^        run: \|/{f=1;next} f&&/^[^ ]/{print NR": "$0}' "$f")"
  if [ -n "$bad" ]; then
    say "❌ 工作流 YAML 缩进自检失败（块标量内出现顶格行，会导致整份 YAML 解析失败）："
    say "$bad"
    return 1
  fi
  return 0
}

# ---------- 3. YAML 自检 ②：用 pyyaml 真解析（找不到则降级） ----------
# 探测逻辑统一收在 lib-common.sh（跨平台 + 客户端自带 Python 一并覆盖）
find_python_yaml() { wb_find_python_yaml; }

lint_workflow_strict() {
  local f="$1" py=""
  py="$(find_python_yaml || true)"
  if [ -z "$py" ]; then
    say "ℹ️  未找到带 pyyaml 的 Python，跳过严格 YAML 校验（仅做缩进自检）"
    return 0
  fi
  local fwin="$f"
  command -v cygpath >/dev/null 2>&1 && fwin="$(cygpath -w "$f" 2>/dev/null || echo "$f")"
  "$py" - "$fwin" <<'PYEOF'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
# ⚠️ YAML 1.1 把裸键 on 解析成布尔 True（不是字符串 "on"），两种键都要认，
#    否则会误报「缺少 on: 触发器」。
trig = (doc or {}).get("on", (doc or {}).get(True))
jobs = (doc or {}).get("jobs") or {}
assert trig, "缺少 on: 触发器"
assert jobs, "缺少 jobs:"
print("  ✓ YAML 解析通过，jobs = " + ", ".join(jobs.keys()))
PYEOF
}

# ---------- 3b. 自检 ③：把每个 run: 块的 shell 抽出来做 bash -n 语法校验 ----------
# 为什么需要：前两道自检只保证「YAML 能被解析」，但 run 块里的 shell 语法错误
# （少个 done、引号没闭、`local` 用在函数外…）YAML 层面完全合法，只有等定时跑起来
# 才发现失败 —— 而失败往往发生在没人看的夜里。这里推到云端之前先拦住。
lint_workflow_shell() {
  local f="$1" py=""
  py="$(find_python_yaml || true)"
  if [ -z "$py" ]; then
    say "ℹ️  未找到带 pyyaml 的 Python，跳过 run 块 shell 校验"
    return 0
  fi
  local fwin="$f"
  command -v cygpath >/dev/null 2>&1 && fwin="$(cygpath -w "$f" 2>/dev/null || echo "$f")"
  "$py" - "$fwin" <<'PYEOF'
import sys, os, yaml, tempfile, subprocess
with open(sys.argv[1], encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
bad, n = [], 0
for jname, job in (doc.get("jobs") or {}).items():
    for st in job.get("steps", []):
        sh = st.get("run")
        if not sh:
            continue
        n += 1
        tmp = tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False, encoding="utf-8", newline="\n")
        tmp.write(sh); tmp.close()
        try:
            r = subprocess.run(["bash", "-n", tmp.name], capture_output=True, text=True)
            if r.returncode != 0:
                bad.append("%s / %s → %s" % (jname, st.get("name"), r.stderr.strip().splitlines()[0] if r.stderr.strip() else "语法错误"))
        finally:
            os.unlink(tmp.name)
if bad:
    print("❌ run 块 shell 语法校验失败：")
    for b in bad:
        print("   " + b)
    sys.exit(1)
print("  ✓ run 块 shell 语法通过（共 %d 个）" % n)
PYEOF
}

say "▶ 推送前自检 ..."
WORKFLOW="$SKILL_DIR/cloud/repo/.github/workflows/checkin.yml"
lint_workflow "$WORKFLOW" || exit 1
lint_workflow_strict "$WORKFLOW" || exit 1
lint_workflow_shell "$WORKFLOW" || exit 1

if [ "$DRY" = "1" ]; then
  say "ℹ️  --dry-run：自检通过，未推送。"
  exit 0
fi

# ---------- 4. 登录检查（gh auth status 会联网，抖动需重试并区分原因） ----------
AUTH_STATE=""
for i in 1 2 3 4 5; do
  out="$("$GH" auth status 2>&1)"
  if printf '%s' "$out" | grep -q 'Logged in to'; then AUTH_STATE="ok"; break; fi
  if printf '%s' "$out" | grep -q 'not logged into any GitHub hosts'; then AUTH_STATE="nologin"; break; fi
  say "  ⚠️ 登录状态检查第 $i/5 次未通过（疑似网络抖动），$((4*i))s 后重试…"
  sleep $((4*i))
done
[ "$AUTH_STATE" = "nologin" ] && { say "❌ gh 未登录，请先 gh auth login --web（建议开 VPN）"; exit 1; }
[ "$AUTH_STATE" = "ok" ] || { say "❌ 无法确认 gh 登录状态（连不上 api.github.com，常见于未开 VPN）"; exit 1; }

# ---------- 5. 推送（contents API；sha 每轮重取，避免重试落到「新建」分支） ----------
FULL="$REPO"
push_file() { # $1 = 仓库内相对路径, $2 = 本地文件
  local rel="$1" src="$2" b64 sha i=1 max=5 delay=4
  b64="$(base64 -w0 "$src")"
  say "▶ 写入 $rel ..."
  while [ "$i" -le "$max" ]; do
    sha="$("$GH" api "repos/$FULL/contents/$rel" --jq .sha 2>/dev/null || true)"
    if [ -n "$sha" ]; then
      if "$GH" api --method PUT "repos/$FULL/contents/$rel" \
           -f message="update $rel" -f content="$b64" -f sha="$sha" -f branch=main \
           --jq '.commit.sha' >/tmp/pcf_out.$$ 2>/tmp/pcf_err.$$; then
        say "  ✓ $rel 已更新（commit $(cut -c1-8 /tmp/pcf_out.$$)）"
        rm -f /tmp/pcf_out.$$ /tmp/pcf_err.$$; return 0
      fi
    else
      if "$GH" api --method PUT "repos/$FULL/contents/$rel" \
           -f message="add $rel" -f content="$b64" -f branch=main \
           --jq '.commit.sha' >/tmp/pcf_out.$$ 2>/tmp/pcf_err.$$; then
        say "  ✓ $rel 已创建（commit $(cut -c1-8 /tmp/pcf_out.$$)）"
        rm -f /tmp/pcf_out.$$ /tmp/pcf_err.$$; return 0
      fi
    fi
    say "  ⚠️ 写入 $rel 第 $i/$max 次失败：$(tail -1 /tmp/pcf_err.$$ 2>/dev/null | cut -c1-150)"
    i=$((i+1))
    [ "$i" -le "$max" ] && sleep $((delay*i))
  done
  say "❌ 写入 $rel 重试 $max 次仍失败"
  rm -f /tmp/pcf_out.$$ /tmp/pcf_err.$$
  return 1
}

for pair in "${FILES[@]}"; do
  rel="${pair%%:*}"; src="${pair#*:}"
  push_file "$rel" "$src" || exit 1
done

say ""
say "✓ 全部文件已同步到 https://github.com/$FULL"
say "  体检：Actions → WorkBuddy Daily Checkin → Run workflow → 勾选 diag"
