#!/usr/bin/env python3
"""Bootstrap OAuth per WHOOP (una tantum).

Prerequisiti sul portale https://developer.whoop.com:
  - un'app con i tuoi Client ID / Client Secret;
  - fra i "Redirect URLs" dell'app deve comparire ESATTAMENTE
    http://localhost:8789/callback (o la porta che passi con --port).

Uso:
  1. crea ~/Library/Application Support/Sketchybar Health/whoop.json con:
       { "client_id": "...", "client_secret": "..." }
     (in alternativa passa --client-id / --client-secret)
  2. python3 whoop_auth.py
  3. autorizza nel browser; il refresh token viene salvato nello stesso file.

Poi ci pensa whoop.py a rinnovare i token da solo.
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
import secrets
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

CONFIG_DIR = os.path.expanduser("~/Library/Application Support/Sketchybar Health")
CONFIG_FILE = os.path.join(CONFIG_DIR, "whoop.json")

AUTH_URL = "https://api.prod.whoop.com/oauth/oauth2/auth"
TOKEN_URL = "https://api.prod.whoop.com/oauth/oauth2/token"
SCOPES = "read:sleep read:recovery read:cycles read:workout read:profile offline"

# Cloudflare davanti a api.prod.whoop.com blocca (403 "error code: 1010") lo
# User-Agent di default di urllib: serve un UA da browser.
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)


def load_config() -> dict:
    try:
        with open(CONFIG_FILE, encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return {}
    except (OSError, json.JSONDecodeError) as error:
        sys.exit(f"Config illeggibile ({CONFIG_FILE}): {error}")


def save_config(config: dict) -> None:
    os.makedirs(CONFIG_DIR, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=CONFIG_DIR, prefix=".whoop.", suffix=".json")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(config, handle, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, CONFIG_FILE)


def exchange_code(config: dict, code: str, redirect_uri: str) -> dict:
    data = urllib.parse.urlencode(
        {
            "grant_type": "authorization_code",
            "code": code,
            "client_id": config["client_id"],
            "client_secret": config["client_secret"],
            "redirect_uri": redirect_uri,
        }
    ).encode()
    request = urllib.request.Request(
        TOKEN_URL,
        data=data,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": USER_AGENT,
            "Accept": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        body = error.read().decode(errors="replace")
        sys.exit(f"Scambio del codice fallito ({error.code}): {body}")
    except urllib.error.URLError as error:
        sys.exit(f"Rete non raggiungibile: {error.reason}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=8789)
    parser.add_argument("--client-id")
    parser.add_argument("--client-secret")
    args = parser.parse_args()

    config = load_config()
    if args.client_id:
        config["client_id"] = args.client_id
    if args.client_secret:
        config["client_secret"] = args.client_secret

    for key in ("client_id", "client_secret"):
        if not config.get(key):
            sys.exit(
                f"Manca '{key}'. Mettilo in {CONFIG_FILE} oppure passalo con --{key.replace('_', '-')}."
            )

    redirect_uri = f"http://localhost:{args.port}/callback"
    state = secrets.token_urlsafe(24)
    auth_query = urllib.parse.urlencode(
        {
            "response_type": "code",
            "client_id": config["client_id"],
            "redirect_uri": redirect_uri,
            "scope": SCOPES,
            "state": state,
        }
    )
    auth_url = f"{AUTH_URL}?{auth_query}"

    result: dict = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):  # silenzia il log di default
            pass

        def do_GET(self):  # noqa: N802 (nome imposto da BaseHTTPRequestHandler)
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path != "/callback":
                self.send_response(404)
                self.end_headers()
                return
            params = urllib.parse.parse_qs(parsed.query)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            if params.get("state", [""])[0] != state:
                self.wfile.write("<h2>state non valido, riprova.</h2>".encode())
                result["error"] = "state mismatch"
            elif "code" in params:
                result["code"] = params["code"][0]
                self.wfile.write(
                    "<h2>WHOOP collegato. Puoi chiudere questa scheda.</h2>".encode()
                )
            else:
                result["error"] = params.get("error", ["risposta senza code"])[0]
                self.wfile.write(f"<h2>Errore: {result['error']}</h2>".encode())

    server = http.server.HTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Redirect URI da registrare sull'app WHOOP: {redirect_uri}")
    print("Apro il browser per l'autorizzazione...")
    if not webbrowser.open(auth_url):
        print(f"Apri manualmente:\n{auth_url}")

    while "code" not in result and "error" not in result:
        server.handle_request()
    server.server_close()

    if "error" in result:
        sys.exit(f"Autorizzazione fallita: {result['error']}")

    payload = exchange_code(config, result["code"], redirect_uri)
    if not payload.get("refresh_token"):
        sys.exit(
            "Nessun refresh_token nella risposta: assicurati che lo scope 'offline' "
            f"sia abilitato per l'app. Risposta: {payload}"
        )

    config["access_token"] = payload.get("access_token")
    config["refresh_token"] = payload["refresh_token"]
    config["access_token_expires_at"] = __import__("time").time() + int(
        payload.get("expires_in", 3600)
    )
    save_config(config)
    print(f"OK. Token salvati in {CONFIG_FILE}")


if __name__ == "__main__":
    main()
