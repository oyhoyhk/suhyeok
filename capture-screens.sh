#!/bin/bash
# Captures what Claude Code and Codex draw in each state, for Tests/AgentDeckTests/Fixtures/screens.
# Run after an agent update, look at what changed, copy the screens you want into the fixtures, run the tests.
#   ./capture-screens.sh <out dir>
# Sends Claude two short prompts (a small amount of usage). Codex is only opened, never trusted or prompted:
# answering its folder-trust question would write to ~/.codex/config.toml.
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:?usage: ./capture-screens.sh <out dir>}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

REPO="$(mktemp -d /tmp/suhyeok-capture.XXXXXX)"
SOCK=suhyeok-capture
t() { tmux -L "$SOCK" "$@"; }
cleanup() { t kill-server 2>/dev/null || true; rm -rf "$REPO"; }
trap cleanup EXIT
(cd "$REPO" && git init -q && echo hi > a.txt && echo old > now.txt)

shot() { t capture-pane -p -t "$1" > "$OUT/$2.txt"; echo "  $2"; }
# wait <pane> <regex> [seconds]: until the screen matches, else fail with the screen.
wait_for() {
  local end=$((SECONDS + ${3:-60}))
  until t capture-pane -p -t "$1" | grep -qE "$2"; do
    if [ $SECONDS -ge $end ]; then echo "timed out waiting for /$2/ in $1:" >&2; t capture-pane -p -t "$1" | grep -v '^\s*$' | tail -15 >&2; exit 1; fi
    sleep 0.3
  done
}
# Started from inside an agent, the child would inherit its session markers (and stop saving its transcript).
launch() { t new-session -d -s "$1" -x 110 -y 36 -c "$REPO" "env -u TMUX -u CLAUDE_CODE_CHILD_SESSION zsh -lic '$2'"; }

echo "Claude Code $(claude --version 2>/dev/null | head -1)"
launch cl claude
wait_for cl 'trust this folder'; sleep 0.5; shot cl claude-trust
t send-keys -t cl Down; sleep 0.3; t send-keys -t cl Enter
wait_for cl 'for shortcuts|Try "|shift\+tab to cycle'; sleep 1; shot cl claude-idle
t send-keys -t cl -l '이 저장소의 파일 목록을 알려줘'; sleep 1; shot cl claude-typed
t send-keys -t cl C-u; sleep 0.5
t send-keys -t cl -l 'Reply with only the word OK. Do not use any tools.'; sleep 0.4; t send-keys -t cl Enter
wait_for cl '…'; shot cl claude-working
wait_for cl '✻ .* for [0-9]'; sleep 0.5; shot cl claude-replied
# Bash commands only ask in manual mode; the user's default may be "accept edits" or another mode.
for _ in 1 2 3 4 5; do t capture-pane -p -t cl | tail -3 | grep -q 'manual mode' && break; t send-keys -t cl BTab; sleep 0.6; done
t send-keys -t cl -l 'Run exactly this shell command with the Bash tool: rm now.txt'; sleep 0.4; t send-keys -t cl Enter
wait_for cl 'Do you want to proceed'; sleep 0.5; shot cl claude-permission
t send-keys -t cl Escape

echo "Codex $(codex --version 2>/dev/null | head -1)"
launch cx codex
wait_for cx 'Ask Codex'; sleep 1; shot cx codex-idle
t send-keys -t cx -l '이 저장소의 파일 목록을 알려줘'
wait_for cx 'Trust and continue' 30; sleep 0.5; shot cx codex-trust
t send-keys -t cx C-c

# Local paths out: the fixtures are public.
for f in "$OUT"/*.txt; do
  sed -i '' -e "s#/private$REPO#/tmp/fixture-repo#g" -e "s#$REPO#/tmp/fixture-repo#g" -e "s#$HOME#~#g" "$f"
  sed -i '' -e 's/[[:space:]]*$//' "$f"
done
{ claude --version 2>/dev/null | head -1; codex --version 2>/dev/null | head -1; date '+captured %Y-%m-%d'; } > "$OUT/VERSIONS"

echo "Menus as 수혁 reads them:"
BIN=.build/release/AgentDeck
[ -x "$BIN" ] || swift build -c release >/dev/null
for f in claude-trust claude-permission codex-trust; do echo "-- $f"; "$BIN" --parse-menu "$OUT/$f.txt" | sed 's/^/   /'; done
echo "Done: $OUT (compare with Tests/AgentDeckTests/Fixtures/screens)"
