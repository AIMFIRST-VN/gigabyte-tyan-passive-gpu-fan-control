#!/usr/bin/env python3
"""apply-fan-profile.py — install a fan profile on a Gigabyte MZ92-FS0 BMC.

The BMC's fan profile is JSON, but the standard Redfish endpoint *reads* it and
refuses to *write* it (405/400). The web UI uses a proprietary ``/api/`` interface
instead; this tool reproduces exactly that: log in for a CSRF token + session
cookie, snapshot the current profile, write a new one, activate it, and **verify
every write by reading it back**.

Credentials come ONLY from the environment — nothing is hardcoded:

    export BMC_HOST=bmc.example.lan BMC_USER=admin BMC_PASS='your-password'

Usage:
    apply-fan-profile.py status                    # active profile + profile list
    apply-fan-profile.py backup stock-profile.json # snapshot the full fan profile
    apply-fan-profile.py apply my-profile.json     # write a profile document
    apply-fan-profile.py mode <strName>            # activate a profile by name
    apply-fan-profile.py restore stock-profile.json# write a snapshot back

The BMC ships a self-signed cert, so TLS verification is disabled (like the UI).
"""
from __future__ import annotations

import json
import os
import sys

import requests

try:  # silence the self-signed-cert warning (verify=False)
    import urllib3
    urllib3.disable_warnings()
except Exception:
    pass

FANPROFILE = "/api/settings/fanprofile"
MODE = "/api/settings/fanprofile/mode"


class BmcError(RuntimeError):
    pass


class FanBmc:
    """Minimal client for the BMC's proprietary ``/api/`` fan-control interface."""

    def __init__(self, host, user, password, *, verify=False, timeout=20):
        self.base = f"https://{host}"
        self.user, self.password, self.timeout = user, password, timeout
        self.session = requests.Session()
        self.session.verify = verify
        self._csrf = None

    def __enter__(self):
        self._login()
        return self

    def __exit__(self, *exc):
        try:  # invalidate the session server-side so a leaked cookie is useless
            self.session.delete(self.base + "/api/session", headers={"X-CSRFTOKEN": self._csrf}, timeout=self.timeout)
        except Exception:
            pass
        self.session.close()

    def _login(self):
        """(Re)authenticate: POST /api/session -> CSRF token + QSESSIONID cookie."""
        r = self.session.post(
            self.base + "/api/session",
            data={"username": self.user, "password": self.password},
            timeout=self.timeout,
        )
        if r.status_code != 200:
            raise BmcError(f"login failed: HTTP {r.status_code}")
        try:
            self._csrf = r.json().get("CSRFToken")
        except ValueError:
            raise BmcError("login response was not JSON")
        if not self._csrf:
            raise BmcError("no CSRF token in login response")

    def _request(self, method, path, *, body=None):
        """One API call. The BMC session (cookie + CSRF) expires after its idle
        timeout (default ~30 min) -> HTTP 401; on a 401 we re-login once and retry,
        so a long-lived caller never dies on an expired session."""
        def send():
            headers = {"X-CSRFTOKEN": self._csrf}
            data = None
            if body is not None:
                headers["Content-Type"] = "application/json"
                data = json.dumps(body)
            return self.session.request(method, self.base + path, headers=headers, data=data, timeout=self.timeout)

        r = send()
        if r.status_code == 401:            # session/CSRF expired or invalid -> re-auth once
            self._login()
            r = send()
        if r.status_code >= 400:
            raise BmcError(f"HTTP {r.status_code} for {method} {path}")
        try:
            return r.json()
        except ValueError:
            return {}

    # -- reads --
    def get_profile(self):
        return self._request("GET", FANPROFILE)

    def get_mode(self):
        return self._request("GET", MODE).get("strMode")

    # -- writes (each verified by read-back) --
    def set_profile(self, doc):
        self._request("POST", FANPROFILE, body=doc)
        want = {p.get("strName") for p in doc.get("arrProfile", [])}
        got = {p.get("strName") for p in self.get_profile().get("arrProfile", [])}
        if not want <= got:
            raise BmcError(f"write not confirmed — missing profiles: {sorted(want - got)}")

    def set_mode(self, name):
        self._request("POST", MODE, body={"strMode": name})
        now = self.get_mode()
        if now != name:
            raise BmcError(f"activate not confirmed — mode is {now!r}, wanted {name!r}")


def _bmc():
    missing = [k for k in ("BMC_HOST", "BMC_USER", "BMC_PASS") if k not in os.environ]
    if missing:
        sys.exit("error: set these environment variables: " + ", ".join(missing))
    return FanBmc(os.environ["BMC_HOST"], os.environ["BMC_USER"], os.environ["BMC_PASS"])


def main(argv):
    if not argv:
        sys.exit(__doc__)
    cmd, rest = argv[0], argv[1:]
    with _bmc() as bmc:
        if cmd == "status":
            print("active profile:", bmc.get_mode())
            print("profiles:", [p.get("strName") for p in bmc.get_profile().get("arrProfile", [])])
        elif cmd == "backup" and rest:
            with open(rest[0], "w", encoding="utf-8") as fh:
                json.dump(bmc.get_profile(), fh, indent=1)
            print("backed up fan profile ->", rest[0])
        elif cmd == "apply" and rest:
            with open(rest[0], encoding="utf-8") as fh:
                bmc.set_profile(json.load(fh))
            print("applied + verified fan profile from", rest[0])
        elif cmd == "mode" and rest:
            bmc.set_mode(rest[0])
            print("activated profile:", rest[0])
        elif cmd == "restore" and rest:
            with open(rest[0], encoding="utf-8") as fh:
                bmc.set_profile(json.load(fh))
            print("restored fan profile from", rest[0])
        else:
            sys.exit(f"unknown or incomplete command {cmd!r}\n{__doc__}")


if __name__ == "__main__":
    main(sys.argv[1:])
