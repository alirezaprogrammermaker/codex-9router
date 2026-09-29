# Codex via 9Router

A Bash launcher for running the Codex CLI through a local 9Router gateway on
Termux.

## Requirements

- Bash
- Node.js 18 or newer
- curl
- Codex CLI
- 9Router, configured with at least one provider

The launcher checks required commands and the Node.js version before starting.
It reads a 9Router client API key from the local 9Router database. Provider
endpoints and provider credentials remain managed by 9Router.

## Usage

```sh
chmod +x codex-9router.sh
./codex-9router.sh
```

With no prompt arguments, the interactive panel lists the models exposed by
9Router,
lets you select a model, runs an optional read-only Codex test, opens the
9Router dashboard for provider/API-key management, and launches Codex. Pass a
prompt to skip the panel, start 9Router in the background if needed, and launch
Codex directly after the gateway is ready:

```sh
./codex-9router.sh "Inspect this project and fix the failing task"
```

The launcher waits only for 9Router's readiness check, then Codex runs while
9Router continues serving requests in the background.
It starts the official `9router` CLI with `--no-browser --skip-update` and
binds the local gateway to `127.0.0.1`.
If the configured port is held by an unresponsive 9Router server, the launcher
stops that server before starting a replacement. It leaves unrelated processes
alone and reports a port conflict instead.

For startup troubleshooting, inspect
`~/.9router/logs/codex-launcher-<port>.log`.

```sh
./codex-9router.sh --dashboard  # show/open the local dashboard
./codex-9router.sh --check      # run a read-only response check
./codex-9router.sh --stop       # stop only a server started by this launcher
./codex-9router.sh --help       # show options
```

`--stop` validates the recorded live process before stopping it. For 9Router's
detached `next-server`, it checks that the process runs from the installed
9Router app directory.

Set `NINEROUTER_PORT` to change the local gateway port. Set
`NINEROUTER_MODEL` to preselect the model ID (default:
`apmix/deepseek-v4-flash-free`).

The launcher binds a server it starts to `127.0.0.1`. Configure your own
providers and credentials in the 9Router dashboard; no API credentials are
included in this repository.
