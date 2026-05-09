@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "TOOLS_DIR=%~dp0"

if defined SKYNET_TOOLS_PYTHON (
  set "PY=%SKYNET_TOOLS_PYTHON%"
) else (
  set "PLATFORM=windows-x86_64"
  set "ARCHIVE_NAME=cpython-3.13.13+20260414-x86_64-pc-windows-msvc-install_only.tar.gz"
  set "ARCHIVE_SHA256=ee0cb26453d6e025d36502d765c1639c34830355e46ab3ad31c0360bc4cd9b79"
  set "ARCHIVE=%TOOLS_DIR%python\archives\!ARCHIVE_NAME!"
  set "RUNTIME_DIR=%TOOLS_DIR%python\runtime\!PLATFORM!"
  set "PY=!RUNTIME_DIR!\python.exe"
  if not exist "!PY!" (
    call :bootstrap_python || exit /b 1
  )
)

if not exist "%PY%" (
  echo Python runtime not found: %PY% 1>&2
  echo Set SKYNET_TOOLS_PYTHON to an existing python.exe for local debugging. 1>&2
  exit /b 1
)

if defined PYTHONPATH (
  set "PYTHONPATH=%TOOLS_DIR%py;%PYTHONPATH%"
) else (
  set "PYTHONPATH=%TOOLS_DIR%py"
)

"%PY%" -m skynet_tools %*
exit /b %ERRORLEVEL%

:bootstrap_python
if not exist "!ARCHIVE!" (
  echo Python archive not found: !ARCHIVE! 1>&2
  echo Run git lfs pull, or set SKYNET_TOOLS_PYTHON to an existing python.exe. 1>&2
  exit /b 1
)

findstr /B /C:"version https://git-lfs.github.com/spec/v1" "!ARCHIVE!" >NUL 2>NUL
if not errorlevel 1 (
  echo Python archive is still a Git LFS pointer: !ARCHIVE! 1>&2
  echo Run git lfs pull before using offline tools. 1>&2
  exit /b 1
)

where tar >NUL 2>NUL
if errorlevel 1 (
  echo tar was not found on PATH; cannot extract vendored Python archive. 1>&2
  exit /b 1
)

set "ACTUAL_SHA256="
for /f "skip=1 tokens=* delims=" %%H in ('certutil -hashfile "!ARCHIVE!" SHA256 ^| findstr /R "^[0-9A-Fa-f][0-9A-Fa-f]"') do (
  set "ACTUAL_SHA256=%%H"
  goto :got_hash
)
:got_hash
set "ACTUAL_SHA256=!ACTUAL_SHA256: =!"
if /I not "!ACTUAL_SHA256!"=="!ARCHIVE_SHA256!" (
  echo Python archive SHA256 mismatch: !ARCHIVE! 1>&2
  echo Expected: !ARCHIVE_SHA256! 1>&2
  echo Actual:   !ACTUAL_SHA256! 1>&2
  exit /b 1
)

set "CACHE_ROOT=%TOOLS_DIR%python\cache"
set "RUNTIME_ROOT=%TOOLS_DIR%python\runtime"
set "TMP_DIR=!CACHE_ROOT!\!PLATFORM!-%RANDOM%-%RANDOM%"
if exist "!TMP_DIR!" rmdir /S /Q "!TMP_DIR!"
mkdir "!TMP_DIR!" || exit /b 1
mkdir "!RUNTIME_ROOT!" 2>NUL

echo Extracting vendored Python runtime for !PLATFORM!...
tar -xzf "!ARCHIVE!" -C "!TMP_DIR!" --strip-components=1
if errorlevel 1 (
  rmdir /S /Q "!TMP_DIR!" 2>NUL
  echo Failed to extract Python archive: !ARCHIVE! 1>&2
  exit /b 1
)

if exist "!RUNTIME_DIR!" rmdir /S /Q "!RUNTIME_DIR!"
move /Y "!TMP_DIR!" "!RUNTIME_DIR!" >NUL
if errorlevel 1 (
  rmdir /S /Q "!TMP_DIR!" 2>NUL
  echo Failed to install Python runtime at !RUNTIME_DIR! 1>&2
  exit /b 1
)

if not exist "!PY!" (
  echo Extracted Python runtime is missing expected executable: !PY! 1>&2
  exit /b 1
)

exit /b 0
