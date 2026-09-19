@echo off
rem DSH launcher - setup wizard.
rem
rem Kept ASCII-only on purpose: cmd.exe does not cope well with a UTF-8 BOM or
rem with UTF-8 text under a non-UTF8 console code page.
rem
rem WPF requires an STA thread. Windows PowerShell 5.1 is STA by default and is
rem always present, so it is the safest host. If you switch this to pwsh.exe you
rem MUST pass -STA as well.

setlocal
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0setup-gui.ps1" %*
if errorlevel 1 (
  echo.
  echo The wizard exited with an error. Press any key to close this window...
  pause >nul
)
endlocal
