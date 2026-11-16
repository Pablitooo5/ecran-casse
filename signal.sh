#!/bin/bash
# Écran Cassé — appelé par les hooks de Claude Code.
#   waiting      : Claude a fini sa réponse (Stop) → on note l'heure
#   waiting keep : Claude attend une validation (Notification) → on note l'heure si rien n'est noté
#   busy         : tu as répondu, ou Claude retravaille → on efface
#   end          : la session se ferme → on efface
#   demo         : lance la démo
# Ne bloque jamais Claude : aucune sortie, toujours code 0. Rien n'est envoyé sur Internet.

DIR="$HOME/.claude/ecran-casse"
WAIT="$DIR/waiting"
APP="$DIR/EcranCasse.app"
mkdir -p "$WAIT" 2>/dev/null

if [ "$1" = "demo" ]; then
  pgrep -xq EcranCasse || open -g "$APP"
  touch "$DIR/demo"
  exit 0
fi

INPUT=$(cat 2>/dev/null)
SID=$(printf '%s' "$INPUT" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
[ -z "$SID" ] && SID="default"
SID=${SID//[^A-Za-z0-9_-]/_}
F="$WAIT/$SID"

case "$1" in
  waiting)
    if [ "$2" = "keep" ] && [ -f "$F" ]; then :; else date +%s > "$F"; fi
    pgrep -xq EcranCasse || open -g "$APP"
    ;;
  busy|end)
    rm -f "$F"
    ;;
esac
exit 0
