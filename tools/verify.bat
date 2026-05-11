@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "ROOT=%~dp0.."
set "MODE=Quick"
set "BUILD_DIR=build"
set "LOGIC_TIMEOUT=300"
set "STRESS_TIMEOUT=600"

:parse
if "%~1"=="" goto parsed
if /I "%~1"=="--mode" set "MODE=%~2" & shift & shift & goto parse
if /I "%~1"=="--build-dir" set "BUILD_DIR=%~2" & shift & shift & goto parse
if /I "%~1"=="--logic-timeout-seconds" set "LOGIC_TIMEOUT=%~2" & shift & shift & goto parse
if /I "%~1"=="--stress-timeout-seconds" set "STRESS_TIMEOUT=%~2" & shift & shift & goto parse
shift
goto parse

:parsed
pushd "%ROOT%" || exit /b 1
call :find_cmake || exit /b 1

call :build "%BUILD_DIR%" Debug || exit /b 1
call :resolve_exe "%BUILD_DIR%" Debug || exit /b 1
call :run_until_pass "!EXE!" "tests/logic/preload.lua" "PASS: unit coverage suite completed" "%LOGIC_TIMEOUT%" "logic-debug" || exit /b 1

if /I "%MODE%"=="Full" (
  call :run_until_pass "!EXE!" "tests/stress/preload.lua" "PASS: stress suite completed" "%STRESS_TIMEOUT%" "stress-debug" || exit /b 1
)

call :build "%BUILD_DIR%-release" Release || exit /b 1
echo verify %MODE% PASS
popd
exit /b 0

:find_cmake
set "CMAKE=cmake"
where cmake >NUL 2>NUL && exit /b 0
set "VS_CMAKE=C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
if exist "%VS_CMAKE%" set "CMAKE=%VS_CMAKE%" & exit /b 0
echo Required tool not found: cmake 1>&2
exit /b 1

:build
set "DIR=%~1"
set "CONFIG=%~2"
"%CMAKE%" -S . -B "%DIR%" -DCMAKE_BUILD_TYPE=%CONFIG% || exit /b 1
"%CMAKE%" --build "%DIR%" --config %CONFIG% --parallel || exit /b 1
exit /b 0

:resolve_exe
set "EXE="
if exist "%~1\%~2\skynet-cpp.exe" set "EXE=%~1\%~2\skynet-cpp.exe"
if not defined EXE if exist "%~1\skynet-cpp.exe" set "EXE=%~1\skynet-cpp.exe"
if not defined EXE if exist "%~1\skynet-cpp" set "EXE=%~1\skynet-cpp"
if defined EXE exit /b 0
echo skynet-cpp executable not found under %~1 1>&2
exit /b 1

:run_until_pass
set "RUN_EXE=%~1"
set "RUN_PRELOAD=%~2"
set "RUN_PASS=%~3"
set "RUN_TIMEOUT=%~4"
set "RUN_LABEL=%~5"
if not exist "verify-results" mkdir "verify-results"
set "OUT=verify-results\%RUN_LABEL%.out"
set "ERR=verify-results\%RUN_LABEL%.err"
del "%OUT%" "%ERR%" >NUL 2>NUL
set "SKYNET_PRELOAD=%RUN_PRELOAD%"
set "SKYNET_THREAD=8"
set "SKYNET_START="
start "" /B cmd /C ""%RUN_EXE%" 1>"%OUT%" 2>"%ERR%""
for /L %%S in (1,1,%RUN_TIMEOUT%) do (
  ping -n 2 127.0.0.1 >NUL
  findstr /C:"%RUN_PASS%" "%OUT%" "%ERR%" >NUL 2>NUL && goto run_pass
  findstr /I /C:"callback error" /C:"timed out" /C:"No dispatch function" /C:"Unknown response session" /C:"CASE failed" /C:"lost response" "%OUT%" "%ERR%" >NUL 2>NUL && goto run_fail
)
goto run_timeout

:run_pass
taskkill /IM skynet-cpp.exe /F >NUL 2>NUL
if exist "%OUT%" type "%OUT%"
if exist "%ERR%" type "%ERR%"
exit /b 0

:run_fail
taskkill /IM skynet-cpp.exe /F >NUL 2>NUL
if exist "%OUT%" type "%OUT%"
if exist "%ERR%" type "%ERR%"
echo %RUN_LABEL% failed 1>&2
exit /b 1

:run_timeout
taskkill /IM skynet-cpp.exe /F >NUL 2>NUL
if exist "%OUT%" type "%OUT%"
if exist "%ERR%" type "%ERR%"
echo %RUN_LABEL% timed out 1>&2
exit /b 1
