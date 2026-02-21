#!/usr/bin/env bash
set -euo pipefail

MODELS_DIR="${HOME}/llm_models"
DEPLOY_STATE="${HOME}/llm_engines/deploy_state.txt"
DEPLOYED_LIST=""

log_info() { echo -e "\033[0;32m[INFO]\033[0m $*"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }

# Классификация GPU
classify_gpu() {
    local vram=$1
    if [[ -z "$vram" || ! "$vram" =~ ^[0-9] ]]; then
        echo "small"
        return
    fi

    local vram_int=${vram%.*}

    if [ "$vram_int" -ge 30 ]; then echo "32gb"
    elif [ "$vram_int" -ge 22 ]; then echo "24gb"
    elif [ "$vram_int" -ge 14 ]; then echo "16gb"
    elif [ "$vram_int" -ge 10 ]; then echo "12gb"
    else echo "small"; fi
}

# Анализ GPU
analyze_gpu() {
    log_info "Анализ GPU..." >&2

    nvidia-smi --query-gpu=index,name,memory.total,memory.free,memory.used --format=csv,noheader,nounits | \
    while IFS=',' read -r idx name total free used; do
        idx=$(echo "$idx" | xargs)
        name=$(echo "$name" | xargs)
        total=$(echo "$total" | xargs)
        free=$(echo "$free" | xargs)
        used=$(echo "$used" | xargs)

        used_percent=$(( (used * 100) / total ))
        total_gb=$(echo "scale=1; $total / 1024" | bc)
        free_gb=$(echo "scale=1; $free / 1024" | bc)

        if [ "$used_percent" -gt 85 ]; then
            log_warn "GPU $idx ($name): занято ${used_percent}%, пропускаем" >&2
            continue
        fi

        echo "$idx|$name|$total_gb|$free_gb"
    done
}

# Подбор модели
get_best_model_for_gpu() {
    local category=$1
    local free_gb=$2
    local total_gb=$3

    local available_models=$(ls -1 "$MODELS_DIR" 2>/dev/null || echo "")
    if [ -z "$available_models" ]; then echo "none|none|0|0|auto|0"; return; fi

    # Умный поиск: ищем Nemo (12B), если нет — Vikhr (8B), если нет — любую
    local model="none"
    if echo "$available_models" | grep -q "saiga_nemo_12b" && (( $(echo "$free_gb > 17.0" | bc -l) )); then
        model="saiga_nemo_12b"
    elif echo "$available_models" | grep -q "QVikhr-3-8B-Instruction"; then
        model="QVikhr-3-8B-Instruction"
    else
        model=$(echo "$available_models" | head -1)
    fi

    local params=$(echo "$model" | grep -oP '\d+(?=[Bb])' | head -1 || echo "8")
    local weight_size=$(echo "$params * 2.0 + 1.2" | bc)
    local kv_mem=$(echo "$free_gb - $weight_size" | bc)

    if (( $(echo "$kv_mem < 0.5" | bc -l) )); then echo "none|none|0|0|auto|0"; return; fi

    # Коэффициенты для расчета контекста
    local kv_dtype="auto"; local tokens_factor=64000
    if (( $(echo "$kv_mem < 4.0" | bc -l) )); then kv_dtype="fp8"; tokens_factor=128000; fi

    local calc_ctx=$(echo "($kv_mem * $tokens_factor) / $params" | bc | cut -d. -f1)

    local ctx=2048
    for pwr in 4096 8192 16384 32768; do
        if [ "$calc_ctx" -ge "$pwr" ]; then ctx=$pwr; else break; fi
    done

    # Сессии и лимит памяти
    local mseq=$(echo "$free_gb * 2" | bc | cut -d. -f1)
    [ "$mseq" -gt 64 ] && mseq=64
    local util=$(echo "scale=2; ($free_gb - 0.5) / $total_gb" | bc)
    [[ $util == .* ]] && util="0$util"

    echo "$model|none|$ctx|$util|$kv_dtype|$mseq"
}
# Выбор движка
choose_engine() {
    local model=$1
    
    # Проверяем установленные движки
    if [ -d "${HOME}/miniconda3/envs/vllm_env" ]; then
        echo "vllm"
    elif [ -d "${HOME}/miniconda3/envs/sglang_env" ]; then
        echo "sglang"
    elif [ -d "${HOME}/miniconda3/envs/lmdeploy_env" ]; then
        echo "lmdeploy"
    else
        log_error "Ни один движок не установлен!"
        exit 1
    fi
}

is_port_free() {
    local port=$1
    # Проверяем, слушает ли кто-то этот порт
    if netstat -tuln | grep -q ":$port "; then
        return 1 # Занят
    fi
    return 0 # Свободен
}

get_next_free_port() {
    local start_port=$1
    local port=$start_port
    while ! is_port_free "$port"; do
        while netstat -tuln | grep -q ":$port "; do
            port=$((port + 1))
        done
    done
    echo "$port"
}

# Создание плана
create_deployment_plan() {
    log_info "Создание плана развертывания..."
    
    local gpu_data=$(analyze_gpu)
    
    if [ -z "$gpu_data" ]; then
        log_error "Нет доступных GPU"
        exit 1
    fi
    
    local gpu_count=$(echo "$gpu_data" | wc -l)
    log_info "Доступно GPU: $gpu_count"
    
    # Создаем план в текстовом формате
    local port=8000
    > /tmp/deployment_plan.txt
    
    echo "$gpu_data" | while IFS='|' read -r gpu_id name total_gb free_gb; do
        log_info "  GPU $gpu_id: $name - ${free_gb}GB свободно из ${total_gb}GB"
        
        local category=$(classify_gpu "$total_gb")
        local model_config=$(get_best_model_for_gpu "$(classify_gpu "$total_gb")" "$free_gb" "$total_gb")

        IFS='|' read -r model quant ctx util kv_dtype max_seqs <<< "$model_config"

        if [ "$model" = "none" ]; then
            log_warn "Нет модели для GPU $gpu_id"
            continue
        fi
        
        local engine=$(choose_engine "$model")
        
        # Сохраняем в файл
        echo "$gpu_id|$name|$total_gb|$free_gb|$category|$model|$engine|$port|$quant|$ctx|$util|$kv_dtype|$max_seqs" >> /tmp/deployment_plan.txt
        
        port=$((port + 1))
    done
    
    if [ ! -s /tmp/deployment_plan.txt ]; then
        log_error "План пуст"
        exit 1
    fi
}

# Запуск модели
start_model() {
    local gpu_id=$1
    local model=$2
    local engine=$3
    local port=$4
    local quant=$5
    local ctx=$6
    local util=$7
    local kv_dtype=$8
    local max_seqs=$9

    local model_path="${MODELS_DIR}/${model}"
    local log_file="${HOME}/llm_engines/${engine}_gpu${gpu_id}.log"
    local pid_file="${HOME}/llm_engines/${engine}_gpu${gpu_id}.pid"
    
    mkdir -p "${HOME}/llm_engines"
    
    log_info "GPU $gpu_id: Запуск $model ($engine) на порту $port..."
    
    case "$engine" in
        "vllm")
            local auto_batch=$(( ctx / 4 ))
            if [ "$auto_batch" -lt 2048 ]; then auto_batch=2048; fi
            if [ "$auto_batch" -gt 8192 ]; then auto_batch=8192; fi

            log_info "GPU $gpu_id: Динамический старт: $model"
            log_info "  → VRAM: $util, Ctx: $ctx, KV: $kv_dtype, Seqs: $max_seqs"

            CUDA_VISIBLE_DEVICES=$gpu_id bash -c "
                source ${HOME}/miniconda3/bin/activate vllm_env
                python -m vllm.entrypoints.openai.api_server \
                    --model ${MODELS_DIR}/${model} \
                    --port ${port} \
                    --max-model-len ${ctx} \
                    --max-num-batched-tokens ${auto_batch} \
                    --max-num-seqs ${max_seqs} \
                    --gpu-memory-utilization ${util} \
                    --kv-cache-dtype ${kv_dtype} \
                    --enable-chunked-prefill \
                    --trust-remote-code \
                    --dtype auto \
                    --enforce-eager \
                    --disable-log-requests \
                    > ${log_file} 2>&1 &
                echo \$! > ${pid_file}
            "
            ;;
        "sglang")
            log_info "GPU $gpu_id: Старт SGLang -> $model (Ctx: $ctx, Util: $util)"
            CUDA_VISIBLE_DEVICES=$gpu_id bash -c "
                source ${HOME}/miniconda3/bin/activate sglang_env
                python -m sglang.launch_server \
                    --model-path ${MODELS_DIR}/${model} \
                    --port ${port} \
                    --context-length ${ctx} \
                    --mem-fraction-static ${util} \
                    --kv-cache-dtype ${kv_dtype} \
                    --max-running-requests ${max_seqs} \
                    --trust-remote-code \
                    > ${log_file} 2>&1 &
                echo \$! > ${pid_file}
            "
            ;;
        "lmdeploy")
            log_info "GPU $gpu_id: Старт LMDeploy -> $model (Util: $util)"
            CUDA_VISIBLE_DEVICES=$gpu_id bash -c "
                source ${HOME}/miniconda3/bin/activate lmdeploy_env
                lmdeploy serve api_server ${MODELS_DIR}/${model} \
                    --server-port ${port} \
                    --cache-max-entry-count ${util} \
                    --model-name ${model} \
                    --trust-remote-code \
                    > ${log_file} 2>&1 &
                echo \$! > ${pid_file}
            "
            ;;
    esac
    
    sleep 2
}

# Развертывание
deploy_all() {
    create_deployment_plan
    
    if [ ! -s /tmp/deployment_plan.txt ]; then
        log_error "План пуст"
        exit 1
    fi
    
    # Показываем план
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "              ПЛАН РАЗВЕРТЫВАНИЯ"
    echo "═══════════════════════════════════════════════════════"
    

    while IFS='|' read -r gpu_id name total_gb free_gb category model engine port quant ctx util kv_dtype max_seqs; do
        echo ""
        echo "GPU $gpu_id ($category - ${total_gb}GB): $name"
        echo "  Модель:  $model"
        echo "  Движок:  $engine"
        echo "  Порт:    $port"
        echo "  Квант:   $quant, Context: $ctx, Util: $util"
    done < /tmp/deployment_plan.txt

    echo ""
    echo "═══════════════════════════════════════════════════════"
    
    # Подтверждение
    if [ "${AUTO_DEPLOY:-false}" != "true" ]; then
        echo ""
        read -p "Начать развертывание? (y/N): " confirm
        if [ "$confirm" != "y" ]; then
            exit 0
        fi
    fi
    
    # Запускаем
    log_info "Запуск моделей..."
    
    while IFS='|' read -r gpu_id name total_gb free_gb category model engine port quant ctx util kv_dtype max_seqs; do
        start_model "$gpu_id" "$model" "$engine" "$port" "$quant" "$ctx" "$util" "$kv_dtype" "$max_seqs"
    done < /tmp/deployment_plan.txt
    
    # Сохраняем состояние
    cp /tmp/deployment_plan.txt "$DEPLOY_STATE"

    # Создаем чистый JSON для Healthcheck
    local json_file="${HOME}/llm_engines/deploy_state.json"
    echo "{\"deployments\": [" > "$json_file"
    local first=true
    while IFS='|' read -r gid name tot free cat mod eng prt qnt ctx utl kv mseq; do
        if [ "$first" = false ]; then echo "," >> "$json_file"; fi
        echo "{\"gpu_id\": $gid, \"model\": \"$mod\", \"engine\": \"$eng\", \"port\": $prt, \"quantization\": \"$qnt\", \"max_context\": $ctx, \"gpu_memory_utilization\": $utl, \"kv_cache_dtype\": \"$kv\", \"max_num_seqs\": $mseq}" >> "$json_file"
        first=false
    done < "$DEPLOY_STATE"
    echo "]}" >> "$json_file"

    log_info "Развертывание завершено!"
        echo ""
        echo "Статус: ./scripts/auto_deploy.sh --status"
    }

# Статус
show_status() {
    if [ ! -f "$DEPLOY_STATE" ]; then
        log_warn "Нет активного deployment"
        return
    fi
    
    echo "═══════════════════════════════════════════════════════"
    echo "              СТАТУС МОДЕЛЕЙ"
    echo "═══════════════════════════════════════════════════════"
    
    while IFS='|' read -r gpu_id name total_gb free_gb category model engine port quant ctx util kv_dtype; do
        local pid_file="${HOME}/llm_engines/${engine}_gpu${gpu_id}.pid"
        
        echo ""
        echo "GPU $gpu_id: $model ($engine) - порт $port"
        
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file")
            if kill -0 "$pid" 2>/dev/null; then
                if curl -s --max-time 5 "http://localhost:$port/health" > /dev/null 2>&1 || \
                   curl -s --max-time 5 "http://localhost:$port/v1/models" > /dev/null 2>&1; then
                    echo "  Статус: ✅ Работает (PID: $pid)"
                else
                    echo "  Статус: ⚠️  Загружается... (PID: $pid)"
                fi
            else
                echo "  Статус: ❌ Упал"
            fi
        else
            echo "  Статус: ❌ Не запущен"
        fi
    done < "$DEPLOY_STATE"
    
    echo ""
    echo "═══════════════════════════════════════════════════════"
}

# Остановка
stop_all() {
    if [ ! -f "$DEPLOY_STATE" ]; then
        log_warn "Нет активного deployment"
        return
    fi
    
    log_info "Остановка всех моделей..."
    
    while IFS='|' read -r gpu_id name total_gb free_gb category model engine port quant ctx util kv_dtype; do
        local pid_file="${HOME}/llm_engines/${engine}_gpu${gpu_id}.pid"
        
        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file")
            if kill -0 "$pid" 2>/dev/null; then
                log_info "Остановка $engine на GPU $gpu_id"
                kill "$pid" 2>/dev/null || true
                sleep 2
                kill -9 "$pid" 2>/dev/null || true
            fi
            rm "$pid_file"
        fi
    done < "$DEPLOY_STATE"
    
    log_info "Готово"
}

# Main
case "${1:-deploy}" in
    deploy|--deploy|start) deploy_all ;;
    --status|status) show_status ;;
    --stop|stop) stop_all ;;
    --auto) AUTO_DEPLOY=true; deploy_all ;;
    *) echo "Команды: deploy, --status, --stop, --auto"; exit 1 ;;
esac
