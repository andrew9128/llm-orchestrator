#!/usr/bin/env bash
# LLM Healthcheck & Auto-Recovery

CONFIG="${HOME}/.config/llm_engines/healthcheck.conf"
LOG="${HOME}/llm_engines/healthcheck.log"
CHECK_INTERVAL=60

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

check_server() {
    local name=$1 url=$2 restart_cmd=$3
    
    if curl -s --max-time 10 "$url/health" | grep -q "ok\|healthy\|200" || \
       curl -s --max-time 10 "$url/v1/models" > /dev/null 2>&1; then
        log "✓ $name: OK"
        return 0
    fi
    
    log "✗ $name: FAILED, перезапуск..."
    eval "$restart_cmd" &
    sleep 30
}

# Дефолтная конфигурация
if [ ! -f "$CONFIG" ]; then
    mkdir -p "$(dirname "$CONFIG")"
    cat > "$CONFIG" << 'CONF'
# name|url|restart_command
vllm|http://localhost:8000|llm-manager start vllm --model ~/llm_models/QVikhr-3-8B-Instruction --port 8000
sglang|http://localhost:8001|llm-manager start sglang --model-path ~/llm_models/saiga_llama3_8b --port 8001
CONF
fi

# Основной цикл
while true; do
    log "=== Healthcheck ==="
    while IFS='|' read -r name url cmd; do
        [[ "$name" =~ ^# ]] && continue
        check_server "$name" "$url" "$cmd"
    done < "$CONFIG"
    sleep "$CHECK_INTERVAL"
done
