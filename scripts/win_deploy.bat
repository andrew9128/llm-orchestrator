@echo off
set "W=%USERPROFILE%\llm_native"
echo [1/4] Cleaning system...
taskkill /F /IM llama-server.exe /T >nul 2>&1
if not exist "%W%\bin" mkdir "%W%\bin"
if not exist "%W%\models" mkdir "%W%\models"

echo [2/4] Installing Microsoft Runtimes...
winget install --id Microsoft.VCRedist.2015+.x64 --silent --accept-package-agreements --accept-source-agreements >nul 2>&1

echo [3/4] Downloading Engine and Model...
if not exist "%W%\bin\llama-server.exe" (
    curl -L "https://github.com/ggerganov/llama.cpp/releases/download/b4594/llama-b4594-bin-win-vulkan-x64.zip" -o "%W%\l.zip"
    tar -xf "%W%\l.zip" -C "%W%\bin"
    del "%W%\l.zip"
)
if not exist "%W%\models\saiga.gguf" (
    curl -L "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_K.gguf" -o "%W%\models\saiga.gguf"
)

echo [4/4] Starting Server on RTX 5060 (GPU 1)...
:: Создаем команду запуска: 16к контекст, сжатие кэша q4_0 чтобы влезло в 8ГБ, выбор GPU 1
echo @echo off > "%W%\start.bat"
echo cd /d "%W%\bin" >> "%W%\start.bat"
echo llama-server.exe --model "%W%\models\saiga.gguf" --port 8010 --n-gpu-layers 99 --ctx-size 16384 --cache-type-kv q4_0 --device 1 --host 0.0.0.0 --log-disable >> "%W%\start.bat"

:: Запуск в скрытом режиме
start /min "" "%W%\start.bat"

echo ===================================================
echo DONE! API: http://localhost:8010/v1
echo Model is loading on GPU 1. You can close this window.
echo ===================================================
pause
