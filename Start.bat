@echo off
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
