#!/bin/zsh
# Double-click installer: copies Jarvis to ~/jarvis (if needed) and runs install.sh there.
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/jarvis"
if [[ "$SRC" != "$DEST" ]]; then
  if [[ -e "$DEST" ]]; then
    echo "Папка $DEST уже есть — обновляю файлы (ваши config.json и ключи не трогаю)."
  fi
  mkdir -p "$DEST"
  rsync -a --exclude config.json --exclude .fish_key --exclude .venv "$SRC/" "$DEST/"
fi
cd "$DEST" && ./install.sh
echo
read "?Нажмите Enter, чтобы закрыть окно…"
