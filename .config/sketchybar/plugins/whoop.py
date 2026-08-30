#!/usr/bin/env python3
"""Aggiorna lo stato salute (WHOOP) per la barra Swift.

Legge le credenziali OAuth da ~/Library/Application Support/Sketchybar Health/
whoop.json, rinnova l'access token quando serve (persistendo atomicamente il
nuovo refresh token, che WHOOP ruota ad ogni refresh) e salva sonno, recovery e
strain più recenti in /tmp/sketchybar_health_state.json.

Nessuna dipendenza esterna: solo urllib della standard library. Il bootstrap
iniziale (primo refresh token) si fa una volta con whoop_auth.py.
"""

from __future__ import annotations

import fcntl
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

CONFIG_DIR = os.path.expanduser("~/Library/Application Support/Sketchybar Health")
CONFIG_FILE = os.path.join(CONFIG_DIR, "whoop.json")
STATE_FILE = "/tmp/sketchybar_health_state.json"
LOCK_FILE = "/tmp/sketchybar_whoop.lock"

TOKEN_URL = "https://api.prod.whoop.com/oauth/oauth2/token"
API_BASE = "https://api.prod.whoop.com/developer/v2"

# api.prod.whoop.com è dietro Cloudflare, che risponde 403 "error code: 1010"
# allo User-Agent di default di urllib. Serve un UA da browser.
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)

# Margine di sicurezza: rinnova un po' prima della scadenza dichiarata.
EXPIRY_MARGIN_SECONDS = 120
HTTP_TIMEOUT = 12


def _now() -> float:
    return time.time()


def _load_config() -> dict:
    try:
        with open(CONFIG_FILE, encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        _fail(f"Config mancante: {CONFIG_FILE}. Esegui whoop_auth.py.")
    except (OSError, json.JSONDecodeError) as error:
        _fail(f"Config illeggibile: {error}")
    return {}


def _save_config(config: dict) -> None:
    os.makedirs(CONFIG_DIR, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=CONFIG_DIR, prefix=".whoop.", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(config, handle, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, CONFIG_FILE)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _post_form(url: str, fields: dict) -> dict:
    data = urllib.parse.urlencode(fields).encode()
    request = urllib.request.Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": USER_AGENT,
            "Accept": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
        return json.load(response)


def _get_json(path: str, token: str, params: dict | None = None) -> dict:
    url = f"{API_BASE}{path}"
    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "User-Agent": USER_AGENT,
            "Accept": "application/json",
        },
        method="GET",
    )
    with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
        return json.load(response)


def _refresh_access_token(config: dict) -> str:
    refresh_token = config.get("refresh_token")
    if not refresh_token:
        _fail("Nessun refresh_token in config. Esegui whoop_auth.py.")

    try:
        payload = _post_form(
            TOKEN_URL,
            {
                "grant_type": "refresh_token",
                "refresh_token": refresh_token,
                "client_id": config["client_id"],
                "client_secret": config["client_secret"],
                "scope": "offline",
            },
        )
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")
        _fail(f"Refresh token rifiutato ({error.code}): {body}")
    except urllib.error.URLError as error:
        _fail(f"Rete non raggiungibile durante il refresh: {error.reason}")

    access_token = payload.get("access_token")
    if not access_token:
        _fail(f"Risposta di refresh senza access_token: {payload}")

    config["access_token"] = access_token
    # WHOOP restituisce un nuovo refresh token ad ogni giro: va salvato subito,
    # il vecchio è già invalidato.
    if payload.get("refresh_token"):
        config["refresh_token"] = payload["refresh_token"]
    expires_in = int(payload.get("expires_in", 3600))
    config["access_token_expires_at"] = _now() + expires_in
    _save_config(config)
    return access_token


def _valid_access_token(config: dict) -> str:
    token = config.get("access_token")
    expires_at = config.get("access_token_expires_at", 0)
    if token and _now() < float(expires_at) - EXPIRY_MARGIN_SECONDS:
        return token
    return _refresh_access_token(config)


def _round(value, digits=0):
    if value is None:
        return None
    try:
        number = round(float(value), digits)
        return int(number) if digits == 0 else number
    except (TypeError, ValueError):
        return None


def _latest_scored(records: list) -> dict | None:
    for record in records:
        if record.get("score_state") == "SCORED" and record.get("score"):
            return record
    return records[0] if records else None


def _sleep_summary(token: str) -> dict:
    # limit alto e nap escluse: la notte principale è la prima non-nap.
    data = _get_json(token=token, path="/activity/sleep", params={"limit": 25})
    records = [r for r in data.get("records", []) if not r.get("nap")]
    record = _latest_scored(records)
    if not record:
        return {}

    score = record.get("score") or {}
    stages = score.get("stage_summary") or {}
    in_bed_ms = stages.get("total_in_bed_time_milli") or 0
    awake_ms = stages.get("total_awake_time_milli") or 0
    asleep_hours = max(in_bed_ms - awake_ms, 0) / 3_600_000

    return {
        "performance": _round(score.get("sleep_performance_percentage")),
        "efficiency": _round(score.get("sleep_efficiency_percentage")),
        "consistency": _round(score.get("sleep_consistency_percentage")),
        "respiratory_rate": _round(score.get("respiratory_rate"), 1),
        "asleep_hours": _round(asleep_hours, 1),
        "rem_hours": _round((stages.get("total_rem_sleep_time_milli") or 0) / 3_600_000, 1),
        "sws_hours": _round(
            (stages.get("total_slow_wave_sleep_time_milli") or 0) / 3_600_000, 1
        ),
        "start": record.get("start"),
        "end": record.get("end"),
    }


def _recovery_summary(token: str) -> dict:
    data = _get_json(token=token, path="/recovery", params={"limit": 1})
    records = data.get("records", [])
    record = _latest_scored(records)
    if not record:
        return {}
    score = record.get("score") or {}
    return {
        "score": _round(score.get("recovery_score")),
        "resting_heart_rate": _round(score.get("resting_heart_rate")),
        "hrv_ms": _round(score.get("hrv_rmssd_milli"), 1),
    }


def _strain_summary(token: str) -> dict:
    data = _get_json(token=token, path="/cycle", params={"limit": 1})
    records = data.get("records", [])
    record = _latest_scored(records)
    if not record:
        return {}
    score = record.get("score") or {}
    return {
        "score": _round(score.get("strain"), 1),
        "average_heart_rate": _round(score.get("average_heart_rate")),
    }


def _week_start_iso() -> str:
    """Lunedì 00:00 (ora locale) della settimana corrente, in UTC ISO-8601."""
    local_now = datetime.now().astimezone()
    monday_local = (local_now - timedelta(days=local_now.weekday())).replace(
        hour=0, minute=0, second=0, microsecond=0
    )
    return monday_local.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _duration_seconds(start, end) -> float:
    if not start or not end:
        return 0.0
    try:
        began = datetime.fromisoformat(start.replace("Z", "+00:00"))
        ended = datetime.fromisoformat(end.replace("Z", "+00:00"))
        return max((ended - began).total_seconds(), 0.0)
    except ValueError:
        return 0.0


def _workouts_summary(token: str) -> dict:
    week_start = _week_start_iso()
    data = _get_json(
        token=token,
        path="/activity/workout",
        params={"limit": 25, "start": week_start},
    )

    items = []
    total_strain = 0.0
    total_kilojoule = 0.0
    total_seconds = 0.0

    for record in data.get("records", []):
        if record.get("score_state") != "SCORED":
            continue
        score = record.get("score") or {}
        start = record.get("start")
        end = record.get("end")
        seconds = _duration_seconds(start, end)
        strain = score.get("strain")
        kilojoule = score.get("kilojoule")
        distance = score.get("distance_meter")

        items.append(
            {
                "sport": record.get("sport_name") or "Allenamento",
                "start": start,
                "end": end,
                "minutes": _round(seconds / 60) if seconds else None,
                "strain": _round(strain, 1),
                "avg_hr": _round(score.get("average_heart_rate")),
                "max_hr": _round(score.get("max_heart_rate")),
                "kcal": _round(kilojoule / 4.184) if kilojoule else None,
                "distance_km": _round(distance / 1000, 2) if distance else None,
            }
        )
        if strain:
            total_strain += float(strain)
        if kilojoule:
            total_kilojoule += float(kilojoule)
        total_seconds += seconds

    items.sort(key=lambda item: item.get("start") or "", reverse=True)

    return {
        "week_start": week_start[:10],
        "count": len(items),
        "total_strain": _round(total_strain, 1),
        "total_kcal": _round(total_kilojoule / 4.184) if total_kilojoule else 0,
        "total_minutes": _round(total_seconds / 60) if total_seconds else 0,
        "items": items,
    }


def _write_state(state: dict) -> None:
    fd, tmp = tempfile.mkstemp(prefix="sketchybar_health_state_", suffix=".json")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(state, handle)
    os.replace(tmp, STATE_FILE)


def _load_state() -> dict:
    try:
        with open(STATE_FILE, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {}


def _fail(message: str) -> None:
    """Segnala l'errore mantenendo l'ultimo stato buono, se esiste."""
    print(f"whoop.py: {message}", file=sys.stderr)
    state = _load_state()
    state["error"] = message
    state["error_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    try:
        _write_state(state)
    except OSError:
        pass
    sys.exit(1)


def main() -> None:
    # Un solo fetch alla volta: la barra e l'archiviatore possono partire
    # insieme e un doppio refresh brucerebbe il refresh token appena ruotato.
    lock_handle = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("whoop.py: altra esecuzione in corso, esco.", file=sys.stderr)
        return

    config = _load_config()
    for key in ("client_id", "client_secret"):
        if not config.get(key):
            _fail(f"Config senza '{key}'. Esegui whoop_auth.py.")

    token = _valid_access_token(config)

    try:
        sleep = _sleep_summary(token)
        recovery = _recovery_summary(token)
        strain = _strain_summary(token)
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")
        _fail(f"API WHOOP {error.code}: {body}")
    except urllib.error.URLError as error:
        _fail(f"Rete non raggiungibile: {error.reason}")

    # I workout richiedono lo scope read:workout: se manca (token generato prima
    # di aggiungerlo) o la chiamata fallisce, il resto dello stato si salva
    # comunque.
    try:
        workouts = _workouts_summary(token)
    except (urllib.error.HTTPError, urllib.error.URLError, ValueError, KeyError) as error:
        print(f"whoop.py: workout non disponibili: {error}", file=sys.stderr)
        workouts = {}

    state = {
        "updated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "sleep": sleep,
        "recovery": recovery,
        "strain": strain,
        "workouts": workouts,
        "error": None,
    }
    _write_state(state)
    print(json.dumps(state, indent=2))


if __name__ == "__main__":
    main()
