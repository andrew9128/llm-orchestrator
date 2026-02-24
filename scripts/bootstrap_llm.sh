#!/usr/bin/env bash
set -euo pipefail

# Установка LLM инфраструктуры с флагами
INSTALL_DIR="${HOME}/.local"
BIN_DIR="${INSTALL_DIR}/bin"

# Флаги по умолчанию
INSTALL_VLLM=false
INSTALL_SGLANG=false
INSTALL_LMDEPLOY=false
INSTALL_LLAMACPP=false
INSTALL_OLLAMA=false
DOWNLOAD_MODELS=false
SELECTED_MODELS=""
AUTO_ACCEPT_TOS=true

log_info() { echo -e "\033[0;32m[INFO]\033[0m $*"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }

show_help() {
    cat << HELP
Установка LLM инфраструктуры

Использование:
    $0 [OPTIONS]

Опции:
    --vllm              Установить vLLM
    --sglang            Установить SGLang
    --lmdeploy          Установить lmdeploy
    --llamacpp          Установить llama.cpp
    --ollama            Установить Ollama
    --all               Установить всё
    --download-models   Скачать модели с HuggingFace
    --help              Показать справку

Примеры:
    $0 --vllm --sglang              # Только vLLM и SGLang
    $0 --all                        # Всё сразу
    $0 --lmdeploy --download-models # lmdeploy + скачивание моделей
HELP
    exit 0
}

# Парсинг аргументов
while [[ $# -gt 0 ]]; do
    case $1 in
        --vllm) INSTALL_VLLM=true; shift ;;
        --sglang) INSTALL_SGLANG=true; shift ;;
        --lmdeploy) INSTALL_LMDEPLOY=true; shift ;;
        --llamacpp) INSTALL_LLAMACPP=true; shift ;;
        --ollama) INSTALL_OLLAMA=true; shift ;;
        --all)
            INSTALL_VLLM=true
            INSTALL_SGLANG=true
            INSTALL_LMDEPLOY=true
            INSTALL_LLAMACPP=true
            INSTALL_OLLAMA=true
            shift
            ;;
        --download-models)
            DOWNLOAD_MODELS=true
            if [[ $# -gt 1 && ! $2 =~ ^-- ]]; then
                SELECTED_MODELS="$2"
                shift
            fi
            shift
            ;;
        --help|-h) show_help ;;
        *) log_error "Неизвестный флаг: $1"; show_help ;;
    esac
done

# Если ничего не выбрано - показать help
if ! $INSTALL_VLLM && ! $INSTALL_SGLANG && ! $INSTALL_LMDEPLOY && ! $INSTALL_LLAMACPP && ! $INSTALL_OLLAMA && ! $DOWNLOAD_MODELS; then
    log_error "Не выбраны движки для установки"
    show_help
fi

check_gpu() {
    if ! command -v nvidia-smi &> /dev/null; then
        log_warn "nvidia-smi не найден, GPU не доступен"
        return 1
    fi
    log_info "Обнаружено GPU:"
    nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader | nl -v 0
    return 0
}

setup_directories() {
    log_info "Создание директорий..."
    mkdir -p "${BIN_DIR}"
    mkdir -p "${HOME}/.cache/pip"
    mkdir -p "${HOME}/llm_engines"
    mkdir -p "${HOME}/llm_models"

    if ! grep -q "${BIN_DIR}" ~/.bashrc 2>/dev/null; then
        echo "export PATH=\"${BIN_DIR}:\$PATH\"" >> ~/.bashrc
        echo "export LD_LIBRARY_PATH=\"${HOME}/.local/lib:\$LD_LIBRARY_PATH\"" >> ~/.bashrc
    fi

    export PATH="${BIN_DIR}:$PATH"
}

install_miniconda() {
    log_info "Установка Miniconda..."

    if [ -d "${HOME}/miniconda3" ]; then
        log_info "Miniconda уже установлен"
        source "${HOME}/miniconda3/bin/activate" 2>/dev/null || true
    else
        wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O /tmp/miniconda.sh
        bash /tmp/miniconda.sh -b -p "${HOME}/miniconda3"
        rm /tmp/miniconda.sh
        "${HOME}/miniconda3/bin/conda" init bash > /dev/null 2>&1
        source "${HOME}/miniconda3/bin/activate"
    fi

    # Автоматически принимаем ToS если нужно
    if $AUTO_ACCEPT_TOS; then
        log_info "Принятие Conda ToS..."
        conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main 2>/dev/null || true
        conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r 2>/dev/null || true
    fi

    "${HOME}/miniconda3/bin/conda" install -y -c conda-forge cmake -q

    log_info "Miniconda готов"
}

create_vllm_env() {
    log_info "Создание окружения vLLM..."

    source "${HOME}/miniconda3/bin/activate"

    if conda env list | grep -q "vllm_env"; then
        log_info "vllm_env уже существует"
        return 0
    fi

    conda create -n vllm_env python=3.11 -y -q
    conda activate vllm_env
    pip install -q vllm ray[default]
    conda deactivate
}

create_sglang_env() {
    log_info "Подготовка окружения SGLang..."
    source "${HOME}/miniconda3/bin/activate"

    if ! conda env list | grep -q "sglang_env"; then
        conda create -n sglang_env python=3.11 -y -q
    fi

    local env_pip="${HOME}/miniconda3/envs/sglang_env/bin/pip"
    local env_conda="${HOME}/miniconda3/bin/conda"

    log_info "Установка GCC 11 через conda (нужен C++20 для SGLang JIT)..."
    $env_conda install -n sglang_env -y -c conda-forge gcc=11 gxx=11 -q
    export CC="${HOME}/miniconda3/envs/sglang_env/bin/x86_64-conda-linux-gnu-gcc"
    export CXX="${HOME}/miniconda3/envs/sglang_env/bin/x86_64-conda-linux-gnu-g++"

    log_info "Установка SGLang..."
    $env_pip install "sglang[all]" --find-links https://flashinfer.ai/whl/cu121/torch2.5/ || \
    $env_pip install "sglang[all]" --find-links https://flashinfer.ai/whl/cu124/torch2.5/ || \
    $env_pip install "sglang[all]"

    log_info "Окружение SGLang готово!"
}


create_lmdeploy_env() {
    log_info "Создание окружения lmdeploy..."
    source "${HOME}/miniconda3/bin/activate"
    if conda env list | grep -q "lmdeploy_env"; then
        log_info "lmdeploy_env уже существует — обновляем lmdeploy"
        conda activate lmdeploy_env
        pip install lmdeploy --upgrade -q
        conda deactivate
        return 0
    fi
    log_info "Создаём новое окружение lmdeploy_env..."
    conda create -n lmdeploy_env python=3.11 -y -q
    conda activate lmdeploy_env
    pip install lmdeploy --upgrade -q
    conda deactivate
    log_info "lmdeploy установлен в lmdeploy_env"
}

install_ollama() {
    log_info "Установка Ollama..."

    if [ -f "${BIN_DIR}/ollama" ]; then
        log_info "Ollama уже установлен"
        return 0
    fi

    curl -sL https://ollama.com/download/ollama-linux-amd64 -o "${BIN_DIR}/ollama"
    chmod +x "${BIN_DIR}/ollama"

    mkdir -p "${HOME}/.ollama/models"

    if ! grep -q "OLLAMA_MODELS" ~/.bashrc 2>/dev/null; then
        echo "export OLLAMA_MODELS=\"${HOME}/.ollama/models\"" >> ~/.bashrc
    fi
}

download_models() {
    log_info "Подготовка к скачиванию моделей..."
    source "${HOME}/miniconda3/bin/activate"
    "${HOME}/miniconda3/bin/python" -m pip install -q huggingface-hub[cli] hf_transfer
    export HF_HUB_ENABLE_HF_TRANSFER=1

    if [ -z "$SELECTED_MODELS" ]; then
        SELECTED_MODELS="Vikhrmodels/QVikhr-3-8B-Instruction IlyaGusev/saiga_nemo_12b"
        log_warn "Список моделей не указан, качаем дефолтные: $SELECTED_MODELS"
    fi

    for repo in $SELECTED_MODELS; do
        local folder=$(echo "$repo" | awk -F'/' '{print $NF}')
        local model_path="${HOME}/llm_models/${folder}"

        local required_space=50 # GB
        local available=$(df -BG "${HOME}" | awk 'NR==2 {print $4}' | sed 's/G//')
        if [ "$available" -lt "$required_space" ]; then
            log_error "Недостаточно места: ${available}GB (нужно ${required_space}GB)"
            continue
        fi

        log_info "Скачивание HF: $repo -> $folder..."
        mkdir -p "$model_path"

        # Скачивание с обработкой ошибок
        if ! huggingface-cli download "$repo" \
            --local-dir "$model_path" \
            --local-dir-use-symlinks False \
            --resume-download 2>&1 | tee "${HOME}/llm_engines/download_${folder}.log"; then
            log_error "Ошибка скачивания $repo, см. логи"
            continue
        fi

        log_info "✓ Скачано: $folder"
    done
}

create_launcher_scripts() {
    log_info "Создание launcher-скриптов..."

    if $INSTALL_VLLM; then
        cat > "${BIN_DIR}/launch_vllm" << 'SCRIPT'
#!/usr/bin/env bash
source "${HOME}/miniconda3/bin/activate" vllm_env
exec python -m vllm.entrypoints.openai.api_server "$@"
SCRIPT
        chmod +x "${BIN_DIR}/launch_vllm"
    fi

    if $INSTALL_SGLANG; then
        cat > "${BIN_DIR}/launch_sglang" << 'SCRIPT'
#!/usr/bin/env bash
source "${HOME}/miniconda3/bin/activate" sglang_env
exec python -m sglang.launch_server "$@"
SCRIPT
        chmod +x "${BIN_DIR}/launch_sglang"
    fi

    if $INSTALL_LMDEPLOY; then
        cat > "${BIN_DIR}/launch_lmdeploy" << 'SCRIPT'
#!/usr/bin/env bash
source "${HOME}/miniconda3/bin/activate" lmdeploy_env
exec lmdeploy serve api_server "$@"
SCRIPT
        chmod +x "${BIN_DIR}/launch_lmdeploy"
    fi
}

create_management_script() {
    log_info "Создание llm-manager..."

    cat > "${BIN_DIR}/llm-manager" << 'SCRIPT'
#!/usr/bin/env bash

show_help() {
    cat << HELP
LLM Manager - управление LLM серверами

Команды:
    start [ENGINE] [OPTIONS]  - Запустить сервер
    stop [ENGINE]             - Остановить сервер
    status                    - Показать статус
    list                      - Список engines

Engines: vllm, sglang, lmdeploy, ollama, llamacpp

Примеры:
    llm-manager start vllm --model ~/llm_models/Vikhr-3-8B --port 8000
    llm-manager stop vllm
    llm-manager status
HELP
}

start_engine() {
    local engine=$1
    shift

    case "$engine" in
        vllm)
            launch_vllm "$@" > ~/llm_engines/vllm.log 2>&1 &
            echo $! > ~/llm_engines/vllm.pid
            echo "vLLM запущен (PID: $(cat ~/llm_engines/vllm.pid))"
            echo "Логи: tail -f ~/llm_engines/vllm.log"
            ;;
        sglang)
            launch_sglang "$@" > ~/llm_engines/sglang.log 2>&1 &
            echo $! > ~/llm_engines/sglang.pid
            echo "SGLang запущен (PID: $(cat ~/llm_engines/sglang.pid))"
            echo "Логи: tail -f ~/llm_engines/sglang.log"
            ;;
        lmdeploy)
            launch_lmdeploy "$@" > ~/llm_engines/lmdeploy.log 2>&1 &
            echo $! > ~/llm_engines/lmdeploy.pid
            echo "lmdeploy запущен (PID: $(cat ~/llm_engines/lmdeploy.pid))"
            echo "Логи: tail -f ~/llm_engines/lmdeploy.log"
            ;;
        ollama)
            OLLAMA_MODELS="${HOME}/.ollama/models" ollama serve > ~/llm_engines/ollama.log 2>&1 &
            echo $! > ~/llm_engines/ollama.pid
            echo "Ollama запущен (PID: $(cat ~/llm_engines/ollama.pid))"
            ;;
        llamacpp)
            llama-server "$@" > ~/llm_engines/llamacpp.log 2>&1 &
            echo $! > ~/llm_engines/llamacpp.pid
            echo "llama.cpp запущен (PID: $(cat ~/llm_engines/llamacpp.pid))"
            ;;
        *)
            echo "Неизвестный engine: $engine"
            show_help
            exit 1
            ;;
    esac
}

stop_engine() {
    local engine=$1
    local pidfile=~/llm_engines/${engine}.pid

    if [ -f "$pidfile" ]; then
        local pid=$(cat "$pidfile")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            sleep 2
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm "$pidfile"
        echo "${engine} остановлен"
    else
        echo "${engine} не запущен"
    fi
}

show_status() {
    echo "Статус LLM серверов:"
    for engine in vllm sglang lmdeploy ollama llamacpp; do
        pidfile=~/llm_engines/${engine}.pid
        if [ -f "$pidfile" ] && kill -0 $(cat "$pidfile") 2>/dev/null; then
            echo "✓ $engine: работает (PID: $(cat "$pidfile"))"
        else
            echo "✗ $engine: не запущен"
        fi
    done
}

case "${1:-}" in
    start) shift; start_engine "$@" ;;
    stop) stop_engine "$2" ;;
    status) show_status ;;
    list) echo "vllm, sglang, lmdeploy, ollama, llamacpp" ;;
    *) show_help ;;
esac
SCRIPT
    chmod +x "${BIN_DIR}/llm-manager"
}

print_summary() {
    cat << SUMMARY

╔════════════════════════════════════════════════════════════════╗
║          Установка завершена!                                  ║
╚════════════════════════════════════════════════════════════════╝

Установлено:
$(if $INSTALL_VLLM; then echo "  ✓ vLLM (conda: vllm_env)"; fi)
$(if $INSTALL_SGLANG; then echo "  ✓ SGLang (conda: sglang_env)"; fi)
$(if $INSTALL_LMDEPLOY; then echo "  ✓ lmdeploy (conda: lmdeploy_env)"; fi)
$(if $INSTALL_LLAMACPP; then echo "  ✓ llama.cpp"; fi)
$(if $INSTALL_OLLAMA; then echo "  ✓ Ollama"; fi)

Следующие шаги:
  1. Перезагрузите shell: source ~/.bashrc
  2. Сконфигурируйте модели: ./scripts/configure_models.sh
  3. Запустите модель: llm-select-model

Команды:
  llm-manager status           # Статус серверов
  llm-select-model            # Список моделей
  llm-manager start vllm --model <path> --port 8000

SUMMARY
}

main() {
    log_info "Начало установки LLM инфраструктуры..."
    log_info "Выбрано: vLLM=$INSTALL_VLLM, SGLang=$INSTALL_SGLANG, lmdeploy=$INSTALL_LMDEPLOY, llama.cpp=$INSTALL_LLAMACPP, Ollama=$INSTALL_OLLAMA"

    check_gpu || log_warn "Продолжаем без GPU"

    setup_directories
    install_miniconda

    if $INSTALL_VLLM; then create_vllm_env; fi
    if $INSTALL_SGLANG; then create_sglang_env; fi
    if $INSTALL_LMDEPLOY; then create_lmdeploy_env; fi
    if $INSTALL_LLAMACPP; then install_llamacpp; fi
    if $INSTALL_OLLAMA; then install_ollama; fi

    if $DOWNLOAD_MODELS; then download_models; fi

    create_launcher_scripts
    create_management_script

    print_summary
}

main "$@"
