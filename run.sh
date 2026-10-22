#!/bin/zsh
cd "$(dirname "$(readlink -f "$0")")" && exec .venv/bin/python jarvis.py "$@"
