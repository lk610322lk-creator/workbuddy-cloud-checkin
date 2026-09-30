#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 Windows 双击启动器 Start.bat。

为什么用脚本生成而不是直接写文件：
  Windows cmd 硬性要求 **CRLF** 行尾 + **GBK**（cp936）编码。用编辑器直写会得到
  LF + UTF-8，后果是：① cmd 解析多行 if 块时直接崩溃退出（黑框一闪）；
  ② 含中文时按 GBK 解码 UTF-8 → 乱码。

用法：
  python scripts/_gen_start_bat.py
生成后再跑一次自检会打印 CRLF / GBK / 菜单项数量。

改菜单项请改本文件里的 BAT 常量，然后重新执行本脚本。
"""

import os
import sys

BAT = r'''@echo off
chcp 936 >nul
setlocal enabledelayedexpansion
cd /d "%~dp0"

rem ============================================================
rem  定位 bash：优先用 WorkBuddy 客户端自带的 PortableGit
rem  （装了客户端就有，用户无需另外安装 Git for Windows）
rem
rem  注意：binaries\PortableGit\versions\current 是**版本标记文件**、
rem  不是目录，所以不能拼 current\bin\bash.exe，必须遍历版本目录。
rem ============================================================
set "BASH="

rem ① 客户端自带（国内版 / 国际版），遍历版本目录
for /d %%V in ("%USERPROFILE%\.workbuddy\binaries\PortableGit\versions\*") do (
  if not defined BASH if exist "%%V\bin\bash.exe" set "BASH=%%V\bin\bash.exe"
)
for /d %%V in ("%USERPROFILE%\.workbuddy-ai\binaries\PortableGit\versions\*") do (
  if not defined BASH if exist "%%V\bin\bash.exe" set "BASH=%%V\bin\bash.exe"
)

rem ② 系统自行安装的 Git for Windows
for %%B in (
  "%ProgramFiles%\Git\bin\bash.exe"
  "%ProgramFiles(x86)%\Git\bin\bash.exe"
  "%LocalAppData%\Programs\Git\bin\bash.exe"
) do (
  if not defined BASH if exist %%B set "BASH=%%~B"
)

if not defined BASH (
  echo.
  echo   [错误] 未找到 bash 运行环境
  echo.
  echo   正常情况下 WorkBuddy 客户端会自带一个，无需另外安装。
  echo   若确实找不到，可安装 Git for Windows（保持默认选项）：
  echo       https://git-scm.com/download/win
  echo.
  pause
  exit /b 1
)

:menu
cls
echo.
echo   ==========================================================
echo     WorkBuddy 云端自动签到
echo   ==========================================================
echo.
echo     1   环境自检            ^<-- 第一次先跑这个
echo     2   一键配置云端签到     （建私有仓库 + 灌令牌 + 验收）
echo     3   立即补签一次
echo     4   查看最近运行记录
echo     5   镜像本机令牌         （建议每周跑，保持云端令牌新鲜）
echo     6   测试通知渠道
echo     7   云端令牌体检         （看云端手里是哪把令牌）
echo     8   本机直连签到         （GitHub 不可用时的兜底）
echo     0   退出
echo.
set /p "CH=  请输入序号并回车: "

if "%CH%"=="1" (
  cls
  "%BASH%" "scripts/preflight.sh"
  echo.
  pause
  goto :menu
)
if "%CH%"=="2" (
  cls
  "%BASH%" "scripts/setup-cloud-repo.sh"
  echo.
  pause
  goto :menu
)
if "%CH%"=="3" (
  cls
  "%BASH%" "scripts/cloud-run-checkin.sh"
  echo.
  pause
  goto :menu
)
if "%CH%"=="4" (
  cls
  "%BASH%" "scripts/cloud-run-checkin.sh" --status
  echo.
  pause
  goto :menu
)
if "%CH%"=="5" (
  cls
  "%BASH%" "scripts/push-token-to-cloud.sh"
  echo.
  pause
  goto :menu
)
if "%CH%"=="6" (
  cls
  "%BASH%" "scripts/cloud-notify-test.sh"
  echo.
  pause
  goto :menu
)
if "%CH%"=="7" (
  cls
  "%BASH%" "scripts/cloud-diag.sh"
  echo.
  pause
  goto :menu
)
if "%CH%"=="8" (
  cls
  "%BASH%" "scripts/local-checkin.sh"
  echo.
  pause
  goto :menu
)
if "%CH%"=="0" exit /b 0

echo.
echo   无效的序号，请重新输入。
timeout /t 2 >nul
goto :menu
'''


def main() -> int:
    skill_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(skill_dir, "Start.bat")

    with open(out, "w", encoding="gbk", newline="\r\n") as f:
        f.write(BAT)

    raw = open(out, "rb").read()
    ok_crlf = b"\r\n" in raw
    ok_nolf = b"\n" not in raw.replace(b"\r\n", b"")
    ok_gbk = True
    try:
        raw.decode("gbk")
    except Exception:
        ok_gbk = False

    print("生成:", out, "(%d 字节)" % len(raw))
    print("  含 CRLF :", ok_crlf)
    print("  无裸 LF :", ok_nolf)
    print("  GBK 可解码 :", ok_gbk)
    print("  文件名 ASCII :", os.path.basename(out).isascii())

    return 0 if (ok_crlf and ok_nolf and ok_gbk) else 1


if __name__ == "__main__":
    sys.exit(main())
