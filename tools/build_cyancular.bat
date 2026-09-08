@echo off
rem Cyancular Ruins - stripped template build
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64 >nul
if errorlevel 1 (
  echo VCVARSALL_FAILED
  exit /b 1
)
cd /d E:\Workspace\godot\godot-4.7.1-src
python -m SCons platform=windows target=template_release production=yes optimize=size arch=x86_64 accesskit=no d3d12=no build_profile=E:\Workspace\godot\the-cyancular-ruins\cyancular_build_profile.gdbuild -j 8
echo BUILD_EXIT=%ERRORLEVEL%
