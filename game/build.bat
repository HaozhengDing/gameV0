@echo off
REM gameV0 T4a one-command build (Windows)
REM deps: Visual Studio 2022+ (C++ desktop workload), CMake >= 3.22, Ninja, Godot 4.5
REM usage: set GODOT_CPP_DIR=C:\path\to\godot-cpp  then run build.bat
setlocal enabledelayedexpansion
cd /d "%~dp0"

if "%GODOT_CPP_DIR%"=="" (
  echo [T4a] set GODOT_CPP_DIR=path\to\godot-cpp first
  exit /b 1
)

REM enter MSVC x64 environment unless already inside a developer prompt
if not defined VSCMD_ARG_TGT_ARCH (
  set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
  if not exist "!VSWHERE!" (
    echo [T4a] vswhere not found; run from a Visual Studio x64 Native Tools prompt
    exit /b 1
  )
  for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"
  if not defined VSPATH (
    echo [T4a] MSVC toolchain not found
    exit /b 1
  )
  call "!VSPATH!\VC\Auxiliary\Build\vcvars64.bat" >nul
  if errorlevel 1 exit /b 1
)

set "EXT=%~dp0gdextension"
set "BUILD=%~dp0build"
set "BIN=%~dp0bin"
if not exist "%BIN%" mkdir "%BIN%"

echo [T4a] build debug (template_debug) ...
cmake -S "%EXT%" -B "%BUILD%\debug" -G Ninja -DCMAKE_BUILD_TYPE=Debug -DGODOT_CPP_DIR="%GODOT_CPP_DIR%" -DGODOTCPP_TARGET=template_debug
if errorlevel 1 exit /b 1
cmake --build "%BUILD%\debug"
if errorlevel 1 exit /b 1
copy /y "%BUILD%\debug\gdsim.dll" "%BIN%\gdsim.windows.template_debug.x86_64.dll" >nul
if errorlevel 1 exit /b 1

echo [T4a] build release (template_release) ...
cmake -S "%EXT%" -B "%BUILD%\release" -G Ninja -DCMAKE_BUILD_TYPE=Release -DGODOT_CPP_DIR="%GODOT_CPP_DIR%" -DGODOTCPP_TARGET=template_release
if errorlevel 1 exit /b 1
cmake --build "%BUILD%\release"
if errorlevel 1 exit /b 1
copy /y "%BUILD%\release\gdsim.dll" "%BIN%\gdsim.windows.template_release.x86_64.dll" >nul
if errorlevel 1 exit /b 1

echo T4A_BUILD_OK
