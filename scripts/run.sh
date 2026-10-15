#!/bin/sh
# Compila em release e roda. Ctrl+C devolve as janelas pra dentro da tela e sai.
cd "$(dirname "$0")/.." && swift build -c release && exec .build/release/niri-os "$@"
