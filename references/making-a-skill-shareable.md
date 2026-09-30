# 把一枚「个人化技能」改造成可分享版（方法论）

本技能就是这么从个人化的 `workbuddy-checkin` 里抽出来的。如果你以后要把**其它**自用技能也做成
"发给别人就能用"的版本，照这五步走，能避开我们实际踩过的坑。

> 核心判据只有一条：**把技能复制到一个干净目录、删掉所有个人状态，它仍然能跑起来并正确告诉用户"下一步做什么"。**
> 任何一步做完都要回到这条判据上验收。

---

## 第 1 步：把硬编码全部揪出来

先扫三类东西，一个都别漏：

```bash
# ① 个人标识（用户名、账号、机器路径）
grep -rn "你的用户名\|你的账号\|C:/Users/" .

# ② 写死的目标（仓库名、项目名、IP、目录）
grep -rn "写死的仓库名\|写死的路径" .

# ③ 凭据痕迹（哪怕已删掉值，也别留形如真 key 的样例）
grep -rInE "eyJ|ghp_|github_pat_|sk-|SCT[A-Za-z0-9]{10,}" .
```

**本次实测**：硬编码集中在 6 个脚本的同一行（`REPO=...`）、2 处个人 venv 的 python 路径、1 处技能名。
**先分类再动手**：能"收口到公共库"的（可配置项）比"逐个 sed 替换"更彻底 —— 见第 2 步。

> ⚠️ 注意 `eyJ` 这类规则会命中**文档里教人自查的句子**。命中不等于泄露，但**必须逐条人工确认**在看的
> 是文档示例还是真实凭据。

## 第 2 步：把"配置"收口成一个公共库

不要在每个脚本里复制粘贴同一段"找 gh / 找 node / 定目标"的代码 —— 那是以后必然不一致的根源。
本次新建 `scripts/lib-common.sh`，只做四件事：

| 能力 | 设计要点 |
|---|---|
| 定位外部工具 | 环境变量 → PATH → 客户端自带 → 常见安装路径，多级回退 |
| **解析目标（三级）** | 环境变量 → 本地状态文件 → 按身份自动推断 ⇒ **对方无需改任何脚本** |
| 跨平台小工具 | `sha256sum` vs `shasum`、`base64 -w0` vs BSD base64、无 `tzdata` 时算本地时间 |
| 统一错误提示 | 缺依赖时给出**可直接复制**的安装命令 |

**这次最关键的改造成果就是"三级解析"**：用户显式指定 > 本地记下的 > 自动推断。
配置成功时把结果写进 `state/<目标>.txt`，后续脚本便**零参数**可用；离线或未登录时也不会瞎猜。

## 第 3 步：补上"易用层"，让非命令行用户也能用

只给一堆 `.sh` 等于没交付。至少补两样：

1. **环境自检脚本**（`preflight.sh`）：逐项检查并给出修复命令 + 最后一行"下一步做什么"。
   零基础用户第一次接触时，这一屏比任何文档都有用。
2. **双击启动器**（Windows `Start.bat`）：中文号码菜单。
   ⚠️ **必须用脚本生成**（如 Python `open(..., encoding='gbk', newline='\r\n')`），
   用编辑器直写会得到 LF+UTF-8 ⇒ cmd 解析多行 `if` 块崩溃（黑框一闪）、中文乱码。
   文件名必须 ASCII。生成后自检：`b"\r\n" in raw`、`raw.decode("gbk")` 成功。

**关于 bash 的定位**：Windows 上**通常不需要用户另装 Git** —— WorkBuddy 客户端自带 PortableGit：
`%USERPROFILE%\.workbuddy\binaries\PortableGit\versions\<版本>\bin\bash.exe`（国际版在 `.workbuddy-ai` 下）。
⚠️ **实测坑**：该目录下的 `versions\current` 是**版本标记文件、不是目录**，
所以**不能**拼 `current\bin\bash.exe`，必须**遍历版本目录**去找。

## 第 4 步：干净目录验证（模拟"别人拿到手"）

```bash
cp -r <技能目录> /tmp/share-test/<技能名>
rm -rf /tmp/share-test/<技能名>/state        # 关键：去掉所有个人状态
cd /tmp/share-test/<技能名> && bash scripts/preflight.sh
```

**合格标准**：它能跑起来，并且明确说出"尚未配置 + 下一步运行什么"，而不是报一堆莫名其妙的错。
本次实测正是这样才发现：自检在干净副本里给出 `尚未配置云端仓库（已可推断为 …）→ 运行 setup…`。

顺手把全部脚本做一遍语法校验：

```bash
for f in scripts/*.sh; do bash -n "$f" || echo "✗ $f"; done
```

> 💡 **路径坑**：Windows 原生程序（Python / gh.exe 等）**不认 MSYS 的 `/tmp`**，会把它解释成 `C:\tmp`，
> 于是"解压到 /tmp"后 bash 去 `/tmp` 找不到东西。跨两种程序传路径时，**统一用 Windows 原生路径**
> （如 `C:/Users/<你>/AppData/Local/Temp/...`）。

## 第 5 步：脱敏打包 + 交付物复检

打包时**必须排除**运行时状态：`state/`、日志、缓存、`.git`、`__pycache__`。

```python
EX_DIRS = {"state", "__pycache__", ".git", "logs"}
```

打包**之后**再解压回一个干净目录，做四项复检（这次全部实测通过）：

| 复检项 | 本次结果 |
|---|---|
| 是否夹带个人状态（`state/`） | 无 ✓ |
| 个人标识扫描（用户名 / 账号 / uid） | 0 命中 ✓ |
| 全部脚本语法 | 14 个全通过 ✓ |
| 解压副本内能否直接跑自检 | 可以，且指引正确 ✓ |

> **为什么要复检**：打包脚本本身的排除规则、以及"我改完忘了重新打包"这类失误，
> 只有在**解压回来跑一遍**时才会暴露。这一步花 1 分钟，能挡住一次真实的泄露或失效。

---

## 附：本次踩到、值得记住的四个坑

1. **判「成功」不能只匹配前缀。** 解密失败时脚本输出的 `DECRYPT_RESULT:ERR …` **同样匹配**
   `^DECRYPT_RESULT:` ⇒ 被当成成功、**静默不回退**，症状是"明明登录着却读不到令牌"。
   必须校验「值非空 **且** 不以 `ERR` 开头」。
   > 通用化：**错误信息常常长得像成功信息的超集**。判据要校验值本身，而不是它像不像。
2. **判定"能力是否可用"要用真实状态码，别 grep 文本。** 曾用 `grep -i "401"` 扫响应体判断令牌过期，
   而响应体里随机 UUID 的 `requestId` 恰好含 `401` 就会误判（实测约 0.57%／次）。
3. **`versions\current` 是文件不是目录**（见第 3 步）。
4. **Windows 原生程序不认 MSYS 的 `/tmp`**（见第 4 步）。

## 第 6 步：发布到 GitHub 公开仓库

分享的下一站通常是公开仓库。开源**近似不可逆**（fork、网页存档、搜索缓存都会留痕），
所以**开仓库前先过三道上闸**：

| 闸门 | 查什么 | 怎么做 |
|---|---|---|
| ① 内容闸 | 有没有夹带凭据与个人痕迹 | 对**暂存区**跑正则扫描（不是只看工作区）：JWT `eyJ…`、SendKey `SCT…`／`sctp…`、`gh[pousr]_…`、`github_pat_…`、私钥 `BEGIN … PRIVATE KEY`、云密钥 `AKIA…`、个人 uid、用户名、机器路径、邮箱、公司名 |
| ② 命名闸 | 会不会与已有仓库撞名 | `gh repo list --limit 40 --json name,visibility` —— 同账号下同名仓库只能存在一个，撞名会直接失败 |
| ③ 身份闸 | 提交者邮箱会不会暴露 | 先看 `git config --global user.email`；为空或不想暴露，就用 GitHub 隐私邮箱 `<id>+<login>@users.noreply.github.com`（`id` 取自 `gh api user -q .id`），**只在本仓库设**，别改全局 |

### 必备的 5 个工程件

| 文件 | 作用 |
|---|---|
| `README.md` | 访客决定"用不用"的地方。建议含：一句话价值、原理图（GitHub 支持 mermaid）、三步上手、命令速查、配置表、FAQ、**兼容性分级（已实测 / 未验证分开写）**、免责声明 |
| `LICENSE` | 不加协议等于"保留所有权利"，与"开源供人使用"直接矛盾。工具类项目首选 MIT |
| `SECURITY.md` | 一旦涉及凭据就必须写明边界；还要写"误提交后的止血顺序：**先吊销凭据，再清历史**"——历史会被 fork 与缓存 |
| `.gitignore` | 第一要务是挡住**状态目录**（本项目是 `state/`，含私有仓库名与令牌指纹） |
| `.gitattributes` | 统一行尾，否则不同平台 clone 出来行为不一致 |

`.gitattributes` 的最小可用写法：

```gitattributes
* text=auto eol=lf
*.bat text eol=crlf   # Windows 批处理必须 CRLF，否则 cmd 解析异常
```

### 推送与验证

```bash
gh repo create <名字> --public --description "…"
git remote add origin https://github.com/<账号>/<名字>.git
GIT_TERMINAL_PROMPT=0 git push -u origin main
```

**验证要从公网侧、匿名做**，不能只看本地 `git log`：

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://raw.githubusercontent.com/<账号>/<名字>/main/README.md
curl -s https://api.github.com/repos/<账号>/<名字>   # 确认 private=false 与 license
```

## 附 2：发布环节新踩的两个坑

5. **本机 `credential.helper` 会让 `git push` 静默挂死。** Git for Windows 默认的
   `credential.helper=helper-selector` 在**非交互**环境（脚本、CI、Agent）里会挂起等凭据输入，
   表现为 `git push` 长时间无输出、最终被 SIGTERM 杀掉——**看起来像网络问题，其实是凭据助手在等人输入**。
   解法：让 `gh` 接管 + 禁交互。
   ```bash
   gh auth setup-git --hostname github.com
   GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never git push -u origin main
   ```
   > 通用化：**非交互环境下，任何"可能弹窗 / 等输入"的组件都会变成挂起，而不是报错。**

6. **查仓库真实行尾要用 `git ls-files --eol`，不能用 `git show :path`。**
   用 `git show :文件` 看索引内容时，**git 会先按属性做行尾转换再输出**，
   于是明明 `.gitattributes` 正常生效，也会看到 CRLF、误判"归一化失效"。
   `git ls-files --eol` 才反映真实存储（`i/` 索引、`w/` 工作区）。
   > 通用化：**验证"会被转换过的输出"之前，先确认自己看到的是转换前还是转换后的形态。**
