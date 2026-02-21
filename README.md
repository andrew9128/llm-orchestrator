# LLM Infrastructure Bootstrap

## Быстрый старт
```bash
cd ~/llm_bootstrap
./scripts/quick_start.sh
# Выбрать опцию 1
source ~/.bashrc
```

##  Структура
```
llm_bootstrap/
├── scripts/           # Установка
├── healthchecks/      # Автопереподнятие моделей
├── docs/              # Документация
└── Makefile           # Управление
```

##  Команды
```bash
llm-select-model                    # Список моделей
llm-manager status                  # Статус
cd healthchecks && ./healthcheck.sh # Healthcheck
```

##  Документация

- `INSTALL.txt` - Инструкция по установке
- `docs/GPU_RECOMMENDATIONS.md` - Рекомендации по GPU
- `docs/CHEATSHEET.txt` - Шпаргалка команд

##  Поддержка GPU

- 12GB (RTX 5070) → Vikhr-3-4B
- 16GB (RTX A4000) → Vikhr-3-8B, Saiga-Llama3-8B
- 24GB (Titan RTX) → Saiga-Nemo-12B
- 32GB (A6000) → Saiga-Nemo-12B FP16
- 2x16GB (TP2) → Nemo-12B, 1268 TPS

---

##  Ключевые особенности
- **Zero-Sudo**: Установка и запуск полностью в user-space.
- **Smart Scaling**: Автоматический расчет `--max-model-len` и `--gpu-memory-utilization` на основе реального остатка памяти (учитывает чужие процессы на GPU).
- **Multi-Engine**: Поддержка vLLM, SGLang и LMDeploy с единым интерфейсом управления.
- **Auto-Healing**: Продвинутый Healthcheck с автоматическим перезапуском и адаптацией параметров при OOM.

## Быстрый старт (Smart Mode)
```bash
cd ~/llm_bootstrap

# Полная установка всех движков и авто-развертывание лучших моделей на всех свободных GPU
./start_llm.sh --auto

# Управление
- ./scripts/auto_deploy.sh --status — Статус запущенных моделей.
- llm-select-model — Ручной выбор и запуск конкретной конфигурации.
- make stress-test — Запуск нагрузочного тестирования (50+ одновременных пользователей).
