# Omnigent as a systemd service (Linux)

Run a LAN-reachable Omnigent server plus the host daemon that executes
sessions on this machine as `systemd --user` services: they start at login,
restart on failure, and (with linger enabled) keep running after you log out —
instead of terminal tabs you have to keep open.

> [!NOTE]
> This is for running Omnigent **on your own machine** (a desktop, laptop, or
> home/VPS server you have a login on). It is not a cloud deploy — for a
> hosted server with a public URL, see [`../README.md`](../README.md)
> (Docker, Render, Fly.io, ...). If you only need the host daemon (no LAN
> access), `omnigent host enable` on its own is enough.

## What it runs

| Unit | Command | Managed by |
|---|---|---|
| `omnigent.service` | `omnigent server --host 0.0.0.0 --no-open` | this directory's `install.sh` |
| `omnigent-host.service` | `omnigent host --server http://127.0.0.1:6767` | `omnigent host enable` (upstream), plus a drop-in from `install.sh` |

The server binds every interface, not just loopback, so other devices on your
network (phone, tablet, another machine) can reach it at
`http://<this-machine-LAN-IP>:6767`. Binding a non-loopback interface with no
auth explicitly pinned makes `omnigent server` default to **accounts (login)
mode** — first boot serves a Create-admin form in the web UI instead of
running open to your LAN. See [`../README.md#auth`](../README.md#auth) to pin
a different mode.

The host unit is written by `omnigent host enable`, so it tracks upstream
changes. `install.sh` adds
`omnigent-host.service.d/omnigent-server.conf`, a drop-in that starts the host
after the server, restarts it with the server, and keeps restarting it if the
server was down long enough for the host to give up.

The host signs in with your `omnigent login` session and renews it from a
refresh grant on reconnect. The server unit sets
`OMNIGENT_GRANT_MAX_LIFETIME_DAYS=365`, so you re-run `omnigent login` about
once a year instead of every 30 days.

They're **user** units, not system-wide ones, on purpose: harnesses launched
from sessions (`claude`, `codex`, ...) read your `$HOME`, your PATH, and
locally-stored credentials (e.g. `~/.claude`), none of which a dedicated
system service account would have.

## Prerequisites

- Omnigent installed and on `PATH` (see the main
  [`README.md`](https://github.com/omnigent-ai/omnigent/blob/main/README.md#1-install)).
- **tmux 3.3 or newer.** Ubuntu 22.04's `apt install tmux` gives 3.2a, which
  managed terminals reject. Build a newer release from
  [tmux releases](https://github.com/tmux/tmux/releases) into `/usr/local`:

  ```bash
  sudo apt install libevent-dev libncurses-dev bison build-essential pkg-config
  curl -fsSLO https://github.com/tmux/tmux/releases/download/3.5a/tmux-3.5a.tar.gz
  tar xzf tmux-3.5a.tar.gz && cd tmux-3.5a
  ./configure --prefix=/usr/local && make && sudo make install
  ```

- **bubblewrap** (`sudo apt install bubblewrap`), which sandboxes agent
  terminals on Linux.

`install.sh` checks tmux and bwrap and stops with an error if either is
missing or too old.

## Install

```bash
just install-systemd     # or: cd deploy/systemd && ./install.sh
```

This writes `~/.config/systemd/user/omnigent.service` and the host drop-in,
starts the server, then runs `omnigent host enable --server
http://127.0.0.1:6767`. The installer bakes the absolute `omnigent` path and a
`PATH` snapshot into the server unit, since systemd user units don't inherit
your shell's PATH; `host enable` does the same for the host unit.

On a first install, create the admin account in the web UI, then sign the
host in:

```bash
omnigent login http://127.0.0.1:6767
systemctl --user restart omnigent-host.service
```

Check both came up:

```bash
systemctl --user status omnigent.service omnigent-host.service
journalctl --user -u omnigent.service -u omnigent-host.service -f
```

### Keep it running after you log out

By default `systemd --user` services stop when your last login session ends.
To keep them running on a headless box or a server you don't stay logged into:

```bash
loginctl enable-linger "$USER"
```

`install.sh` prints this reminder automatically when linger isn't already
enabled.

## Upgrading Omnigent

The units call the installed `omnigent`, so upgrade it and restart the server
(the drop-in restarts the host with it):

```bash
uv tool upgrade omnigent
systemctl --user restart omnigent.service
```

## Uninstall

```bash
just uninstall-systemd   # or: cd deploy/systemd && ./install.sh --uninstall
```

Runs `omnigent host disable`, removes the drop-in, and stops, disables, and
removes the server unit.

## Configuration

The server unit uses your normal Omnigent state directories (`~/.omnigent`).
To point it elsewhere, edit the `OMNIGENT_CONFIG_HOME` / `OMNIGENT_DATA_DIR`
lines in `~/.config/systemd/user/omnigent.service`, then:

```bash
systemctl --user daemon-reload
systemctl --user restart omnigent.service
```
