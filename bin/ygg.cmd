@echo off
rem bin/ygg.cmd - Windows batch shim for Yggdrasil configuration manager
setlocal
where nu >nul 2>nul
if %ERRORLEVEL% neq 0 (
    if exist "%USERPROFILE%\.local\bin\nu.exe" (
        set "PATH=%USERPROFILE%\.local\bin;%PATH%"
    ) else if exist "%LOCALAPPDATA%\Programs\nu\bin\nu.exe" (
        set "PATH=%LOCALAPPDATA%\Programs\nu\bin;%PATH%"
    ) else if exist "%LOCALAPPDATA%\Microsoft\WinGet\Links\nu.exe" (
        set "PATH=%LOCALAPPDATA%\Microsoft\WinGet\Links;%PATH%"
    ) else if exist "%ProgramFiles%\nu\bin\nu.exe" (
        set "PATH=%ProgramFiles%\nu\bin;%PATH%"
    ) else if exist "%USERPROFILE%\scoop\shims\nu.exe" (
        set "PATH=%USERPROFILE%\scoop\shims;%PATH%"
    )
)
if exist "%~dp0ygg.nu" (
    set "YGG_SCRIPT=%~dp0ygg.nu"
) else if defined YGG_ENGINE_DIR (
    set "YGG_SCRIPT=%YGG_ENGINE_DIR%\bin\ygg.nu"
) else if exist "%USERPROFILE%\.ygg\.engine\bin\ygg.nu" (
    set "YGG_SCRIPT=%USERPROFILE%\.ygg\.engine\bin\ygg.nu"
) else (
    echo [ygg] Error: could not locate ygg.nu >&2
    exit /b 1
)
where nu >nul 2>nul
if %ERRORLEVEL% neq 0 (
    echo [ygg] Error: nushell 'nu' was not found in PATH. >&2
    echo [ygg] Please install Nushell via winget, scoop, or run scripts\install.ps1 >&2
    exit /b 1
)
nu "%YGG_SCRIPT%" %*
