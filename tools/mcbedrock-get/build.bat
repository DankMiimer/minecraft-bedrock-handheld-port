@echo off
REM Build mcbedrock-get.exe. Needs Python 3.10+ on PATH; everything else is
REM fetched as a wheel, so no compiler is required.
setlocal

REM PyInstaller requires stable hash and PE timestamp inputs for reproducible builds.
set "PYTHONHASHSEED=1"
set "SOURCE_DATE_EPOCH=1767225600"

if not exist .venv (
    python -m venv .venv || goto :fail
)

set "VENV_PY=.venv\Scripts\python.exe"
"%VENV_PY%" -m pip install --upgrade pip || goto :fail
"%VENV_PY%" -m pip install -r requirements.txt || goto :fail

"%VENV_PY%" -m PyInstaller --noconfirm --clean ^
    --name mcbedrock-get ^
    --onefile ^
    --console ^
    --copy-metadata gpsoauth ^
    --hidden-import webview.platforms.edgechromium ^
    mcbedrock_get.py || goto :fail

REM Licence notices, generated from what is actually installed in this venv.
"%VENV_PY%" gen_notices.py dist\mcbedrock-get-NOTICES.txt || goto :fail

REM Ship the companion files next to the executable.
copy /Y "Create desktop shortcut.cmd" "dist\Create desktop shortcut.cmd" >nul
copy /Y "setup-downloader.sh" "dist\setup-downloader.sh" >nul

"%VENV_PY%" package_release.py || goto :fail

echo.
echo Built dist\mcbedrock-get.exe
echo Built the versioned Windows release bundle.
echo Publish the bundle SHA-256 alongside the download:
for %%F in (dist\mcbedrock-get-windows-v*.zip) do certutil -hashfile "%%F" SHA256
goto :eof

:fail
echo.
echo Build failed.
exit /b 1
