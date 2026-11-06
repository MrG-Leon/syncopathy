@echo off
rem ============================================================
rem build-cn.bat - One-click Windows release build (CN network)
rem
rem Double-click to run. Downloads mpv / ANGLE / objectbox and
rem builds the app with no archive pre-placement needed.
rem
rem GitHub release assets are blocked or flaky from CN, so step 0
rem prefetches them through GitHub proxy mirrors and seeds CMake's
rem cache. See the "Prefetch CMake archives" section below.
rem
rem NOTE: kept ASCII-only on purpose. cmd.exe parses batch files
rem using the legacy ANSI codepage, so UTF-8 Chinese text here
rem would render as mojibake.
rem ============================================================

setlocal
cd /d "%~dp0"

rem --- Network environment ---

rem Fix CMake archive download failures on this machine: schannel
rem cert revocation check fails offline (CRYPT_E_REVOCATION_OFFLINE)
rem for the mpv / ANGLE / objectbox downloads. CMake's bundled curl
rem reads this environment variable.
set "CMAKE_TLS_VERIFY=0"

rem CN mirrors for pub.dev packages and Flutter engine artifacts
set "PUB_HOSTED_URL=https://pub.flutter-io.cn"
set "FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn"

rem GitHub release proxy mirrors. These proxy arbitrary github.com
rem URLs (append the full github URL after the host) and are reachable
rem from CN, while github.com release assets themselves often are not.
set "GH_MIRROR_1=https://ghfast.top"
set "GH_MIRROR_2=https://gh-proxy.com"
set "GH_MIRROR_3=https://ghproxy.net"

rem media_kit is a git dependency hosted on github.com. If cloning
rem is slow or unstable, uncomment and adjust the port; both git and
rem CMake downloads will honor it:
rem set "HTTP_PROXY=http://127.0.0.1:7890"
rem set "HTTPS_PROXY=http://127.0.0.1:7890"

rem --- Pre-check ---

rem 7-Zip extracts the libmpv / ANGLE archives. If it is missing from
rem PATH, CMake falls back to a branch that has an add_custom_command
rem syntax bug (missing POST_BUILD, hard error on CMake 3.31).
where 7z >nul 2>nul
if not errorlevel 1 goto sevenz_ok
echo [WARN] 7z not found in PATH. One-time fix, then restart the terminal:
echo   Run in PowerShell:
echo   [Environment]::SetEnvironmentVariable('Path', $env:Path + ';E:\7-Zip', 'User')
:sevenz_ok

rem curl.exe ships with Windows 10 1803+. Without it there is no way to
rem prefetch through the mirrors, so skip step 0 entirely and let CMake
rem try its own (direct) downloads.
where curl.exe >nul 2>nul
if errorlevel 1 (
  echo [WARN] curl.exe not found; skipping mirror prefetch. CMake will download directly.
  goto after_prefetch
)

rem --- Prefetch CMake archives from CN mirrors ---
rem
rem media_kit_libs_windows_video's CMakeLists downloads ANGLE.7z from a
rem GitHub release (blocked in CN) and libmpv from SourceForge; the
rem objectbox_flutter_libs plugin fetches objectbox-windows-x64.zip from
rem a GitHub release too. media_kit's download_and_verify() skips its
rem download when the archive is already in build\windows\x64 with a
rem matching MD5, so prefetching here bypasses CMake's own downloads.
rem objectbox's FetchContent has no such hook, so instead its pub-cache
rem CMakeLists is patched to point at a local copy of the zip.
echo.
echo [0/3] Prefetching CMake archives via CN mirrors

set "CMAKE_ARCH_DIR=%~dp0build\windows\x64"
if not exist "%CMAKE_ARCH_DIR%" mkdir "%CMAKE_ARCH_DIR%"
set "LOCAL_CACHE_DIR=%~dp0third_party_cache"
if not exist "%LOCAL_CACHE_DIR%" mkdir "%LOCAL_CACHE_DIR%"

rem ANGLE.7z (GitHub release; MD5 must match media_kit's CMakeLists)
set "ANGLE_URLS=%GH_MIRROR_1%/https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z"
set "ANGLE_URLS=%ANGLE_URLS%;%GH_MIRROR_2%/https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z"
set "ANGLE_URLS=%ANGLE_URLS%;%GH_MIRROR_3%/https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z"
set "ANGLE_URLS=%ANGLE_URLS%;https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z"
call :prefetch "%CMAKE_ARCH_DIR%\ANGLE.7z" "e866f13e8d552348058afaafe869b1ed" "%ANGLE_URLS%"

rem libmpv (SourceForge; MD5 must match media_kit's CMakeLists).
rem SourceForge is unreliable from CN: the main site stalls or redirects
rem to mirrors that never answer. gh-proxy.com runs a dedicated
rem SourceForge accelerator (see gh-proxy.com/docs/sourceforge-mirror),
rem so it goes first; the direct mirror subdomains and the plain
rem SourceForge URLs follow as fallbacks.
set "LIBMPV_FILE=mpv-dev-x86_64-20250713-git-bd21180.7z"
set "LIBMPV_URLS=https://gh-proxy.com/sourceforge/https://sourceforge.net/projects/mpv-player-windows/files/libmpv/%LIBMPV_FILE%/download"
set "LIBMPV_URLS=%LIBMPV_URLS%;https://master.dl.sourceforge.net/project/mpv-player-windows/libmpv/%LIBMPV_FILE%"
set "LIBMPV_URLS=%LIBMPV_URLS%;https://cytranet-dal.dl.sourceforge.net/project/mpv-player-windows/libmpv/%LIBMPV_FILE%"
set "LIBMPV_URLS=%LIBMPV_URLS%;https://downloads.sourceforge.net/project/mpv-player-windows/libmpv/%LIBMPV_FILE%"
set "LIBMPV_URLS=%LIBMPV_URLS%;https://sourceforge.net/projects/mpv-player-windows/files/libmpv/%LIBMPV_FILE%/download"
call :prefetch "%CMAKE_ARCH_DIR%\%LIBMPV_FILE%" "ba26043729f3e3b69d87d7dad36f3447" "%LIBMPV_URLS%"

rem objectbox (GitHub release; no published checksum, so no MD5 check)
set "OBJECTBOX_URLS=%GH_MIRROR_1%/https://github.com/objectbox/objectbox-c/releases/download/v5.3.2/objectbox-windows-x64.zip"
set "OBJECTBOX_URLS=%OBJECTBOX_URLS%;%GH_MIRROR_2%/https://github.com/objectbox/objectbox-c/releases/download/v5.3.2/objectbox-windows-x64.zip"
set "OBJECTBOX_URLS=%OBJECTBOX_URLS%;%GH_MIRROR_3%/https://github.com/objectbox/objectbox-c/releases/download/v5.3.2/objectbox-windows-x64.zip"
set "OBJECTBOX_URLS=%OBJECTBOX_URLS%;https://github.com/objectbox/objectbox-c/releases/download/v5.3.2/objectbox-windows-x64.zip"
call :prefetch "%LOCAL_CACHE_DIR%\objectbox-windows-x64.zip" "" "%OBJECTBOX_URLS%"
call :patch_objectbox "%LOCAL_CACHE_DIR%\objectbox-windows-x64.zip"

:after_prefetch

rem --- Build ---

echo.
echo [1/3] flutter pub get
call flutter pub get
if errorlevel 1 goto failed

echo.
echo [2/3] flutter build windows --release
call flutter build windows --release
if errorlevel 1 goto failed

echo.
echo [3/3] Done.
echo [OK] build\windows\x64\runner\Release\syncopathy.exe
pause
exit /b 0

:failed
echo.
echo [ERROR] Build failed. See output above.
pause
exit /b 1

rem ============================================================
rem Subroutines
rem ============================================================

rem :prefetch <outfile> <expected-md5 or empty> <semicolon-separated urls>
rem
rem Leaves <outfile> in place, downloading it from the first mirror that
rem works. Skipped when the file already exists and (when an md5 is
rem given) its checksum matches. Failed/partial downloads are deleted
rem before trying the next mirror.
:prefetch
setlocal EnableDelayedExpansion
set "pf_out=%~1"
set "pf_want=%~2"
set "pf_urls=%~3"

set "pf_have="
if exist "%pf_out%" call :md5of "%pf_out%" pf_have
if defined pf_want (
  if /i "!pf_have!"=="!pf_want!" (
    echo   [OK] Cached and verified: %~nx1
    endlocal
    goto :eof
  )
  if exist "%pf_out%" (
    echo   [..] Checksum mismatch, re-downloading: %~nx1
    del /f /q "%pf_out%"
  )
) else (
  if exist "%pf_out%" (
    echo   [OK] Cached: %~nx1
    endlocal
    goto :eof
  )
)

for %%u in ("!pf_urls:;=" "!") do (
  if not exist "%pf_out%" (
    echo   [..] Trying %%~u
    curl.exe -fL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 1800 -o "%pf_out%" "%%~u" 2>nul
    if exist "%pf_out%" (
      if defined pf_want (
        set "pf_got="
        call :md5of "%pf_out%" pf_got
        if /i not "!pf_got!"=="!pf_want!" (
          echo   [..] Checksum failed, trying next mirror
          del /f /q "%pf_out%"
        )
      )
    )
  )
)
if exist "%pf_out%" (
  echo   [OK] %~nx1 ready.
) else (
  echo   [WARN] All mirrors failed for %~nx1. CMake will try its own download.
)
endlocal
goto :eof

rem :md5of <file> <variable to receive the hash>
rem Reads certutil's output (line 1 is a header, line 2 the bare hash)
rem and stores it in the named variable with spaces stripped.
:md5of
setlocal
set "md5_h="
for /f "skip=1 delims=" %%h in ('certutil -hashfile "%~1" MD5 2^>nul') do (
  if not defined md5_h set "md5_h=%%h"
)
endlocal & set "%~2=%md5_h: =%"
goto :eof

rem :patch_objectbox <local objectbox-windows-x64.zip>
rem
rem objectbox_flutter_libs' windows CMakeLists.txt declares a
rem FetchContent download from
rem   https://github.com/objectbox/objectbox-c/releases/download/
rem     v${OBJECTBOX_VERSION}/objectbox-windows-${OBJECTBOX_ARCH}.zip
rem FetchContent cannot be pre-seeded, so rewrite that URL to the local
rem zip. The replacement targets the literal template (the ${...} parts
rem are expanded by CMake at build time), so it keeps working across
rem objectbox version bumps. Idempotent: already-patched files are left
rem alone.
:patch_objectbox
if not exist "%~1" (
  echo   [SKIP] objectbox zip unavailable; leaving CMake untouched.
  goto :eof
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$zip=('%~f1' -replace '\\','/'); Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Pub\Cache\hosted') -Directory -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem $_.FullName -Directory -Filter 'objectbox_flutter_libs-*' -ErrorAction SilentlyContinue | ForEach-Object { $f=Join-Path $_.FullName 'windows\CMakeLists.txt'; if (Test-Path $f) { $c=Get-Content $f -Raw; if ($c.Contains('https://github.com/objectbox/objectbox-c/releases/download')) { $c=$c.Replace('https://github.com/objectbox/objectbox-c/releases/download/v${OBJECTBOX_VERSION}/objectbox-windows-${OBJECTBOX_ARCH}.zip', $zip); Set-Content -Path $f -Value $c -NoNewline -Encoding Ascii; Write-Host ('  [OK] Patched objectbox CMakeLists to use local zip: ' + $f) } elseif ($c.Contains($zip)) { Write-Host '  [OK] objectbox CMakeLists already patched.' } } } }"
goto :eof
