#!/usr/bin/env bash
set -euo pipefail

MODEL_DIR="${HOME}/llm_models"
CONFIG_DIR="${HOME}/.config/llm_engines"

log_info() { echo -e "\033[0;32m[INFO]\033[0m $*"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }

mkdir -p "${CONFIG_DIR}"

# Получение свободной VRAM на GPU
get_gpu_free_vram() {
    local gpu_id=$1
    nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits -i "$gpu_id" 2>/dev/null || echo "0"
}

# Оценка размера модели в GB
estimate_model_size() {
    local model_name=$1
    
    case "$model_name" in
        *4B*|*4b*) echo "8" ;;
        *7B*|*7b*) echo "15" ;;
        *8B*|*8b*) echo "16" ;;
        *12B*|*12b*) echo "24" ;;
        *13B*|*13b*) echo "26" ;;
        *) echo "20" ;;  # default
    esac
}

# Автоматический выбор оптимальных параметров
auto_config() {
    local model_size=$1
    local gpu_vram=$2
    
    # Квантизация
    local quant="none"
    local ctx=16384
    local util=0.90
    
    if (( $(echo "$model_size > $gpu_vram" | bc -l) )); then
        quant="fp8"
        ctx=8192
        util=0.85
    fi
    
    if (( $(echo "$model_size * 0.5 > $gpu_vram" | bc -l) )); then
        ctx=4096
        util=0.80
    fi
    
    echo "$quant|$ctx|$util"
}

scan_and_configure_models() {
    log_info "Сканирование моделей в ${MODEL_DIR}..."
    
    if [ ! -d "$MODEL_DIR" ]; then
        log_warn "Директория не найдена: $MODEL_DIR"
        log_warn "Создайте директорию и поместите модели, или используйте --download-models"
        return 1
    fi
    
    local model_count=0
    
    # Получаем информацию о первом доступном GPU
    local gpu_vram=$(get_gpu_free_vram 0)
    gpu_vram=$(echo "scale=2; $gpu_vram / 1024" | bc)
    
    if [ "$gpu_vram" != "0" ]; then
        log_info "Обнаружено GPU 0 с ${gpu_vram}GB свободной VRAM"
    fi
    
    for model_dir in "$MODEL_DIR"/*; do
        if [ -d "$model_dir" ]; then
            local model_name=$(basename "$model_dir")
            log_info "Обработка: $model_name"
            
            local model_size=$(estimate_model_size "$model_name")
            local config=$(auto_config "$model_size" "${gpu_vram:-16}")
            IFS='|' read -r quant ctx util <<< "$config"
            
            # vLLM launcher
            cat > "${CONFIG_DIR}/launch_vllm_${model_name}.sh" << VLLM
#!/usr/bin/env bash
source "\${HOME}/miniconda3/bin/activate" vllm_env

# Auto-configured for ${model_name}
# Estimated size: ${model_size}GB, GPU VRAM: ${gpu_vram}GB
# Quantization: $quant, Context: $ctx, Utilization: $util

python -m vllm.entrypoints.openai.api_server \\
    --model "${model_dir}" \\
    --port 8000 \\
    --dtype auto \\
    --max-model-len $ctx \\
    --gpu-memory-utilization $util \\
    $(if [ "$quant" != "none" ]; then echo "--quantization $quant"; fi) \\
    --trust-remote-code \\
    "\$@"
VLLM
            chmod +x "${CONFIG_DIR}/launch_vllm_${model_name}.sh"
            
            # SGLang launcher с оптимизацией
            local sglang_ctx=$ctx
            local kv_dtype="auto"
            if (( model_size > 16 )); then
                kv_dtype="fp8_e5m2"
            fi
            
            cat > "${CONFIG_DIR}/launch_sglang_${model_name}.sh" << SGLANG
#!/usr/bin/env bash
source "\${HOME}/miniconda3/bin/activate" sglang_env

# Auto-configured for ${model_name}
python -m sglang.launch_server \\
    --model-path "${model_dir}" \\
    --port 8001 \\
    --tp 1 \\
    --mem-fraction-static $util \\
    --context-length $sglang_ctx \\
    --kv-cache-dtype $kv_dtype \\
    --trust-remote-code \\
    "\$@"
SGLANG
            chmod +x "${CONFIG_DIR}/launch_sglang_${model_name}.sh"
            
            # lmdeploy launcher
            cat > "${CONFIG_DIR}/launch_lmdeploy_${model_name}.sh" << LMDEPLOY
#!/usr/bin/env bash
source "\${HOME}/miniconda3/bin/activate" lmdeploy_env

# Auto-configured for ${model_name}
lmdeploy serve api_server \\
    "${model_dir}" \\
    --server-port 8002 \\
    --tp 1 \\
    --cache-max-entry-count $util \\
    --trust-remote-code \\
    "\$@"
LMDEPLOY
            chmod +x "${CONFIG_DIR}/launch_lmdeploy_${model_name}.sh"
            
            ((model_count++))
        fi
    done
    
    if [ $model_count -eq 0 ]; then
        log_warn "Модели не найдены!"
        log_warn "Используйте: ./scripts/bootstrap_llm.sh --download-models"
        return 1
    fi
    
    log_info "Обработано моделей: $model_count"
}

create_model_selector() {
    cat > "${HOME}/.local/bin/llm-select-model" << 'SELECTOR'
#!/usr/bin/env bash

CONFIG_DIR="${HOME}/.config/llm_engines"

if [ $# -eq 0 ]; then
    echo "Доступные конфигурации:"
    for script in "${CONFIG_DIR}"/launch_*.sh; do
        if [ -f "$script" ]; then
            name=$(basename "$script" .sh | sed 's/^launch_//')
            echo "  • $name"
        fi
    done
    echo ""
    echo "Использование: $0 <engine>_<model_name>"
    echo "Пример: $0 vllm_QVikhr-3-8B-Instruction"
    exit 0
fi

config_name=$1
shift
script_path="${CONFIG_DIR}/launch_${config_name}.sh"

if [ ! -f "$script_path" ]; then
    echo "Конфигурация не найдена: $config_name"
    exit 1
fi

exec bash "$script_path" "$@"
SELECTOR
    
    chmod +x "${HOME}/.local/bin/llm-select-model"
}

main() {
    scan_and_configure_models || exit 1
    create_model_selector
    log_info "Конфигурация завершена!"
    echo ""
    echo "Запуск:"
    echo "  llm-select-model                          # Список"
    echo "  llm-select-model vllm_<model_name>        # Запуск"
}

main "$@"
