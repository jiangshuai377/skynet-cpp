@echo off
setlocal EnableExtensions

set "ROOT=%~dp0.."
set "BUILD_CONFIG=Release"
set "BUILD_DIR=build-package"
set "INSTALL_DIR=dist\skynet-cpp"
set "CLEAN=0"

:parse
if "%~1"=="" goto parsed
if /I "%~1"=="--build-config" set "BUILD_CONFIG=%~2" & shift & shift & goto parse
if /I "%~1"=="--build-dir" set "BUILD_DIR=%~2" & shift & shift & goto parse
if /I "%~1"=="--install-dir" set "INSTALL_DIR=%~2" & shift & shift & goto parse
if /I "%~1"=="--clean" set "CLEAN=1" & shift & goto parse
shift
goto parse

:parsed
pushd "%ROOT%" || exit /b 1
set "CMAKE=cmake"
where cmake >NUL 2>NUL || set "CMAKE=C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
if not exist "%CMAKE%" if /I not "%CMAKE%"=="cmake" echo Required tool not found: cmake 1>&2 & exit /b 1
if "%CLEAN%"=="1" (
  if exist "%BUILD_DIR%" rmdir /S /Q "%BUILD_DIR%"
  if exist "%INSTALL_DIR%" rmdir /S /Q "%INSTALL_DIR%"
)
"%CMAKE%" -S . -B "%BUILD_DIR%" -DCMAKE_BUILD_TYPE=%BUILD_CONFIG% || exit /b 1
"%CMAKE%" --build "%BUILD_DIR%" --config %BUILD_CONFIG% --parallel || exit /b 1
"%CMAKE%" --install "%BUILD_DIR%" --config %BUILD_CONFIG% --prefix "%CD%\%INSTALL_DIR%" || exit /b 1
echo package PASS: %INSTALL_DIR%
popd
exit /b 0
