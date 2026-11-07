@echo off
rem bin/ygg.cmd — Windows batch shim for Yggdrasil configuration manager
where nu >nul 2>nul
if %ERRORLEVEL% neq 0 (
    if exist "%USERPROFILE%\.local\bin\nu.exe" (
        set "PATH=%USERPROFILE%\.local\bin;%PATH%"
    ) else if exist "%LOCALAPPDATA%\Microsoft\WinGet\Links\nu.exe" (
        set "PATH=%LOCALAPPDATA%\Microsoft\WinGet\Links;%PATH%"
    )
)
nu "%~dp0ygg.nu" %*
