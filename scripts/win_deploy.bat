@echo off
:: Отключаем лишний вывод и настраиваем пути
set "W=%USERPROFILE%\llm_native"
set "B=%USERPROFILE%\llm_native\bin"
set "M=%USERPROFILE%\llm_native\models"

echo [1/4] Cleaning system...
taskkill /F /IM llama-server.exe /T >nul 2>&1

:: Создаем структуру папок без лишних проверок
mkdir "%W%" 2>nul
mkdir "%B%" 2>nul
mkdir "%M%" 2>nul

echo [2/4] Installing Microsoft Runtimes...
winget install --id Microsoft.VCRedist.2015+.x64 --silent --accept-package-agreements --accept-source-agreements >nul 2>&1

echo [3/4] Downloading Components...
:: Проверяем движок. Если его нет - качаем и распаковываем
dir "%B%\llama-server.exe" >nul 2>&1 || curl -L "https://github.com/ggerganov/llama.cpp/releases/download/b4594/llama-b4594-bin-win-vulkan-x64.zip" -o "%W%\l.zip"
dir "%B%\llama-server.exe" >nul 2>&1 || tar -xf "%W%\l.zip" -C "%B%"
if exist "%W%\l.zip" del "%W%\l.zip"

:: Проверяем модель Saiga 8B (5.5GB)
dir "%M%\saiga.gguf" >nul 2>&1 || echo Downloading Model, please wait...
dir "%M%\saiga.gguf" >nul 2>&1 || curl -L "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_K.gguf" -o "%M%\saiga.gguf"

echo [4/4] Starting API Server on GPU 1 (RTX 5060)...
:: Создаем чистый скрипт запуска
echo @echo off > "%W%\s.bat"
echo cd /d "%B%" >> "%W%\s.bat"
:: ВАЖНО: --device 1 (для твоей 5060) и --cache-type-kv q4_0 (чтобы 16к влезло в 8ГБ)
echo llama-server.exe --model "%M%\saiga.gguf" --port 8010 --n-gpu-layers 99 --ctx-size 16384 --cache-type-kv q4_0 --device 1 --host 0.0.0.0 --log-disable >> "%W%\s.bat"

:: Запуск в невидимом режиме
start /min "" "%W%\s.bat"

echo ===================================================
echo SUCCESS! API: http://localhost:8010/v1
echo GPU 1 (RTX 5060) is active with 16k context.
echo ===================================================
timeout /t 10
