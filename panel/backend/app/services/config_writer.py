"""Write telemt config.toml from template + active users from DB."""
import os
import secrets
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    import tomllib
except ImportError:
    import tomli as tomllib  # type: ignore
import tomli_w

from app.config import settings
from app.models.user import User


def _load_template(path: str | None) -> dict[str, Any]:
    if not path or not os.path.isfile(path):
        return _default_template()
    with open(path, "rb") as f:
        data = tomllib.load(f)
    # Remove panel-managed keys so we can merge cleanly
    if "access" in data:
        for key in ("users", "user_max_tcp_conns", "user_data_quota", "user_expirations", "user_max_unique_ips"):
            data["access"].pop(key, None)
    return data


def _default_template() -> dict[str, Any]:
    # server.port must match Traefik backend (telemt:1234) when running behind Traefik in Docker
    # metrics_port so panel can scrape /metrics (e.g. telemt:9090); whitelist allows Docker network
    return {
        "general": {"fast_mode": True, "use_middle_proxy": False, "modes": {"classic": False, "secure": False, "tls": True}},
        "server": {
            "port": 1234,
            "listen_addr_ipv4": "0.0.0.0",
            "listen_addr_ipv6": "::",
            "metrics_port": 9090,
            "metrics_whitelist": ["0.0.0.0/0"],
        },
        "censorship": {"tls_domain": settings.tls_domain, "mask": True, "mask_port": 443, "fake_cert_len": 2048},
        "access": {"replay_check_len": 65536, "replay_window_secs": 1800, "ignore_time_skew": settings.telemt_ignore_time_skew},
        "upstreams": [{"type": "direct", "enabled": True, "weight": 10}],
    }


def _users_for_config(users: list[User]) -> tuple[dict[str, str], dict[str, int], dict[str, int], dict[str, str], dict[str, int]]:
    """Build access.* dicts for active, non-expired users."""
    now = datetime.now(timezone.utc)
    users_dict: dict[str, str] = {}
    max_tcp: dict[str, int] = {}
    data_quota: dict[str, int] = {}
    expirations: dict[str, str] = {}
    max_ips: dict[str, int] = {}

    for u in users:
        if u.status != "active":
            continue
        if u.expire_at and u.expire_at <= now:
            continue
        users_dict[u.username] = u.secret
        if u.max_connections is not None:
            max_tcp[u.username] = u.max_connections
        if u.data_limit is not None:
            data_quota[u.username] = u.data_limit
        if u.expire_at is not None:
            expirations[u.username] = u.expire_at.strftime("%Y-%m-%dT%H:%M:%SZ")
        if u.max_unique_ips is not None:
            max_ips[u.username] = u.max_unique_ips

    return users_dict, max_tcp, data_quota, expirations, max_ips


def write_config(users: list[User], config_path: str | None = None) -> None:
    path = config_path or settings.telemt_config_path
    if not path:
        return
    template = _load_template(path)
    template.setdefault("server", {})
    template["server"].setdefault("metrics_port", 9090)
    template["server"].setdefault("metrics_whitelist", ["0.0.0.0/0"])
    users_dict, max_tcp, data_quota, expirations, max_ips = _users_for_config(users)

    # When DB has no users yet (first run), keep existing users from file so telemt can start
    if not users_dict and path and os.path.isfile(path):
        try:
            with open(path, "rb") as f:
                existing = tomllib.load(f)
            if existing.get("access", {}).get("users"):
                users_dict = existing["access"]["users"]
        except Exception:
            pass

    template.setdefault("access", {})
    template["access"]["ignore_time_skew"] = settings.telemt_ignore_time_skew
    template["access"]["users"] = users_dict
    template["access"]["user_max_tcp_conns"] = max_tcp
    template["access"]["user_data_quota"] = data_quota
    template["access"]["user_expirations"] = expirations
    template["access"]["user_max_unique_ips"] = max_ips

    dirpath = os.path.dirname(path)
    if dirpath:
        os.makedirs(dirpath, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=dirpath or None, prefix="telemt_", suffix=".toml")
    try:
        with os.fdopen(fd, "wb") as f:
            tomli_w.dump(template, f)
        os.replace(tmp, path)
    except Exception:
        os.unlink(tmp)
        raise


def generate_secret_32hex() -> str:
    return secrets.token_hex(16)
