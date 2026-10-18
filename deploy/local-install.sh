#!/usr/bin/env bash
# Configures the OFFICIAL goose CLI on this machine to use the llm box's LiteLLM
# endpoint, so you just type `goose` - no exports, no wrapper, no per-shell wiring.
#
#   curl -fsSL https://raw.githubusercontent.com/Gorokhov/goose/main/deploy/local-install.sh \
#     | GOOSE_LLM_TOKEN=<litellm-key> bash
#
# NB the env var goes on the RIGHT of the pipe. `VAR=x curl ... | bash` sets it for
# curl, not for bash, and the script will exit telling you it's unset.
#
# The token is never committed to this repo - it's supplied at install time and
# written only into this machine's ~/.config/goose/secrets.yaml (mode 0600).
#
# THIS IS NOT deploy/client-install.sh. That one installs a thin ACP client driving a
# `goose serve` on the llm host, so the AGENT runs over there: it reads and edits files
# on the SERVER, not here, and its cwd must exist server-side. Fine for chatting, wrong
# for coding on your own machine. This script runs a normal LOCAL goose that merely
# calls a remote model - the agent sits next to your code, only inference is remote.
set -euo pipefail

# 2026-10-08: LiteLLM and mcp-hub moved to the service VM (llm-hub-vm, tailnet 100.111.215.112).
# The llm box (192.168.200.15 / 100.78.76.21) now runs inference only - no :4000 there.
GOOSE_LLM_HOST="${GOOSE_LLM_HOST:-100.111.215.112}"
GOOSE_LLM_PORT="${GOOSE_LLM_PORT:-4000}"
# Chat tier: MoE, ~73 tok/s, the right default for interactive work. The smart tier
# Qwen3.8-27B is ~3x slower but much stronger on reasoning/coding - select it per-run
# with `GOOSE_MODEL=Qwen3.8-27B goose`, or re-run this script with GOOSE_LLM_MODEL set
# to change the baked-in default.
GOOSE_LLM_MODEL="${GOOSE_LLM_MODEL:-Qwen3.6-35B-A3B}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/goose"
# Shared memory + delegation: the memory store is the SAME one OpenWebUI reads and
# writes, so what you tell the chat UI is known here and vice versa.
#
# This points at the hub's REMOTE-AGENT PROFILE, /agent/mcp: shared memory, the
# subagent tools (delegate bulky work to the box's local models), and find_tool /
# call_tool for everything else in the catalogue on demand.
#
# Do NOT point this at the hub's root path /mcp. That view also carries the server's
# browser and fetch tools, and goose already has its own LOCAL equivalents - two sets
# of similar-sounding tools acting on two different machines is how an agent does the
# work on the wrong one. (For the same reason the server's fs_*/git_*/sql_* tools were
# retired from the hub entirely in 2026-09.)
#
# History: this view used to be its own port (8093), then :8090/memory/mcp. It is now
# one PATH among several on the single tool bridge - one process, one port, one bearer
# token. /memory/mcp still exists and still serves the 4 memory tools, so an older
# install keeps working; set GOOSE_LLM_MEMORY_PATH=/memory/mcp to pin that behaviour.
# GOOSE_LLM_MEMORY_PORT is kept so an explicit override from an older invocation still
# works; leave it alone and it follows the hub port.
GOOSE_LLM_MEMORY="${GOOSE_LLM_MEMORY:-1}"
GOOSE_LLM_HUB_PORT="${GOOSE_LLM_HUB_PORT:-8090}"
GOOSE_LLM_MEMORY_PORT="${GOOSE_LLM_MEMORY_PORT:-$GOOSE_LLM_HUB_PORT}"
GOOSE_LLM_MEMORY_PATH="${GOOSE_LLM_MEMORY_PATH:-/agent/mcp}"
GOOSE_LLM_MEMORY_URI="${GOOSE_LLM_MEMORY_URI:-http://${GOOSE_LLM_HOST}:${GOOSE_LLM_MEMORY_PORT}${GOOSE_LLM_MEMORY_PATH}}"
GOOSE_LLM_MEMORY_TOKEN="${GOOSE_LLM_MEMORY_TOKEN:-}"

BASE="http://${GOOSE_LLM_HOST}:${GOOSE_LLM_PORT}"

if [ -z "${GOOSE_LLM_TOKEN:-}" ]; then
  echo "GOOSE_LLM_TOKEN is not set (the LiteLLM master key). Re-run as:" >&2
  echo "  curl -fsSL <this script's URL> | GOOSE_LLM_TOKEN=<key> bash" >&2
  exit 1
fi

command -v python3 >/dev/null 2>&1 || { echo "python3 is required but was not found on PATH." >&2; exit 1; }

# Cheap end-to-end proof before we touch any config: exercises routing, the key, and
# the model name. Catches a typo'd model now instead of at first use - and llama.cpp
# will NOT 404 on a wrong alias, it just serves whatever GGUF that port has loaded.
echo ">> Checking ${BASE} is reachable and serving ${GOOSE_LLM_MODEL}"
MODELS="$(curl -fsS -m 15 "${BASE}/v1/models" -H "Authorization: Bearer ${GOOSE_LLM_TOKEN}" 2>&1)" \
  || { echo "ERROR: cannot reach ${BASE}/v1/models - host down, wrong address, or bad key." >&2; exit 1; }
if ! printf '%s' "$MODELS" | grep -q "\"${GOOSE_LLM_MODEL}\""; then
  echo "ERROR: model '${GOOSE_LLM_MODEL}' is not served by ${BASE}. Available:" >&2
  printf '%s' "$MODELS" | tr ',' '\n' | grep -o '"id":"[^"]*"' | cut -d'"' -f4 | sed 's/^/  /' >&2
  exit 1
fi
echo "   ok"

if ! command -v goose >/dev/null 2>&1; then
  echo ">> Installing the official goose CLI"
  # The release artifact is a .tar.bz2; without bzip2 the upstream installer fails in a
  # way that doesn't mention bzip2 at all.
  command -v bzip2 >/dev/null 2>&1 || echo "   NOTE: bzip2 not found - install it if the next step fails" >&2
  curl -fsSL https://github.com/block/goose/releases/download/stable/download_cli.sh | CONFIGURE=false bash
  export PATH="$HOME/.local/bin:$PATH"
  command -v goose >/dev/null 2>&1 || { echo "ERROR: goose still not on PATH after install." >&2; exit 1; }
fi
echo ">> goose $(goose --version 2>&1 | tr -d '\n ')"

mkdir -p "$CONFIG_DIR"

# Why two files: goose reads provider/model/host from config.yaml, but it will NEVER
# read the API key from there - keys come from the OS keyring or, when
# GOOSE_DISABLE_KEYRING is set, from secrets.yaml. Verified the hard way: key in
# config.yaml gives "401 ... No api key passed in" even with keyring disabled.
# Headless boxes have no Secret Service, hence file-based storage.
echo ">> Writing config to $CONFIG_DIR"
python3 - "$CONFIG_DIR" "$GOOSE_LLM_MODEL" "$BASE" "$GOOSE_LLM_TOKEN" \
  "$GOOSE_LLM_MEMORY" "$GOOSE_LLM_MEMORY_TOKEN" "$GOOSE_LLM_MEMORY_URI" <<'PY'
import os, sys, shutil, time

cfg_dir, model, base, token, mem_on, mem_token, mem_uri = sys.argv[1:8]
config_path  = os.path.join(cfg_dir, "config.yaml")
secrets_path = os.path.join(cfg_dir, "secrets.yaml")

try:
    import yaml
except ImportError:
    yaml = None

# Both the legacy flat keys and the newer providers/active_provider block. goose 1.43
# migrates the flat ones into the block on first run, but an existing config may
# already carry the block - and then a flat key alone may not win. Writing both is
# exactly the state goose itself converges to.
config_updates = {
    "GOOSE_PROVIDER": "openai",
    "GOOSE_MODEL": model,
    "OPENAI_HOST": base,
    "GOOSE_DISABLE_KEYRING": 1,
    "active_provider": "openai",
}

def backup(path):
    dest = "%s.bak-%s" % (path, time.strftime("%Y%m%d%H%M%S"))
    shutil.copy2(path, dest)
    print("   backed up %s -> %s" % (os.path.basename(path), os.path.basename(dest)))

def write(path, text, mode=0o644):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(path, mode)

# --- config.yaml ---
if os.path.exists(config_path):
    if yaml is None:
        backup(config_path)
        print("   PyYAML is missing and a config already exists - NOT modifying it.")
        print("   Install PyYAML and re-run, or add these keys by hand:")
        for k, v in config_updates.items():
            print("     %s: %s" % (k, v))
    else:
        backup(config_path)
        with open(config_path) as f:
            cfg = yaml.safe_load(f) or {}
        cfg.update(config_updates)
        providers = cfg.setdefault("providers", {})
        providers.setdefault("openai", {}).update(
            {"enabled": True, "model": model, "configured": True})
        # setdefault, not update: never re-enable an extension the user disabled.
        if mem_on == "1" and mem_token:
            cfg.setdefault("extensions", {})["sharedmemory"] = {
                "enabled": True, "name": "sharedmemory", "type": "streamable_http",
                "uri": mem_uri, "headers": {"Authorization": "Bearer " + mem_token},
                "timeout": 60}
        cfg.setdefault("extensions", {}).setdefault("developer", {
            "enabled": True, "type": "builtin", "name": "developer",
            "display_name": "Developer", "timeout": None, "bundled": True})
        write(config_path, yaml.safe_dump(cfg, sort_keys=False))
        print("   merged into existing config.yaml")
else:
    lines = ["%s: %s" % (k, v) for k, v in config_updates.items()]
    lines += [
        "providers:", "  openai:", "    enabled: true",
        "    model: %s" % model, "    configured: true",
        "extensions:", "  developer:", "    enabled: true", "    type: builtin",
        "    name: developer", "    display_name: Developer", "    timeout: null",
        "    bundled: true",
    ]
    if mem_on == "1" and mem_token:
        lines += ["  sharedmemory:", "    enabled: true", "    name: sharedmemory",
                  "    type: streamable_http", f"    uri: {mem_uri}", "    headers:",
                  f"      Authorization: Bearer {mem_token}", "    timeout: 60"]
    write(config_path, "\n".join(lines) + "\n")
    print("   wrote a fresh config.yaml")

# --- secrets.yaml (0600) ---
if os.path.exists(secrets_path) and yaml is not None:
    with open(secrets_path) as f:
        secrets = yaml.safe_load(f) or {}
    secrets["OPENAI_API_KEY"] = token
    write(secrets_path, yaml.safe_dump(secrets, sort_keys=False), 0o600)
    print("   merged OPENAI_API_KEY into existing secrets.yaml (0600)")
elif os.path.exists(secrets_path):
    backup(secrets_path)
    print("   PyYAML is missing and secrets.yaml exists - NOT modifying it.")
    print("   Add by hand:  OPENAI_API_KEY: <your key>")
else:
    write(secrets_path, "OPENAI_API_KEY: %s\n" % token, 0o600)
    print("   wrote secrets.yaml (0600)")
PY

# Strip every relevant variable so this proves the BAKED config works, not the
# environment this script happens to be running in. XDG_CONFIG_HOME is deliberately
# kept so a sandboxed test install verifies its own config dir.
echo ">> Verifying with a plain 'goose' and no environment variables set"
REPLY_TEXT="$(env -u OPENAI_API_KEY -u OPENAI_HOST -u GOOSE_PROVIDER -u GOOSE_MODEL \
     -u GOOSE_DISABLE_KEYRING -u OPENAI_BASE_PATH \
     goose run --no-session -q -t "reply with exactly one word: OK" 2>&1 || true)"
if printf '%s' "$REPLY_TEXT" | grep -qi '\bOK\b'; then
  echo "   ok - the model answered"
else
  echo "   WARNING: smoke test did not return the expected answer:" >&2
  printf '%s\n' "$REPLY_TEXT" | tail -5 | sed 's/^/     /' >&2
fi

cat <<EOF
>> Done. Just run: goose
   endpoint:  ${BASE}
   model:     ${GOOSE_LLM_MODEL}
   smart tier: GOOSE_MODEL=Qwen3.8-27B goose
   change the default later: goose configure   (or re-run this with GOOSE_LLM_MODEL set)
EOF
