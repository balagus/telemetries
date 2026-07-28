#!/usr/bin/env python3
"""Check that every variable the config files reference is actually supplied.

The files under config/ use plain ${VAR} with no defaults, because Mimir's
config expansion does not support the ${VAR:-default} form — it expands it to
an empty string instead. That makes an unset variable silently become "",
which typically surfaces much later as a backend that starts happily and then
refuses writes.

This walks config/, collects every ${VAR} and sys.env("VAR") reference, and
verifies both launchers provide it: bare-metal/defaults.sh for the binaries,
and docker-compose.yml for the containers. Run it after adding a setting to
any config file.

    ./stack.sh check-config

Exits non-zero if anything is missing. Docker is optional — the Compose half
is skipped with a note when the CLI is unavailable.
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG = ROOT / "config"

# Which Compose service mounts which config file. Anything not listed is
# Grafana's (its provisioning directory holds several files).
SERVICE_OF = {
    "config/loki/loki.yaml": "loki",
    "config/tempo/tempo.yaml": "tempo",
    "config/mimir/mimir.yaml": "mimir",
    "config/alloy/config.alloy": "alloy",
}
DEFAULT_SERVICE = "grafana"

VAR_RE = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)\}")
ENV_FN_RE = re.compile(r'sys\.env\("([A-Z_][A-Z0-9_]*)"\)')

GREEN, RED, YELLOW, DIM, RESET = (
    "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[0m")


def strip_comments(text):
    """Drop whole-line comments so documentation examples are not mistaken
    for real references — this file's own docs mention ${VAR}."""
    out = []
    for line in text.splitlines():
        s = line.lstrip()
        if s.startswith("#") or s.startswith("//"):
            continue
        out.append(line)
    return "\n".join(out)


def referenced_vars():
    """{relative path: {VAR, ...}} for every config file that uses any."""
    found = {}
    for path in sorted(CONFIG.rglob("*")):
        if not path.is_file():
            continue
        body = strip_comments(path.read_text())
        names = set(VAR_RE.findall(body)) | set(ENV_FN_RE.findall(body))
        if names:
            found[str(path.relative_to(ROOT))] = names
    return found


def bare_metal_exports():
    """Every variable defaults.sh exports."""
    script = f'. "{ROOT}/bare-metal/defaults.sh" >/dev/null 2>&1; compgen -e'
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"{RED}error:{RESET} could not source defaults.sh:\n{r.stderr}",
              file=sys.stderr)
        sys.exit(2)
    return set(r.stdout.split())


def compose_env():
    """{service: {VAR, ...}} from the resolved Compose config, or None."""
    r = subprocess.run(
        ["docker", "compose", "config", "--format", "json"],
        capture_output=True, text=True, cwd=ROOT)
    if r.returncode != 0:
        return None
    services = json.loads(r.stdout).get("services", {})
    return {n: set((s.get("environment") or {}).keys())
            for n, s in services.items()}


def main():
    refs = referenced_vars()
    if not refs:
        print(f"{RED}error:{RESET} no variable references found under config/ "
              "— is the tree intact?", file=sys.stderr)
        return 2

    bm = bare_metal_exports()
    dc = compose_env()

    total = len(set().union(*refs.values()))
    print(f"Checking {total} distinct variables across {len(refs)} config files\n")

    if dc is None:
        print(f"{YELLOW}note:{RESET} docker compose unavailable — "
              f"checking the bare-metal launcher only\n")

    failed = False
    for path, names in refs.items():
        service = SERVICE_OF.get(path, DEFAULT_SERVICE)
        missing_bm = sorted(v for v in names if v not in bm)
        missing_dc = []
        if dc is not None:
            missing_dc = sorted(v for v in names
                                if v not in dc.get(service, set()))

        ok = not missing_bm and not missing_dc
        mark = f"{GREEN}ok  {RESET}" if ok else f"{RED}GAP {RESET}"
        print(f"  {mark} {path} {DIM}({service}){RESET}")
        if missing_bm:
            failed = True
            print(f"         {RED}defaults.sh does not export:{RESET} "
                  f"{', '.join(missing_bm)}")
        if missing_dc:
            failed = True
            print(f"         {RED}compose service '{service}' does not set:"
                  f"{RESET} {', '.join(missing_dc)}")

    if failed:
        print(f"\n{RED}Gaps found.{RESET} Each variable above expands to an "
              "empty string at runtime.\nAdd it to bare-metal/defaults.sh "
              "(and its export list) and to docker-compose.yml.")
        return 1

    scope = "both launchers" if dc is not None else "the bare-metal launcher"
    print(f"\n{GREEN}All referenced variables are supplied by {scope}.{RESET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
