@echo off
set "W=%USERPROFILE%\llm_native"
echo [1/4] Cleaning system...
taskkill /F /IM llama-server.exe /T >nul 2>&1
if not exist "%W%\bin" mkdir "%W%\bin"
if not exist "%W%\models" mkdir "%W%\models"

echo [2/4] Installing Microsoft Runtimes (Silent)...
winget install --id Microsoft.VCRedist.2015+.x64 --silent --accept-package-agreements --accept-source-agreements >nul 2>&1

echo [3/4] Downloading Engine and Model...
if not exist "%W%\bin\llama-server.exe" (
    curl -L "https://github.com/ggerganov/llama.cpp/releases/download/b4594/llama-b4594-bin-win-vulkan-x64.zip" -o "%W%\l.zip"
    tar -xf "%W%\l.zip" -C "%W%\bin"
    del "%W%\l.zip"
)
if not exist "%W%\models\saiga.gguf" (
    echo Downloading Saiga 8B (5.5GB)...
    curl -L "https://huggingface.co/IlyaGusev/saiga_llama3_8b_gguf/resolve/main/model-q4_K.gguf" -o "%W%\models\saiga.gguf"
)

echo [4/4] Launching Background Server on RTX 5060 (GPU 1)...
echo @echo off > "%W%\start.bat"
echo cd /d "%W%\bin" >> "%W%\start.bat"
:: Оптимизация: q4_0 кеш (влезет 16к в 8ГБ) + принудительно GPU 1
echo llama-server.exe --model "%W%\models\saiga.gguf" --port 8010 --n-gpu-layers 99 --ctx-size 16384 --cache-type-kv q4_0 --device 1 --host 0.0.0.0 --log-disable >> "%W%\start.bat"

start /min "" "%W%\start.bat"

echo ===================================================
echo SUCCESS! API is starting at: http://localhost:8010/v1
echo GPU 1 (RTX 5060) is now working.
echo ===================================================
timeout /t 10
