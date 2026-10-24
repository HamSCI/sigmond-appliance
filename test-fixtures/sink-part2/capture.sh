#!/bin/bash
# Regenerate the fixtures test-nested-sink-part2.sh reads (sigmond step 2b
# part 2, global constraint 4: the rig's parsers read real output, never lines
# typed by hand).
#
#   test-fixtures/sink-part2/capture.sh [SIGMOND_CHECKOUT] [COMMIT] [PART1_COMMIT]
#
# Everything comes from one sigmond commit (default: the checkout's HEAD),
# taken with `git archive`, so uncommitted edits never leak in:
#   manifest_step_part2.txt      the manifest step's V1 run (Task 19's capture)
#   sink_fill_part2.txt          `smd sink fill --reason rig` (Task 20's capture)
#   sink_status_<case>.json      `hs-uploader sink status --json` (Task 15's
#                                capture), for site-off, all-upload, marker-absent
#   pipelines_gate.toml          the gate form's legacy manifest, and
#   sigmond_gate.toml            its pipelines.d/sigmond.toml, for a station
#                                with no client and the heartbeat enabled (the
#                                nest's case), rendered by that commit's
#                                uploader_manifest.generate_forms
#   pipelines_part1.toml         the same station in part 1's form (no gate)
#   switch_view_<case>.txt       `smd sink status`'s switch view
#                                (commands/sink.py _show_switches) of the
#                                status fixture of the same case
#   lever_lines_more.txt         lever and stale-writer lines for a
#                                meteor-scatter instance, wspr-uploader and
#                                the mag fallback, as `smd sink fill` prints
#                                them (sink_levers *Result.lines() through
#                                commands/config.py _say_lines)
#   lever_lines_linked.txt       the same for a linked wspr-uploader the
#                                plant enabled: its enablement link removed,
#                                the unit stopped (sigmond Task 28 F2)
#   lever_lines_linked_failed.txt  the same when the links record could
#                                not be written: stopped, enablement standing
#   smd_err_line.txt             one manifest-step error line, as
#                                commands/uploader.py _err prints it
#   restore_part2/               a restore to a sigmond below part 2 and the
#                                manifest step after it (Task 22's restore,
#                                Task 24's capture): restore.txt, rerun.txt,
#                                the switch files after each step, the
#                                markers and coordination.toml
#   update_plan_pull.txt         `smd update`'s plan for a station whose
#                                sigmond and hs-uploader checkouts sit one
#                                commit behind their branch: the print code
#                                --apply runs, taken as a dry run so nothing
#                                escalates (bin/smd at COMMIT, on
#                                tests/test_update_executor.py's git rig)
#   manifest_step_part1.txt      part 1's manifest step (PART1_COMMIT,
#                                default be91e22: sigmond main when this
#                                branch was cut, the release the update rig
#                                restores to), re-rendering over the gate form
#   SOURCE                       the commits and the files' origin
# The copied files carry their own capture scripts in sigmond
# (tests/fixtures/capture_*.py, tests/fixtures/sink_status/capture.sh); this
# script copies their committed output, so a re-run at the same commit leaves
# `git diff` empty.  test-nested-sink-part2.sh wraps each the way
# `qm guest exec` hands it back.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sig="$(cd "${1:-$here/../../../sigmond}" && pwd)"
commit="$(git -C "$sig" rev-parse --verify "${2:-HEAD}^{commit}")"
py="${PYTHON:-python3}"
part1="$(git -C "$sig" rev-parse --verify "${3:-be91e22}^{commit}")"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

git -C "$sig" archive "$commit" lib tests/fixtures/manifest_step_part2.txt \
    tests/fixtures/sink_fill_part2.txt tests/fixtures/sink_status \
    tests/fixtures/restore_part2 \
    | tar -x -C "$work"
f="$work/tests/fixtures"
cp "$f/manifest_step_part2.txt" "$here/manifest_step_part2.txt"
cp "$f/sink_fill_part2.txt" "$here/sink_fill_part2.txt"
for c in site-off all-upload marker-absent; do
    cp "$f/sink_status/$c.json" "$here/sink_status_$c.json"
done
rm -rf "$here/restore_part2"
cp -R "$f/restore_part2" "$here/restore_part2"

(cd / && "$py" -I -B - "$work/lib" "$here" <<'PY'
import contextlib, io, logging, sys, tomllib
from pathlib import Path
sys.path.insert(0, sys.argv[1])
out = Path(sys.argv[2])
logging.disable(logging.CRITICAL)
from sigmond import uploader_manifest as um
from sigmond import sink_state
from sigmond.coordination import parse_coordination
from sigmond.topology import Topology
from sigmond.commands import sink as sink_cmd

# The nest after the wizard: identity, [uploads] off, the heartbeat on, and
# no client the manifest step could render a pipeline for.
coord = parse_coordination(tomllib.loads('''
[station]
callsign = "N0CALL"
grid_square = "EM00aa"
reporter_id = "N0CALL/T1"
[uploads]
mode = "discard"
[heartbeat]
enabled = true
station = "N0CALL-T1"
host = "wd30.wsprdaemon.org"
port = 38222
'''))
topo = Topology(client_dir=Path("/nonexistent"), smd_bin=Path("/nonexistent"))
base = {"pipelines.d", "send-log-v3", "switch-files"}
gate = um.generate_forms(topo, coord, features=frozenset(base | {"gate"}),
                         marker_stands=True, supports_discard=True,
                         store_version=3)
part1 = um.generate_forms(topo, coord, features=frozenset(base),
                          marker_stands=True, supports_discard=True,
                          store_version=3)
assert gate.sigmond_file and part1.sigmond_file is None
(out / "pipelines_gate.toml").write_text(gate.legacy_text)
(out / "sigmond_gate.toml").write_text(gate.sigmond_file)
(out / "pipelines_part1.toml").write_text(part1.legacy_text)

for case in ("site-off", "all-upload"):
    state = sink_state.parse_status((out / f"sink_status_{case}.json").read_text())
    assert state is not None, case
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        sink_cmd._show_switches(state)
    (out / f"switch_view_{case}.txt").write_text(buf.getvalue())

# The lever lines the Task 20 capture holds no example of (its station has no
# meteor-scatter, wspr-uploader or mag fallback), printed by the code that
# prints them in `smd sink fill`: LeverResult.lines() and StaleResult.lines()
# through commands/config.py _say_lines.
from sigmond import sink_levers
from sigmond.commands import config as cfg
lv = sink_levers.LeverResult(
    changed=[Path("/etc/meteor-scatter/env/N0CALL=T1.env"),
             Path("/etc/mag-recorder/mag-recorder-config.toml")],
    disabled=["wspr-uploader.service"],
    restarted=["meteor-scatter@N0CALL\\x3dT1.service"])
st = sink_levers.StaleResult(restarted=["wspr-recorder@N0CALL\\x3dT1.service"])
buf = io.StringIO()
with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
    cfg._say_lines(lv.lines())
    cfg._say_lines(st.lines())
(out / "lever_lines_more.txt").write_text(buf.getvalue())
# A linked wspr-uploader that the plant enabled (sigmond Task 28 F2): the
# lever removes its enablement link and stops it, never disables it.
lv = sink_levers.LeverResult(
    unwanted=[Path("/etc/systemd/system/multi-user.target.wants/"
                   "wspr-uploader.service")],
    stopped=["wspr-uploader.service"])
buf = io.StringIO()
with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
    cfg._say_lines(lv.lines())
(out / "lever_lines_linked.txt").write_text(buf.getvalue())
# The same unit when its links record could not be written: nothing
# removed, the unit stopped, its enablement standing (review M-2).
lv = sink_levers.LeverResult(
    stopped=["wspr-uploader.service"], unwant_tried=True,
    failures=[("wspr-uploader.service", "cannot write the record of its "
               "enablement links ([Errno 21] Is a directory); removed none, "
               "left enabled")])
buf = io.StringIO()
with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
    cfg._say_lines(lv.lines())
(out / "lever_lines_linked_failed.txt").write_text(buf.getvalue())

# One error line as the manifest step prints it to stderr (_err: every such
# line reads "smd: uploader: "), here the failed features probe's.
from sigmond.commands import uploader as up_cmd
buf = io.StringIO()
with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
    up_cmd._err("cannot ask hs-uploader for `capabilities --features` "
                "(failed or timed out); rendering without it")
(out / "smd_err_line.txt").write_text(buf.getvalue())
PY
)

# `smd update`'s plan, from bin/smd at the commit, on the git rig its own
# tests use (origin plus a checkout one commit behind).  A dry run with
# no_fetch (the rig fetches first): it prints each step exactly as --apply
# does and runs nothing.  Every subprocess passes a guard that refuses sudo,
# doas, pkexec and run0, so nothing here can elevate.  The tests' venv
# provides pytest for their conftest.
mkdir -p "$work/upd"
git -C "$sig" archive "$commit" bin/smd lib tests/conftest.py \
    tests/test_update_executor.py | tar -x -C "$work/upd"
vpy="$sig/.venv/bin/python"; [ -x "$vpy" ] || vpy="$py"
(cd / && SIGMOND_TEST_NO_ELEVATE=1 "$vpy" -I -B - "$work/upd" "$here" <<'PY'
import contextlib, io, subprocess, sys, types
from pathlib import Path
root, out = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(root / "lib")); sys.path.insert(0, str(root / "tests"))
_real = subprocess.run
def guard(cmd, *a, **kw):
    if isinstance(cmd, (list, tuple)) and any(
            str(c).rsplit("/", 1)[-1] in ("sudo", "doas", "pkexec", "run0") for c in cmd):
        raise RuntimeError(f"capture refuses privilege: {cmd}")
    return _real(cmd, *a, **kw)
subprocess.run = guard
import test_update_executor as tue
tue._REAL_RUN = guard
class Rig(tue._Rig):
    COMP = "sigmond"
    def runTest(self):
        pass
r = Rig()
r.setUp()
try:
    hsu, _ = r._add_plain_component("hs-uploader")
    for d in (r.host, hsu):
        tue._git("fetch", "origin", cwd=d)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        rc = tue.smd.cmd_update(types.SimpleNamespace(base=r.base, apply=False,
                                                      no_fetch=True))
    assert rc == 0, buf.getvalue()
    (out / "update_plan_pull.txt").write_text(
        buf.getvalue().replace(str(r.base), "/opt/git/sigmond"))
finally:
    r.tearDown()
PY
)

# Part 1's manifest step, at PART1_COMMIT: the restored release's own step
# after a rollback.  Its lib renders the nest (the coordination above, no
# client) over the gate form the branch rendered, with the daemon, migrate
# and the probes faked: the restored hs-uploader answers part 1's three
# feature words.
mkdir -p "$work/p1"
git -C "$sig" archive "$part1" lib | tar -x -C "$work/p1"
(cd / && "$py" -I -B - "$work/p1/lib" "$here" <<'PY'
import contextlib, io, logging, sys, tempfile, tomllib, types
from pathlib import Path
from unittest import mock
sys.path.insert(0, sys.argv[1])
out = Path(sys.argv[2])
logging.disable(logging.CRITICAL)
from sigmond import uploader_manifest as um
from sigmond import coordination as co
from sigmond.commands import uploader as up
from sigmond.topology import Topology
coord = co.parse_coordination(tomllib.loads("""
[station]
callsign = "N0CALL"
grid_square = "EM00aa"
reporter_id = "N0CALL/T1"
[uploads]
mode = "discard"
[heartbeat]
enabled = true
station = "N0CALL-T1"
host = "wd30.wsprdaemon.org"
port = 38222
"""))
topo = Topology(client_dir=Path("/nonexistent"), smd_bin=Path("/nonexistent"))
tmp = Path(tempfile.mkdtemp())
man = tmp / "pipelines.toml"
man.write_text((out / "pipelines_gate.toml").read_text())
gen, sup = um.generate, um.suppressed_pipelines
buf = io.StringIO()
with mock.patch.object(um, "MANIFEST_PATH", man), \
     mock.patch.object(co, "load_coordination", return_value=coord), \
     mock.patch.object(um, "generate",
                       side_effect=lambda topology=None, coord=None, **kw: gen(topo, coord, **kw)), \
     mock.patch.object(um, "suppressed_pipelines",
                       side_effect=lambda topology=None, **kw: sup(topo, **kw)), \
     mock.patch.object(um, "hs_uploader_store_version", return_value=3), \
     mock.patch.object(um, "hs_uploader_supports_discard", return_value=True), \
     mock.patch.object(um, "hs_uploader_features",
                       return_value=frozenset({"pipelines.d", "send-log-v3", "switch-files"})), \
     mock.patch.object(up.os, "geteuid", return_value=0), \
     mock.patch.object(up, "_ensure_daemon_installed", return_value=True), \
     mock.patch.object(up, "_run_migrate", return_value=0), \
     mock.patch.object(up, "_run", return_value=0), \
     mock.patch.object(up, "_service_active", return_value=True), \
     mock.patch.object(up, "_started_before_manifest", return_value=False), \
     mock.patch.object(up, "_daemon_store_path", return_value=tmp / "watermarks.db"), \
     contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
    rc = up.cmd_uploader_manifest(types.SimpleNamespace(write=True, enable=True))
assert rc == 0, buf.getvalue()
(out / "manifest_step_part1.txt").write_text(
    buf.getvalue().replace(str(man), "/etc/hs-uploader/pipelines.toml"))
PY
)

cat > "$here/SOURCE" <<SRC
sigmond $commit
part 1 $part1
manifest_step_part2.txt  <- tests/fixtures/manifest_step_part2.txt
sink_fill_part2.txt      <- tests/fixtures/sink_fill_part2.txt
sink_status_<case>.json  <- tests/fixtures/sink_status/<case>.json
restore_part2/           <- tests/fixtures/restore_part2/ (capture_restore_part2.py)
update_plan_pull.txt     <- bin/smd cmd_update (dry run) at the commit, printed by capture.sh
manifest_step_part1.txt  <- lib/sigmond/commands/uploader.py at part 1, printed by capture.sh
pipelines_*.toml, sigmond_gate.toml, switch_view_*.txt, lever_lines_*.txt, smd_err_line.txt <- printed by capture.sh from lib/ at that commit
SRC
echo "capture: wrote $here from sigmond $commit"
