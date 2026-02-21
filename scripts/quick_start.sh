#!/usr/bin/env bash
set -euo pipefail

show_banner() {
    cat << 'BANNER'
╔════════════════════════════════════════════════════════════════╗
║           LLM Infrastructure Quick Start                       ║
╚════════════════════════════════════════════════════════════════╝
BANNER
}

show_menu() {
    echo "Выберите режим установки:"
    echo "  1) Локальная установка"
    echo "  2) Конфигурация моделей"
    echo "  3) Статус"
    echo "  0) Выход"
}

main() {
    show_banner
    show_menu
    read -r choice
    
    case $choice in
        1)
            ./scripts/bootstrap_llm.sh
            echo ""
            echo "Выполните: source ~/.bashrc"
            ;;
        2)
            ./scripts/configure_models.sh
            ;;
        3)
            llm-manager status 2>/dev/null || echo "llm-manager не установлен"
            ;;
        0)
            exit 0
            ;;
        *)
            echo "Неверный выбор"
            ;;
    esac
}

main "$@"
