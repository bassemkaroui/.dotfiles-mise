#!/usr/bin/env python3
"""Nextcloud AIO helper for install:nextcloud-aio and the nextcloud doctor checks.

Commands (exit codes in brackets):
  state       print the mastercontainer's Docker status, or "absent"   [0]
  running     the mastercontainer is running                 [0 yes, 1 no]
  domain      print this node's tailnet name                 [0, 1 not connected,
                                                              2 HTTPS certs off, 3 no tailscale]
  serve       classify `tailscale serve` on :443             [0 ours, 1 none, 2 something else,
                                                              3 unreadable]
  setup-done  AIO's first-run setup was completed            [0 yes, 1 no, 2 unreadable]
  check       AIO's settings match settings.toml             [0 match, 1 differ, 2 unreadable]
  backup      a backup target is configured in AIO           [0 yes, 1 no, 2 unreadable]
  checklist   print the first-run clicks, domain filled in   [0]

AIO keeps its settings in configuration.json inside the mastercontainer's
volume, next to its passphrase and the secrets it generates. This file reads
it through `docker exec`, copies out ONLY the keys in WANTED_KEYS, and never
prints anything else. Key names and defaults mirror AIO's
php/src/Data/ConfigurationManager.php (main branch, 2026-09-27).
"""

import json
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

MASTER = "nextcloud-aio-mastercontainer"
CONFIG_FILE = "/mnt/docker-aio-config/data/configuration.json"
BACKEND = "127.0.0.1:11000"
ADMIN_URL = "https://127.0.0.1:8080"
SETTINGS = Path(__file__).resolve().parents[3] / "services" / "nextcloud-aio" / "settings.toml"

# AIO's own defaults for a key it never saved (the fallback argument of each
# `$this->get(...)` in ConfigurationManager.php).
CONTAINER_DEFAULTS = {
    "isTalkEnabled": True,
    "isTalkRecordingEnabled": False,
    "isImaginaryEnabled": True,
    "isWhiteboardEnabled": True,
    "isClamavEnabled": False,
    "isFulltextsearchEnabled": False,
}
LABELS = {
    "isTalkEnabled": "Talk",
    "isTalkRecordingEnabled": "Talk recording",
    "isImaginaryEnabled": "Imaginary",
    "isWhiteboardEnabled": "Whiteboard",
    "isClamavEnabled": "ClamAV",
    "isFulltextsearchEnabled": "Full-text search",
}
OFFICE_KEYS = ("officeSuite", "isCollaboraEnabled", "isOnlyofficeEnabled", "isEuroofficeEnabled")
WANTED_KEYS = (
    "domain",
    "timezone",
    "wasStartButtonClicked",
    "borg_backup_host_location",
    "borg_remote_repo",
    *CONTAINER_DEFAULTS,
    *OFFICE_KEYS,
)


# ─── Plumbing ────────────────────────────────────────────────────────────────


def run(*argv: str) -> subprocess.CompletedProcess | None:
    """Run a command, capturing output; None when the binary is missing."""
    if shutil.which(argv[0]) is None:
        return None
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=8, check=False)
    except subprocess.TimeoutExpired:
        # A hung daemon reads as "unreadable", like any other failure.
        return subprocess.CompletedProcess(argv, 124, "", "timed out")


def php_bool(value: object) -> bool:
    """PHP's boolval(): old AIO configs store 1/0 or "1"/"0"/"" for booleans."""
    if isinstance(value, str):
        return value not in ("", "0")
    if isinstance(value, (list, dict)):
        return len(value) > 0
    return bool(value)


def read_aio() -> dict | None:
    """The whitelisted part of configuration.json, or None when unreadable."""
    proc = run("docker", "exec", MASTER, "cat", CONFIG_FILE)
    if proc is None or proc.returncode != 0 or not proc.stdout.strip():
        return None
    try:
        raw = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None
    return {k: raw[k] for k in WANTED_KEYS if k in raw}


def office_suite(cfg: dict) -> str:
    """ConfigurationManager::readOfficeSuite(), including its legacy keys."""
    if "officeSuite" in cfg:
        value = str(cfg["officeSuite"])
        return value if value in ("collabora", "onlyoffice", "eurooffice") else ""
    for key, suite in (
        ("isCollaboraEnabled", "collabora"),
        ("isOnlyofficeEnabled", "onlyoffice"),
        ("isEuroofficeEnabled", "eurooffice"),
    ):
        if php_bool(cfg.get(key, False)):
            return suite
    # All three false: "no office" only if the user ever saved the choice,
    # which the two older keys being present proves; otherwise AIO's default.
    if "isCollaboraEnabled" in cfg and "isOnlyofficeEnabled" in cfg:
        return ""
    return "eurooffice"


def containers(cfg: dict) -> dict[str, bool]:
    """Effective container toggles, with AIO's defaults for unsaved keys."""
    have = {k: php_bool(cfg.get(k, d)) for k, d in CONTAINER_DEFAULTS.items()}
    # AIO: recording is only ever on together with Talk.
    have["isTalkRecordingEnabled"] = have["isTalkEnabled"] and have["isTalkRecordingEnabled"]
    return have


def tailnet() -> tuple[int, str]:
    """(status, domain) as in the `domain` command's exit codes."""
    proc = run("tailscale", "status", "--json")
    if proc is None:
        return 3, ""
    try:
        status = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return 1, ""
    domain = str((status.get("Self") or {}).get("DNSName", "")).rstrip(".")
    if status.get("BackendState") != "Running" or not domain:
        return 1, ""
    if not status.get("CertDomains"):
        return 2, domain
    return 0, domain


def host_timezone() -> str:
    proc = run("timedatectl", "show", "-p", "Timezone", "--value")
    if proc is not None and proc.returncode == 0 and proc.stdout.strip():
        return proc.stdout.strip()
    try:
        return Path("/etc/timezone").read_text().strip()
    except OSError:
        return ""


def load_settings() -> dict:
    with SETTINGS.open("rb") as f:
        return tomllib.load(f)


def show(value: object) -> str:
    if value == "":
        return "none"
    if isinstance(value, bool):
        return "on" if value else "off"
    return str(value)


# ─── Commands ────────────────────────────────────────────────────────────────


def container_state() -> str:
    """Docker's State.Status for the mastercontainer, or "absent"."""
    proc = run("docker", "container", "inspect", MASTER)
    if proc is None or proc.returncode != 0:
        return "absent"
    try:
        return json.loads(proc.stdout)[0].get("State", {}).get("Status", "unknown")
    except (json.JSONDecodeError, IndexError):
        return "unknown"


def cmd_state() -> int:
    print(container_state())
    return 0


def cmd_running() -> int:
    state = container_state()
    print(f"{MASTER}: {state}")
    return 0 if state == "running" else 1


def cmd_domain() -> int:
    status, domain = tailnet()
    if domain:
        print(domain)
    return status


def cmd_serve() -> int:
    proc = run("tailscale", "serve", "status", "--json")
    if proc is None or proc.returncode != 0:
        print("cannot read the serve config")
        return 3
    try:
        cfg = json.loads(proc.stdout or "{}")
    except json.JSONDecodeError:
        print("cannot parse the serve config")
        return 3
    handler = None
    for hostport, web in (cfg.get("Web") or {}).items():
        if hostport.endswith(":443"):
            handler = ((web or {}).get("Handlers") or {}).get("/")
            if handler is not None:
                break
    if handler is None and "443" not in (cfg.get("TCP") or {}):
        print("nothing served on :443")
        return 1
    proxy = str((handler or {}).get("Proxy", ""))
    target = proxy.removeprefix("http://").replace("localhost", "127.0.0.1").rstrip("/")
    if target == BACKEND:
        print(f"https :443 / -> http://{BACKEND}")
        return 0
    print(f"https :443 / is already serving something else: {proxy or 'a non-proxy handler'}")
    return 2


def cmd_setup_done() -> int:
    cfg = read_aio()
    if cfg is None:
        return 2
    return 0 if cfg.get("domain") and php_bool(cfg.get("wasStartButtonClicked", False)) else 1


def cmd_check() -> int:
    cfg = read_aio()
    if cfg is None:
        print(f"cannot read AIO's configuration ({MASTER} not running?)")
        return 2
    want = load_settings()
    rows: list[tuple[str, object, object]] = []

    status, domain = tailnet()
    if status in (0, 2):
        rows.append(("domain", cfg.get("domain", ""), domain))
    else:
        print("domain: not verified (tailscale not connected)")
    tz = host_timezone()
    if tz:
        rows.append(("timezone", cfg.get("timezone", ""), tz))
    else:
        print("timezone: not verified (host timezone unknown)")
    rows.append(("office suite", office_suite(cfg), want.get("officeSuite", "")))
    have = containers(cfg)
    for key, wanted in (want.get("containers") or {}).items():
        if key not in have:
            print(f"{key}: not a known AIO key — fix settings.toml")
            return 1
        rows.append((LABELS[key], have[key], bool(wanted)))

    differ = [(k, h, w) for k, h, w in rows if h != w]
    for name, h, w in differ:
        print(f"{name}: AIO has {show(h)}, expected {show(w)}")
    if not differ:
        print(f"all {len(rows)} recorded settings match")
    return 1 if differ else 0


def cmd_backup() -> int:
    cfg = read_aio()
    if cfg is None:
        print(f"cannot read AIO's configuration ({MASTER} not running?)")
        return 2
    target = cfg.get("borg_backup_host_location") or cfg.get("borg_remote_repo")
    print(f"backup target: {target}" if target else "no backup target set")
    return 0 if target else 1


def cmd_checklist() -> int:
    want = load_settings()
    office = want.get("officeSuite", "")
    _, domain = tailnet()
    # Flag what differs from AIO's default: those are the boxes to actually click.
    toggles = ", ".join(
        f"{LABELS[k]} {show(bool(v))}" + (" (CHANGE)" if bool(v) != CONTAINER_DEFAULTS.get(k) else "")
        for k, v in (want.get("containers") or {}).items()
    )
    steps = [
        f"Open {ADMIN_URL} on this machine and accept the self-signed certificate.",
        "Save the passphrase it shows in 1Password — it is the only key to this interface.",
        f"Log in and submit the domain: {domain or '<tailscale is not connected>'}",
        f"Optional containers: {toggles}.",
        f"Office suite: {show(office)}"
        + (" (AIO's default)." if office == "eurooffice" else " (pick it explicitly; AIO defaults to eurooffice)."),
        f"Timezone: {host_timezone() or '<this machine timezone>'}.",
        ("TICK" if want.get("installLatestMajor") else "Leave UNTICKED")
        + " 'Install Nextcloud Hub <newer>' (settings.toml: installLatestMajor).",
        "Click 'Download and start containers'; save the initial admin password it shows.",
        "Backups: set a location when decided — until then `mise doctor project` reports it.",
        "Afterwards: mise doctor project",
    ]
    for i, step in enumerate(steps, 1):
        print(f"{i}. {step}")
    return 0


COMMANDS = {
    "state": cmd_state,
    "running": cmd_running,
    "domain": cmd_domain,
    "serve": cmd_serve,
    "setup-done": cmd_setup_done,
    "check": cmd_check,
    "backup": cmd_backup,
    "checklist": cmd_checklist,
}


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1] not in COMMANDS:
        print(f"usage: {Path(sys.argv[0]).name} {{{'|'.join(COMMANDS)}}}", file=sys.stderr)
        sys.exit(64)
    sys.exit(COMMANDS[sys.argv[1]]())


if __name__ == "__main__":
    main()
