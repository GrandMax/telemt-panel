"""Scrape telemt Prometheus /metrics and persist to DB."""
import re
from datetime import datetime, timezone
from typing import Any

import httpx
from sqlalchemy.orm import Session

from app.config import settings
from app.models.user import User
from app.models.stats import TrafficLog, SystemStats
from app.services.config_writer import write_config


# Prometheus text format: telemt_user_octets_from_client{user="alice"} 12345
METRIC_PATTERN = re.compile(
    r'telemt_user_octets_from_client\{user="([^"]+)"\}\s+(\d+)'
)
METRIC_TO_PATTERN = re.compile(
    r'telemt_user_octets_to_client\{user="([^"]+)"\}\s+(\d+)'
)
UPTIME_PATTERN = re.compile(r"telemt_uptime_seconds\s+([\d.]+)")
CONNECTIONS_PATTERN = re.compile(r"telemt_connections_total\s+(\d+)")
BAD_CONNECTIONS_PATTERN = re.compile(r"telemt_connections_bad_total\s+(\d+)")
UNIQUE_IPS_ACTIVE_PATTERN = re.compile(
    r'telemt_user_unique_ips_active\{user="([^"]+)"\}\s+(\d+)'
)


def parse_metrics(text: str) -> dict[str, Any]:
    """Parse Prometheus metrics text. Returns dict with user octets and system stats."""
    result: dict[str, Any] = {
        "octets_from": {},
        "octets_to": {},
        "uptime": 0.0,
        "total_connections": 0,
        "bad_connections": 0,
        "unique_ips_active": {},
    }
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = METRIC_PATTERN.match(line)
        if m:
            result["octets_from"][m.group(1)] = int(m.group(2))
            continue
        m = METRIC_TO_PATTERN.match(line)
        if m:
            result["octets_to"][m.group(1)] = int(m.group(2))
            continue
        m = UPTIME_PATTERN.match(line)
        if m:
            result["uptime"] = float(m.group(1))
            continue
        m = CONNECTIONS_PATTERN.match(line)
        if m:
            result["total_connections"] = int(m.group(1))
            continue
        m = BAD_CONNECTIONS_PATTERN.match(line)
        if m:
            result["bad_connections"] = int(m.group(1))
            continue
        m = UNIQUE_IPS_ACTIVE_PATTERN.match(line)
        if m:
            result["unique_ips_active"][m.group(1)] = int(m.group(2))
    return result


async def fetch_metrics() -> str:
    """Fetch raw /metrics from telemt."""
    async with httpx.AsyncClient(timeout=10.0) as client:
        r = await client.get(settings.telemt_metrics_url)
        r.raise_for_status()
        return r.text


def scrape_and_persist(db: Session, metrics_text: str, last_values: dict[str, tuple[int, int]]) -> dict[str, tuple[int, int]]:
    """
    Parse metrics, compute deltas from last_values, persist to traffic_logs and users.data_used.
    Returns new last_values (username -> (octets_from, octets_to)) for next run.
    """
    parsed = parse_metrics(metrics_text)
    now = datetime.now(timezone.utc)
    new_last: dict[str, tuple[int, int]] = {}

    all_users = set(parsed["octets_from"]) | set(parsed["octets_to"])
    users_for_ip_update = all_users | set(parsed.get("unique_ips_active", {}))
    for username in all_users:
        from_val = parsed["octets_from"].get(username, 0)
        to_val = parsed["octets_to"].get(username, 0)
        new_last[username] = (from_val, to_val)
        prev = last_values.get(username, (0, 0))
        delta_from = from_val - prev[0]
        delta_to = to_val - prev[1]
        if delta_from <= 0 and delta_to <= 0:
            continue
        user = db.query(User).filter(User.username == username).first()
        if not user:
            continue
        # Persist delta to traffic_logs
        db.add(
            TrafficLog(
                user_id=user.id,
                octets_from=delta_from,
                octets_to=delta_to,
                recorded_at=now,
            )
        )
        # Update user.data_used (cumulative)
        user.data_used = (user.data_used or 0) + delta_from + delta_to
        user.last_seen_at = now
        # Enforce data_limit: set status to limited and exclude from config
        if user.data_limit is not None and user.data_used >= user.data_limit:
            user.status = "limited"

    unique_ips = parsed.get("unique_ips_active", {})
    for username in users_for_ip_update:
        user = db.query(User).filter(User.username == username).first()
        if user:
            user.active_unique_ips = unique_ips.get(username)

    db.add(
        SystemStats(
            uptime=parsed["uptime"],
            total_connections=parsed["total_connections"],
            bad_connections=parsed["bad_connections"],
            recorded_at=now,
        )
    )
    db.commit()
    # Regenerate config so limited users are removed from telemt
    from app.services.user_service import get_active_users_for_config  # noqa: PLC0415
    write_config(get_active_users_for_config(db))
    return new_last
