#!/bin/zsh
# One-line install: curl -fsSL https://raw.githubusercontent.com/m0ln1z/jarvis/main/get.sh | zsh
set -e
DEST="$HOME/jarvis"
if [[ -d "$DEST/.git" ]]; then
  git -C "$DEST" pull --ff-only
else
  git clone https://github.com/m0ln1z/jarvis.git "$DEST"
fi
cd "$DEST" && ./install.sh
