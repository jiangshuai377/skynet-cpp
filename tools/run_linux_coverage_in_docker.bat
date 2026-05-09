@echo off
setlocal
if "%~1"=="" set "SKYNET_TOOLS_PAUSE=1"
call "%~dp0_run_tool.bat" docker-linux-coverage %*
set "CODE=%ERRORLEVEL%"
if "%SKYNET_TOOLS_PAUSE%"=="1" pause
exit /b %CODE%

