#!/usr/bin/env bash
# Installs a thin goose ACP client that connects to a centrally-running
# `goose serve` instead of spinning up its own agent loop or local model.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Gorokhov/goose/main/deploy/client-install.sh \
#     | GOOSE_REMOTE_TOKEN=<secret> bash
#
# NB the env var goes on the RIGHT of the pipe. `VAR=x curl ... | bash` sets it for
# curl, not for bash, and the script will exit telling you it's unset.
#
# The token is never committed to this repo - it's supplied at install time
# and baked only into the local wrapper script on this machine.
set -euo pipefail

GOOSE_REMOTE_HOST="${GOOSE_REMOTE_HOST:-192.168.200.15}"
GOOSE_REMOTE_PORT="${GOOSE_REMOTE_PORT:-3284}"
# session/new sends a working directory that the AGENT resolves on its own filesystem.
# This client is remote by definition, so the local directory you happen to launch
# from usually doesn't exist over there - the agent then rejects the session with a
# bare "Invalid params" (data: "invalid directory path"). Pin a path that exists on
# the agent host instead of inheriting $PWD.
GOOSE_REMOTE_CWD="${GOOSE_REMOTE_CWD:-/home/corle}"
REPO_URL="https://github.com/Gorokhov/goose.git"
GOOSE_REMOTE_REF="${GOOSE_REMOTE_REF:-main}"
INSTALL_DIR="${GOOSE_REMOTE_INSTALL_DIR:-$HOME/.local/share/goose-remote-client}"
# Overridable so a throwaway test install (GOOSE_REMOTE_INSTALL_DIR=/tmp/...) doesn't
# repoint the real `goose-remote` at a directory that's about to be deleted - which is
# exactly what happened on 2026-09-07, leaving MODULE_NOT_FOUND behind.
WRAPPER_PATH="${GOOSE_REMOTE_WRAPPER_PATH:-$HOME/.local/bin/goose-remote}"
# Pinned: pnpm majors differ in how they hoist, and we've already been bitten by
# @aaif/goose-sdk landing in ui/node_modules on one machine and ui/text/node_modules
# on another. Override only if you're deliberately testing a different resolver.
PNPM_VERSION="${GOOSE_REMOTE_PNPM_VERSION:-12.3.4}"

LOG="$(mktemp -t goose-remote-install.XXXXXX.log)"

fail() {
  echo >&2
  echo "ERROR: $1" >&2
  echo "--- last 40 lines of $LOG ---" >&2
  tail -40 "$LOG" >&2
  echo "--- full log: $LOG ---" >&2
  exit 1
}

# Every build step goes through this. The previous version sent pnpm/tsc output to
# /dev/null, so a failed build still printed ">> Done" and left a broken tree behind
# for the user to discover at runtime.
run() {
  local what="$1"; shift
  echo "\$ $*" >>"$LOG"
  "$@" >>"$LOG" 2>&1 || fail "$what failed"
}

if [ -z "${GOOSE_REMOTE_TOKEN:-}" ]; then
  echo "GOOSE_REMOTE_TOKEN is not set. Re-run as:" >&2
  echo "  curl -fsSL <this script's URL> | GOOSE_REMOTE_TOKEN=<secret> bash" >&2
  exit 1
fi

for cmd in node npx git; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "$cmd is required but was not found on PATH." >&2; exit 1; }
done
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 18 ] || { echo "node >= 18 required, found $(node --version)." >&2; exit 1; }

echo ">> Fetching client source into $INSTALL_DIR (ref: $GOOSE_REMOTE_REF)"
rm -rf "$INSTALL_DIR"
run "git clone" git clone --depth 1 --branch "$GOOSE_REMOTE_REF" "$REPO_URL" "$INSTALL_DIR"
echo "   commit: $(git -C "$INSTALL_DIR" rev-parse --short HEAD)"

# --frozen-lockfile: ui/pnpm-lock.yaml is committed, so use it. Without this a fresh
# install silently resolves newer transitive deps than the tree was tested against,
# which makes "worked in July, broken in September, no code changed" possible.
echo ">> Installing dependencies (sdk + text only, no desktop app)"
run "pnpm install" env -C "$INSTALL_DIR/ui" \
  npx --yes "pnpm@${PNPM_VERSION}" install --frozen-lockfile --filter=./sdk --filter=./text

echo ">> Building"
run "sdk build" env -C "$INSTALL_DIR/ui/sdk" npx --yes tsc
run "text build" env -C "$INSTALL_DIR/ui/text" npx --yes tsc

TUI_ENTRY="$INSTALL_DIR/ui/text/dist/tui.js"
[ -f "$TUI_ENTRY" ] || fail "build reported success but $TUI_ENTRY does not exist"

# ui/text depends on the PUBLISHED @aaif/goose-sdk (pnpm-workspace.yaml pins it by
# version, not `workspace:*`), so our local fixes to ui/sdk don't reach it unless we
# overwrite the installed copy. Resolve the exact package ui/text loads rather than
# patching every copy `find` turns up: with several versions installed, blanket
# patching would clobber a newer SDK with our older build.
# Resolve the package's main entry and walk up to its root - the package's `exports`
# map deliberately hides ./package.json, so resolving that path directly throws.
SDK_DIR="$(node -e "
  const path = require('path'), fs = require('fs');
  let dir = path.dirname(require.resolve('@aaif/goose-sdk', {paths: ['$INSTALL_DIR/ui/text']}));
  while (dir !== path.dirname(dir)) {
    const pj = path.join(dir, 'package.json');
    if (fs.existsSync(pj) && JSON.parse(fs.readFileSync(pj, 'utf8')).name === '@aaif/goose-sdk') {
      console.log(dir); process.exit(0);
    }
    dir = path.dirname(dir);
  }
  process.exit(1);
" 2>/dev/null)" || fail "ui/text cannot resolve @aaif/goose-sdk - dependency install is incomplete"
SDK_VERSION="$(node -p "require('$SDK_DIR/package.json').version")"
echo ">> Patching @aaif/goose-sdk@${SDK_VERSION} at ${SDK_DIR}"

cp "$INSTALL_DIR/ui/sdk/dist/http-stream.js" "$SDK_DIR/dist/http-stream.js"
# The auth fix is the whole reason this client exists; without it every request is
# unauthenticated and the server answers 404.
grep -q 'authHeaders' "$SDK_DIR/dist/http-stream.js" \
  || fail "patch did not take - authHeaders missing from $SDK_DIR/dist/http-stream.js"

OTHER_COPIES="$(find "$INSTALL_DIR/ui" -path '*/node_modules/@aaif/goose-sdk/dist/http-stream.js' \
  ! -path "$SDK_DIR/*" 2>/dev/null || true)"
if [ -n "$OTHER_COPIES" ]; then
  echo "   NOTE: other @aaif/goose-sdk copies exist and were left alone:" >&2
  echo "$OTHER_COPIES" | sed 's/^/     /' >&2
fi

mkdir -p "$(dirname "$WRAPPER_PATH")"
cat > "$WRAPPER_PATH" <<EOF
#!/usr/bin/env bash
# --cwd is a path on the AGENT host, not this machine. Override per-invocation by
# passing your own --cwd, which wins since later flags take precedence.
exec node "$TUI_ENTRY" \\
  --server "http://${GOOSE_REMOTE_HOST}:${GOOSE_REMOTE_PORT}?token=${GOOSE_REMOTE_TOKEN}" \\
  --cwd "${GOOSE_REMOTE_CWD}" \\
  "\$@"
EOF
chmod +x "$WRAPPER_PATH"

# Cheap end-to-end proof: exercises DNS, routing, the secret, and the ACP handshake
# without loading the model or spending tokens. Catches the 404/auth class of failure
# at install time instead of at first use.
echo ">> Verifying ACP handshake against ${GOOSE_REMOTE_HOST}:${GOOSE_REMOTE_PORT}"
if command -v curl >/dev/null 2>&1; then
  HANDSHAKE="$(curl -sS -m 10 "http://${GOOSE_REMOTE_HOST}:${GOOSE_REMOTE_PORT}/acp" \
    -H "X-Secret-Key: ${GOOSE_REMOTE_TOKEN}" -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}' 2>&1 || true)"
  case "$HANDSHAKE" in
    *'"agentInfo"'*) echo "   ok - agent: $(printf '%s' "$HANDSHAKE" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const a=JSON.parse(s).result.agentInfo;console.log(a.name+" "+a.version)})' 2>/dev/null || echo reachable)" ;;
    *'"error"'*)     echo "   WARNING: server rejected the handshake: $HANDSHAKE" >&2 ;;
    *)               echo "   WARNING: no usable response (server down, wrong host/port, or bad token): $HANDSHAKE" >&2 ;;
  esac
else
  echo "   skipped (curl not installed)"
fi

rm -f "$LOG"
echo ">> Done. Run: goose-remote"
case ":$PATH:" in
  *":$(dirname "$WRAPPER_PATH"):"*) ;;
  *) echo "   NOTE: $(dirname "$WRAPPER_PATH") is not on your PATH - add 'export PATH=\"$(dirname "$WRAPPER_PATH"):\$PATH\"' to your shell rc" ;;
esac
