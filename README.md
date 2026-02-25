# LLM Infrastructure Bootstrap

Скрипты для автоматической установки, настройки и запуска LLM-инфраструктуры на Linux без прав root. Поддерживает vLLM, SGLang, lmdeploy с автоматическим подбором параметров под железо.

---

## Быстрый старт

```bash
# Установить SGLang + vLLM и запустить автоматически
./scripts/bootstrap_llm.sh --sglang --vllm
ENGINE_TYPE=sglang ./start_llm.sh --auto
```

Скрипт сам определит GPU, подберёт модель, скачает её при необходимости и запустит сервер.

**Время первого запуска:** 30–60 минут (зависит от скорости интернета, модели ~15GB).

---

## Архитектура

```
llm-orchestrator/
├── start_llm.sh                  # Точка входа: меню или --auto
├── scripts/
│   ├── bootstrap_llm.sh          # Установка движков в conda-окружения
│   ├── auto_deploy.sh            # Анализ GPU, выбор модели, запуск
│   └── configure_models.sh       # Генерация конфигов
├── healthchecks/
│   ├── advanced_healthcheck.sh   # Мониторинг + автовосстановление
│   └── healthcheck.sh            # Простой healthcheck
├── benchmarks/
│   └── stress_test.py
└── docs/
    ├── GPU_RECOMMENDATIONS.md
    └── CHEATSHEET.txt
```

Каждый движок устанавливается в отдельное conda-окружение (`vllm_env`, `sglang_env`, `lmdeploy_env`). Это позволяет иметь разные версии torch/CUDA на одной машине и переключаться между движками без конфликтов.

---

## Установка

### Требования

- Linux x86_64 (проверено на Ubuntu 20.04)
- NVIDIA GPU с поддержкой CUDA 12+
- `nvidia-smi`, `curl`, `jq`, `bc` в системе
- Без sudo: всё ставится в `~/miniconda3` и `~/.local`

### Установка движков

```bash
# По одному
./scripts/bootstrap_llm.sh --vllm
./scripts/bootstrap_llm.sh --sglang
./scripts/bootstrap_llm.sh --lmdeploy

# Всё сразу
./scripts/bootstrap_llm.sh --all
```

Что происходит при установке:

1. Устанавливается Miniconda в `~/miniconda3` (если нет)
2. Создаётся conda-окружение под каждый движок
3. Для SGLang дополнительно устанавливается GCC 11 через conda-forge — он нужен для JIT-компиляции CUDA-ядер (системный GCC 9 на Ubuntu 20.04 не поддерживает C++20)
4. Создаются launcher-скрипты в `~/.local/bin/`

### Скачивание моделей

Модели скачиваются автоматически при запуске `--auto` если их нет локально. Также вручную:

```bash
./scripts/bootstrap_llm.sh --download-models "Vikhrmodels/QVikhr-3-8B-Instruction"
./scripts/bootstrap_llm.sh --download-models "IlyaGusev/saiga_nemo_12b"
```

Модели хранятся в `~/llm_models/`.

---

## Движки и бэкенды

### SGLang 0.5.9

**Окружение:** `sglang_env` — Python 3.11, Torch 2.9.1+cu128, CUDA 12.8

| Компонент | Версия | Примечание |
|-----------|--------|------------|
| FlashInfer | 0.6.3 | JIT через tvm-ffi/ninja |
| Triton | 3.5.1 | основной attention backend |
| GCC (conda) | 11.4.0 | нужен для JIT C++20 ядер |
| CUDA graph | отключён | GCC системный (9.x) не поддерживает C++20 при системной компиляции |
| Attention backend | triton | задаётся флагом `--attention-backend triton` |
| Sampling backend | pytorch | задаётся флагом `--sampling-backend pytorch` |

**Параметры запуска:**
```
--mem-fraction-static 0.80
--disable-cuda-graph
--attention-backend triton
--sampling-backend pytorch
--tokenizer-mode auto
--trust-remote-code
```

**Когда выбирается:** GPU категории 24gb при `ENGINE_TYPE=auto`.

### vLLM 0.15.1

**Окружение:** `vllm_env` — Python 3.11, Torch 2.9.1+cu128, CUDA 12.8

| Компонент | Версия | Примечание |
|-----------|--------|------------|
| Flash Attention | нет | не установлен, vLLM использует встроенный FLASH_ATTN |
| Attention backend | FLASH_ATTN (встроенный) | автовыбор из FLASH_ATTN / FLASHINFER / TRITON |
| CUDA graph | отключён | `--enforce-eager` |
| Chunked prefill | включён | |
| Prefix caching | включён | |

**Параметры запуска:**
```
--dtype auto
--enforce-eager
--enable-chunked-prefill
--trust-remote-code
--max-num-batched-tokens {ctx}
--gpu-memory-utilization {util}
--kv-cache-dtype {kv_dtype}
```

**Когда выбирается:** GPU категории 32gb, или когда SGLang недоступен, или при `ENGINE_TYPE=vllm`.

### lmdeploy

**Окружение:** `lmdeploy_env` — не установлен на текущей машине.

**Параметры запуска:**
```
--backend pytorch
--tp 1
--session-len {ctx}
--cache-max-entry-count {util}
```

**Когда выбирается:** multi-GPU конфигурации (TP > 1), или как fallback если vLLM и SGLang недоступны.

---

## Логика автовыбора

### Классификация GPU по VRAM

| Категория | VRAM | Пример GPU |
|-----------|------|------------|
| small | < 10GB | GTX 1080, RTX 3060 |
| 12gb | 10–14GB | RTX 3080, RTX 4070 |
| 16gb | 14–22GB | RTX A4000, RTX 4080 |
| 24gb | 22–30GB | RTX A5000, RTX 3090 |
| 32gb | ≥ 30GB | RTX A6000, A100 |

### Выбор модели по категории

| Категория | Приоритет моделей |
|-----------|-------------------|
| 12gb | QVikhr-3-4B-Instruction → saiga_mistral_7b |
| 16gb | QVikhr-3-8B-Instruction → saiga_llama3_8b |
| 24gb | saiga_nemo_12b → QVikhr-3-8B-Instruction |
| 32gb | saiga_gemma3_27b → saiga_nemo_12b |

### Выбор движка по категории (`ENGINE_TYPE=auto`)

| Ситуация | Движок |
|----------|--------|
| Multi-GPU (TP > 1) | lmdeploy → vllm |
| 32gb+ | vllm → sglang → lmdeploy |
| 24gb | sglang → vllm → lmdeploy |
| 16gb и меньше | vllm → sglang → lmdeploy |

### Расчёт параметров запуска

```
weight_gb  = params_b × bytes_per_param + 0.5
  fp16: bytes_per_param = 2.0
  fp8:  bytes_per_param = 1.0
  int4: bytes_per_param = 0.5

overhead_gb = 1.2 (модели ≤ 9B) | 1.8 (модели > 9B)

kv_budget  = free_gb - weight_gb - overhead_gb
ctx        = f(kv_budget, params_b)  → округление до 4096/8192/16384/32768

util = (free_gb - 1.5) / total_gb  → зажать в [0.50, 0.92]

# SGLang получает +0.12 к util (mem_fraction_static считается иначе)
# и зажимается в [0.80, 0.92]
```

---

## Управление

```bash
# Запуск с автовыбором движка
./start_llm.sh --auto

# Запуск с конкретным движком
ENGINE_TYPE=sglang ./start_llm.sh --auto
ENGINE_TYPE=vllm   ./start_llm.sh --auto

# Статус
./scripts/auto_deploy.sh --status

# Остановка
./start_llm.sh --stop

# Интерактивное меню
./start_llm.sh
```

Логи движков пишутся в `~/llm_engines/{engine}_gpu{id}.log`.

PID-файлы: `~/llm_engines/{engine}_gpu{id}.pid`.

---

## Мониторинг

```bash
# Логи SGLang на GPU 0
tail -f ~/llm_engines/sglang_gpu0.log

# Логи vLLM на GPU 0
tail -f ~/llm_engines/vllm_gpu0.log

# GPU в реальном времени
watch -n 1 nvidia-smi

# Healthcheck в фоне
./start_llm.sh --healthcheck-start
tail -f ~/llm_engines/healthcheck.log

# Метрики vLLM
curl http://localhost:8000/metrics
```

Healthcheck проверяет `/health` и `/v1/models` каждые 30 секунд и перезапускает упавшие процессы с cooldown 5 минут.

---

## API Reference

Все движки поднимают OpenAI-совместимый API.

```bash
# Chat completions
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "QVikhr-3-8B-Instruction",
    "messages": [{"role": "user", "content": "Привет!"}]
  }'

# Список моделей
curl http://localhost:8000/v1/models

# Healthcheck
curl http://localhost:8000/health

# Метрики (только vLLM)
curl http://localhost:8000/metrics
```

### bootstrap_llm.sh

```
--vllm              Установить vLLM
--sglang            Установить SGLang
--lmdeploy          Установить lmdeploy
--llamacpp          Установить llama.cpp
--ollama            Установить Ollama
--all               Всё сразу
--download-models   Скачать модели (опционально список через пробел)
```

### auto_deploy.sh

```
deploy / --auto     Автоматическое развертывание
--status            Статус всех моделей
--stop              Остановить всё
--help              Справка
```

Переменные окружения:

```
ENGINE_TYPE=auto|vllm|sglang|lmdeploy   (default: auto)
AUTO_DEPLOY=true|false                   (default: false)
```

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
