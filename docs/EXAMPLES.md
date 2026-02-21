# Примеры использования

## Сценарий 1: Разработчик, одна модель для тестов
```bash
./scripts/bootstrap_llm.sh --vllm --download-models "Vikhrmodels/QVikhr-3-4B-Instruction"
source ~/.bashrc
llm-select-model vllm_QVikhr-3-4B-Instruction
```

## Сценарий 2: Production, все GPU, мониторинг
```bash
./start_llm.sh --auto
cd healthchecks && ./setup_healthcheck.sh
systemctl --user enable --now llm-healthcheck
```

## Сценарий 3: Обновление модели
```bash
./scripts/auto_deploy.sh --stop
rm -rf ~/llm_models/old_model
./scripts/bootstrap_llm.sh --download-models "new/model"
./scripts/configure_models.sh
./scripts/auto_deploy.sh --auto
```
