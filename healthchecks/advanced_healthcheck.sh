#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Advanced Healthcheck с умным автовосстановлением
# ============================================================================

DEPLOY_STATE="${HOME}/llm_engines/deploy_state.json"
LOG_FILE="${HOME}/llm_engines/healthcheck.log"
CHECK_INTERVAL=30
MAX_RESTART_ATTEMPTS=3
COOLDOWN_PERIOD=300  # 5 минут между перезапусками

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Состояние перезапусков (in-memory)
declare -A RESTART_COUNT
declare -A LAST_RESTART_TIME
declare -A FAILURE_REASON

check_oom_in_logs() {
    local log_file=$1
    
    if [ ! -f "$log_file" ]; then
        return 1
    fi
    
    # Последние 100 строк логов
    local recent_logs=$(tail -100 "$log_file")
    
    # Проверка на OOM
    if echo "$recent_logs" | grep -qi "out of memory\|OOM\|CUDA out of memory\|not enough memory"; then
        echo "oom"
        return 0
    fi
    
    # Проверка на context length errors
    if echo "$recent_logs" | grep -qi "context length\|exceeds.*context\|maximum context"; then
        echo "context"
        return 0
    fi
    
    # Проверка на quantization errors
    if echo "$recent_logs" | grep -qi "quantization.*failed\|unsupported.*quantization"; then
        echo "quantization"
        return 0
    fi
    
    echo "unknown"
}

adjust_parameters_on_error() {
    local deployment=$1
    local error_type=$2
    
    local gpu_id=$(echo "$deployment" | jq -r '.gpu_id')
    local model=$(echo "$deployment" | jq -r '.model')
    local ctx=$(echo "$deployment" | jq -r '.max_context')
    local util=$(echo "$deployment" | jq -r '.gpu_memory_utilization')
    local quant=$(echo "$deployment" | jq -r '.quantization')
    
    log "🔧 Адаптация параметров для GPU $gpu_id ($error_type)"
    
    case "$error_type" in
        "oom")
            # OOM - уменьшаем utilization и context
            local new_util=$(echo "$util - 0.10" | bc)
            local new_ctx=$((ctx / 2))
            
            if (( $(echo "$new_util < 0.60" | bc -l) )); then
                new_util=0.60
            fi
            
            if [ $new_ctx -lt 2048 ]; then
                new_ctx=2048
            fi
            
            # Добавляем квантизацию если не было
            if [ "$quant" = "none" ]; then
                quant="fp8"
            fi
            
            log "  → Уменьшение utilization: $util → $new_util"
            log "  → Уменьшение context: $ctx → $new_ctx"
            log "  → Квантизация: $quant"
            
            # Обновляем deployment
            echo "$deployment" | jq \
                ".gpu_memory_utilization = $new_util | .max_context = $new_ctx | .quantization = \"$quant\""
            ;;
            
        "context")
            # Context error - уменьшаем только context
            local new_ctx=$((ctx / 2))
            
            if [ $new_ctx -lt 2048 ]; then
                new_ctx=2048
            fi
            
            log "  → Уменьшение context: $ctx → $new_ctx"
            
            echo "$deployment" | jq ".max_context = $new_ctx"
            ;;
            
        *)
            # Неизвестная ошибка - консервативные настройки
            log "  → Применение консервативных настроек"
            
            echo "$deployment" | jq \
                '.gpu_memory_utilization = 0.75 | .max_context = 4096 | .quantization = "fp8"'
            ;;
    esac
}

restart_model() {
    local deployment=$1
    local attempt=${2:-1}
    
    local gpu_id=$(echo "$deployment" | jq -r '.gpu_id')
    local model=$(echo "$deployment" | jq -r '.model')
    local engine=$(echo "$deployment" | jq -r '.engine')
    local port=$(echo "$deployment" | jq -r '.port')
    
    local key="${engine}_gpu${gpu_id}"
    
    # Проверка cooldown
    local now=$(date +%s)
    local last_restart=${LAST_RESTART_TIME[$key]:-0}
    local time_since_restart=$((now - last_restart))
    
    if [ $time_since_restart -lt $COOLDOWN_PERIOD ]; then
        log "⏰ GPU $gpu_id: В cooldown периоде ($time_since_restart/$COOLDOWN_PERIOD сек)"
        return 1
    fi
    
    # Проверка максимума попыток
    local count=${RESTART_COUNT[$key]:-0}
    if [ $count -ge $MAX_RESTART_ATTEMPTS ]; then
        log "🚫 GPU $gpu_id: Достигнут лимит перезапусков ($count/$MAX_RESTART_ATTEMPTS)"
        return 1
    fi
    
    log "🔄 GPU $gpu_id: Попытка перезапуска #$attempt - $model ($engine)"
    
    # Останавливаем старый процесс
    local pid_file="${HOME}/llm_engines/${key}.pid"
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        kill -9 "$pid" 2>/dev/null || true
        rm "$pid_file"
    fi
    
    # Проверяем логи на ошибки
    local log_file="${HOME}/llm_engines/${key}.log"
    local error_type=$(check_oom_in_logs "$log_file")
    
    if [ "$error_type" != "unknown" ]; then
        log "📊 Обнаружена ошибка: $error_type"
        
        # Адаптируем параметры
        deployment=$(adjust_parameters_on_error "$deployment" "$error_type")
        
        # Сохраняем обновленный deployment
        update_deployment_in_state "$gpu_id" "$deployment"
    fi
    
    # Архивируем старый лог
    if [ -f "$log_file" ]; then
        mv "$log_file" "${log_file}.$(date +%Y%m%d_%H%M%S).bak"
    fi
    
    sleep 5
    
    # Строим команду запуска
    local model_path="${HOME}/llm_models/$(echo "$deployment" | jq -r '.model')"
    local quant=$(echo "$deployment" | jq -r '.quantization')
    local ctx=$(echo "$deployment" | jq -r '.max_context')
    local util=$(echo "$deployment" | jq -r '.gpu_memory_utilization')
    local kv_dtype=$(echo "$deployment" | jq -r '.kv_cache_dtype')
    
    case "$engine" in
        "vllm")
            CUDA_VISIBLE_DEVICES=$gpu_id bash -c "
                source \"\${HOME}/miniconda3/bin/activate\" vllm_env && \
                python -m vllm.entrypoints.openai.api_server \
                  --model \"$model_path\" \
                  --port $port \
                  --max-model-len $ctx \
                  --gpu-memory-utilization $util \
                  --kv-cache-dtype $kv_dtype \
                  $([ "$quant" != "none" ] && echo "--quantization $quant" || echo "") \
                  --trust-remote-code \
                  --dtype auto \
                  > \"$log_file\" 2>&1 & echo \$! > \"$pid_file\"
            "
            ;;
        "sglang")
            CUDA_VISIBLE_DEVICES=$gpu_id bash -c "
                source \"\${HOME}/miniconda3/bin/activate\" sglang_env && \
                python -m sglang.launch_server \
                  --model-path \"$model_path\" \
                  --port $port \
                  --tp 1 \
                  --mem-fraction-static $util \
                  --context-length $ctx \
                  --kv-cache-dtype $kv_dtype \
                  --trust-remote-code \
                  > \"$log_file\" 2>&1 & echo \$! > \"$pid_file\"
            "
            ;;
        "lmdeploy")
            CUDA_VISIBLE_DEVICES=$gpu_id bash -c "
                source \"\${HOME}/miniconda3/bin/activate\" lmdeploy_env && \
                lmdeploy serve api_server \
                  \"$model_path\" \
                  --server-port $port \
                  --tp 1 \
                  --cache-max-entry-count $util \
                  --trust-remote-code \
                  > \"$log_file\" 2>&1 & echo \$! > \"$pid_file\"
            "
            ;;
    esac
    
    # Обновляем счетчики
    RESTART_COUNT[$key]=$((count + 1))
    LAST_RESTART_TIME[$key]=$now
    FAILURE_REASON[$key]=$error_type
    
    log "✅ GPU $gpu_id: Перезапуск выполнен"
    return 0
}

update_deployment_in_state() {
    local gpu_id=$1
    local new_deployment=$2
    
    if [ ! -f "$DEPLOY_STATE" ]; then
        return
    fi
    
    local plan=$(cat "$DEPLOY_STATE")
    local updated_plan=$(echo "$plan" | jq \
        "(.deployments[] | select(.gpu_id == $gpu_id)) = $new_deployment")
    
    echo "$updated_plan" > "$DEPLOY_STATE"
}

check_model() {
    local deployment=$1
    
    local gpu_id=$(echo "$deployment" | jq -r '.gpu_id')
    local model=$(echo "$deployment" | jq -r '.model')
    local engine=$(echo "$deployment" | jq -r '.engine')
    local port=$(echo "$deployment" | jq -r '.port')
    
    local key="${engine}_gpu${gpu_id}"
    local pid_file="${HOME}/llm_engines/${key}.pid"
    
    # Проверка процесса
    if [ ! -f "$pid_file" ]; then
        log "❌ GPU $gpu_id: PID файл не найден"
        restart_model "$deployment"
        return
    fi
    
    local pid=$(cat "$pid_file")
    if ! kill -0 "$pid" 2>/dev/null; then
        log "❌ GPU $gpu_id: Процесс упал (PID: $pid)"
        restart_model "$deployment"
        return
    fi
    
    # Проверка HTTP endpoint
    local health_ok=false
    
    if curl -s --max-time 10 "http://localhost:$port/health" | grep -qi "ok\|healthy" 2>/dev/null; then
        health_ok=true
    elif curl -s --max-time 10 "http://localhost:$port/v1/models" > /dev/null 2>&1; then
        health_ok=true
    fi
    
    if $health_ok; then
        log "✅ GPU $gpu_id: $model OK (port $port)"
        
        # Сбрасываем счетчик при успехе
        RESTART_COUNT[$key]=0
    else
        log "⚠️  GPU $gpu_id: API не отвечает"
        
        # Проверяем логи на ошибки
        local log_file="${HOME}/llm_engines/${key}.log"
        local error_type=$(check_oom_in_logs "$log_file")
        
        if [ "$error_type" != "unknown" ]; then
            log "🔍 GPU $gpu_id: Обнаружена ошибка в логах: $error_type"
            restart_model "$deployment"
        fi
    fi
}

main_loop() {
    log "🚀 Запуск Advanced Healthcheck"
    log "Интервал проверки: ${CHECK_INTERVAL}с"
    log "Макс. перезапусков: $MAX_RESTART_ATTEMPTS"
    log "Cooldown: ${COOLDOWN_PERIOD}с"
    
    while true; do
        if [ ! -f "$DEPLOY_STATE" ]; then
            log "⚠️  Файл состояния не найден: $DEPLOY_STATE"
            sleep $CHECK_INTERVAL
            continue
        fi
        
        local plan=$(cat "$DEPLOY_STATE")
        local deploy_count=$(echo "$plan" | jq -r '.deployments | length')
        
        log "═══ Проверка ($deploy_count моделей) ═══"
        
        for ((i=0; i<deploy_count; i++)); do
            local d=$(echo "$plan" | jq -r ".deployments[$i]")
            check_model "$d"
        done
        
        sleep $CHECK_INTERVAL
    done
}

# Запуск
mkdir -p "$(dirname "$LOG_FILE")"
main_loop
