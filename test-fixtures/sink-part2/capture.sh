#!/bin/bash
# Regenerate the fixtures test-nested-sink-part2.sh reads (sigmond step 2b
# part 2, global constraint 4: the rig's parsers read real output, never lines
# typed by hand).
#
#   test-fixtures/sink-part2/capture.sh [SIGMOND_CHECKOUT] [COMMIT]
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
#   smd_err_line.txt             one manifest-step error line, as
#                                commands/uploader.py _err prints it
#   SOURCE                       the commit and the files' origin
# The three copied files carry their own capture scripts in sigmond
# (tests/fixtures/capture_*.py, tests/fixtures/sink_status/capture.sh); this
# script copies their committed output, so a re-run at the same commit leaves
# `git diff` empty.  test-nested-sink-part2.sh wraps each the way
# `qm guest exec` hands it back.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sig="${1:-$here/../../../sigmond}"
commit="$(git -C "$sig" rev-parse --verify "${2:-HEAD}^{commit}")"
py="${PYTHON:-python3}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

git -C "$sig" archive "$commit" lib tests/fixtures/manifest_step_part2.txt \
    tests/fixtures/sink_fill_part2.txt tests/fixtures/sink_status \
    | tar -x -C "$work"
f="$work/tests/fixtures"
cp "$f/manifest_step_part2.txt" "$here/manifest_step_part2.txt"
cp "$f/sink_fill_part2.txt" "$here/sink_fill_part2.txt"
for c in site-off all-upload marker-absent; do
    cp "$f/sink_status/$c.json" "$here/sink_status_$c.json"
done

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

cat > "$here/SOURCE" <<SRC
sigmond $commit
manifest_step_part2.txt  <- tests/fixtures/manifest_step_part2.txt
sink_fill_part2.txt      <- tests/fixtures/sink_fill_part2.txt
sink_status_<case>.json  <- tests/fixtures/sink_status/<case>.json
pipelines_*.toml, sigmond_gate.toml, switch_view_*.txt, lever_lines_more.txt, smd_err_line.txt <- printed by capture.sh from lib/ at that commit
SRC
echo "capture: wrote $here from sigmond $commit"
