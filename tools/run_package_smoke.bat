@echo off
setlocal EnableExtensions

set "ROOT=%~dp0.."
set "INSTALL_DIR=dist\skynet-cpp"
set "THREAD=4"
set "TIMEOUT_SECONDS=20"

:parse
if "%~1"=="" goto parsed
if /I "%~1"=="--install-dir" set "INSTALL_DIR=%~2" & shift & shift & goto parse
if /I "%~1"=="--thread" set "THREAD=%~2" & shift & shift & goto parse
if /I "%~1"=="--timeout-seconds" set "TIMEOUT_SECONDS=%~2" & shift & shift & goto parse
shift
goto parse

:parsed
pushd "%ROOT%" || exit /b 1
set "EXE=%INSTALL_DIR%\bin\skynet-cpp.exe"
if not exist "%EXE%" set "EXE=%INSTALL_DIR%\bin\skynet-cpp"
if not exist "%EXE%" echo package executable not found under %INSTALL_DIR%\bin 1>&2 & exit /b 1
if not exist "package-results" mkdir "package-results"
set "OUT=package-results\package-smoke.out"
set "ERR=package-results\package-smoke.err"
del "%OUT%" "%ERR%" >NUL 2>NUL
set "SKYNET_THREAD=%THREAD%"
set "SKYNET_PRELOAD=examples/preload.lua"
pushd "%INSTALL_DIR%" || exit /b 1
start "" /B cmd /C ""%CD%\bin\skynet-cpp.exe" 1>"%ROOT%\%OUT%" 2>"%ROOT%\%ERR%""
popd
for /L %%S in (1,1,%TIMEOUT_SECONDS%) do (
  ping -n 2 127.0.0.1 >NUL
  findstr /C:"[main] === Example completed ===" "%OUT%" "%ERR%" >NUL 2>NUL && goto pass
)
taskkill /IM skynet-cpp.exe /F >NUL 2>NUL
if exist "%OUT%" type "%OUT%"
if exist "%ERR%" type "%ERR%"
echo package smoke timed out 1>&2
exit /b 1

:pass
taskkill /IM skynet-cpp.exe /F >NUL 2>NUL
if exist "%OUT%" type "%OUT%"
if exist "%ERR%" type "%ERR%"
echo package smoke PASS
popd
exit /b 0
