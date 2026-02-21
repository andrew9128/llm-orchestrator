.PHONY: install configure status deploy stop stress-test

install:
	./scripts/bootstrap_llm.sh --all

configure:
	./scripts/configure_models.sh

deploy:
	./scripts/auto_deploy.sh --auto

status:
	./scripts/auto_deploy.sh --status

stop:
	./scripts/auto_deploy.sh --stop
	pkill -f advanced_healthcheck || true

help:
	@echo "Команды:"
	@echo "  make install    - Установка"
	@echo "  make configure  - Конфигурация моделей"
	@echo "  make deploy     - Автоматический запуск"
	@echo "  make status     - Статус"
	@echo "  make stop       - Остановить всё"
