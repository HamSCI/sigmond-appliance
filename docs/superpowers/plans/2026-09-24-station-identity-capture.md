# Station identity — Plan 1: capture and check

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put every reachable station's identity into the ops repository, encrypted, and give operators a command that says whether a live station still matches it.

**Architecture:** sigmond gains one standard-library module, `lib/sigmond/identity.py`, that holds the single list of identity files and can export them as a tar or describe them as a manifest. The devbox tool `ops/bin/site-identity` pipes that module's source to `python3 -` on each plane of a station (the Proxmox host through `reach`, the VM through `reach` then `hop`), encrypts the result with `age` to `sigmond-appliance/operators/*.pub`, and commits it under `ops/site-deltas/<site>/`.

**Tech Stack:** Python 3.11+ standard library (`tarfile`, `tomllib`, `hashlib`, `glob`), the `age` CLI on the devbox, OpenSSH, pytest.

**Spec:** `sigmond-appliance/docs/superpowers/specs/2026-09-24-station-identity-design.md`

## Scope, and one departure from the spec

This plan covers the spec's order-of-work steps 1 and 2 only.  Plan 2 covers the installer restore (v3.53) and Plan 3 the RAC reuse branch with Rob.  Neither exists yet.

Spec §4 names station-side verbs `smd admin identity export|fingerprints`.  This plan does not add them.  The Proxmox host carries `python3` but no `smd`, and a station runs whatever sigmond it shipped with, so a new smd verb would not exist on B4 until a deploy.  Piping the module's source works on every station today, on both planes, and still keeps the file list in one place.  Plan 2 adds `smd admin identity restore`, and the other two verbs with it if they earn a use.

## Global Constraints

- `identity.py` imports the Python standard library only, and runs under Python 3.11 or newer (`tomllib`).  It must work when fed to `python3 -` on stdin, with no sigmond installed.
- `identity.py` only reads.  No mode, owner or file on a station changes.
- A manifest carries no secret values: paths, owners, modes, SHA-256 digests and SSH fingerprints only.  The RAC credential appears as a list of field names plus one digest.
- Plaintext identity never touches the devbox disk.  The bundle lives in memory from the ssh read to the `age` encrypt.
- Encryption recipients come from `~/hamsci/repos/sigmond-appliance/operators/*.pub`, every line that starts with `ssh-`.
- `site-identity` resolves reach and hop through `sigmond.fleet.load_fleet` and `ops/fleet.toml`, never a retyped address.  It acts on ONE named site per run and refuses a host marked frozen, the same wall `ops/bin/fleet-ssh` keeps.
- The VM plane runs as root through `sudo -n`.  `smd` never gets wrapped in sudo (it refuses to run that way).
- Commits: develop on main; end each message with the attribution lines the session gives.  Nothing gets pushed by this plan.

## File map

| File | Repo | Responsibility |
|---|---|---|
| `lib/sigmond/identity.py` (create) | sigmond | the identity file list; manifest; tar export; CLI |
| `tests/test_identity.py` (create) | sigmond | unit tests against a temporary root |
| `bin/site-identity` (create) | ops | capture, check; reach resolution; age; commit |
| `tests/test_site_identity.py` (create) | ops | unit tests with a fake remote runner and a throwaway age recipient |
| `site-deltas/<site>/identity.age`, `identity.manifest` (generated) | ops | the committed bundle |

---

### Task 0: Install `age` on the devbox

The operator does this; auto mode cannot run `sudo apt`.

- [ ] **Step 1: Install**

Ask Michael to run: `! sudo apt-get install -y age`

- [ ] **Step 2: Confirm it reads SSH recipients**

Run: `age --version && ssh-keygen -q -t ed25519 -N '' -f /tmp/claude-age-probe && echo hi | age -R /tmp/claude-age-probe.pub | age -d -i /tmp/claude-age-probe && rm -f /tmp/claude-age-probe /tmp/claude-age-probe.pub`
Expected: a version line, then `hi`.

---

### Task 1: `identity.py` — the file list and the manifest

**Files:**
- Create: `~/hamsci/repos/sigmond/lib/sigmond/identity.py`
- Test: `~/hamsci/repos/sigmond/tests/test_identity.py`

**Interfaces:**
- Produces: `PLANES = ("vm", "pm")`; `FILE_PATTERNS: dict[str, tuple[str, ...]]`; `matched_files(plane: str, root: str) -> list[str]` (root-relative paths); `ssh_fingerprint(pub_text: str) -> str | None`; `manifest(plane: str, root: str = "/") -> dict` with keys `schema`, `plane`, `files` (list of dicts with `path`, `owner`, `group`, `mode`, `sha256`, and `ssh_fingerprint` on `.pub` files), and on `pm` also `rac_credential`.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_identity.py`:

```python
"""Tests for sigmond.identity — the station identity file list.

Every test builds a fake station under a temporary root; nothing touches /etc.
"""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from sigmond import identity


def _keygen(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(path)],
                   check=True)


def _vm_root(tmp: Path) -> Path:
    root = tmp / "vm"
    _keygen(root / "etc/ssh/ssh_host_ed25519_key")
    _keygen(root / "etc/hs-uploader/keys/id_ed25519_host")
    (root / "home/timestd/.ssh").mkdir(parents=True)
    # Neither of these is identity; both must stay out.
    (root / "home/timestd/.ssh/known_hosts").write_text("x\n")
    (root / "etc/ssh/sshd_config").write_text("Port 22\n")
    return root


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_vm_manifest_lists_host_and_uploader_keys_only(self):
        root = _vm_root(self.tmp)
        paths = {e["path"] for e in identity.manifest("vm", str(root))["files"]}
        self.assertEqual(paths, {
            "/etc/ssh/ssh_host_ed25519_key",
            "/etc/ssh/ssh_host_ed25519_key.pub",
            "/etc/hs-uploader/keys/id_ed25519_host",
            "/etc/hs-uploader/keys/id_ed25519_host.pub",
        })

    def test_pub_fingerprint_matches_ssh_keygen(self):
        root = _vm_root(self.tmp)
        pub = root / "etc/ssh/ssh_host_ed25519_key.pub"
        want = subprocess.run(["ssh-keygen", "-lf", str(pub)], check=True,
                              capture_output=True, text=True).stdout.split()[1]
        entry = next(e for e in identity.manifest("vm", str(root))["files"]
                     if e["path"] == "/etc/ssh/ssh_host_ed25519_key.pub")
        self.assertEqual(entry["ssh_fingerprint"], want)

    def test_manifest_records_mode(self):
        root = _vm_root(self.tmp)
        os.chmod(root / "etc/ssh/ssh_host_ed25519_key", 0o600)
        entry = next(e for e in identity.manifest("vm", str(root))["files"]
                     if e["path"] == "/etc/ssh/ssh_host_ed25519_key")
        self.assertEqual(entry["mode"], "0600")

    def test_manifest_holds_no_private_key_bytes(self):
        root = _vm_root(self.tmp)
        secret = (root / "etc/ssh/ssh_host_ed25519_key").read_text()
        body = [l for l in secret.splitlines() if l and not l.startswith("-----")]
        text = json.dumps(identity.manifest("vm", str(root)))
        for line in body:
            self.assertNotIn(line, text)

    def test_missing_optional_files_are_simply_absent(self):
        root = self.tmp / "bare"
        root.mkdir()
        self.assertEqual(identity.manifest("vm", str(root))["files"], [])

    def test_unknown_plane_refused(self):
        with self.assertRaises(ValueError):
            identity.manifest("dom0", str(self.tmp))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ~/hamsci/repos/sigmond && .venv/bin/python -m pytest tests/test_identity.py -v --override-ini addopts=`
Expected: collection ERROR, `ImportError: cannot import name 'identity' from 'sigmond'`.

- [ ] **Step 3: Write the minimal implementation**

Create `lib/sigmond/identity.py`:

```python
"""Station identity — the files a station minted that others have learned to trust.

Host keys, the uploader key, the RAC credential.  When a reflash mints new ones,
every party that trusted the old ones stops trusting the station: operators'
known_hosts, the wd30 heartbeat account, PSWS, gw2.  This module holds the ONE
list of those files.  Capture reads it now; the installer's restore will read it
in Plan 2, so the two can never drift apart.

Standard library only, Python 3.11+.  ops/bin/site-identity pipes this file's
source to `python3 -` on stations that may carry no sigmond at all — the
Proxmox host has none.  It only reads.

Design: sigmond-appliance/docs/superpowers/specs/2026-09-24-station-identity-design.md
"""
from __future__ import annotations

import argparse
import base64
import glob
import grp
import hashlib
import io
import json
import os
import pwd
import stat
import sys
import tarfile
import tomllib

SCHEMA = 1
PLANES = ("vm", "pm")

# Root-relative glob patterns, per plane.  known_hosts and authorized_keys stay
# out: they record whom the station trusts, not who the station is.
FILE_PATTERNS: dict[str, tuple[str, ...]] = {
    "vm": (
        "etc/ssh/ssh_host_*",
        "etc/hs-uploader/keys/id_*",
        "home/timestd/.ssh/id_*",
    ),
    "pm": (
        "etc/ssh/ssh_host_*",
        # Rides every RAC login as [metadatas] pubkey, and the VM's sigmond
        # account trusts it for the PM -> VM hop.
        "root/.ssh/id_ed25519",
        "root/.ssh/id_ed25519.pub",
    ),
}

RAC_CONFIG = "etc/sigmond/frpc-host.toml"            # pm only
RAC_FIELDS = (("user",), ("auth", "method"), ("auth", "token"))
RAC_MEMBER = "identity/rac-credential.json"
MANIFEST_MEMBER = "identity/manifest.json"


def _check_plane(plane: str) -> None:
    if plane not in PLANES:
        raise ValueError(f"unknown plane {plane!r}; expected one of {PLANES}")


def matched_files(plane: str, root: str) -> list[str]:
    """Regular files (never symlinks) matching the plane's patterns, root-relative."""
    _check_plane(plane)
    found = set()
    for pattern in FILE_PATTERNS[plane]:
        for path in glob.glob(os.path.join(root, pattern)):
            if os.path.isfile(path) and not os.path.islink(path):
                found.add(os.path.relpath(path, root))
    return sorted(found)


def ssh_fingerprint(pub_text: str) -> str | None:
    """The SHA256:... fingerprint `ssh-keygen -lf` prints, from a .pub line."""
    parts = pub_text.split()
    if len(parts) < 2:
        return None
    try:
        blob = base64.b64decode(parts[1], validate=True)
    except ValueError:
        return None
    digest = base64.b64encode(hashlib.sha256(blob).digest()).decode()
    return "SHA256:" + digest.rstrip("=")


def _name(lookup, ident: int) -> str:
    try:
        return lookup(ident)[0]
    except KeyError:
        return str(ident)


def _file_entry(root: str, rel: str) -> dict:
    path = os.path.join(root, rel)
    st = os.stat(path)
    with open(path, "rb") as f:
        data = f.read()
    entry = {
        "path": "/" + rel,
        "owner": _name(pwd.getpwuid, st.st_uid),
        "group": _name(grp.getgrgid, st.st_gid),
        "mode": format(stat.S_IMODE(st.st_mode), "04o"),
        # A digest of a private key reveals nothing, and lets check() see a
        # changed private half even where no .pub sits beside it.
        "sha256": hashlib.sha256(data).hexdigest(),
    }
    if rel.endswith(".pub"):
        fp = ssh_fingerprint(data.decode("utf-8", "replace"))
        if fp:
            entry["ssh_fingerprint"] = fp
    return entry


def _canonical(obj) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()


def rac_credential(root: str) -> dict | None:
    """The credential lines of frpc-host.toml, keyed 'user', 'auth.method', 'auth.token'.

    Only these.  The proxy list gets regenerated from the station's layout, and
    a restored list could contradict a changed layout.
    """
    path = os.path.join(root, RAC_CONFIG)
    if not os.path.isfile(path):
        return None
    with open(path, "rb") as f:
        doc = tomllib.load(f)
    cred = {}
    for keys in RAC_FIELDS:
        node = doc
        for key in keys:
            node = node.get(key) if isinstance(node, dict) else None
        if node is not None:
            cred[".".join(keys)] = node
    return cred or None


def manifest(plane: str, root: str = "/") -> dict:
    """Describe the plane's identity without carrying any secret value."""
    _check_plane(plane)
    m = {
        "schema": SCHEMA,
        "plane": plane,
        "files": [_file_entry(root, rel) for rel in matched_files(plane, root)],
    }
    if plane == "pm":
        cred = rac_credential(root)
        m["rac_credential"] = None if cred is None else {
            "fields": sorted(cred),
            "sha256": hashlib.sha256(_canonical(cred)).hexdigest(),
        }
    return m
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ~/hamsci/repos/sigmond && .venv/bin/python -m pytest tests/test_identity.py -v --override-ini addopts=`
Expected: 6 passed.

- [ ] **Step 5: Mutation check — watch the key test fail**

Temporarily delete the line `"etc/ssh/ssh_host_*",` from the `"vm"` tuple.  Re-run the Step 4 command.
Expected: `test_vm_manifest_lists_host_and_uploader_keys_only` and `test_pub_fingerprint_matches_ssh_keygen` FAIL.  Restore the line and confirm 6 pass again.

- [ ] **Step 6: Commit**

```bash
cd ~/hamsci/repos/sigmond
git add lib/sigmond/identity.py tests/test_identity.py
git commit -m "identity: one list of the files a station's identity lives in

Host keys, uploader keys and (Task 2) the RAC credential, described by a
manifest that carries no secret values. Standard library only, so the
devbox can pipe it to python3 on a Proxmox host with no sigmond."
```

---

### Task 2: the RAC credential on the PM plane

**Files:**
- Modify: `~/hamsci/repos/sigmond/tests/test_identity.py` (add a class)
- (`identity.py` already carries `rac_credential`; this task proves it.)

**Interfaces:**
- Consumes: `identity.rac_credential(root) -> dict | None`, `identity.manifest("pm", root)`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_identity.py`, above the `if __name__` block:

```python
FRPC = """\
serverAddr = "gw.example"
serverPort = 35736
user = "0123456789abcdef"

[metadatas]
pubkey = "ssh-ed25519 AAAA..."
site = "TEST_SITE"

[auth]
method = "token"
token = "s3cret-token-value"

[[proxies]]
name = "TEST_SITE-host-ssh"
"""


class RacCredentialTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        (self.root / "etc/sigmond").mkdir(parents=True)
        (self.root / "etc/sigmond/frpc-host.toml").write_text(FRPC)
        _keygen(self.root / "etc/ssh/ssh_host_ed25519_key")

    def tearDown(self):
        self._tmp.cleanup()

    def test_only_credential_fields_are_taken(self):
        self.assertEqual(identity.rac_credential(str(self.root)), {
            "user": "0123456789abcdef",
            "auth.method": "token",
            "auth.token": "s3cret-token-value",
        })

    def test_pm_manifest_names_fields_but_holds_no_values(self):
        m = identity.manifest("pm", str(self.root))
        self.assertEqual(m["rac_credential"]["fields"],
                         ["auth.method", "auth.token", "user"])
        text = json.dumps(m)
        self.assertNotIn("s3cret-token-value", text)
        self.assertNotIn("0123456789abcdef", text)

    def test_pm_without_rac_config_records_none(self):
        (self.root / "etc/sigmond/frpc-host.toml").unlink()
        self.assertIsNone(identity.manifest("pm", str(self.root))["rac_credential"])

    def test_token_change_changes_the_digest(self):
        before = identity.manifest("pm", str(self.root))["rac_credential"]["sha256"]
        (self.root / "etc/sigmond/frpc-host.toml").write_text(
            FRPC.replace("s3cret-token-value", "another-token"))
        after = identity.manifest("pm", str(self.root))["rac_credential"]["sha256"]
        self.assertNotEqual(before, after)
```

- [ ] **Step 2: Run to see them pass, then prove they can fail**

Run: `cd ~/hamsci/repos/sigmond && .venv/bin/python -m pytest tests/test_identity.py -v --override-ini addopts=`
Expected: 10 passed.  Task 1 already wrote the code, so these tests must now show they can fail.  Change `RAC_FIELDS` to `(("user",),)` and re-run.
Expected: `test_only_credential_fields_are_taken`, `test_pm_manifest_names_fields_but_holds_no_values` and `test_token_change_changes_the_digest` FAIL.  Restore `RAC_FIELDS`; 10 pass.

- [ ] **Step 3: Commit**

```bash
cd ~/hamsci/repos/sigmond
git add tests/test_identity.py
git commit -m "identity: tests for the RAC credential — fields in, values never in the manifest"
```

---

### Task 3: tar export and the piped-source CLI

**Files:**
- Modify: `~/hamsci/repos/sigmond/lib/sigmond/identity.py` (append)
- Modify: `~/hamsci/repos/sigmond/tests/test_identity.py` (add a class)

**Interfaces:**
- Consumes: `manifest`, `rac_credential`, `RAC_MEMBER`, `MANIFEST_MEMBER`.
- Produces: `export(plane: str, out: BinaryIO, root: str = "/") -> dict` (writes an uncompressed tar stream; returns the manifest); `main(argv: list[str] | None = None) -> int` with verbs `export --plane P [--root R]` (tar to stdout) and `fingerprints --plane P [--root R]` (manifest JSON to stdout).  Tar members: each identity file at its root-relative path with owner, group and mode preserved; on pm, `identity/rac-credential.json`; always `identity/manifest.json` last.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_identity.py`, above the `if __name__` block:

```python
import io
import sys
import tarfile

IDENTITY_SRC = Path(identity.__file__).read_bytes()


class ExportTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_export_round_trip_keeps_content_and_mode(self):
        root = _vm_root(self.tmp)
        os.chmod(root / "etc/ssh/ssh_host_ed25519_key", 0o600)
        buf = io.BytesIO()
        m = identity.export("vm", buf, str(root))
        buf.seek(0)
        with tarfile.open(fileobj=buf) as tar:
            names = tar.getnames()
            key = tar.getmember("etc/ssh/ssh_host_ed25519_key")
            self.assertEqual(key.mode, 0o600)
            self.assertEqual(tar.extractfile(key).read(),
                             (root / "etc/ssh/ssh_host_ed25519_key").read_bytes())
            inner = json.loads(tar.extractfile(identity.MANIFEST_MEMBER).read())
        self.assertEqual(names[-1], identity.MANIFEST_MEMBER)
        self.assertEqual({n for n in names if not n.startswith("identity/")},
                         {e["path"].lstrip("/") for e in m["files"]})
        self.assertEqual(inner, m)

    def test_pm_export_carries_the_credential_member(self):
        root = self.tmp / "pm"
        (root / "etc/sigmond").mkdir(parents=True)
        (root / "etc/sigmond/frpc-host.toml").write_text(FRPC)
        buf = io.BytesIO()
        identity.export("pm", buf, str(root))
        buf.seek(0)
        with tarfile.open(fileobj=buf) as tar:
            member = tar.getmember(identity.RAC_MEMBER)
            cred = json.loads(tar.extractfile(member).read())
        self.assertEqual(member.mode, 0o600)
        self.assertEqual(cred["auth.token"], "s3cret-token-value")

    def test_fingerprints_runs_from_piped_source(self):
        # Exactly how site-identity runs it on a station with no sigmond.
        root = _vm_root(self.tmp)
        out = subprocess.run(
            [sys.executable, "-", "fingerprints", "--plane", "vm", "--root", str(root)],
            input=IDENTITY_SRC, capture_output=True, check=True)
        self.assertEqual(json.loads(out.stdout), identity.manifest("vm", str(root)))

    def test_export_runs_from_piped_source(self):
        root = _vm_root(self.tmp)
        out = subprocess.run(
            [sys.executable, "-", "export", "--plane", "vm", "--root", str(root)],
            input=IDENTITY_SRC, capture_output=True, check=True)
        with tarfile.open(fileobj=io.BytesIO(out.stdout)) as tar:
            self.assertIn("etc/ssh/ssh_host_ed25519_key", tar.getnames())
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ~/hamsci/repos/sigmond && .venv/bin/python -m pytest tests/test_identity.py -v --override-ini addopts=`
Expected: the four ExportTests FAIL, with `AttributeError: module 'sigmond.identity' has no attribute 'export'` and, for the piped tests, a non-zero exit (the script does nothing yet).

- [ ] **Step 3: Write the implementation**

Append to `lib/sigmond/identity.py`:

```python
def _add_bytes(tar: tarfile.TarFile, name: str, data: bytes, mode: int) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = mode
    info.uname = info.gname = "root"
    tar.addfile(info, io.BytesIO(data))


def export(plane: str, out, root: str = "/") -> dict:
    """Write the plane's identity as an uncompressed tar stream; return its manifest.

    Members keep their owner, group and mode, so a restore can put them back
    exactly.  The manifest goes last, as identity/manifest.json.
    """
    m = manifest(plane, root)
    with tarfile.open(fileobj=out, mode="w|") as tar:
        for entry in m["files"]:
            rel = entry["path"].lstrip("/")
            tar.add(os.path.join(root, rel), arcname=rel, recursive=False)
        if plane == "pm":
            cred = rac_credential(root)
            if cred is not None:
                _add_bytes(tar, RAC_MEMBER, _canonical(cred), 0o600)
        _add_bytes(tar, MANIFEST_MEMBER,
                   json.dumps(m, indent=2, sort_keys=True).encode(), 0o644)
    return m


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="identity", description="Read a station plane's identity files.")
    verbs = parser.add_subparsers(dest="verb", required=True)
    for verb, text in (("export", "write the identity tar to stdout"),
                       ("fingerprints", "print the manifest (no secrets) as JSON")):
        p = verbs.add_parser(verb, help=text)
        p.add_argument("--plane", required=True, choices=PLANES)
        p.add_argument("--root", default="/")
    args = parser.parse_args(argv)
    if args.verb == "fingerprints":
        json.dump(manifest(args.plane, args.root), sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0
    export(args.plane, sys.stdout.buffer, args.root)
    sys.stdout.buffer.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ~/hamsci/repos/sigmond && .venv/bin/python -m pytest tests/test_identity.py -v --override-ini addopts=`
Expected: 14 passed.

- [ ] **Step 5: Run the full sigmond suite**

Run: `cd ~/hamsci/repos/sigmond && .venv/bin/python -m pytest -q --override-ini addopts= 2>&1 | tail -3`
Expected: the same pass count as before this plan plus 14, and no new failures.  Record the numbers.

- [ ] **Step 6: Commit**

```bash
cd ~/hamsci/repos/sigmond
git add lib/sigmond/identity.py tests/test_identity.py
git commit -m "identity: tar export and a CLI that runs from piped source

site-identity feeds this file to 'python3 -' on each plane; the tests run
it exactly that way."
```

---

### Task 4: `site-identity` — reach, remote run, and compare

**Files:**
- Create: `~/hamsci/ops/bin/site-identity` (mode 0755)
- Create: `~/hamsci/ops/tests/test_site_identity.py`

**Interfaces:**
- Consumes: `sigmond.fleet.load_fleet(path)` returning `{name: host}` where `host.reach: str`, `host.hop: str | None`, `host.frozen: str | None`.
- Produces: `load_host(site: str) -> host`; `plane_argv(host, plane: str, verb: str) -> list[str]`; `RUN(argv: list[str], stdin: bytes) -> bytes` (module-level, replaceable in tests; raises `RemoteError` on non-zero exit); `compare(committed: dict, live: dict) -> list[str]` (both keyed by plane, values are manifests; returns human-readable differences, empty when identical).

- [ ] **Step 1: Write the failing tests**

Create `~/hamsci/ops/tests/test_site_identity.py`:

```python
"""Tests for ops/bin/site-identity. No test reaches a real station."""
import importlib.machinery
import importlib.util
import types
import unittest
from pathlib import Path

OPS = Path(__file__).resolve().parent.parent


def _load():
    loader = importlib.machinery.SourceFileLoader(
        "site_identity_under_test", str(OPS / "bin" / "site-identity"))
    spec = importlib.util.spec_from_loader("site_identity_under_test", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


si = _load()

HOST = types.SimpleNamespace(reach="b4pm", hop="sigmond@10.99.0.2", frozen=None)


def _m(plane, files, rac=None):
    m = {"schema": 1, "plane": plane, "files": files}
    if plane == "pm":
        m["rac_credential"] = rac
    return m


F = {"path": "/etc/ssh/ssh_host_ed25519_key", "owner": "root", "group": "root",
     "mode": "0600", "sha256": "aa"}


class PlaneArgvTests(unittest.TestCase):
    def test_pm_runs_on_the_reach_itself(self):
        argv = si.plane_argv(HOST, "pm", "fingerprints")
        self.assertEqual(argv[:3], ["ssh", "-o", "BatchMode=yes"])
        self.assertEqual(argv[3], "b4pm")
        self.assertIn("python3 - fingerprints --plane pm", argv[-1])

    def test_vm_hops_and_elevates_with_sudo_n(self):
        argv = si.plane_argv(HOST, "vm", "export")
        self.assertIn("sigmond@10.99.0.2", argv[-1])
        self.assertIn("sudo -n python3 - export --plane vm", argv[-1])

    def test_vm_without_hop_refused(self):
        with self.assertRaises(SystemExit):
            si.plane_argv(types.SimpleNamespace(reach="x", hop=None, frozen=None),
                          "vm", "export")


class CompareTests(unittest.TestCase):
    def setUp(self):
        self.base = {"pm": _m("pm", [F], {"fields": ["user"], "sha256": "r1"}),
                     "vm": _m("vm", [F])}

    def _copy(self):
        import copy
        return copy.deepcopy(self.base)

    def test_identical_reports_nothing(self):
        self.assertEqual(si.compare(self.base, self._copy()), [])

    def test_changed_key_named(self):
        live = self._copy()
        live["vm"]["files"][0]["sha256"] = "bb"
        diffs = si.compare(self.base, live)
        self.assertEqual(len(diffs), 1)
        self.assertIn("vm", diffs[0])
        self.assertIn("/etc/ssh/ssh_host_ed25519_key", diffs[0])
        self.assertIn("sha256", diffs[0])

    def test_missing_and_extra_files_named(self):
        live = self._copy()
        live["pm"]["files"] = []
        live["vm"]["files"].append(dict(F, path="/etc/hs-uploader/keys/id_new"))
        text = "\n".join(si.compare(self.base, live))
        self.assertIn("pm: missing /etc/ssh/ssh_host_ed25519_key", text)
        self.assertIn("vm: new /etc/hs-uploader/keys/id_new", text)

    def test_mode_change_named(self):
        live = self._copy()
        live["pm"]["files"][0]["mode"] = "0644"
        self.assertIn("mode", "\n".join(si.compare(self.base, live)))

    def test_rac_credential_change_named(self):
        live = self._copy()
        live["pm"]["rac_credential"]["sha256"] = "r2"
        self.assertIn("RAC credential", "\n".join(si.compare(self.base, live)))


class LoadHostTests(unittest.TestCase):
    def test_frozen_host_refused(self):
        frozen = types.SimpleNamespace(reach="x", hop="y", frozen="dark since 09-17")
        si.load_fleet_hosts = lambda: {"ai6vn": frozen}
        with self.assertRaises(SystemExit) as cm:
            si.load_host("ai6vn")
        self.assertIn("frozen", str(cm.exception))

    def test_unknown_site_refused(self):
        si.load_fleet_hosts = lambda: {}
        with self.assertRaises(SystemExit):
            si.load_host("nowhere")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ~/hamsci/ops && ~/hamsci/repos/sigmond/.venv/bin/python -m pytest tests/test_site_identity.py -v`
Expected: collection ERROR — `bin/site-identity` does not exist.

- [ ] **Step 3: Write the implementation**

Create `~/hamsci/ops/bin/site-identity`:

```python
#!/usr/bin/env python3
"""site-identity — keep a station's identity in ops, encrypted, and check it.

    site-identity capture <site>   # read both planes, encrypt, commit
    site-identity check <site>     # live station vs the committed manifest

WHY
---
A reflash mints new host keys, a new uploader key and a new RAC credential, and
everything that trusted the old ones stops trusting the station.  B4 on
2026-09-23 lost its known_hosts entries, its wd30 heartbeat, its PSWS login and
its RAC name in one install.  This tool keeps the identity itself, so a later
install can put it back.  Design:
sigmond-appliance/docs/superpowers/specs/2026-09-24-station-identity-design.md

HOW
---
The file list lives once, in sigmond/lib/sigmond/identity.py.  This tool pipes
that file to `python3 -` on the Proxmox host (the site's `reach`) and on the VM
(reach, then `hop`, as root through `sudo -n`).  The PM carries no sigmond, and
a VM may run an older one, so nothing needs deploying first.

Plaintext never touches this disk.  The tar travels from ssh's stdout straight
into `age`, encrypted to every key in sigmond-appliance/operators/*.pub.

Like fleet-ssh, this acts on ONE named site and refuses a frozen host.
"""
from __future__ import annotations

import datetime
import io
import json
import os
import shlex
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

OPS = Path(__file__).resolve().parent.parent
REPOS = Path.home() / "hamsci" / "repos"
SIGMOND_LIB = REPOS / "sigmond" / "lib"
IDENTITY_PY = SIGMOND_LIB / "sigmond" / "identity.py"
OPERATORS = REPOS / "sigmond-appliance" / "operators"
DELTAS = OPS / "site-deltas"
DEFAULT_FLEET = OPS / "fleet.toml"
PLANES = ("pm", "vm")
MANIFEST_MEMBER = "identity/manifest.json"
COMPARED = ("sha256", "mode", "owner", "group")


class RemoteError(RuntimeError):
    pass


def load_fleet_hosts():
    """The inventory through sigmond's own loader, never a second parser."""
    sys.path.insert(0, str(SIGMOND_LIB))
    from sigmond.fleet import load_fleet
    return load_fleet(os.environ.get("SIGMOND_FLEET") or str(DEFAULT_FLEET))


def load_host(site: str):
    hosts = load_fleet_hosts()
    if site not in hosts:
        sys.exit(f"site-identity: {site!r} is not in the fleet inventory. "
                 f"Known: {', '.join(sorted(hosts))}")
    host = hosts[site]
    if getattr(host, "frozen", None):
        sys.exit(f"site-identity: {site} is marked frozen — {host.frozen}")
    return host


def plane_argv(host, plane: str, verb: str) -> list[str]:
    base = ["ssh", "-o", "BatchMode=yes", *shlex.split(host.reach)]
    if plane == "pm":
        # Proxmox has no sudo; the reach normally lands as root already.
        run = f"python3 - {verb} --plane pm"
        return base + [f'if [ "$(id -u)" = 0 ]; then {run}; else sudo -n {run}; fi']
    if not getattr(host, "hop", None):
        sys.exit("site-identity: this site has no hop, so no VM plane to read")
    inner = f"sudo -n python3 - {verb} --plane vm"
    return base + [f"ssh -o BatchMode=yes {host.hop} {shlex.quote(inner)}"]


def _run(argv: list[str], stdin: bytes) -> bytes:
    proc = subprocess.run(argv, input=stdin, capture_output=True)
    if proc.returncode != 0:
        raise RemoteError(f"{' '.join(argv[:4])} … exited {proc.returncode}: "
                          f"{proc.stderr.decode(errors='replace').strip()}")
    return proc.stdout


RUN = _run


def _by_path(manifest: dict) -> dict:
    return {f["path"]: f for f in manifest.get("files", [])}


def compare(committed: dict, live: dict) -> list[str]:
    """Differences between two {plane: manifest} maps, one line each."""
    diffs = []
    for plane in PLANES:
        old, new = committed.get(plane), live.get(plane)
        if old is None or new is None:
            diffs.append(f"{plane}: plane missing from "
                         f"{'the committed bundle' if old is None else 'the live station'}")
            continue
        a, b = _by_path(old), _by_path(new)
        for path in sorted(a.keys() - b.keys()):
            diffs.append(f"{plane}: missing {path}")
        for path in sorted(b.keys() - a.keys()):
            diffs.append(f"{plane}: new {path}")
        for path in sorted(a.keys() & b.keys()):
            changed = [k for k in COMPARED if a[path].get(k) != b[path].get(k)]
            if changed:
                diffs.append(f"{plane}: changed {path} ({', '.join(changed)})")
        if plane == "pm" and old.get("rac_credential") != new.get("rac_credential"):
            diffs.append("pm: RAC credential differs")
    return diffs


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[0] not in ("capture", "check"):
        print(__doc__)
        return 2
    verb, site = argv
    host = load_host(site)
    return capture(site, host) if verb == "capture" else check(site, host)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

Then: `chmod 0755 ~/hamsci/ops/bin/site-identity`.  (`capture` and `check` arrive in Tasks 5 and 6; `main` refers to them by name, which Python resolves at call time, so the tests in this task import and run cleanly.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ~/hamsci/ops && ~/hamsci/repos/sigmond/.venv/bin/python -m pytest tests/test_site_identity.py -v`
Expected: 10 passed.

- [ ] **Step 5: Mutation check**

Temporarily change `COMPARED` to `("owner", "group")`.  Re-run.
Expected: `test_changed_key_named` and `test_mode_change_named` FAIL.  Restore; 10 pass.

- [ ] **Step 6: Commit**

```bash
cd ~/hamsci/ops
git add bin/site-identity tests/test_site_identity.py
git commit -m "site-identity: reach both planes of one site and compare manifests"
```

---

### Task 5: `capture` — encrypt with age and commit

**Files:**
- Modify: `~/hamsci/ops/bin/site-identity` (add functions above `main`)
- Modify: `~/hamsci/ops/tests/test_site_identity.py` (add a class)

**Interfaces:**
- Consumes: `plane_argv`, `RUN`, `IDENTITY_PY`, `OPERATORS`, `DELTAS`, `MANIFEST_MEMBER`.
- Produces: `recipients(operators_dir: Path) -> list[str]`; `bundle(tars: dict[str, bytes]) -> bytes` (outer tar holding `pm.tar` and `vm.tar`); `inner_manifest(tar_bytes: bytes) -> dict`; `age_encrypt(data: bytes, keys: list[str]) -> bytes`; `capture(site, host, *, commit: bool = True, verify_key: Path | None = DEFAULT_VERIFY_KEY) -> int`.  Writes `DELTAS/<site>/identity.age` and `DELTAS/<site>/identity.manifest` (JSON: `schema`, `site`, `captured_utc`, `planes: {pm, vm}`).

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_site_identity.py`, above the `if __name__` block:

```python
import io
import json
import shutil
import subprocess
import sys
import tarfile
import tempfile

sys.path.insert(0, str(Path.home() / "hamsci/repos/sigmond/lib"))
from sigmond import identity  # noqa: E402

FRPC = 'user = "0123456789abcdef"\n[auth]\nmethod = "token"\ntoken = "s3cret"\n'


def _keygen(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(path)],
                   check=True)


@unittest.skipUnless(shutil.which("age"), "age not installed (plan Task 0)")
class CaptureTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        t = Path(self._tmp.name)
        self.roots = {"pm": t / "pm", "vm": t / "vm"}
        _keygen(self.roots["pm"] / "etc/ssh/ssh_host_ed25519_key")
        (self.roots["pm"] / "etc/sigmond").mkdir(parents=True)
        (self.roots["pm"] / "etc/sigmond/frpc-host.toml").write_text(FRPC)
        _keygen(self.roots["vm"] / "etc/ssh/ssh_host_ed25519_key")
        _keygen(self.roots["vm"] / "etc/hs-uploader/keys/id_ed25519_host")
        # A throwaway operator: its .pub stands in for operators/*.pub.
        self.operator = t / "operator"
        _keygen(self.operator)
        (t / "operators").mkdir()
        shutil.copy(str(self.operator) + ".pub", t / "operators/tester.pub")
        si.OPERATORS = t / "operators"
        si.DELTAS = t / "site-deltas"

        def fake_run(argv, stdin):
            plane = "pm" if "--plane pm" in argv[-1] else "vm"
            buf = io.BytesIO()
            if " export " in argv[-1]:
                identity.export(plane, buf, str(self.roots[plane]))
                return buf.getvalue()
            return json.dumps(identity.manifest(plane, str(self.roots[plane]))).encode()

        si.RUN = fake_run

    def tearDown(self):
        self._tmp.cleanup()

    def _capture(self):
        rc = si.capture("b4", HOST, commit=False, verify_key=self.operator)
        self.assertEqual(rc, 0)
        return si.DELTAS / "b4"

    def test_capture_writes_ciphertext_and_plain_manifest(self):
        out = self._capture()
        self.assertTrue((out / "identity.age").read_bytes().startswith(b"age-encryption.org/v1"))
        man = json.loads((out / "identity.manifest").read_text())
        self.assertEqual(man["site"], "b4")
        self.assertEqual(set(man["planes"]), {"pm", "vm"})

    def test_operator_can_decrypt_both_planes(self):
        out = self._capture()
        plain = subprocess.run(["age", "-d", "-i", str(self.operator),
                                str(out / "identity.age")],
                               check=True, capture_output=True).stdout
        with tarfile.open(fileobj=io.BytesIO(plain)) as outer:
            self.assertEqual(sorted(outer.getnames()), ["pm.tar", "vm.tar"])
            vm = outer.extractfile("vm.tar").read()
        with tarfile.open(fileobj=io.BytesIO(vm)) as inner:
            self.assertIn("etc/hs-uploader/keys/id_ed25519_host", inner.getnames())

    def test_plain_manifest_holds_no_secret(self):
        out = self._capture()
        text = (out / "identity.manifest").read_text()
        self.assertNotIn("s3cret", text)
        key = (self.roots["vm"] / "etc/ssh/ssh_host_ed25519_key").read_text()
        body = [l for l in key.splitlines() if l and not l.startswith("-----")]
        for line in body:
            self.assertNotIn(line, text)

    def test_no_recipients_refuses(self):
        for f in si.OPERATORS.iterdir():
            f.unlink()
        with self.assertRaises(SystemExit):
            si.capture("b4", HOST, commit=False, verify_key=self.operator)
        self.assertFalse((si.DELTAS / "b4" / "identity.age").exists())
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ~/hamsci/ops && ~/hamsci/repos/sigmond/.venv/bin/python -m pytest tests/test_site_identity.py -v`
Expected: the four CaptureTests FAIL with `AttributeError: ... has no attribute 'capture'`.  If they report SKIPPED, Task 0 has not run; stop and do it.

- [ ] **Step 3: Write the implementation**

In `bin/site-identity`, add below `compare` and above `main`:

```python
DEFAULT_VERIFY_KEY = Path.home() / ".ssh" / "id_ed25519_devbox"


def recipients(operators_dir: Path) -> list[str]:
    keys = []
    for pub in sorted(operators_dir.glob("*.pub")):
        keys += [l.strip() for l in pub.read_text().splitlines()
                 if l.strip().startswith("ssh-")]
    return keys


def _add(tar: tarfile.TarFile, name: str, data: bytes) -> None:
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = 0o600
    tar.addfile(info, io.BytesIO(data))


def bundle(tars: dict[str, bytes]) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as outer:
        for plane in PLANES:
            _add(outer, f"{plane}.tar", tars[plane])
    return buf.getvalue()


def inner_manifest(tar_bytes: bytes) -> dict:
    with tarfile.open(fileobj=io.BytesIO(tar_bytes)) as tar:
        return json.loads(tar.extractfile(MANIFEST_MEMBER).read())


def age_encrypt(data: bytes, keys: list[str]) -> bytes:
    # The recipients file holds public keys only, so a temp file costs nothing.
    with tempfile.NamedTemporaryFile("w", suffix=".recipients") as rf:
        rf.write("\n".join(keys) + "\n")
        rf.flush()
        proc = subprocess.run(["age", "-R", rf.name], input=data, capture_output=True)
    if proc.returncode != 0:
        sys.exit(f"site-identity: age failed: {proc.stderr.decode().strip()}")
    return proc.stdout


def _verify(ciphertext: bytes, plain: bytes, key: Path) -> None:
    """Prove at least one recipient can open the bundle before we commit it."""
    with tempfile.NamedTemporaryFile(suffix=".age") as cf:
        cf.write(ciphertext)
        cf.flush()
        proc = subprocess.run(["age", "-d", "-i", str(key), cf.name], capture_output=True)
    if proc.returncode != 0 or proc.stdout != plain:
        sys.exit(f"site-identity: the bundle would not decrypt with {key}; "
                 f"nothing written")


def capture(site: str, host, *, commit: bool = True,
            verify_key: Path | None = DEFAULT_VERIFY_KEY) -> int:
    keys = recipients(OPERATORS)
    if not keys:
        sys.exit(f"site-identity: no ssh- keys in {OPERATORS}/*.pub; refusing to "
                 f"encrypt to nobody")
    src = IDENTITY_PY.read_bytes()
    tars = {}
    for plane in PLANES:
        try:
            tars[plane] = RUN(plane_argv(host, plane, "export"), src)
        except RemoteError as exc:
            sys.exit(f"site-identity: {site} {plane}: {exc}")
    plain = bundle(tars)
    ciphertext = age_encrypt(plain, keys)
    if verify_key is not None and Path(verify_key).exists():
        _verify(ciphertext, plain, Path(verify_key))
    doc = {
        "schema": 1,
        "site": site,
        "captured_utc": datetime.datetime.now(datetime.timezone.utc)
                                         .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "planes": {plane: inner_manifest(tars[plane]) for plane in PLANES},
    }
    out = DELTAS / site
    out.mkdir(parents=True, exist_ok=True)
    (out / "identity.age").write_bytes(ciphertext)
    (out / "identity.manifest").write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
    n = sum(len(doc["planes"][p]["files"]) for p in PLANES)
    print(f"site-identity: {site}: {n} files, RAC credential "
          f"{'present' if doc['planes']['pm'].get('rac_credential') else 'ABSENT'}, "
          f"encrypted to {len(keys)} operator key(s) -> {out}")
    if commit:
        subprocess.run(["git", "-C", str(OPS), "add", str(out)], check=True)
        subprocess.run(["git", "-C", str(OPS), "commit", "-q", "-m",
                        f"{site}: identity capture {doc['captured_utc']}", "--",
                        str(out)], check=True)
        print("site-identity: committed (not pushed)")
    return 0
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ~/hamsci/ops && ~/hamsci/repos/sigmond/.venv/bin/python -m pytest tests/test_site_identity.py -v`
Expected: 14 passed, none skipped.

- [ ] **Step 5: Mutation check**

Temporarily make `bundle` skip the VM (`for plane in ("pm",):`).  Re-run.
Expected: `test_operator_can_decrypt_both_planes` FAILS.  Restore; 14 pass.

- [ ] **Step 6: Commit**

```bash
cd ~/hamsci/ops
git add bin/site-identity tests/test_site_identity.py
git commit -m "site-identity capture: both planes into one age bundle, verified before commit"
```

---

### Task 6: `check`

**Files:**
- Modify: `~/hamsci/ops/bin/site-identity` (add `check` above `main`)
- Modify: `~/hamsci/ops/tests/test_site_identity.py` (add to `CaptureTests`)

**Interfaces:**
- Consumes: `compare`, `plane_argv`, `RUN`, `DELTAS`.
- Produces: `check(site, host) -> int` — 0 when the live station matches, 1 on any difference (each printed), 2 when no committed manifest exists.

- [ ] **Step 1: Write the failing tests**

Add these methods to `CaptureTests`:

```python
    def test_check_matches_right_after_capture(self):
        self._capture()
        self.assertEqual(si.check("b4", HOST), 0)

    def test_check_names_a_reminted_key(self):
        self._capture()
        key = self.roots["vm"] / "etc/hs-uploader/keys/id_ed25519_host"
        key.unlink()
        Path(str(key) + ".pub").unlink()
        _keygen(key)
        self.assertEqual(si.check("b4", HOST), 1)

    def test_check_without_capture_says_so(self):
        self.assertEqual(si.check("b4", HOST), 2)
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd ~/hamsci/ops && ~/hamsci/repos/sigmond/.venv/bin/python -m pytest tests/test_site_identity.py -v`
Expected: three FAIL with `AttributeError: ... has no attribute 'check'`.

- [ ] **Step 3: Write the implementation**

Add above `main` in `bin/site-identity`:

```python
def check(site: str, host) -> int:
    path = DELTAS / site / "identity.manifest"
    if not path.exists():
        print(f"site-identity: no identity captured for {site} ({path}); "
              f"run: site-identity capture {site}")
        return 2
    committed = json.loads(path.read_text())
    src = IDENTITY_PY.read_bytes()
    live = {}
    for plane in PLANES:
        try:
            live[plane] = json.loads(RUN(plane_argv(host, plane, "fingerprints"), src))
        except RemoteError as exc:
            print(f"site-identity: {site} {plane}: cannot read the live station: {exc}")
            return 1
    diffs = compare(committed["planes"], live)
    if not diffs:
        print(f"site-identity: {site} matches its bundle "
              f"(captured {committed['captured_utc']})")
        return 0
    print(f"site-identity: {site} does NOT match its bundle "
          f"(captured {committed['captured_utc']}):")
    for line in diffs:
        print(f"  {line}")
    return 1
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd ~/hamsci/ops && ~/hamsci/repos/sigmond/.venv/bin/python -m pytest tests/test_site_identity.py -v`
Expected: 17 passed.

- [ ] **Step 5: Mutation check**

Temporarily make `check` return 0 unconditionally after reading `live`.  Re-run.
Expected: `test_check_names_a_reminted_key` FAILS.  Restore; 17 pass.

- [ ] **Step 6: Commit**

```bash
cd ~/hamsci/ops
git add bin/site-identity tests/test_site_identity.py
git commit -m "site-identity check: live fingerprints against the committed manifest"
```

---

### Task 7: capture the fleet

This task reads private keys off live stations.  It changes nothing on them, but it still goes on the bus first.  Auto mode may refuse the capture; if it does, stage the exact command and have Michael run it with `!`.

**Files:**
- Generated: `~/hamsci/ops/site-deltas/<site>/identity.age`, `identity.manifest`

- [ ] **Step 1: Announce on the bus**

Write `/srv/hamsci/claude-bus/$(date -u +%Y%m%dT%H%M%SZ)-mjh.md` (then `chown mjh:hamsci`, `chmod 660`) saying: read-only identity capture of b4, ac0g-nd and dasi002 via `ops/bin/site-identity`; it runs `python3 -` as root on each PM and `sudo -n python3 -` on each VM; no service touched; ai6vn skipped (frozen).

- [ ] **Step 2: Capture B4 and check it**

Run: `~/hamsci/ops/bin/site-identity capture b4 && ~/hamsci/ops/bin/site-identity check b4`
Expected: `b4: 16 files, RAC credential present, encrypted to 4 operator key(s)`, `committed (not pushed)`, then `b4 matches its bundle`.  The 16: on the VM, six host-key files and the uploader key pair; on the PM, six host-key files and root's `id_ed25519` pair.  Compare that list with `ls /etc/ssh/ssh_host_* /etc/hs-uploader/keys/ /home/timestd/.ssh/` on each plane.  A file the capture missed means `FILE_PATTERNS` has a gap; stop and fix it before going on.

- [ ] **Step 3: Confirm a second operator key can open it**

Run: `age -d -i ~/.ssh/id_ed25519_devbox ~/hamsci/ops/site-deltas/b4/identity.age | tar tf - `
Expected: `pm.tar` and `vm.tar`.  (Rob's keys cannot be tested from here; say so in the bus note.)

- [ ] **Step 4: Capture AC0G-ND and DASI002**

Run each separately, one named site per run:
`~/hamsci/ops/bin/site-identity capture ac0g-nd && ~/hamsci/ops/bin/site-identity check ac0g-nd`
`~/hamsci/ops/bin/site-identity capture dasi002 && ~/hamsci/ops/bin/site-identity check dasi002`
Expected: each captures and matches.  DASI002 has sent no heartbeat since 2026-09-18, so an unreachable result counts as a finding to report, not a failure to retry.

- [ ] **Step 5: Report**

Post a bus note with each site's file count, whether its RAC credential came back present, the ops commit hashes, and the sites not captured with the reason (ai6vn frozen; any unreachable).  Update the spec's §7 step 2 status line in `sigmond-appliance` only if Michael asks.

---

## Self-review notes

- Spec coverage: §2 file list → Task 1 (`FILE_PATTERNS`, with PM root's `id_ed25519` added from the live B4 inspection) and Task 2 (RAC); §3 bundle and manifest → Task 5; §4 `capture`, `check` → Tasks 5, 6; §7 step 2 fleet capture → Task 7.  `site-identity stick`, `smd admin identity restore`, the installer changes and the nested round trip belong to Plan 2; the RAC reuse branch to Plan 3.
- §3 says plaintext exists briefly in the devbox scratch directory.  This plan improves on that: plaintext stays in memory.
