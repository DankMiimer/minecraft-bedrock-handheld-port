@echo off
REM Puts a shortcut to mcbedrock-get.exe on the current user's desktop.
REM Keep this file in the same folder as the executable.
setlocal

set "TARGET=%~dp0mcbedrock-get.exe"

if not exist "%TARGET%" (
    echo Could not find mcbedrock-get.exe next to this script.
    echo Keep both files in the same folder, then run this again.
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$shell = New-Object -ComObject WScript.Shell;" ^
  "$link = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Minecraft Bedrock APK downloader.lnk'));" ^
  "$link.TargetPath = '%TARGET%';" ^
  "$link.WorkingDirectory = [System.IO.Path]::GetDirectoryName('%TARGET%');" ^
  "$link.Description = 'Download your own Minecraft Bedrock builds for the handheld port';" ^
  "$link.Save()" || goto :fail

echo.
echo Done - "Minecraft Bedrock APK downloader" is on your desktop.
echo.
pause
exit /b 0

:fail
echo.
echo Could not create the shortcut.
echo.
pause
exit /b 1
