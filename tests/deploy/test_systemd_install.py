from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "deploy" / "systemd" / "install.sh"

# Real tools the installer may use; everything else comes from stubs so tests
# never touch the developer's actual systemd, tmux, or omnigent install.
_REAL_TOOLS = ("cat", "cut", "dirname", "grep", "id", "mkdir", "rm", "sed", "sh", "uname")


def _stub(bin_dir: Path, name: str, body: str) -> None:
    path = bin_dir / name
    path.write_text(f"#!/bin/sh\n{body}\n")
    path.chmod(0o755)


def _logging_stub(bin_dir: Path, name: str, log: Path, extra: str = "") -> None:
    _stub(bin_dir, name, f"printf '%s %s\\n' {name} \"$*\" >> {log}\n{extra}")


@pytest.fixture
def env(tmp_path: Path) -> dict[str, str]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for tool in _REAL_TOOLS:
        real = shutil.which(tool)
        assert real is not None, tool
        (bin_dir / tool).symlink_to(real)
    log = tmp_path / "calls.log"
    log.touch()
    _logging_stub(bin_dir, "systemctl", log)
    _logging_stub(bin_dir, "omnigent", log)
    _logging_stub(bin_dir, "loginctl", log, "echo Linger=yes")
    _stub(bin_dir, "tmux", 'echo "tmux ${FAKE_TMUX_VERSION:-3.5a}"')
    _stub(bin_dir, "bwrap", "exit 0")
    home = tmp_path / "home"
    home.mkdir()
    return {"HOME": str(home), "PATH": str(bin_dir), "USER": "tester"}


def _run(env: dict[str, str], *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["sh", str(SCRIPT), *args], check=False, text=True, capture_output=True, env=env
    )


def _calls(env: dict[str, str]) -> list[str]:
    log = Path(env["PATH"]).parent / "calls.log"
    return log.read_text().splitlines()


def _unit_dir(env: dict[str, str]) -> Path:
    return Path(env["HOME"]) / ".config" / "systemd" / "user"


def test_install_writes_lan_server_unit_with_resolved_paths(env: dict[str, str]) -> None:
    result = _run(env)

    assert result.returncode == 0, result.stderr
    unit = (_unit_dir(env) / "omnigent.service").read_text()
    assert f"ExecStart={env['PATH']}/omnigent server --host 0.0.0.0 --no-open" in unit
    assert f"Environment=PATH={env['PATH']}" in unit
    assert "Environment=OMNIGENT_GRANT_MAX_LIFETIME_DAYS=365" in unit
    assert "{{" not in unit
    assert "systemctl --user enable omnigent.service" in _calls(env)
    assert "systemctl --user restart omnigent.service" in _calls(env)


def test_reinstall_restarts_running_server_to_apply_unit_changes(env: dict[str, str]) -> None:
    assert _run(env).returncode == 0

    result = _run(env)

    assert result.returncode == 0, result.stderr
    assert _calls(env).count("systemctl --user restart omnigent.service") == 2


def test_install_delegates_host_daemon_to_upstream_host_enable(env: dict[str, str]) -> None:
    result = _run(env)

    assert result.returncode == 0, result.stderr
    calls = _calls(env)
    assert "omnigent host enable --server http://127.0.0.1:6767" in calls
    # The server must be started before the host service that dials it.
    assert calls.index("systemctl --user restart omnigent.service") < calls.index(
        "omnigent host enable --server http://127.0.0.1:6767"
    )


def test_install_orders_host_service_after_server_via_drop_in(env: dict[str, str]) -> None:
    result = _run(env)

    assert result.returncode == 0, result.stderr
    drop_in = (_unit_dir(env) / "omnigent-host.service.d" / "omnigent-server.conf").read_text()
    for line in (
        "After=omnigent.service",
        "Wants=omnigent.service",
        "PartOf=omnigent.service",
        "Restart=always",
    ):
        assert line in drop_in


def test_install_honors_xdg_config_home(env: dict[str, str], tmp_path: Path) -> None:
    env["XDG_CONFIG_HOME"] = str(tmp_path / "xdg")

    result = _run(env)

    assert result.returncode == 0, result.stderr
    assert (tmp_path / "xdg" / "systemd" / "user" / "omnigent.service").is_file()
    assert (
        tmp_path / "xdg" / "systemd" / "user" / "omnigent-host.service.d" / "omnigent-server.conf"
    ).is_file()


@pytest.mark.parametrize("version", ["3.2a", "2.9"])
def test_install_rejects_tmux_older_than_3_3(env: dict[str, str], version: str) -> None:
    env["FAKE_TMUX_VERSION"] = version

    result = _run(env)

    assert result.returncode != 0
    assert "tmux 3.3" in result.stderr
    assert not (_unit_dir(env) / "omnigent.service").exists()


@pytest.mark.parametrize("version", ["3.3", "3.3a", "3.5a", "next-3.6", "4.0"])
def test_install_accepts_tmux_3_3_or_newer(env: dict[str, str], version: str) -> None:
    env["FAKE_TMUX_VERSION"] = version

    result = _run(env)

    assert result.returncode == 0, result.stderr


def test_install_rejects_missing_tmux(env: dict[str, str]) -> None:
    (Path(env["PATH"]) / "tmux").unlink()

    result = _run(env)

    assert result.returncode != 0
    assert "tmux" in result.stderr


def test_install_rejects_missing_bwrap(env: dict[str, str]) -> None:
    (Path(env["PATH"]) / "bwrap").unlink()

    result = _run(env)

    assert result.returncode != 0
    assert "bubblewrap" in result.stderr
    assert not (_unit_dir(env) / "omnigent.service").exists()


def test_no_start_enables_server_without_starting_and_skips_host(env: dict[str, str]) -> None:
    result = _run(env, "--no-start")

    assert result.returncode == 0, result.stderr
    calls = _calls(env)
    assert "systemctl --user enable omnigent.service" in calls
    assert "systemctl --user restart omnigent.service" not in calls
    assert not any(call.startswith("omnigent host enable") for call in calls)
    assert "omnigent host enable --server http://127.0.0.1:6767" in result.stdout


def test_uninstall_removes_host_service_drop_in_and_server_unit(env: dict[str, str]) -> None:
    assert _run(env).returncode == 0

    result = _run(env, "--uninstall")

    assert result.returncode == 0, result.stderr
    calls = _calls(env)
    assert "omnigent host disable" in calls
    assert "systemctl --user disable --now omnigent.service" in calls
    assert not (_unit_dir(env) / "omnigent.service").exists()
    assert not (_unit_dir(env) / "omnigent-host.service.d").exists()


def test_uninstall_does_not_need_tmux_or_bwrap(env: dict[str, str]) -> None:
    (Path(env["PATH"]) / "tmux").unlink()
    (Path(env["PATH"]) / "bwrap").unlink()

    result = _run(env, "--uninstall")

    assert result.returncode == 0, result.stderr


def test_rejects_unknown_option(env: dict[str, str]) -> None:
    result = _run(env, "--bogus")

    assert result.returncode != 0
    assert "--bogus" in result.stderr
    assert _calls(env) == []
