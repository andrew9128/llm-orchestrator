#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Единая точка входа для LLM инфраструктуры
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_info() { echo -e "\033[0;32m[INFO]\033[0m $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }

show_banner() {
    cat << 'BANNER'
╔════════════════════════════════════════════════════════════════╗
║                                                                ║
║              LLM Infrastructure Manager                        ║
║                                                                ║
║  Автоматическая установка, конфигурация и запуск моделей     ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
BANNER
}

check_dependencies() {
    local missing=false
    
    for cmd in jq bc curl; do
        if ! command -v $cmd &> /dev/null; then
            log_error "Требуется: $cmd"
            missing=true
        fi
    done
    
    if $missing; then
        log_error "Установите зависимости: sudo apt install jq bc curl"
        exit 1
    fi
}

show_menu() {
    echo ""
    echo "Выберите действие:"
    echo ""
    echo "  1) Установка (выбор движков)"
    echo "  2) Скачать модели с HuggingFace"
    echo "  3) Автоматическое развертывание (на всех GPU)"
    echo "  4) Статус моделей"
    echo "  5) Остановить все модели"
    echo "  6) Запустить healthcheck"
    echo "  7) Остановить healthcheck"
    echo "  0) Выход"
    echo ""
}

install_engines() {
    echo ""
    echo "Выберите движки для установки:"
    echo "  1) vLLM"
    echo "  2) SGLang"
    echo "  3) lmdeploy"
    echo "  4) llama.cpp"
    echo "  5) Ollama"
    echo "  6) Всё сразу"
    echo ""
    read -p "Введите номера через пробел (например: 1 2): " choices
    
    local flags=""
    for choice in $choices; do
        case $choice in
            1) flags="$flags --vllm" ;;
            2) flags="$flags --sglang" ;;
            3) flags="$flags --lmdeploy" ;;
            4) flags="$flags --llamacpp" ;;
            5) flags="$flags --ollama" ;;
            6) flags="--all"; break ;;
        esac
    done
    
    if [ -z "$flags" ]; then
        log_error "Не выбраны движки"
        return
    fi
    
    log_info "Запуск установки с флагами: $flags"
    "${SCRIPT_DIR}/scripts/bootstrap_llm.sh" $flags
}

download_models() {
    log_info "Скачивание моделей..."
    "${SCRIPT_DIR}/scripts/bootstrap_llm.sh" --vllm --download-models
}

auto_deploy() {
    log_info "Автоматическое развертывание..."
    
    # Проверяем наличие моделей
    if [ ! -d "${HOME}/llm_models" ] || [ -z "$(ls -A ${HOME}/llm_models 2>/dev/null)" ]; then
        log_error "Модели не найдены в ~/llm_models"
        read -p "Скачать модели сейчас? (y/N): " download
        if [ "$download" = "y" ] || [ "$download" = "Y" ]; then
            download_models
        else
            return
        fi
    fi
    
    # Конфигурируем модели
    if [ ! -d "${HOME}/.config/llm_engines" ] || [ -z "$(ls -A ${HOME}/.config/llm_engines 2>/dev/null)" ]; then
        log_info "Конфигурация моделей..."
        "${SCRIPT_DIR}/scripts/configure_models.sh"
    fi
    
    # Запускаем auto-deploy
    "${SCRIPT_DIR}/scripts/auto_deploy.sh" --auto
}

show_status() {
    "${SCRIPT_DIR}/scripts/auto_deploy.sh" --status
}

stop_all() {
    "${SCRIPT_DIR}/scripts/auto_deploy.sh" --stop
}

start_healthcheck() {
    log_info "Запуск healthcheck в фоне..."
    
    nohup "${SCRIPT_DIR}/healthchecks/advanced_healthcheck.sh" \
        > "${HOME}/llm_engines/healthcheck_daemon.log" 2>&1 &
    
    echo $! > "${HOME}/llm_engines/healthcheck.pid"
    
    log_info "Healthcheck запущен (PID: $(cat ${HOME}/llm_engines/healthcheck.pid))"
    log_info "Логи: tail -f ~/llm_engines/healthcheck.log"
}

stop_healthcheck() {
    local pid_file="${HOME}/llm_engines/healthcheck.pid"
    
    if [ ! -f "$pid_file" ]; then
        log_error "Healthcheck не запущен"
        return
    fi
    
    local pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        rm "$pid_file"
        log_info "Healthcheck остановлен"
    else
        log_error "Процесс не найден"
        rm "$pid_file"
    fi
}

main() {
    show_banner
    check_dependencies
    
    while true; do
        show_menu
        read -p "Выбор: " choice
        
        case $choice in
            1) install_engines ;;
            2) download_models ;;
            3) auto_deploy ;;
            4) show_status ;;
            5) stop_all ;;
            6) start_healthcheck ;;
            7) stop_healthcheck ;;
            0) log_info "Выход"; exit 0 ;;
            *) log_error "Неверный выбор" ;;
        esac
        
        echo ""
        read -p "Нажмите Enter для продолжения..."
    done
}

# Если скрипт запущен с аргументами - выполняем напрямую
if [ $# -gt 0 ]; then
    case "$1" in
        --install) install_engines ;;
        --download) download_models ;;
        --deploy) auto_deploy ;;
        --status) show_status ;;
        --stop) stop_all ;;
        --healthcheck-start) start_healthcheck ;;
        --healthcheck-stop) stop_healthcheck ;;
        --auto)
            # Полностью автоматический режим
            if [ ! -d "${HOME}/miniconda3" ]; then
                install_engines
                source ~/.bashrc
            fi
            if [ ! -d "${HOME}/llm_models" ] || [ -z "$(ls -A ${HOME}/llm_models)" ]; then
                download_models
            fi
            auto_deploy
            start_healthcheck
            ;;
        *) main ;;
    esac
else
    main
fi
