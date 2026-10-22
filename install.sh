#!/bin/zsh
# Jarvis installer for macOS.
#   ./install.sh              install dependencies and start Jarvis in the background (autostart at login)
#   ./install.sh --uninstall  stop Jarvis and remove autostart
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.jarvis.voice"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [[ "$1" == "--uninstall" ]]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Jarvis остановлен, автозапуск удалён."
  exit 0
fi

[[ "$(uname)" == "Darwin" ]] || { echo "Нужен macOS"; exit 1; }
command -v brew >/dev/null || { echo "Нужен Homebrew: https://brew.sh"; exit 1; }
command -v claude >/dev/null || { echo "Нужен Claude Code: https://docs.claude.com/claude-code"; exit 1; }

echo "→ tmux и ffmpeg"
for pkg in tmux ffmpeg; do command -v $pkg >/dev/null || brew install $pkg; done

echo "→ Python-окружение"
[[ -d "$HERE/.venv" ]] || python3 -m venv "$HERE/.venv"
"$HERE/.venv/bin/pip" install -q --upgrade pip
"$HERE/.venv/bin/pip" install -q -r "$HERE/requirements.txt"

[[ -f "$HERE/config.json" ]] || cp "$HERE/config.example.json" "$HERE/config.json"
chmod +x "$HERE/run.sh" "$HERE/jarvisctl"
ln -sf "$HERE/run.sh" "$(brew --prefix)/bin/jarvis"

echo "→ Автозапуск"
BIN_PATH="$(brew --prefix)/bin:$(dirname "$(command -v claude)"):/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$HERE/.venv/bin/python</string><string>-u</string><string>$HERE/jarvis.py</string>
  </array>
  <key>WorkingDirectory</key><string>$HERE</string>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$BIN_PATH</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HERE/jarvis.log</string>
  <key>StandardErrorPath</key><string>$HERE/jarvis.log</string>
</dict></plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "Готово. Jarvis работает в фоне. Лог: tail -f $HERE/jarvis.log"
echo "При первом запуске macOS спросит доступ к микрофону — разрешите."
