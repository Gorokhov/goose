#!/usr/bin/env bash
# Collects everything needed to diagnose a broken `goose-remote` install, in one
# pasteable report. Read-only: changes nothing.
#
# Usage:
#   bash ~/.local/share/goose-remote-client/deploy/client-debug.sh
#   curl -fsSL https://raw.githubusercontent.com/Gorokhov/goose/main/deploy/client-debug.sh | bash
#
# The bearer token is redacted from all output, so the report is safe to paste.

INSTALL_DIR="${GOOSE_REMOTE_INSTALL_DIR:-$HOME/.local/share/goose-remote-client}"
WRAPPER_PATH="${GOOSE_REMOTE_WRAPPER_PATH:-$HOME/.local/bin/goose-remote}"
OUT="$(mktemp -t goose-remote-debug.XXXXXX.log)"

redact() { sed -E 's/(token=|X-Secret-Key: ?)[A-Za-z0-9._-]+/\1<REDACTED>/g'; }
hdr() { printf '\n=== %s ===\n' "$1"; }

{
hdr "environment"
echo "date:   $(date -Is)"
echo "os:     $(uname -srm)"
echo "node:   $(node --version 2>&1)"
echo "npm:    $(npm --version 2>&1)"
echo "TERM:   ${TERM:-unset}"
echo "size:   $(stty size 2>/dev/null || echo 'no tty')"

hdr "wrapper ($WRAPPER_PATH)"
if [ -f "$WRAPPER_PATH" ]; then cat "$WRAPPER_PATH"; else echo "MISSING"; fi

hdr "install dir"
if [ -d "$INSTALL_DIR" ]; then
  echo "commit: $(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>&1)  ($(git -C "$INSTALL_DIR" log -1 --format=%cs 2>&1))"
  TUI="$INSTALL_DIR/ui/text/dist/tui.js"
  if [ -f "$TUI" ]; then echo "tui.js: present, $(stat -c%s "$TUI" 2>/dev/null || stat -f%z "$TUI") bytes, $(date -r "$TUI" -Is 2>/dev/null)"
  else echo "tui.js: MISSING - the build did not complete"; fi
else
  echo "MISSING: $INSTALL_DIR"
fi

hdr "@aaif/goose-sdk copies (version / auth patch applied?)"
# authHeaders>0 means our X-Secret-Key fix is present in that copy. The copy that
# matters is the one ui/text actually resolves, printed last.
find "$INSTALL_DIR/ui" -path '*/node_modules/@aaif/goose-sdk/package.json' 2>/dev/null | while read -r f; do
  d="$(dirname "$f")"
  printf '  %s  authHeaders=%s  %s\n' \
    "$(node -p "require('$f').version" 2>/dev/null || echo '?')" \
    "$(grep -c authHeaders "$d/dist/http-stream.js" 2>/dev/null || echo 0)" "$d"
done
# The package's `exports` map hides ./package.json, so resolve the main entry and
# walk up to the package root instead.
echo "  resolved by ui/text -> $(node -e "
  const path = require('path'), fs = require('fs');
  try {
    let dir = path.dirname(require.resolve('@aaif/goose-sdk', {paths:['$INSTALL_DIR/ui/text']}));
    while (dir !== path.dirname(dir)) {
      const pj = path.join(dir, 'package.json');
      if (fs.existsSync(pj) && JSON.parse(fs.readFileSync(pj,'utf8')).name === '@aaif/goose-sdk') {
        console.log(dir); process.exit(0);
      }
      dir = path.dirname(dir);
    }
    console.log('UNRESOLVABLE');
  } catch (e) { console.log('UNRESOLVABLE - ' + e.message) }" 2>&1)"

hdr "server reachability + ACP handshake"
SRV="$(grep -oE 'http://[^"]+' "$WRAPPER_PATH" 2>/dev/null | head -1)"
HOSTPORT="$(printf '%s' "$SRV" | sed -E 's#http://([^/?]+).*#\1#')"
TOKEN="$(printf '%s' "$SRV" | sed -nE 's/.*token=([A-Za-z0-9._-]+).*/\1/p')"
echo "target: $HOSTPORT"
if command -v curl >/dev/null 2>&1 && [ -n "$HOSTPORT" ]; then
  echo "-- initialize (expect result.agentInfo) --"
  curl -sS -m 10 "http://${HOSTPORT}/acp" -H "X-Secret-Key: ${TOKEN}" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}' 2>&1 | head -c 600
  echo
  echo "-- no-auth (expect 401; proves the secret is actually enforced) --"
  curl -sS -o /dev/null -w 'http %{http_code}\n' -m 10 "http://${HOSTPORT}/acp" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}' 2>&1
else
  echo "curl unavailable or wrapper unreadable - skipped"
fi

hdr "--text mode (non-interactive path)"
ACP_DEBUG=1 timeout 90 "$WRAPPER_PATH" --text "reply with exactly one word: OK" 2>&1 | tail -40

hdr "interactive mode (TUI path - makes _goose/unstable/defaults/read, which --text does not)"
# Needs a pty or Ink won't start; `script` supplies one. Killed after 30s since the
# TUI never exits on its own.
if command -v script >/dev/null 2>&1; then
  ACP_DEBUG=1 timeout 45 script -qec "$WRAPPER_PATH" /dev/null 2>&1 \
    | tr -d '\r' | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | tail -60
else
  echo "'script' not installed - cannot drive the TUI headlessly"
fi

hdr "methods attempted (interactive)"
echo "(look for the last method before any 'Invalid params' above)"
} 2>&1 | redact | tee "$OUT"

echo
echo "Report saved to: $OUT (token redacted - safe to paste)"
