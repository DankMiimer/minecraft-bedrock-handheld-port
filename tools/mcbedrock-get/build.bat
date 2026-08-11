@echo off
REM Build mcbedrock-get.exe. Needs Python 3.10+ on PATH; everything else is
REM fetched as a wheel, so no compiler is required.
setlocal

if not exist .venv (
    python -m venv .venv || goto :fail
)

call .venv\Scripts\activate.bat
python -m pip install --upgrade pip || goto :fail
python -m pip install -r requirements.txt pyinstaller || goto :fail

pyinstaller --noconfirm --clean ^
    --name mcbedrock-get ^
    --onefile ^
    --windowed ^
    --copy-metadata gpsoauth ^
    --hidden-import webview.platforms.edgechromium ^
    mcbedrock_get.py || goto :fail

REM Licence notices, generated from what is actually installed in this venv.
python gen_notices.py dist\mcbedrock-get-NOTICES.txt || goto :fail

REM Ship the companion files next to the executable.
copy /Y "Create desktop shortcut.cmd" "dist\Create desktop shortcut.cmd" >nul
copy /Y "wsl-setup.sh" "dist\wsl-setup.sh" >nul

echo.
echo Built dist\mcbedrock-get.exe
echo Publish its SHA-256 alongside the download:
certutil -hashfile dist\mcbedrock-get.exe SHA256
goto :eof

:fail
echo.
echo Build failed.
exit /b 1
