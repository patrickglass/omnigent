# Omnigent as a systemd service (Linux)

Run the local Omnigent server + host daemon as a `systemd --user` service:
it starts at login, restarts on failure, and (with linger enabled) keeps
running after you log out — instead of a terminal tab you have to keep open.

> [!NOTE]
> This is for running Omnigent **on your own machine** (a desktop, laptop, or
> home/VPS server you have a login on). It is not a cloud deploy — for a
> hosted server with a public URL, see [`../README.md`](../README.md)
> (Docker, Render, Fly.io, ...).

## What it runs

The unit runs `omnigent server --host 0.0.0.0 --no-open` in the foreground —
the same foreground command Docker/cloud deploys use, bound to every
interface instead of just loopback, so other devices on your network (phone,
tablet, another machine) can reach it at `http://<this-machine-LAN-IP>:6767`.
`--no-open` skips trying to launch a browser, since a service has none.

Binding a non-loopback interface with no auth explicitly pinned makes
`omnigent server` default to **accounts (login) mode** automatically — first
boot serves a Create-admin form in the web UI instead of running open to
your LAN. See [`../README.md#auth`](../README.md#auth) to pin a different
mode (e.g. `OMNIGENT_AUTH_ENABLED=0` for single-user, no-login — only do this
on a network you trust).

It's a **user** unit, not a system-wide one, on purpose: harnesses launched
from sessions (`claude`, `codex`, ...) read your `$HOME`, your PATH, and
locally-stored credentials (e.g. `~/.claude`), none of which a dedicated
system service account would have.

The server alone doesn't execute agent sessions — see [Execution
model](../README.md#execution-model). To have sessions actually run on this
machine (not just be reachable here), also register it as a host once the
service is up:

```bash
omnigent host http://127.0.0.1:6767
```

(or point it at a different server if this box is only serving as an
execution host, not the coordinator).

## Install

```bash
cd deploy/systemd
./install.sh
```

This writes `~/.config/systemd/user/omnigent.service`, then runs
`systemctl --user enable --now omnigent.service`. Check it came up:

```bash
systemctl --user status omnigent.service
journalctl --user -u omnigent.service -f
```

Omnigent must already be installed and on `PATH` (see the main
[`README.md`](https://github.com/omnigent-ai/omnigent/blob/main/README.md#1-install))
— the installer resolves `omnigent` at install time and bakes the absolute
path (and a `PATH` snapshot, so `node`/`npm`/`tmux`/`bwrap` and the harness
CLIs still resolve) into the unit, since systemd user units don't inherit
your shell's PATH.

### Keep it running after you log out

By default a `systemd --user` service stops when your last login session
ends. To keep it running on a headless box or a server you don't stay logged
into:

```bash
loginctl enable-linger "$USER"
```

`install.sh` prints this reminder automatically when linger isn't already
enabled.

## Uninstall

```bash
cd deploy/systemd
./install.sh --uninstall
```

Stops and disables the service and removes the unit file. `omnigent
uninstall` (see the main README) also detects and offers to clean up this
unit.

## Configuration

The default unit uses your normal Omnigent state directories (`~/.omnigent`).
To point it elsewhere, edit the `OMNIGENT_CONFIG_HOME` / `OMNIGENT_DATA_DIR`
lines in `~/.config/systemd/user/omnigent.service`, then:

```bash
systemctl --user daemon-reload
systemctl --user restart omnigent.service
```

To run the **host daemon** instead of (or in addition to, as a second unit)
the server — e.g. a machine that should only execute sessions for a server
running elsewhere — change `ExecStart` to `omnigent host <server-url>` (empty
string `""` for local mode: spawns its own loopback-only server and
registers as a host against it; see `omnigent host --help`).
