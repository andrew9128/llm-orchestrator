.PHONY: install configure status deploy stop stress-test

install:
./scripts/bootstrap_llm.sh --all

configure:
./scripts/configure_models.sh

deploy:
	./start_llm.sh --auto

status:
llm-manager status


help:
@echo "Команды:"
@echo "  make install    - Установка"
@echo "  make configure  - Конфигурация моделей"
@echo "  make status     - Статус"
