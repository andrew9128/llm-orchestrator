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
    local category="${1:-}"
    local available=$(ls -1 "$MODELS_DIR" 2>/dev/null || true)
    if [ -z "$available" ]; then echo "none|0"; return; fi

    local model=""
    local params=8

    case "$category" in
        "12gb") # Setup 1 (5070)
            model=$(echo "$available" | grep -E "QVikhr-3-4B|saiga_mistral_7b" | head -1)
            params=4 ;;
        "16gb") # Setup 2 (A4000)
            model=$(echo "$available" | grep -E "QVikhr-3-8B|saiga_llama3_8b" | head -1)
            params=8 ;;
        "24gb") # Setup 3 (A5000/Titan)
            model=$(echo "$available" | grep "saiga_nemo_12b" | head -1)
            [ -z "$model" ] && model=$(echo "$available" | grep "QVikhr-3-8B" | head -1)
            params=12 ;;
        "32gb") # Setup 4 (A6000)
            model=$(echo "$available" | grep -E "saiga_gemma3_27b|saiga_nemo_12b" | head -1)
            params=27 ;;
    esac
    [ -z "$model" ] && model=$(echo "$available" | head -1)
    echo "$model|$params"
}

is_port_free() {
    local port=$1
    python3 -c "import socket; s = socket.socket(socket.socket.AF_INET, socket.SOCK_STREAM); exit(s.connect_ex(('127.0.0.1', $port)))" >/dev/null 2>&1
    if [ $? -eq 0 ]; then return 1; else return 0; fi
}
# ============================================================================
# ПРОВЕРКА КОМПЛЕКТНОСТИ МОДЕЛИ
# ============================================================================

check_model_complete() {
    local model_path="$1"

    # Обязательные файлы токенайзера
    local required_tokenizer=false
    if [ -f "${model_path}/tokenizer.json" ] || \
       [ -f "${model_path}/tokenizer.model" ] || \
       [ -f "${model_path}/vocab.json" ]; then
        required_tokenizer=true
    fi

    # Хотя бы один шард модели
    local has_weights=false
    if ls "${model_path}"/model-*.safetensors 2>/dev/null | head -1 | grep -q .; then
        has_weights=true
    fi
    if ls "${model_path}"/*.bin 2>/dev/null | head -1 | grep -q .; then
        has_weights=true
    fi

    # Считаем сколько шардов есть vs сколько должно быть
    if $has_weights; then
        local expected=1
        if [ -f "${model_path}/model.safetensors.index.json" ]; then
            expected=$(python3 -c "
import json
d = json.load(open('${model_path}/model.safetensors.index.json'))
files = set(d['weight_map'].values())
print(len(files))
" 2>/dev/null || echo "0")
        fi

        local actual
        actual=$(ls "${model_path}"/model-*.safetensors 2>/dev/null | wc -l)

        if [ "$expected" -gt 1 ] && [ "$actual" -lt "$expected" ]; then
            log_warn "  Модель неполная: найдено ${actual}/${expected} шардов" >&2
            echo "incomplete"
            return
        fi
    fi

    if ! $required_tokenizer || ! $has_weights; then
        log_warn "  Отсутствуют обязательные файлы (tokenizer или веса)" >&2
        echo "incomplete"
        return
    fi

    echo "ok"
}

# ============================================================================
# ЗАГРУЗКА МОДЕЛИ С HUGGINGFACE
# ============================================================================

KNOWN_MODELS=(
    "12gb:Vikhrmodels/QVikhr-3-4B-Instruction:QVikhr-3-4B-Instruction"
    "12gb:IlyaGusev/saiga_mistral_7b:saiga_mistral_7b"
    "16gb:Vikhrmodels/QVikhr-3-8B-Instruction:QVikhr-3-8B-Instruction"
    "16gb:IlyaGusev/saiga_llama3_8b:saiga_llama3_8b"
    "24gb:IlyaGusev/saiga_nemo_12b:saiga_nemo_12b"
    "24gb:Vikhrmodels/QVikhr-3-8B-Instruction:QVikhr-3-8B-Instruction"
    "32gb:IlyaGusev/saiga_gemma3_27b:saiga_gemma3_27b"
    "32gb:IlyaGusev/saiga_nemo_12b:saiga_nemo_12b"
)

get_hf_repo_for_model() {
    local folder="$1"
    for entry in "${KNOWN_MODELS[@]}"; do
        local repo folder_name
        repo=$(echo "$entry"   | cut -d: -f2)
        folder_name=$(echo "$entry" | cut -d: -f3)
        if [ "$folder_name" = "$folder" ]; then
            echo "$repo"
            return
        fi
    done
    echo ""
}

download_model() {
    local repo="$1"
    local model_path="$2"

    log_info "  Скачивание модели: $repo → $model_path"

    # Устанавливаем huggingface-hub если нет
    if ! command -v huggingface-cli &>/dev/null; then
        "${HOME}/miniconda3/bin/python" -m pip install -q huggingface-hub[cli] hf_transfer
    fi

    export HF_HUB_ENABLE_HF_TRANSFER=1
    mkdir -p "$model_path"

    if ! huggingface-cli download "$repo" \
        --local-dir "$model_path" \
        --local-dir-use-symlinks False \
        --resume-download; then
        log_error "  Ошибка скачивания $repo"
        return 1
    fi

    log_info "  ✓ Загружено: $repo"
}

# ============================================================================
# ОБЕСПЕЧЕНИЕ НАЛИЧИЯ МОДЕЛИ (проверка + загрузка при необходимости)
# ============================================================================

ensure_model() {
    local model="$1"
    local model_path="${MODELS_DIR}/${model}"

    if [ ! -d "$model_path" ]; then
        log_warn "Модель не найдена локально: $model"
    else
        local status
        status=$(check_model_complete "$model_path")
        if [ "$status" = "ok" ]; then
            log_info "  Модель готова: $model"
            return 0
        fi
        log_warn "  Модель повреждена или неполная: $model"
    fi

    # Ищем HF репозиторий
    local repo
    repo=$(get_hf_repo_for_model "$model")

    if [ -z "$repo" ]; then
        log_error "  Не знаем откуда скачать: $model (добавьте в KNOWN_MODELS)"
        return 1
    fi

    if [ "${AUTO_DEPLOY}" = "true" ]; then
        log_info "  AUTO_DEPLOY=true → скачиваем автоматически"
        download_model "$repo" "$model_path"
    else
        read -r -p "  Скачать $model с HuggingFace? ($repo) [y/N]: " yn
        if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
            download_model "$repo" "$model_path"
        else
            log_error "  Модель пропущена"
            return 1
        fi
    fi
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
    local category="${1:-}"
    local params="${2:-0}"
    local free_gb="${3:-0}"
    local total_gb="${4:-0}"
    # ── 1. Выбираем квантизацию и считаем вес модели ──────────────────────
    local quant="none"
    local bytes_per_param="2.0"

    case "$category" in
        "12gb")
            if [ "$params" -ge 7 ]; then
                quant="fp8"; bytes_per_param="1.0"
            else
                quant="none"; bytes_per_param="2.0"
            fi
            ;;
        "16gb")
            quant="fp8"; bytes_per_param="1.0"
            ;;
        "24gb")
            quant="fp8"
            bytes_per_param="1.0"
            ;;
        "32gb")
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

    local kv_budget
    kv_budget=$(echo "scale=2; $free_gb - $weight_gb - $overhead_gb" | bc)

    log_info "  Расчёт памяти: free=${free_gb}GB, weights=${weight_gb}GB (${quant}), overhead=${overhead_gb}GB → KV budget=${kv_budget}GB" >&2

    if [ "$(echo "$kv_budget < 0.5" | bc)" -eq 1 ]; then
        log_warn "  Недостаточно памяти для KV-cache (${kv_budget}GB < 0.5GB)" >&2
        echo "none|0|0|auto|0"; return
    fi

    local kv_dtype="auto"
    if [ "$(echo "$kv_budget < 2.5" | bc)" -eq 1 ]; then
        kv_dtype="fp8_e5m2"
        log_info " KV budget мал (${kv_budget}GB) → kv_dtype=fp8_e5m2" >&2
    fi

    # Оцениваем max_ctx из KV budget:
    # KV per token ≈ 2 * n_layers * n_heads * head_dim * 2 bytes (fp16)
    # Для 8B Qwen/Llama-style: ~0.5MB/token (fp16), ~0.25MB/token (fp8)
    # Упрощённая формула: ctx = kv_budget_MB / mb_per_token
    #   fp16: ~0.50 MB/tok для 8B, ~0.75 для 12B
    #   fp8:  ~0.25 MB/tok для 8B, ~0.375 для 12B
    local mb_per_token
    if [ "$kv_dtype" = "fp8_e5m2" ]; then
        mb_per_token=$(echo "scale=4; $params * 0.018" | bc)
    else
        mb_per_token=$(echo "scale=4; $params * 0.040" | bc)
    fi

    local kv_budget_mb
    kv_budget_mb=$(echo "scale=0; $kv_budget * 1024" | bc | cut -d. -f1)

    local max_ctx_calc
    max_ctx_calc=$(echo "scale=0; ($kv_budget_mb / $mb_per_token) * 2.0" | bc | cut -d. -f1)

    max_ctx_calc=${max_ctx_calc%%.*}

    # Округляем до ближайшей степени 2 (не выше 32768)
    local ctx=4096
    for c in 4096 8192 16384 32768; do
        [ "$max_ctx_calc" -ge "$c" ] && ctx=$c
    done

    # Ограничения по сценарию
    case "$category" in
        "12gb") [ "$ctx" -gt 16384 ] && ctx=16384 ;;
        "16gb") [ "$ctx" -gt 16384 ] && ctx=16384 ;;
        "24gb") [ "$ctx" -gt 16384 ] && ctx=16384 ;;
        "32gb") [ "$ctx" -gt 32768 ] && ctx=32768 ;;
    esac

    log_info "  Расчётный контекст: max_ctx_calc=${max_ctx_calc} → ctx=${ctx}" >&2

    # util = сколько от TOTAL GPU памяти отдать движку.
    # Формула: (free_gb - safety_reserve) / total_gb
    # safety_reserve: буфер чтобы не словить OOM при пиковых нагрузках
    local safety_gb="1.5"
    local util
    util=$(echo "scale=2; ($free_gb - $safety_gb) / $total_gb" | bc)

    [[ $util == .* ]] && util="0${util}"

    # Зажимаем в разумные пределы [0.50 … 0.92]
    if [ "$(echo "$util < 0.50" | bc)" -eq 1 ]; then util="0.50"; fi
    if [ "$(echo "$util > 0.92" | bc)" -eq 1 ]; then util="0.92"; fi

    log_info "  gpu_memory_utilization = (${free_gb} - ${safety_gb}) / ${total_gb} = ${util}" >&2

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
    local category="${1:-24gb}"
    local tp_size="${2:-1}"

    if [ "$preferred" = "auto" ]; then
        local has_vllm=false
        local has_sglang=false
        local has_lmdeploy=false
        [ -d "${HOME}/miniconda3/envs/vllm_env"     ] && has_vllm=true
        [ -d "${HOME}/miniconda3/envs/sglang_env"   ] && has_sglang=true
        [ -d "${HOME}/miniconda3/envs/lmdeploy_env" ] && has_lmdeploy=true

        # Multi-GPU (TP > 1) → lmdeploy лучший выбор
        if [ "$tp_size" -gt 1 ]; then
            if $has_lmdeploy; then echo "lmdeploy"; return; fi
            if $has_vllm;     then echo "vllm";     return; fi
        fi

        # 32gb+ → vLLM (лучший throughput на больших моделях)
        if [ "$category" = "32gb" ]; then
            if $has_vllm;     then echo "vllm";    return; fi
            if $has_sglang;   then echo "sglang";  return; fi
            if $has_lmdeploy; then echo "lmdeploy";return; fi
        fi

        # 24gb → sglang (быстрее на среднем throughput)
        if [ "$category" = "24gb" ]; then
            if $has_sglang;   then echo "sglang";  return; fi
            if $has_vllm;     then echo "vllm";    return; fi
            if $has_lmdeploy; then echo "lmdeploy";return; fi
        fi

        # 16gb и меньше → vLLM (стабильнее на малой памяти)
        if $has_vllm;     then echo "vllm";     return; fi
        if $has_sglang;   then echo "sglang";   return; fi
        if $has_lmdeploy; then echo "lmdeploy"; return; fi

        log_error "Ни один движок не установлен!" >&2
        exit 1
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
        engine=$(choose_engine "$category" "1")

        # SGLang использует mem_fraction_static вместо util,
        # поэтому для него дополнительно снижаем на 0.05 (его overhead выше)
        local sgl_util="$util"

        if [ "$engine" = "sglang" ]; then
            sgl_util=$(echo "scale=2; $util + 0.12" | bc)
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
    log_info "  → Порт: $port | ctx: $ctx | util: $util | kv: $kv_dtype | seqs: $max_seqs"

    case "$engine" in
        "vllm")
            # Для vLLM используем чистый util, а не sgl_util
            CUDA_VISIBLE_DEVICES=$gpu_id bash -c "
                source ${HOME}/miniconda3/bin/activate vllm_env
                python -m vllm.entrypoints.openai.api_server \
                    --model '${model_path}' \
                    --port ${port} \
                    --max-model-len ${ctx} \
                    --gpu-memory-utilization ${util} \
                    --kv-cache-dtype ${kv_dtype} \
                    --max-num-batched-tokens ${ctx} \
                    --max-num-seqs ${max_seqs} \
                    --enable-chunked-prefill \
                    --trust-remote-code \
                    --dtype auto \
                    --enforce-eager \
                    > '${log_file}' 2>&1 &
                echo \$! > '${pid_file}'
            "
            ;;
        "sglang")
            local sgl_kv="$kv_dtype"
            [ "$sgl_kv" == "fp8" ] && sgl_kv="fp8_e5m2"
            [ "$sgl_kv" == "auto" ] && sgl_kv="bf16"

            log_info "GPU $gpu_id: Динамический старт SGLang ($model)"
            CUDA_VISIBLE_DEVICES=$gpu_id bash -c "
                source ${HOME}/miniconda3/bin/activate sglang_env
                export CC=${HOME}/miniconda3/envs/sglang_env/bin/x86_64-conda-linux-gnu-gcc
                export CXX=${HOME}/miniconda3/envs/sglang_env/bin/x86_64-conda-linux-gnu-g++
                python -m sglang.launch_server \
                    --model-path '${model_path}' \
                    --port ${port} \
                    --context-length ${ctx} \
                    --mem-fraction-static 0.80 \
                    --kv-cache-dtype ${sgl_kv} \
                    --max-running-requests ${max_seqs} \
                    --tokenizer-mode auto \
                    --attention-backend triton \
                    --sampling-backend pytorch \
                    --disable-cuda-graph \
                    --trust-remote-code \
                    > '${log_file}' 2>&1 &
                echo \$! > '${pid_file}'
            "
            ;;
        "lmdeploy")
            local raw_mem=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits -i "$gpu_id" | tr -d '[:space:]')
            local safe_lm_util="0.2"
            if [ "$raw_mem" -ge 20000 ]; then safe_lm_util="0.8"; fi

            log_info "GPU $gpu_id: Blackwell Detect. Запуск LMDeploy (PyTorch Backend)"
            CUDA_VISIBLE_DEVICES=$gpu_id bash -c "
                source ${HOME}/miniconda3/bin/activate lmdeploy_env
                python -m lmdeploy serve api_server '${model_path}' \
                    --backend pytorch \
                    --server-port ${port} \
                    --session-len ${ctx} \
                    --cache-max-entry-count ${safe_lm_util} \
                    --model-name ${model} \
                    --tp 1 \
                    --log-level INFO \
                    > '${log_file}' 2>&1 &
                echo \$! > '${pid_file}'
            "
            ;;
    esac
    sleep 2
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
        if ensure_model "$model"; then
            start_model "$gpu_id" "$model" "$engine" "$port" "$quant" "$ctx" "$util" "$sgl_util" "$kv_dtype" "$max_seqs"
        else
            log_error "GPU $gpu_id: пропускаем запуск — модель $model недоступна"
        fi
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
