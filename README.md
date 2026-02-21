# LLM Infrastructure Bootstrap

##  Оглавление
1. [Быстрый старт](#быстрый-старт)
2. [Архитектура](#архитектура)
3. [Установка](#установка)
4. [Использование](#использование)
5. [Мониторинг](#мониторинг)
6. [Troubleshooting](#troubleshooting)
7. [API Reference](#api-reference)

##  Быстрый старт

### Одной командой (рекомендуется)
```bash
cd ~/llm_bootstrap
./start_llm.sh --auto
```

**Что происходит:**
1. Проверка зависимостей (jq, bc, curl)
2. Установка Miniconda + vLLM/SGLang/lmdeploy
3. Скачивание моделей (Vikhr-3-8B, Saiga-Nemo-12B)
4. Автоматическое распределение по GPU
5. Запуск healthcheck

**Время:** ~30-45 минут (зависит от интернета)

### Пошаговая установка
```bash
# 1. Установить только vLLM
./scripts/bootstrap_llm.sh --vllm

# 2. Скачать конкретную модель
./scripts/bootstrap_llm.sh --download-models "Vikhrmodels/QVikhr-3-8B-Instruction"

# 3. Сгенерировать конфигурации
source ~/.bashrc
./scripts/configure_models.sh

# 4. Запустить вручную
llm-select-model vllm_QVikhr-3-8B-Instruction
```

## ️ Архитектура

### Структура проекта
```
llm_bootstrap/
├── scripts/
│   ├── bootstrap_llm.sh      # Установка движков
│   ├── auto_deploy.sh        # Умное распределение по GPU
│   └── configure_models.sh   # Генерация конфигов
├── healthchecks/
│   ├── advanced_healthcheck.sh  # Мониторинг + автовосстановление
│   └── healthcheck.sh           # Простой healthcheck
├── benchmarks/
│   └── stress_test.py        # Нагрузочное тестирование
└── docs/
    ├── GPU_RECOMMENDATIONS.md  # Рекомендации по моделям
    └── CHEATSHEET.txt          # Шпаргалка команд
```

### Компоненты

**1. Bootstrap (`bootstrap_llm.sh`)**
- Установка Miniconda без sudo
- Создание conda окружений для каждого движка
- Компиляция llama.cpp с CUDA
- Скачивание моделей через HuggingFace CLI

**2. Auto-Deploy (`auto_deploy.sh`)**
- Анализ доступных GPU (VRAM, загрузка)
- Умный подбор модели под каждый GPU
- Динамический расчет `max-model-len`, `gpu-memory-utilization`
- Пропуск занятых GPU (>50% VRAM)

**3. Healthcheck (`advanced_healthcheck.sh`)**
- Мониторинг HTTP endpoints каждые 30с
- Парсинг логов на OOM/context errors
- Автоматический перезапуск с адаптацией параметров
- Cooldown период (5 минут между перезапусками)

##  Примеры вывода

### Успешное развертывание
```
[INFO] Анализ GPU...
[INFO]   GPU 0: NVIDIA RTX A4000 - 15.6GB свободно из 16.0GB
[INFO]   GPU 1: NVIDIA RTX A5000 - 22.6GB свободно из 24.0GB
[INFO] Доступно GPU: 2

═══════════════════════════════════════════════════════
              ПЛАН РАЗВЕРТЫВАНИЯ
═══════════════════════════════════════════════════════

GPU 0 (16gb - 16.0GB): NVIDIA RTX A4000
  Модель:  QVikhr-3-8B-Instruction
  Движок:  vllm
  Порт:    8000
  Квант:   fp8, Context: 16384, Util: 0.90

GPU 1 (24gb - 24.0GB): NVIDIA RTX A5000
  Модель:  saiga_nemo_12b
  Движок:  vllm
  Порт:    8001
  Квант:   fp8, Context: 16384, Util: 0.90

═══════════════════════════════════════════════════════

[INFO] Запуск моделей...
[INFO] GPU 0: Запуск QVikhr-3-8B-Instruction (vllm) на порту 8000...
[INFO] GPU 1: Запуск saiga_nemo_12b (vllm) на порту 8001...
[INFO] Развертывание завершено!
```

### Проверка статуса
```bash
$ ./scripts/auto_deploy.sh --status

═══════════════════════════════════════════════════════
              СТАТУС МОДЕЛЕЙ
═══════════════════════════════════════════════════════

GPU 0: QVikhr-3-8B-Instruction (vllm) - порт 8000
  Статус: ✅ Работает (PID: 12345)

GPU 1: saiga_nemo_12b (vllm) - порт 8001
  Статус: ⚠️  Загружается... (PID: 12346)

═══════════════════════════════════════════════════════
```

##  Troubleshooting

### Модель не запускается (OOM)
**Симптомы:**
```
[ERROR] CUDA out of memory
```

**Решение:**
```bash
# 1. Проверить сколько реально свободно
nvidia-smi

# 2. Убить чужие процессы
kill -9 <PID>

# 3. Перезапустить с меньшим context
CUDA_VISIBLE_DEVICES=0 llm-manager start vllm \
  --model ~/llm_models/QVikhr-3-8B \
  --max-model-len 8192 \  # вместо 16384
  --gpu-memory-utilization 0.75  # вместо 0.90
```

### Healthcheck не работает
**Симптомы:**
```
[WARN] Файл состояния не найден: deploy_state.json
```

**Решение:**
```bash
# Проверить что модели запущены через auto_deploy
./scripts/auto_deploy.sh --status

# Если нет JSON файла
ls -la ~/llm_engines/deploy_state.*

# Пересоздать deployment
./scripts/auto_deploy.sh --stop
./scripts/auto_deploy.sh --auto
```

### Conda окружение не активируется
**Решение:**
```bash
source ~/miniconda3/bin/activate
conda init bash
source ~/.bashrc
```

##  API Reference

### bootstrap_llm.sh
```bash
./scripts/bootstrap_llm.sh [OPTIONS]

OPTIONS:
  --vllm              Установить vLLM
  --sglang            Установить SGLang
  --lmdeploy          Установить lmdeploy
  --all               Все движки
  --download-models   Скачать модели (опционально список)

EXAMPLES:
  # Только vLLM
  ./scripts/bootstrap_llm.sh --vllm
  
  # Все + конкретная модель
  ./scripts/bootstrap_llm.sh --all --download-models "Vikhrmodels/QVikhr-3-8B-Instruction"
```

### auto_deploy.sh
```bash
./scripts/auto_deploy.sh [COMMAND]

COMMANDS:
  deploy, --auto      Автоматическое развертывание
  --status            Статус моделей
  --stop              Остановить все
  --plan              Показать план без запуска

EXAMPLES:
  # Автозапуск
  ./scripts/auto_deploy.sh --auto
  
  # Проверка
  ./scripts/auto_deploy.sh --status
```

##  Продвинутое использование

### Ручной запуск с кастомными параметрами
```bash
# Nemo-12B на 2 GPU с tensor parallelism
CUDA_VISIBLE_DEVICES=0,1 \
source ~/miniconda3/bin/activate lmdeploy_env && \
lmdeploy serve api_server ~/llm_models/saiga_nemo_12b \
  --tp 2 \
  --server-port 8002 \
  --cache-max-entry-count 0.9
```

### Benchmark
```bash
cd ~/llm_bootstrap/benchmarks
python stress_test.py
```

##  Метрики и мониторинг

### GPU мониторинг
```bash
# Реалтайм
watch -n 1 nvidia-smi

# Логирование
nvidia-smi dmon -s u -c 100 > gpu_usage.log
```

### API метрики
```bash
# vLLM metrics
curl http://localhost:8000/metrics

# Latency test
time curl -X POST http://localhost:8000/v1/completions \
  -d '{"model":"model","prompt":"test","max_tokens":10}'
```
```

---
