#!/usr/bin/env python3
"""Offline PTY smoke test of the real pi extension loader and decision UI."""
import fcntl
import os
from pathlib import Path
import pty
import select
import shutil
import struct
import subprocess
import tempfile
import termios
import time

pi = shutil.which("pi")
if not pi:
    raise SystemExit("pi is required")
extension = Path(__file__).resolve().parents[1] / "extensions/decision-selector.ts"
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 0, 0))
with tempfile.TemporaryDirectory(prefix="pi-selector-smoke-") as temp:
    env = {**os.environ, "TERM": "xterm-256color", "PI_CODING_AGENT_DIR": temp, "PI_OFFLINE": "1"}
    proc = subprocess.Popen([
        pi, "--no-extensions", "-e", str(extension), "--no-skills", "--no-context-files",
        "--offline", "--no-session", "--no-approve",
    ], cwd=temp, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    output = bytearray()

    def wait_for(needle, timeout=15):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if select.select([master], [], [], 0.2)[0]:
                chunk = os.read(master, 65536)
                output.extend(chunk)
                # Answer common terminal capability probes deterministically.
                if b"\x1b[6n" in chunk:
                    os.write(master, b"\x1b[1;1R")
                if b"\x1b[c" in chunk:
                    os.write(master, b"\x1b[?1;2c")
                if needle.encode() in output:
                    return
            if proc.poll() is not None:
                break
        raise AssertionError(f"Missing {needle!r} in real TUI output:\n{output.decode(errors='replace')}")

    try:
        wait_for("decision-selector.ts")
        # Allow resource discovery and editor installation to finish.
        time.sleep(1)
        output.clear()
        os.write(master, b"/decision-demo\r")
        wait_for("Consigliata")
        assert b"Risposta libera" in output
        output.clear()
        os.write(master, b"\r")
        wait_for("Piano essenziale")
        output.clear()
        os.write(master, b"/decision-demo\r")
        wait_for("Consigliata")
        output.clear()
        os.write(master, b"\x1b")
        wait_for("Nessuna scelta inviata")
        print("PASS: real pi loader, custom selector, Enter selection and Escape cancellation (offline)")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
        os.close(master)
