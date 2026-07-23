#!/usr/bin/env bash
# Installs a thin goose ACP client that connects to a centrally-running
# `goose serve` instead of spinning up its own agent loop or local model.
#
# Usage:
#   GOOSE_REMOTE_TOKEN=<secret> curl -fsSL \
#     https://raw.githubusercontent.com/Gorokhov/goose/main/deploy/client-install.sh | bash
#
# The token is never committed to this repo - it's supplied at install time
# and baked only into the local wrapper script on this machine.
set -euo pipefail

GOOSE_REMOTE_HOST="${GOOSE_REMOTE_HOST:-192.168.200.15}"
GOOSE_REMOTE_PORT="${GOOSE_REMOTE_PORT:-3284}"
REPO_URL="https://github.com/Gorokhov/goose.git"
INSTALL_DIR="${GOOSE_REMOTE_INSTALL_DIR:-$HOME/.local/share/goose-remote-client}"
WRAPPER_PATH="$HOME/.local/bin/goose-remote"

if [ -z "${GOOSE_REMOTE_TOKEN:-}" ]; then
  echo "GOOSE_REMOTE_TOKEN is not set. Re-run as:" >&2
  echo "  GOOSE_REMOTE_TOKEN=<secret> curl -fsSL <this script's URL> | bash" >&2
  exit 1
fi

command -v node >/dev/null 2>&1 || {
  echo "node is required (v18+) but was not found on PATH." >&2
  exit 1
}
command -v npx >/dev/null 2>&1 || {
  echo "npx is required but was not found on PATH (usually ships with npm)." >&2
  exit 1
}

echo ">> Fetching client source into $INSTALL_DIR"
rm -rf "$INSTALL_DIR"
git clone --depth 1 "$REPO_URL" "$INSTALL_DIR" >/dev/null 2>&1

echo ">> Installing dependencies (sdk + text only, no desktop app)"
(cd "$INSTALL_DIR/ui" && npx --yes pnpm@latest install --filter=./sdk --filter=./text >/dev/null 2>&1)

echo ">> Building"
(cd "$INSTALL_DIR/ui/sdk" && npx --yes tsc >/dev/null 2>&1)
(cd "$INSTALL_DIR/ui/text" && npx --yes tsc >/dev/null 2>&1)

# ui/text depends on the published @aaif/goose-sdk npm package, not the
# workspace-local one (pnpm-workspace.yaml pins it by version, not
# `workspace:*`). Overwrite the installed copy with our patched build so the
# auth fix (X-Secret-Key / ?token=) actually ships.
INSTALLED_SDK_DIST="$INSTALL_DIR/ui/text/node_modules/@aaif/goose-sdk/dist"
if [ -d "$INSTALLED_SDK_DIST" ]; then
  cp "$INSTALL_DIR/ui/sdk/dist/http-stream.js" "$INSTALLED_SDK_DIST/http-stream.js"
else
  echo "WARNING: could not find installed @aaif/goose-sdk to patch; auth may not work." >&2
fi

mkdir -p "$(dirname "$WRAPPER_PATH")"
cat > "$WRAPPER_PATH" <<EOF
#!/usr/bin/env bash
exec node "$INSTALL_DIR/ui/text/dist/tui.js" \\
  --server "http://${GOOSE_REMOTE_HOST}:${GOOSE_REMOTE_PORT}?token=${GOOSE_REMOTE_TOKEN}" \\
  "\$@"
EOF
chmod +x "$WRAPPER_PATH"

echo ">> Done. Run: goose-remote"
echo "   (make sure $HOME/.local/bin is on your PATH)"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "   NOTE: it isn't right now - add 'export PATH=\"\$HOME/.local/bin:\$PATH\"' to your shell rc" ;;
esac
