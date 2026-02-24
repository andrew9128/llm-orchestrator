#!/usr/bin/env bash
set -euo pipefail

# Проверка зависимостей
for cmd in bc jq curl nvidia-smi; do
    if ! command -v $cmd &> /dev/null; then
        echo "Требуется: $cmd (sudo apt install $cmd)" >&2
        exit 1
    fi
done

MODELS_DIR="${HOME}/llm_models"
DEPLOY_STATE="${HOME}/llm_engines/deploy_state.txt"

ENGINE_TYPE="${ENGINE_TYPE:-auto}"   # auto, vllm, sglang, lmdeploy
AUTO_DEPLOY="${AUTO_DEPLOY:-false}"

log_info()  { echo -e "\033[0;32m[INFO]\033[0m $*"; }
log_warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*"; }

# ============================================================================
# КЛАССИФИКАЦИЯ GPU
# ============================================================================
# Возвращает сценарий на основе TOTAL VRAM (не свободной — это категория железа).
# Свободная память влияет только на расчёт параметров запуска.

classify_gpu() {
    local total_gb_raw=$1
    local total_int=${total_gb_raw%.*}

    if   [ "$total_int" -ge 30 ]; then echo "32gb"
    elif [ "$total_int" -ge 22 ]; then echo "24gb"
    elif [ "$total_int" -ge 14 ]; then echo "16gb"
    elif [ "$total_int" -ge 10 ]; then echo "12gb"
    else echo "small"; fi
}

# ============================================================================
# АНАЛИЗ GPU
# ============================================================================

analyze_gpu() {
    log_info "Анализ GPU..." >&2

    nvidia-smi --query-gpu=index,name,memory.total,memory.free,memory.used \
               --format=csv,noheader,nounits | \
    while IFS=',' read -r idx name total free used; do
        idx=$(echo "$idx"   | xargs)
        name=$(echo "$name" | xargs)
        total=$(echo "$total" | xargs)
        free=$(echo "$free"   | xargs)
        used=$(echo "$used"   | xargs)

        local used_pct=$(( (used * 100) / total ))
        local total_gb=$(echo "scale=1; $total / 1024" | bc)
        local free_gb=$(echo  "scale=1; $free  / 1024" | bc)

        # Пропускаем перегруженные GPU (>85% занято)
        if [ "$used_pct" -gt 85 ]; then
            log_warn "GPU $idx ($name): занято ${used_pct}%, пропускаем" >&2
            continue
        fi

        # Минимум 6 GB свободно
        if [ "$(echo "$free_gb < 6" | bc)" -eq 1 ]; then
            log_warn "GPU $idx ($name): мало памяти (${free_gb}GB < 6GB), пропускаем" >&2
            continue
        fi

        echo "$idx|$name|$total_gb|$free_gb"
    done
}

# ============================================================================
# ВЫБОР МОДЕЛИ ПО СЦЕНАРИЮ
# ============================================================================
# Приоритеты русскоговорящих моделей для каждого сетапа.
# Возвращает: model|params_b

get_best_model() {
    local category=$1
    local available
    available=$(ls -1 "$MODELS_DIR" 2>/dev/null || true)

    if [ -z "$available" ]; then echo "none|0"; return; fi

    # Функция поиска первой совпадающей модели
    find_model() {
        local patterns=("$@")
        for pat in "${patterns[@]}"; do
            local found
            found=$(echo "$available" | grep -i "$pat" | head -1 || true)
            if [ -n "$found" ]; then echo "$found"; return; fi
        done
        echo ""
    }

    local model=""
    local params=8

    case "$category" in
        "12gb")
            # Сетап 1: 12GB (5070) → 4B или 7B русские модели
            # Vikhr-4B — первый приоритет, потом 7B если влезает
            model=$(find_model \
                "QVikhr-3-4B" "Vikhr.*4[Bb]" \
                "saiga.*7b" "Vikhr.*7[Bb]" \
                "saiga_mistral_7b" "saiga_llama.*7b")
            [ -z "$model" ] && model=$(echo "$available" | head -1)
            # Определяем размер
            params=$(echo "$model" | grep -oiP '\d+(?=[Bb])' | head -1 || echo "4")
            ;;

        "16gb")
            # Сетап 2: 16GB → 8B русские модели (Vikhr-8B, Saiga-8B)
            model=$(find_model \
                "QVikhr-3-8B" "Vikhr.*8[Bb]" \
                "saiga.*8b" "saiga_llama3_8b" \
                "saiga_llama.*8b")
            # Fallback на 7B если нет 8B
            [ -z "$model" ] && model=$(find_model \
                "saiga.*7b" "saiga_mistral_7b" "Vikhr.*7[Bb]")
            [ -z "$model" ] && model=$(echo "$available" | head -1)
            params=$(echo "$model" | grep -oiP '\d+(?=[Bb])' | head -1 || echo "8")
            ;;

        "24gb")
            # Сетап 3: 24GB (A5000/Titan) → 12B модели, Saiga-Nemo приоритет
            model=$(find_model \
                "saiga_nemo_12b" "saiga.*nemo.*12" \
                "saiga_gemma3_12b" "saiga.*12b" \
                "Vikhr.*12[Bb]")
            # Fallback на 8B
            [ -z "$model" ] && model=$(find_model \
                "QVikhr-3-8B" "saiga_llama3_8b" "saiga.*8b")
            [ -z "$model" ] && model=$(echo "$available" | head -1)
            params=$(echo "$model" | grep -oiP '\d+(?=[Bb])' | head -1 || echo "12")
            ;;

        "32gb")
            # Сетап 4: 32GB+ → тяжелые веса / большой контекст
            # Приоритет на самую крупную русскую модель
            model=$(find_model \
                "saiga_nemo_12b" "saiga.*nemo" \
                "saiga_gemma3_12b" "saiga.*12b" \
                "Vikhr.*12[Bb]" \
                "QVikhr-3-8B" "saiga.*8b")
            [ -z "$model" ] && model=$(echo "$available" | head -1)
            params=$(echo "$model" | grep -oiP '\d+(?=[Bb])' | head -1 || echo "12")
            ;;

        *)
            echo "none|0"; return ;;
    esac

    if [ -z "$model" ]; then echo "none|0"; return; fi
    echo "$model|$params"
}

# ============================================================================
# РАСЧЁТ ПАРАМЕТРОВ ЗАПУСКА
# ============================================================================
# Вся математика сосредоточена здесь.
#
# Ключевые формулы:
#   weight_gb  = params_b * bytes_per_param
#   bytes_per_param: fp16=2, fp8=1, int4=0.5
#   kv_available = free_gb - weight_gb_loaded - overhead_gb
#   util = (free_gb - safety_gb) / total_gb
#
# Возвращает: quant|ctx|util|kv_dtype|max_seqs

calc_launch_params() {
    local category=$1
    local params=$2       # размер модели в B (4, 7, 8, 12, ...)
    local free_gb=$3      # реально свободно прямо сейчас
    local total_gb=$4

    # ── 1. Выбираем квантизацию и считаем вес модели ──────────────────────
    local quant="none"
    local bytes_per_param="2.0"   # fp16 по умолчанию

    case "$category" in
        "12gb")
            # 12GB: 4B-fp16=8GB, 7B-fp16=14GB (не влезет) → 7B нужен fp8
            if [ "$params" -ge 7 ]; then
                quant="fp8"; bytes_per_param="1.0"
            else
                quant="none"; bytes_per_param="2.0"
            fi
            ;;
        "16gb")
            # 16GB: 8B-fp16=16GB (встык!) → fp8 обязательно → 8GB
            quant="fp8"; bytes_per_param="1.0"
            ;;
        "24gb")
            quant="fp8"
            bytes_per_param="1.0"
            ;;
        "32gb")
            # 32GB: 12B-fp16=24GB — влезает без квантизации
            if [ "$params" -ge 30 ]; then
                quant="fp8"; bytes_per_param="1.0"
            else
                quant="none"; bytes_per_param="2.0"
            fi
            ;;
    esac

    # ── 2. Вес модели после загрузки ──────────────────────────────────────
    case "$quant" in
        "none"|"fp16"|"bf16")   bytes_per_param=2.0 ;;
        "fp8"|"fp8_e4m3"|"fp8_e5m2") bytes_per_param=1.0 ;;
        "int8"|"awq")           bytes_per_param=1.0 ;;
        "int4"|"gptq")          bytes_per_param=0.5 ;;
        *)                      bytes_per_param=2.0 ;;
    esac

    local weight_gb
    weight_gb=$(echo "scale=2; $params * $bytes_per_param + 0.5" | bc)   # +0.5 ГБ небольшой запас

    # ── 3. Overhead: CUDA context + Python runtime + буферы активаций ─────
    local overhead_gb
    if [ "$params" -le 9 ]; then
        overhead_gb=1.2
    else
        overhead_gb=1.8
    fi
    # ── 4. Реально доступно для KV-cache ──────────────────────────────────
    local kv_budget
    kv_budget=$(echo "scale=2; $free_gb - $weight_gb - $overhead_gb" | bc)

    log_info "  Расчёт памяти: free=${free_gb}GB, weights=${weight_gb}GB (${quant}), overhead=${overhead_gb}GB → KV budget=${kv_budget}GB" >&2

    if [ "$(echo "$kv_budget < 0.5" | bc)" -eq 1 ]; then
        log_warn "  Недостаточно памяти для KV-cache (${kv_budget}GB < 0.5GB)" >&2
        echo "none|0|0|auto|0"; return
    fi

    # ── 5. Тип KV-cache ───────────────────────────────────────────────────
    # fp8 KV экономит ~2x памяти, включаем если KV budget < 3GB
    local kv_dtype="auto"
    if [ "$(echo "$kv_budget < 2.5" | bc)" -eq 1 ]; then
        kv_dtype="fp8_e5m2"
        log_info " KV budget мал (${kv_budget}GB) → kv_dtype=fp8_e5m2" >&2
    fi
    # ── 6. Контекст ───────────────────────────────────────────────────────
    # Оцениваем max_ctx из KV budget:
    # KV per token ≈ 2 * n_layers * n_heads * head_dim * 2 bytes (fp16)
    # Для 8B Qwen/Llama-style: ~0.5MB/token (fp16), ~0.25MB/token (fp8)
    # Упрощённая формула: ctx = kv_budget_MB / mb_per_token
    #   fp16: ~0.50 MB/tok для 8B, ~0.75 для 12B
    #   fp8:  ~0.25 MB/tok для 8B, ~0.375 для 12B
    local mb_per_token
    if [ "$kv_dtype" = "fp8_e5m2" ]; then
        mb_per_token=$(echo "scale=4; $params * 0.018" | bc)   # ≈0.144 MB/tok для 8B fp8 — реалистично
    else
        mb_per_token=$(echo "scale=4; $params * 0.040" | bc)   # ≈0.32 MB/tok для fp16
    fi

    local kv_budget_mb
    kv_budget_mb=$(echo "scale=0; $kv_budget * 1024" | bc | cut -d. -f1)

    local max_ctx_calc
    max_ctx_calc=$(echo "scale=0; ($kv_budget_mb / $mb_per_token) * 1.6" | bc | cut -d. -f1 2>/dev/null || echo "4096")

    max_ctx_calc=${max_ctx_calc%%.*}

    # Округляем до ближайшей степени 2 (не выше 32768)
    local ctx=4096
    for c in 4096 8192 16384 32768; do
        [ "$max_ctx_calc" -ge "$c" ] && ctx=$c
    done

    # Ограничения по сценарию
    case "$category" in
        "12gb") [ "$ctx" -gt  8192 ] && ctx=8192  ;;
        "16gb") [ "$ctx" -gt 16384 ] && ctx=16384 ;;
        "24gb") [ "$ctx" -gt 16384 ] && ctx=16384 ;;
        "32gb") [ "$ctx" -gt 32768 ] && ctx=32768 ;;
    esac

    log_info "  Расчётный контекст: max_ctx_calc=${max_ctx_calc} → ctx=${ctx}" >&2

    # ── 7. gpu_memory_utilization (util) ──────────────────────────────────
    # util = сколько от TOTAL GPU памяти отдать движку.
    # Формула: (free_gb - safety_reserve) / total_gb
    # safety_reserve: буфер чтобы не словить OOM при пиковых нагрузках
    local safety_gb="1.5"
    local util
    util=$(echo "scale=2; ($free_gb - $safety_gb) / $total_gb" | bc)

    # Добавляем 0 если начинается с точки
    [[ $util == .* ]] && util="0${util}"

    # Зажимаем в разумные пределы [0.50 … 0.92]
    if [ "$(echo "$util < 0.50" | bc)" -eq 1 ]; then util="0.50"; fi
    if [ "$(echo "$util > 0.92" | bc)" -eq 1 ]; then util="0.92"; fi

    log_info "  gpu_memory_utilization = (${free_gb} - ${safety_gb}) / ${total_gb} = ${util}" >&2

    # ── 8. Параллельные запросы ───────────────────────────────────────────
    # Исходим из KV budget: каждый запрос резервирует ~ctx/2 токенов
    # max_seqs ≈ kv_budget_mb / (ctx/2 * mb_per_token)
    local half_ctx=$(( ctx / 2 ))
    local max_seqs
    max_seqs=$(echo "scale=0; $kv_budget_mb / ($half_ctx * $mb_per_token)" | bc 2>/dev/null | cut -d. -f1 || echo "8")
    [ -z "$max_seqs" ] || [ "$max_seqs" -lt 4  ] && max_seqs=4
    [ "$max_seqs" -gt 128 ] && max_seqs=128

    echo "$quant|$ctx|$util|$kv_dtype|$max_seqs"
}

# ============================================================================
# ВЫБОР ДВИЖКА
# ============================================================================

choose_engine() {
    local preferred="${ENGINE_TYPE}"

    if [ "$preferred" = "auto" ]; then
        # Приоритет: vllm → sglang → lmdeploy
        if   [ -d "${HOME}/miniconda3/envs/vllm_env"     ]; then echo "vllm"
        elif [ -d "${HOME}/miniconda3/envs/sglang_env"   ]; then echo "sglang"
        elif [ -d "${HOME}/miniconda3/envs/lmdeploy_env" ]; then echo "lmdeploy"
        else
            log_error "Ни один движок не установлен!" >&2
            exit 1
        fi
    else
        if [ -d "${HOME}/miniconda3/envs/${preferred}_env" ]; then
            echo "$preferred"
        else
            log_error "Движок $preferred не установлен!" >&2
            log_info  "Установите: ./scripts/bootstrap_llm.sh --${preferred}" >&2
            exit 1
        fi
    fi
}

# ============================================================================
# СОЗДАНИЕ ПЛАНА РАЗВЕРТЫВАНИЯ
# ============================================================================

create_deployment_plan() {
    log_info "Создание плана развертывания..."

    local gpu_data
    gpu_data=$(analyze_gpu)

    if [ -z "$gpu_data" ]; then
        log_error "Нет доступных GPU"
        exit 1
    fi

    local gpu_count
    gpu_count=$(echo "$gpu_data" | wc -l)
    log_info "Доступно GPU: $gpu_count"

    local port=8000
    > /tmp/deployment_plan.txt

    while IFS='|' read -r gpu_id name total_gb free_gb; do
        log_info "  GPU $gpu_id: $name — ${free_gb}GB свободно из ${total_gb}GB"

        local category
        category=$(classify_gpu "$total_gb")

        local model_info
        model_info=$(get_best_model "$category")
        local model params
        model=$(echo  "$model_info" | cut -d'|' -f1)
        params=$(echo "$model_info" | cut -d'|' -f2)

        if [ "$model" = "none" ]; then
            log_warn "Нет подходящей модели для GPU $gpu_id (категория: $category)"
            continue
        fi

        log_info "  Выбрана модель: $model (${params}B, категория: $category)"

        local launch_params
        launch_params=$(calc_launch_params "$category" "$params" "$free_gb" "$total_gb")
        local quant ctx util kv_dtype max_seqs
        quant=$(    echo "$launch_params" | cut -d'|' -f1)
        ctx=$(      echo "$launch_params" | cut -d'|' -f2)
        util=$(     echo "$launch_params" | cut -d'|' -f3)
        kv_dtype=$( echo "$launch_params" | cut -d'|' -f4)
        max_seqs=$( echo "$launch_params" | cut -d'|' -f5)

        if [ "$quant" = "none" ] && [ "$ctx" = "0" ]; then
            log_warn "Не хватает памяти для запуска модели на GPU $gpu_id"
            continue
        fi

        local engine
        engine=$(choose_engine)

        # SGLang использует mem_fraction_static вместо util,
        # поэтому для него дополнительно снижаем на 0.05 (его overhead выше)
        local sgl_util="$util"

        if [ "$engine" = "sglang" ]; then
            sgl_util=$(echo "scale=2; $util + 0.12" | bc)   # +0.12 для SGLang, чтобы дать больше памяти
            [[ $sgl_util == .* ]] && sgl_util="0${sgl_util}"
            [ "$(echo "$sgl_util > 0.92" | bc)" -eq 1 ] && sgl_util="0.92"
            [ "$(echo "$sgl_util < 0.80" | bc)" -eq 1 ] && sgl_util="0.80"
        fi

        # Проверка что порт свободен
        while netstat -tuln 2>/dev/null | grep -q ":$port "; do
            port=$((port + 1))
        done

        echo "$gpu_id|$name|$total_gb|$free_gb|$category|$model|$params|$engine|$port|$quant|$ctx|$util|$sgl_util|$kv_dtype|$max_seqs" \
            >> /tmp/deployment_plan.txt

        port=$((port + 1))
    done <<< "$gpu_data"

    if [ ! -s /tmp/deployment_plan.txt ]; then
        log_error "План развертывания пуст — нет подходящих GPU или моделей"
        exit 1
    fi
}

# ============================================================================
# ЗАПУСК МОДЕЛИ
# ============================================================================

start_model() {
    local gpu_id=$1 model=$2 engine=$3 port=$4 quant=$5
    local ctx=$6 util=$7 sgl_util=$8 kv_dtype=$9 max_seqs=${10}

    local model_path="${MODELS_DIR}/${model}"
    local log_file="${HOME}/llm_engines/${engine}_gpu${gpu_id}.log"
    local pid_file="${HOME}/llm_engines/${engine}_gpu${gpu_id}.pid"

    mkdir -p "${HOME}/llm_engines"

    log_info "GPU $gpu_id: Запуск $model ($engine)"
    log_info "  → Порт: $port | ctx: $ctx | util: $util | kv: $kv_dtype | seqs: $max_seqs | quant: $quant"

    case "$engine" in
        "vllm")
            local batch_tokens=$(( ctx / 2 ))
            [ "$batch_tokens" -lt 2048  ] && batch_tokens=2048
            [ "$batch_tokens" -gt 16384 ] && batch_tokens=16384

            # Строим флаг квантизации
            local quant_flag=""

            CUDA_VISIBLE_DEVICES=$gpu_id bash -c "
                source '${HOME}/miniconda3/bin/activate' vllm_env
                python -m vllm.entrypoints.openai.api_server \
                    --model '${model_path}' \
                    --port ${port} \
                    --max-model-len ${ctx} \
                    --max-num-batched-tokens ${batch_tokens} \
                    --max-num-seqs ${max_seqs} \
                    --mem-fraction-static ${sgl_util}
                    --kv-cache-dtype ${kv_dtype} \
                    ${quant_flag} \
                    --enable-chunked-prefill \
                    --trust-remote-code \
                    --dtype auto \
                    > '${log_file}' 2>&1 &
                echo \$! > '${pid_file}'
            "
            ;;
        "sglang")
            local sgl_kv="$kv_dtype"
            if [ "$sgl_kv" = "auto" ]; then
                sgl_kv="bf16"  # bf16 — безопасно
            fi
            CUDA_VISIBLE_DEVICES=$gpu_id bash -c "
                source '${HOME}/miniconda3/bin/activate' sglang_env
                export SGLANG_DISABLE_JIT=1
                export TVM_DISABLE_JIT=1
                python -m sglang.launch_server \
                    --model-path '${model_path}' \
                    --port ${port} \
                    --context-length ${ctx} \
                    --mem-fraction-static ${sgl_util} \
                    --kv-cache-dtype ${sgl_kv} \
                    --max-running-requests ${max_seqs} \
                    --chunked-prefill-size 2048 \
                    --disable-cuda-graph \
                    --attention-backend torch_native \
                    --prefill-attention-backend torch_native \
                    --decode-attention-backend torch_native \
                    --sampling-backend pytorch \
                    --disable-radix-cache \
                    --trust-remote-code \
                    > '${log_file}' 2>&1 &
                echo \$! > '${pid_file}'
            "
            ;;
        "lmdeploy")
            CUDA_VISIBLE_DEVICES=$gpu_id bash -c "
                source '${HOME}/miniconda3/bin/activate' lmdeploy_env
                lmdeploy serve api_server '${model_path}' \
                    --server-port ${port} \
                    --tp 1 \
                    --cache-max-entry-count ${util} \
                    --trust-remote-code \
                    > '${log_file}' 2>&1 &
                echo \$! > '${pid_file}'
            "
            ;;
    esac

    sleep 3
}

# ============================================================================
# ОТОБРАЖЕНИЕ ПЛАНА
# ============================================================================

print_plan() {
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "          ПЛАН РАЗВЕРТЫВАНИЯ (Engine: $ENGINE_TYPE)"
    echo "═══════════════════════════════════════════════════════"

    while IFS='|' read -r gpu_id name total_gb free_gb category model params engine port quant ctx util sgl_util kv_dtype max_seqs; do
        echo ""
        echo "GPU $gpu_id ($category — ${total_gb}GB): $name"
        echo "  Свободно: ${free_gb}GB"
        echo "  Модель:   $model (${params}B)"
        echo "  Движок:   $engine"
        echo "  Порт:     $port"
        echo "  Quant:    $quant"
        echo "  Context:  $ctx tokens"
        echo "  Util:     $util (sglang: $sgl_util)"
        echo "  KV dtype: $kv_dtype"
        echo "  Max seqs: $max_seqs"
    done < /tmp/deployment_plan.txt

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo ""
}

# ============================================================================
# РАЗВЕРТЫВАНИЕ
# ============================================================================

deploy_all() {
    create_deployment_plan
    print_plan

    if [ "$AUTO_DEPLOY" != "true" ]; then
        read -r -p "Начать развертывание? (y/N): " confirm
        [ "$confirm" != "y" ] && exit 0
    fi

    log_info "Запуск моделей..."

    while IFS='|' read -r gpu_id name total_gb free_gb category model params engine port quant ctx util sgl_util kv_dtype max_seqs; do
        start_model "$gpu_id" "$model" "$engine" "$port" "$quant" "$ctx" "$util" "$sgl_util" "$kv_dtype" "$max_seqs"
    done < /tmp/deployment_plan.txt

    cp /tmp/deployment_plan.txt "$DEPLOY_STATE"

    # JSON-стейт для healthcheck
    {
        echo '{"deployments":['
        local first=true
        while IFS='|' read -r gpu_id name total_gb free_gb category model params engine port quant ctx util sgl_util kv_dtype max_seqs; do
            [ "$first" = "false" ] && echo ","
            jq -n \
                --argjson gi  "$gpu_id" \
                --arg     m   "$model" \
                --arg     e   "$engine" \
                --argjson p   "$port" \
                --arg     q   "$quant" \
                --argjson c   "$ctx" \
                --arg     u   "$util" \
                --arg     k   "$kv_dtype" \
                --argjson ms  "$max_seqs" \
                '{gpu_id:$gi, model:$m, engine:$e, port:$p,
                  quantization:$q, max_context:$c,
                  gpu_memory_utilization:$u, kv_cache_dtype:$k, max_num_seqs:$ms}'
            first=false
        done < "$DEPLOY_STATE"
        echo ']}'
    } > "${HOME}/llm_engines/deploy_state.json"

    log_info "Развертывание завершено!"
    echo ""
    echo "Проверка статуса: ./scripts/auto_deploy.sh --status"
    echo "Остановка:        ./scripts/auto_deploy.sh --stop"
}

# ============================================================================
# СТАТУС
# ============================================================================

show_status() {
    if [ ! -f "$DEPLOY_STATE" ]; then
        log_warn "Нет активного deployment"; return
    fi

    echo "═══════════════════════════════════════════════════════"
    echo "                   СТАТУС МОДЕЛЕЙ"
    echo "═══════════════════════════════════════════════════════"

    while IFS='|' read -r gpu_id name total_gb free_gb category model params engine port quant ctx util sgl_util kv_dtype max_seqs; do
        local pid_file="${HOME}/llm_engines/${engine}_gpu${gpu_id}.pid"
        echo ""
        echo "GPU $gpu_id: $model ($engine) → http://localhost:$port"

        if [ -f "$pid_file" ]; then
            local pid
            pid=$(cat "$pid_file")
            if kill -0 "$pid" 2>/dev/null; then
                if timeout 5 curl -s "http://localhost:$port/health" > /dev/null 2>&1 || \
                   timeout 5 curl -s "http://localhost:$port/v1/models" > /dev/null 2>&1; then
                    echo "  Статус: ✅ Работает (PID: $pid)"
                else
                    echo "  Статус: ⚠️  Загружается... (PID: $pid)"
                    echo "  Логи:   tail -f ~/llm_engines/${engine}_gpu${gpu_id}.log"
                fi
            else
                echo "  Статус: ❌ Упал (см. логи)"
                echo "  Логи:   tail -100 ~/llm_engines/${engine}_gpu${gpu_id}.log"
            fi
        else
            echo "  Статус: ❌ Не запущен"
        fi
    done < "$DEPLOY_STATE"

    echo ""
    echo "═══════════════════════════════════════════════════════"
}

# ============================================================================
# ОСТАНОВКА
# ============================================================================

stop_all() {
    log_info "Остановка всех моделей..."

    for pidfile in "${HOME}/llm_engines"/*.pid; do
        [ -f "$pidfile" ] || continue
        local pid
        pid=$(cat "$pidfile" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log_info "Остановка PID $pid"
            kill -15 "$pid" 2>/dev/null || true
            sleep 2
            kill -9  "$pid" 2>/dev/null || true
        fi
        rm -f "$pidfile"
    done

    pkill -9 -f "vllm.entrypoints.openai.api_server" 2>/dev/null || true
    pkill -9 -f "sglang.launch_server"               2>/dev/null || true
    pkill -9 -f "lmdeploy serve"                     2>/dev/null || true

    local leftover
    leftover=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | grep -v "^$" || true)
    if [ -n "$leftover" ]; then
        log_warn "На GPU остались процессы (возможно от другого пользователя):"
        nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null || true
    fi

    log_info "Остановка завершена"
}

# ============================================================================
# СПРАВКА
# ============================================================================

show_help() {
cat << 'HELP'
LLM Auto-Deploy — автоматическое развертывание русских LLM

Использование:
    ./scripts/auto_deploy.sh [COMMAND]

Команды:
    deploy / --auto     Автоматическое развертывание (по умолчанию)
    --status            Статус всех моделей
    --stop              Остановить все модели
    --help              Показать справку

Переменные окружения:
    ENGINE_TYPE=auto|vllm|sglang|lmdeploy   (default: auto)
    AUTO_DEPLOY=true|false                   (default: false)

Примеры:
    ./scripts/auto_deploy.sh --auto
    ENGINE_TYPE=sglang ./scripts/auto_deploy.sh --auto
    ENGINE_TYPE=vllm   AUTO_DEPLOY=true ./scripts/auto_deploy.sh --auto
    ./scripts/auto_deploy.sh --status
    ./scripts/auto_deploy.sh --stop

Сценарии и модели (по приоритету):
    Сетап 1 — 12GB (5070):
        Модели:  QVikhr-3-4B-Instruction → saiga_*7b
        Params:  ctx=4-8k, quant=none(4B)/fp8(7B), kv=fp8_e5m2

    Сетап 2 — 16GB (A4000 и др.):
        Модели:  QVikhr-3-8B-Instruction → saiga_llama3_8b
        Params:  ctx=8-16k, quant=fp8, kv=fp8_e5m2

    Сетап 3 — 24GB (A5000 / Titan):
        Модели:  saiga_nemo_12b → saiga_gemma3_12b → saiga_*8b
        Params:  ctx=16k, quant=fp8, kv=auto

    Сетап 4 — 32GB+ (A6000 / 2×GPU):
        Модели:  saiga_nemo_12b → saiga_gemma3_12b
        Params:  ctx=32k, quant=none, kv=auto

Движки (ENGINE_TYPE):
    auto    — vllm (приоритет) → sglang → lmdeploy
    vllm    — стабильный, хорошо считает util
    sglang  — быстрее на throughput, mem_fraction_static на 5% ниже util
    lmdeploy— хорош для TP (multi-GPU)

HELP
}

# ============================================================================
# MAIN
# ============================================================================

case "${1:-deploy}" in
    deploy|--deploy|start|--auto)
        AUTO_DEPLOY=true
        deploy_all
        ;;
    --status|status) show_status  ;;
    --stop|stop)     stop_all     ;;
    --help|-h|help)  show_help    ;;
    *)
        log_error "Неизвестная команда: $1"
        show_help
        exit 1
        ;;
esac
