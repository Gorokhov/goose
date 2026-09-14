# deploy/

Install scripts for pointing other machines at the llm box (`192.168.200.15`).

There are two, and they are **not** interchangeable. The difference is *where the agent
runs* — which decides whose filesystem gets edited.

| | `local-install.sh` | `client-install.sh` |
|---|---|---|
| Agent runs | on **your** machine | on the **llm box** |
| Edits files on | your machine | the server |
| Remote part | inference only | the whole agent |
| Run it with | `goose` | `goose-remote` |
| Good for | coding, anything touching local files | chatting, driving the server |

**If you're not sure, you want `local-install.sh`.** Coding on a laptop with
`client-install.sh` means the agent edits files on the server that you can't see.

## local-install.sh

Configures the official goose CLI to use the llm box as its model provider. Bakes
everything into `~/.config/goose/`, so plain `goose` works with no exports.

```bash
curl -fsSL https://raw.githubusercontent.com/Gorokhov/goose/main/deploy/local-install.sh \
  | GOOSE_LLM_TOKEN=<litellm-key> bash
```

The env var goes on the **right** of the pipe. `VAR=x curl ... | bash` sets it for
curl, not bash.

Installs the goose CLI if missing, then writes:

- `config.yaml` — provider, model, `OPENAI_HOST`, keyring off
- `secrets.yaml` — the API key, mode `0600`

Two files because goose **never** reads the API key from `config.yaml`; keys come from
the OS keyring, or from `secrets.yaml` when `GOOSE_DISABLE_KEYRING` is set. Headless
boxes have no Secret Service, so file-based storage it is. Putting the key in
`config.yaml` fails with `401 ... No api key passed in`, which is not a helpful clue.

Existing configs are backed up and merged (needs PyYAML); without PyYAML the script
refuses to touch an existing config and prints the keys to add by hand.

Overrides: `GOOSE_LLM_HOST`, `GOOSE_LLM_PORT`, `GOOSE_LLM_MODEL`.

Model tiers — both live behind LiteLLM on `:4000`:

- `Qwen3.6-35B-A3B` — chat tier, MoE, ~73 tok/s. The default.
- `Qwen3.8-27B` — smart tier, ~22 tok/s but clearly better at reasoning and coding.
  Per-run: `GOOSE_MODEL=Qwen3.8-27B goose`.

Whatever is listed here must actually be loaded on the box. llama.cpp does **not** 404
on an unknown alias — it answers with whichever GGUF that port currently holds, so a
stale name silently returns the wrong model.

## client-install.sh

Thin ACP client against a `goose serve` on the llm box. Needs the patched
`@aaif/goose-sdk` (auth headers), which it builds and installs from this fork.

```bash
curl -fsSL https://raw.githubusercontent.com/Gorokhov/goose/main/deploy/client-install.sh \
  | GOOSE_REMOTE_TOKEN=<secret> bash
```

`--cwd` defaults to `/home/corle` because `session/new` sends a working directory that
the **agent** resolves on its own filesystem. Inheriting `$PWD` from a laptop sends a
path that doesn't exist server-side, and the agent rejects the session with a bare
`Invalid params` (the real reason, `invalid directory path`, only appears in the
server's log at `~/.local/state/goose/logs/cli/<date>/*.log`).

`client-debug.sh` prints a token-redacted diagnostic report for when it breaks.

## Secrets

No token is committed here. Both scripts take it at install time and write it only to
the local machine.
