#!/usr/bin/env bash

echo "Установка LLM healthcheck service..."

mkdir -p ~/.config/systemd/user
cp healthchecks/llm-healthcheck.service ~/.config/systemd/user/

SCRIPT_PATH="$(pwd)/healthchecks/healthcheck.sh"
sed -i "s|%h/llm_bootstrap/healthchecks/healthcheck.sh|$SCRIPT_PATH|g" \
    ~/.config/systemd/user/llm-healthcheck.service

systemctl --user daemon-reload

echo "✓ Установлено"
echo ""
echo "Команды:"
echo "  systemctl --user start llm-healthcheck"
echo "  systemctl --user enable llm-healthcheck"
echo "  systemctl --user status llm-healthcheck"
