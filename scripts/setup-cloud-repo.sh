#!/bin/bash
# ============================================================
# WorkBuddy 签到 · GitHub 云端仓库一键落地
#
# 做什么（全部通过 GitHub API，不依赖 git push）：
#   1. 检查 gh 登录状态（未登录则给出登录指引）
#   2. 创建私有仓库
#   3. 通过 contents API 写入 .github/workflows/checkin.yml 与 README.md
#   4. 提取本机令牌，管道灌入仓库 Secrets（令牌全程不显示）
#   5. 触发一次 workflow 并回读运行结果
#
# 为什么用 API 而不是 git push：
#   国内直连 github.com 常被干扰（实测 5 次请求 2 通 3 超时），
#   而 api.github.com 相对更稳；API 写入不需要 git/ssh 通道。
#
# 用法（在你自己的终端里跑，Windows 用 Git Bash / macOS 用 Terminal 均可）：
#   bash scripts/setup-cloud-repo.sh                # 默认仓库名 workbuddy-checkin
#   WB_REPO_NAME=wb-checkin bash scripts/setup-cloud-repo.sh
#   WB_REPO_NAME=xxx bash scripts/setup-cloud-repo.sh --skip-run   # 只建仓库不做验证
#
# ⚠️ 前提：先完成 gh 登录（脚本会检测并提示）：
#   gh auth login --hostname github.com --git-protocol https --web
# ============================================================
set -uo pipefail

# ⚠️ Git Bash/MSYS 会把以 / 开头的参数当成路径自动转换（实测把 "/repos/owner/repo/..."
# 转成了 "C:/.../PortableGit/.../repos/..."，导致 gh api 报 invalid API endpoint）。
# 关闭自动转换；同时下面所有 API 端点都不写前导斜杠，双保险。
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib-common.sh
. "$SCRIPT_DIR/lib-common.sh"
REPO_NAME="${WB_REPO_NAME:-workbuddy-checkin}"
DO_RUN=1
VERIFY_FAILED=0
[ "${1:-}" = "--skip-run" ] && DO_RUN=0

# ---------- 定位 gh（跨平台，统一走 lib） ----------
GH="$(wb_find_gh || true)"
if [ -z "$GH" ]; then
  wb_need_gh_msg
  exit 1
fi
echo "✓ GitHub CLI: $("$GH" --version | head -1)"

# ---------- 带重试的调用（应对 github 直连抖动） ----------
retry() {
  local desc="$1"; shift
  local i=1 max=5 delay=4
  while [ "$i" -le "$max" ]; do
    if "$@" >/tmp/gh_out.$$ 2>/tmp/gh_err.$$; then
      cat /tmp/gh_out.$$; rm -f /tmp/gh_out.$$ /tmp/gh_err.$$
      return 0
    fi
    if grep -qiE "already exists|name already exists" /tmp/gh_err.$$ 2>/dev/null; then
      cat /tmp/gh_out.$$ 2>/dev/null; rm -f /tmp/gh_out.$$ /tmp/gh_err.$$
      echo "ℹ️  $desc：已存在，跳过"
      return 0
    fi
    echo "⚠️  $desc 第 $i/$max 次失败：$(tail -1 /tmp/gh_err.$$ 2>/dev/null | cut -c1-160)"
    i=$((i+1))
    [ "$i" -le "$max" ] && sleep $((delay*i))
  done
  echo "❌ $desc 重试 $max 次仍失败"
  rm -f /tmp/gh_out.$$ /tmp/gh_err.$$
  return 1
}

# ⚠️ 带 stdin 的重试：绝不能写成 `printf ... | retry ...`
#    管道会被「第一次尝试」耗尽，后续重试拿到的是空 stdin —— 而 gh secret set 对空
#    stdin 会「成功地」把 Secret 设成空值，造成静默损坏（实测踩到过：签到工作流报
#    「缺少 Secrets」）。因此这里把内容当函数参数传入，每次尝试现场重建管道。
retry_stdin() { # $1 = 描述, $2 = 要喂给 stdin 的内容, 其余 = 命令
  local desc="$1" input="$2"; shift 2
  local i=1 max=5 delay=4
  while [ "$i" -le "$max" ]; do
    # 子 shell 内临时关掉 pipefail：printf 遇 gh 提前退出可能产生 EPIPE，不应误判失败
    if ( set +o pipefail; printf '%s' "$input" | "$@" ) >/tmp/gh_out.$$ 2>/tmp/gh_err.$$; then
      cat /tmp/gh_out.$$; rm -f /tmp/gh_out.$$ /tmp/gh_err.$$
      return 0
    fi
    echo "⚠️  $desc 第 $i/$max 次失败：$(tail -1 /tmp/gh_err.$$ 2>/dev/null | cut -c1-160)"
    i=$((i+1))
    [ "$i" -le "$max" ] && sleep $((delay*i))
  done
  echo "❌ $desc 重试 $max 次仍失败"
  rm -f /tmp/gh_out.$$ /tmp/gh_err.$$
  return 1
}

# ---------- 1. 登录检查 ----------
if ! "$GH" auth status >/dev/null 2>&1; then
  echo ""
  echo "❌ gh 尚未登录。请先在你自己的终端运行下面这一条，完成浏览器授权后再回来重跑本脚本："
  echo ""
  echo "   \"$GH\" auth login --hostname github.com --git-protocol https --web"
  echo ""
  echo "   （会显示一个一次性代码并自动开浏览器；若 github.com 打不开，请先开代理/VPN）"
  exit 1
fi
for __try in 1 2 3 4 5; do
  OWNER="$("$GH" api user --jq .login 2>/dev/null)"
  [ -n "$OWNER" ] && break
  echo "⚠️  获取 GitHub 用户名第 $__try/5 次失败（网络抖动），4s 后重试…"
  sleep $((4*__try))
done
if [ -z "$OWNER" ]; then
  echo "❌ 无法获取 GitHub 用户名（网络不通）。请确认代理已开启、能访问 api.github.com 后重试。"
  exit 1
fi
echo "✓ 已登录：$OWNER"

# ---------- 2. 创建私有仓库 ----------
echo ""
echo "▶ 创建私有仓库 $OWNER/$REPO_NAME ..."
retry "创建仓库" "$GH" repo create "$REPO_NAME" --private \
  --description "WorkBuddy daily checkin on GitHub Actions (no local machine needed)" || exit 1
FULL="$OWNER/$REPO_NAME"
# 记住目标仓库，后续脚本（推令牌 / 补签 / 体检 / 通知测试）即可免参数直接使用
wb_save_repo "$SKILL_DIR" "$FULL" && echo "✓ 已记录目标仓库到 state/cloud-repo.txt"

# ---------- 3. 写入文件（contents API） ----------
push_file() { # $1 = 仓库内相对路径, $2 = 本地文件
  local rel="$1" src="$2" b64 sha i=1 max=5 delay=4
  [ -f "$src" ] || { echo "❌ 本地文件缺失：$src"; return 1; }
  b64="$(wb_b64_file "$src")"
  echo "▶ 写入 $rel ..."
  # ⚠️ 教训（与 Secret 管道 bug 同源）：**凡是「在重试循环外只取一次」的值，都要考虑它取失败时
  #    重试会做错事**。这里 sha 必须每轮重新取：首轮网络抖动取到空值 → 会被当成「新建」，
  #    对已存在文件报 422 "sha wasn't supplied"（实测踩到过）。
  while [ "$i" -le "$max" ]; do
    sha="$("$GH" api "repos/$FULL/contents/$rel" --jq .sha 2>/dev/null || true)"
    if [ -n "$sha" ]; then
      if "$GH" api --method PUT "repos/$FULL/contents/$rel" \
           -f message="update $rel" -f content="$b64" -f sha="$sha" -f branch=main \
           --jq '.commit.sha' >/tmp/pf_out.$$ 2>/tmp/pf_err.$$; then
        cat /tmp/pf_out.$$; rm -f /tmp/pf_out.$$ /tmp/pf_err.$$
        echo "  ✓ $rel 已更新"; return 0
      fi
    else
      if "$GH" api --method PUT "repos/$FULL/contents/$rel" \
           -f message="add $rel" -f content="$b64" -f branch=main \
           --jq '.commit.sha' >/tmp/pf_out.$$ 2>/tmp/pf_err.$$; then
        cat /tmp/pf_out.$$; rm -f /tmp/pf_out.$$ /tmp/pf_err.$$
        echo "  ✓ $rel 已创建"; return 0
      fi
      # 若报 sha wasn't supplied，说明该文件其实已存在（说明首轮取 sha 失败）→ 下一轮会重新取到
    fi
    echo "  ⚠️ 写入 $rel 第 $i/$max 次失败：$(tail -1 /tmp/pf_err.$$ 2>/dev/null | cut -c1-150)"
    i=$((i+1))
    [ "$i" -le "$max" ] && sleep $((delay*i))
  done
  echo "❌ 写入 $rel 重试 $max 次仍失败"
  rm -f /tmp/pf_out.$$ /tmp/pf_err.$$
  return 1
}

# 推送前自检 ①：run: | 块标量内不得出现顶格行（历史故障根因，见 checkin.yml 注释）
lint_workflow() {
  local f="$1" bad
  bad="$(awk '/^        run: \|/{f=1;next} f&&/^[^ ]/{print NR": "$0}' "$f")"
  if [ -n "$bad" ]; then
    echo "❌ 工作流 YAML 缩进自检失败（块标量内出现顶格行，会导致整份 YAML 解析失败）："
    echo "$bad"
    return 1
  fi
  return 0
}

# 推送前自检 ②：用 pyyaml 做真解析（比缩进启发式强得多）。
# 找不到 pyyaml 时自动降级为「仅自检 ①」，不阻塞流程。
lint_workflow_strict() {
  local f="$1" py=""
  py="$(wb_find_python_yaml || true)"
  if [ -z "$py" ]; then
    echo "ℹ️  未找到带 pyyaml 的 Python，跳过严格 YAML 校验（仅做缩进自检）"
    return 0
  fi
  # Windows 上的 Python 不认 Git Bash 的 /c/... 路径，需转成原生路径
  local fwin="$f"
  command -v cygpath >/dev/null 2>&1 && fwin="$(cygpath -w "$f" 2>/dev/null || echo "$f")"
  "$py" - "$fwin" <<'PYEOF'
import sys, io, yaml
p = sys.argv[1]
try:
    d = yaml.safe_load(io.open(p, encoding='utf-8'))
except Exception as e:
    print("❌ YAML 严格解析失败：%s" % e)
    sys.exit(1)
on_key = [k for k in d if k is True or k == 'on']
if not on_key:
    print("❌ YAML 缺少 on: 触发器")
    sys.exit(1)
trig = d[on_key[0]] or {}
if 'workflow_dispatch' not in trig:
    print("❌ 缺少 workflow_dispatch 触发器（dispatch 会报 422）")
    sys.exit(1)
bad = []
for job in (d.get('jobs') or {}).values():
    for st in job.get('steps') or []:
        if 'run' in st:
            r = st['run']
            if not r.endswith('\n'):
                bad.append(st.get('name', '?'))
if bad:
    print("❌ 以下步骤的 run 块疑似被截断（结尾异常）：%s" % bad)
    sys.exit(1)
print("✓ YAML 严格解析通过（触发器: %s；步骤数: %d）" % (
    ",".join(trig.keys()), sum(len(j.get('steps') or []) for j in (d.get('jobs') or {}).values())))
PYEOF
}

mkdir -p "$SKILL_DIR/cloud/repo/.github/workflows"
cp -f "$SKILL_DIR/cloud/workflow-checkin.yml" "$SKILL_DIR/cloud/repo/.github/workflows/checkin.yml" \
  || { echo "❌ 同步 workflow-checkin.yml → cloud/repo/... 失败"; exit 1; }
echo "▶ 推送前校验工作流 ..."
lint_workflow "$SKILL_DIR/cloud/repo/.github/workflows/checkin.yml" || exit 1
lint_workflow_strict "$SKILL_DIR/cloud/repo/.github/workflows/checkin.yml" || exit 1
push_file ".github/workflows/checkin.yml" "$SKILL_DIR/cloud/repo/.github/workflows/checkin.yml" || exit 1
push_file "notify.sh" "$SKILL_DIR/cloud/repo/notify.sh" || exit 1
push_file "diag-token.sh" "$SKILL_DIR/cloud/repo/diag-token.sh" || exit 1
push_file "README.md" "$SKILL_DIR/cloud/repo/README.md" || exit 1

# ---------- 4. 灌 Secrets（令牌仅经管道） ----------
echo ""
echo "▶ 提取本机令牌并写入 Secrets（不会显示令牌内容）..."
TOKEN="$(bash "$SCRIPT_DIR/extract-token-cloud.sh" --raw)"
UID_VAL="$(bash "$SCRIPT_DIR/extract-token-cloud.sh" --uid-only)"
if [ -z "$TOKEN" ] || [ "$TOKEN" = "ERR_TOKEN_UNAVAILABLE" ]; then
  echo "❌ 令牌提取失败。请确认 WorkBuddy 桌面端已登录，然后重跑本脚本。"
  exit 1
fi
if [ -z "$UID_VAL" ]; then
  echo "❌ uid 提取失败（令牌已取到）。请确认 WorkBuddy 桌面端已登录，然后重跑本脚本。"
  exit 1
fi
echo "  令牌长度 ${#TOKEN} 字符（不显示内容）"
retry_stdin "写入 WB_CHECKIN_TOKEN" "$TOKEN" "$GH" secret set WB_CHECKIN_TOKEN -R "$FULL" || exit 1
retry_stdin "写入 WB_CHECKIN_UID" "$UID_VAL" "$GH" secret set WB_CHECKIN_UID -R "$FULL" || exit 1
unset TOKEN UID_VAL
echo "✓ Secrets 已写入（令牌未显示、未落盘）"

# ---------- 5. 触发验证 ----------
if [ "$DO_RUN" = "1" ]; then
  echo ""
  echo "▶ 触发一次 workflow 验证..."
  # 刚写入的 workflow 需要片刻才会被 Actions 注册，否则 dispatch 报 422
  WID=""
  for i in 1 2 3 4 5 6; do
    WID="$("$GH" api "repos/$FULL/actions/workflows" --jq '.workflows[0].id' 2>/dev/null || true)"
    [ -n "$WID" ] && break
    sleep 5
  done
  if [ -z "$WID" ]; then
    echo "⚠️  工作流尚未被 GitHub 注册（可稍后在网页 Actions 页手动 Run workflow）"
  else
    echo "  workflow id = $WID"
    sleep 5
    if retry "触发 workflow" "$GH" api --method POST "repos/$FULL/actions/workflows/$WID/dispatches" -f ref=main; then
      echo "  ✓ 已触发，等待运行结果…"
      sleep 20
      echo ""
      echo "▶ 最近运行："
      for __t in 1 2 3; do
        "$GH" run list -R "$FULL" --limit 4 2>/dev/null && break
        sleep 4
      done
      RID="$("$GH" run list -R "$FULL" --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)"
      if [ -n "$RID" ]; then
        echo ""
        echo "▶ 运行日志（关键行）："
        for __t in 1 2 3; do
          "$GH" run view "$RID" -R "$FULL" --log 2>/dev/null \
            | grep -iE "notice|error|签到|积分|HTTP=" | tail -12 && break
          sleep 4
        done
      fi
      echo ""
      echo "▶ 运行详情链接：https://github.com/$FULL/actions"
      CONCL=""
      for __t in 1 2 3; do
        CONCL="$("$GH" run view "$RID" -R "$FULL" --json conclusion --jq '.conclusion' 2>/dev/null)"
        [ -n "$CONCL" ] && [ "$CONCL" != "null" ] && break
        sleep 6
      done
      case "$CONCL" in
        success) echo "✓ 验收通过：云端签到链路已跑通（本次为幂等重复触发，属正常）" ;;
        "")      echo "ℹ️  运行尚未结束或结论未取到，可稍后在网页查看" ;;
        *)       echo "❌ 验收失败：运行结论=$CONCL，请检查上方日志或网页详情"; VERIFY_FAILED=1 ;;
      esac
    else
      echo "⚠️  触发失败（配置已就绪，可稍后重试或在网页 Actions 页点 Run workflow）"
      echo "    若持续报 422，检查 .github/workflows/checkin.yml 是否 YAML 解析失败。"
    fi
  fi
fi

echo ""
echo "==================== 完成 ===================="
echo "仓库：https://github.com/$FULL （私有）"
echo "定时：北京时间 08:30（主干）+ 20:30（兜底）自动签到 —— 接口幂等，重复跑也安全"
echo ""
echo "建议接着做两件事："
echo "  1) 让令牌自动续期：把 push-token-to-cloud.sh 挂成每周一次的计划任务（见 SKILL.md「令牌无感续期」）"
echo "  2) 想要签到结果推到微信/钉钉：见 references/notify-channels.md"
echo ""
echo "极端情况（连续 55 天未用桌面端）看到 401 时："
echo "  1) 打开 WorkBuddy 桌面端（自动换发新令牌）"
echo "  2) 跑 bash scripts/push-token-to-cloud.sh --force（幂等，自带云端验收）"
echo "============================================="

if [ "$VERIFY_FAILED" = "1" ]; then
  exit 1
fi
