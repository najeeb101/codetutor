"""The server files of Deploy Step 5 (docs/deploy.md §10) agree with the rest of the repo."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEPLOY = ROOT / "deploy"


def test_caddy_proxies_to_the_published_web_port() -> None:
    makefile = (ROOT / "Makefile").read_text()
    port = re.search(r"^PROD_WEB_PORT \?= (\d+)$", makefile, re.MULTILINE)
    assert port, "PROD_WEB_PORT is not set in the Makefile"
    assert f"reverse_proxy 127.0.0.1:{port.group(1)} {{" in (DEPLOY / "Caddyfile").read_text()


def test_caddy_replaces_the_forwarded_header() -> None:
    # TRUSTED_PROXY_HOPS=1 is only right if Caddy throws the visitor's own header away.
    assert "header_up X-Forwarded-For {remote_host}" in (DEPLOY / "Caddyfile").read_text()


def test_the_setup_script_fills_in_the_domain_placeholder() -> None:
    assert (DEPLOY / "Caddyfile").read_text().count("CODETUTOR_DOMAIN {") == 1
    assert "s/^CODETUTOR_DOMAIN {/$DOMAIN {/" in (DEPLOY / "setup-server.sh").read_text()


def test_caddy_owns_its_log_folder_after_validating() -> None:
    script = (DEPLOY / "setup-server.sh").read_text()
    validate = script.index("caddy validate")
    assert script.index("chown -R caddy:caddy /var/log/caddy", validate) < script.index(
        "systemctl reload-or-restart caddy", validate
    )


def test_the_server_scripts_stop_on_errors_and_are_executable() -> None:
    for name in ("setup-server.sh", "backup.sh", "check-proxy-ip.sh"):
        path = DEPLOY / name
        assert "\nset -euo pipefail\n" in path.read_text(), name
        assert path.stat().st_mode & 0o111, f"{name} is not executable"
