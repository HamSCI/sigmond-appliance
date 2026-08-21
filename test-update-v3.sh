#!/bin/bash
# Tier-2 nested UPDATE test v3 — runs on B3.  Sibling of test-nested-v3.sh.
#
# test-nested-v3.sh proves an INSTALL (phases A-D).  Nothing proved an
# UPDATE: dasi002's wspr-recorder sat silently three commits behind while
# every process we had reported it fine, and the runuser/PATH crash in the
# `qm guest exec` update channel only ever appeared on a live station.
# Both defects were SILENT — something reported success the whole time.
#
# This rig boots the PREVIOUS blessed image (via the sibling, whose install
# phases are reused verbatim, never reimplemented), rolls it forward to
# current main through the REAL production root channel (`qm guest exec`
# from the nested Proxmox host — never a direct ssh into the guest for a
# mutation), verifies, then rolls BACK via `smd admin manifest restore` and
# verifies again.  One rig, both directions, every release.
#
#   PHASE E — forward roll (the station-inward procedure of CONTRIBUTING §3,
#             scripted): pre-state, `smd update --apply`, idempotence,
#             SHA-level assertion against --target, no NEW doctor findings,
#             and the awareness heartbeat contract survives the update.
#   PHASE F — adopt the release manifest with --allow-superset (the updated
#             guest is a sanctioned superset of the blessed baseline).
#   PHASE G — `smd admin manifest restore` back to the blessed SHAs, then a
#             STRICT adopt of the same manifest: the round-trip proof.
#
# Log conventions match the sibling: append-only, one line per step, phases
# announced with ════ banners and closed with a PASS line, so bless-release
# style evidence checks can bound a run in the log.  This one appends to
# test-update-v3.log (the sibling owns test-v3.log).
#
# Traps this script is deliberately exemplary about (sigmond CONTRIBUTING §7):
#   * a pipeline's exit status is its LAST command's — every exit code here
#     is captured from a file or a variable, never from `cmd | tail`.  That
#     mistake has masked a crashed fleet update once and a refused manifest
#     adoption twice in a single day.
#   * `pgrep -f <string>` matches the shell running it, and has reported a
#     VM as running after it stopped.  There is no pgrep here at all: the
#     nested guest is detected with `ps -C qemu-system-x86_64 -o args=`, the
#     sibling's idiom, which cannot match this shell.
#   * git run as root rewrites .git/index and recreates the exact damage
#     `smd doctor --fix` exists to repair — every guest snippet exports
#     GIT_OPTIONAL_LOCKS=0 and every git call passes --no-optional-locks.
set -u

# ── arguments ───────────────────────────────────────────────────────────
# Parsed BEFORE the log redirect so a usage error lands on the operator's
# terminal instead of silently at the end of a log nobody is tailing yet.
usage(){
    cat <<'USAGE'
usage: test-update-v3.sh [--image <release.img>] [--target <git-ref>] [--resume]

  --image   release image to roll forward FROM (default: the newest
            sigmond-appliance-*-release.img in the rig dir)
  --target  git ref the guest must end up level with (default: origin/main)
  --resume  skip the install phases and reuse the nested production PM/VM
            left running by a previous run (probed, never assumed)

env overrides (for a scratch rig; never needed for a normal run):
  RIG_DIR              image/log staging dir      (default: $HOME/appliance/v3)
  NESTED_TEST          path to test-nested-v3.sh  (default: alongside this script)
  SIGMOND_REPO         sigmond checkout used to resolve --target on the
                       DEVBOX side                (default: $HOME/appliance/repos/sigmond)
  SIGMOND_TARGET_SHA   resolved target sha, bypassing SIGMOND_REPO entirely
  NESTED_PM_RE         hostname regex the nested PM must match before ANY
                       mutation is attempted
  U2_ALLOW_NEW_KINDS   comma-separated doctor finding kinds an operator has
                       ALREADY ruled on and sanctioned as acceptable-new
                       (default: empty — a new kind is a failure)
USAGE
}
IMGARG=""; TARGET="origin/main"; RESUME=0
while [ $# -gt 0 ]; do
    case "$1" in
        --image)  [ $# -ge 2 ] || { echo "--image needs a value" >&2; exit 2; }; IMGARG="$2"; shift 2 ;;
        --target) [ $# -ge 2 ] || { echo "--target needs a value" >&2; exit 2; }; TARGET="$2"; shift 2 ;;
        --resume) RESUME=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unrecognized argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# ── rig location ────────────────────────────────────────────────────────
# Location-agnostic the way the sibling and bless-release.sh are: the rig
# dir is a default, not a hardcode, and the sibling script is found next to
# THIS file rather than at an absolute path.
RIG_DIR="${RIG_DIR:-$HOME/appliance/v3}"
[ -d "$RIG_DIR" ] || { echo "FATAL: rig dir not found: $RIG_DIR" >&2; exit 1; }
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
NESTED_TEST="${NESTED_TEST:-$SELF_DIR/test-nested-v3.sh}"
cd "$RIG_DIR" || { echo "FATAL: cannot cd $RIG_DIR" >&2; exit 1; }
LOG="$PWD/test-update-v3.log"
NESTED_LOG="$PWD/test-v3.log"          # the sibling's own append-only log
exec >> "$LOG" 2>&1
say(){ echo "[upd $(date '+%T')] $*"; }

# Evidence dir: every raw guest-exec capture of THIS run, kept for
# post-mortem.  Cleared at the start of each run rather than accumulating,
# so "the last run's captures" is never ambiguous.
WORK="$PWD/update-evidence"
rm -rf "$WORK"; mkdir -p "$WORK" || { say "FATAL: cannot create $WORK"; exit 1; }

say "════════════════════════════════════════════════════════════════"
say "test-update-v3.sh starting (rig=$RIG_DIR resume=$RESUME target=$TARGET)"
say "raw guest captures: $WORK"

# ── ssh into the nested PM: the sibling's idiom, kept identical ─────────
# These four helpers (SSHOPTS/SSHKEY/SSHPW/resolve_ssh and vm_running) are
# COPIES of test-nested-v3.sh's, deliberately kept character-for-character
# equivalent.  They cannot be shared by sourcing: the sibling has top-level
# code (it cds, redirects its own log and runs its phase `case` on load), so
# sourcing it would run the whole install rig.  Refactoring a proven release
# gate into a library mid-release is a larger risk than two duplicated
# helpers, so the duplication is deliberate — change them together.
KEY="$HOME/appliance/build/applkey"
SSHPASSWORD="${SIGMOND_TEST_PASSWORD:-hamsci-sigmond}"
# ServerAlive* is the one intentional difference from the sibling: a single
# `qm guest exec` carrying `smd update --apply` can block this ssh session
# for many minutes with no traffic, and a silently dropped session would
# look exactly like an update that hung.
SSHOPTS="-p 5561 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o ServerAliveInterval=30 -o ServerAliveCountMax=20 root@127.0.0.1"
SSHKEY="ssh -i $KEY $SSHOPTS"
SSHPW="sshpass -p $SSHPASSWORD ssh $SSHOPTS"
SSHN=""
VMID=100

vm_running(){ ps -C qemu-system-x86_64 -o args= 2>/dev/null | grep -q "guest=sigv3"; }

resolve_ssh(){
    local tries="$1" delay="$2" label="${3:-}" i
    if [ -n "$SSHN" ]; then
        for i in $(seq 1 "$tries"); do $SSHN true 2>/dev/null && return 0; sleep "$delay"; done
        say "FATAL: nested PVE ssh never came back${label:+ ($label)}"; return 1
    fi
    for i in $(seq 1 "$tries"); do
        if $SSHKEY true 2>/dev/null; then SSHN="$SSHKEY"; say "auth: ssh test key accepted"; return 0; fi
        if $SSHPW true 2>/dev/null; then SSHN="$SSHPW"; say "auth: test key not accepted, falling back to image-default password (release build)"; return 0; fi
        sleep "$delay"
    done
    if vm_running; then
        say "FATAL: nested host is up but neither ssh key nor password auth worked${label:+ ($label)}"
    else
        say "FATAL: nested PVE ssh never came up${label:+ ($label)}"
    fi
    return 1
}

# ── failure reporting ───────────────────────────────────────────────────
# fatal <output-file|-> <message...> : every phase failure prints the
# failing command's tail before exiting 1, so the log alone is enough to
# diagnose without re-running a 40-minute rig.
fatal(){
    local f="$1"; shift
    say "FATAL: $*"
    if [ "$f" != "-" ] && [ -f "$f" ]; then
        say "── tail of the failing command's output ($f) ──"
        tail -40 "$f"
        say "── end tail ──"
    fi
    say "UPDATE RIG FAILED"
    exit 1
}
excerpt(){ # excerpt <file> <n>
    [ -f "$1" ] || return 0
    say "── $1 (last $2 lines) ──"
    tail -"$2" "$1"
    say "── end ──"
}

# ── the guest-exec channel ──────────────────────────────────────────────
# gx <timeout-s> <tag> <shell-snippet>
#
# Runs <shell-snippet> INSIDE the decoder VM through the nested PM's
# `qm guest exec` — the production root channel (CONTRIBUTING §3), the same
# one that crashed on runuser/PATH once.  Never ssh: a direct ssh into the
# guest as a service user cannot self-elevate, so it would prove a channel
# no station actually uses.
#
# The snippet is shipped base64-encoded and run from a file.  That removes
# the quoting minefield entirely (a snippet may contain any quotes, $, or
# newlines) and, more importantly, keeps the transport identical for every
# call so one call's quoting accident cannot silently change another's
# semantics.  base64 output is [A-Za-z0-9+/=] only, so it is safe inside
# the PM-side double quotes with no escaping at all.
#
# PATH is set the production way: the OUTER shell is `bash -lc`, exactly as
# sigmond-wizard.sh's gexec() and the sibling's guest probes do, so the
# snippet sees the login PATH (/usr/local/bin, where smd lives).  The INNER
# shell is non-login so that /etc/profile output can never contaminate the
# captured command output.
#
# Sets:
#   GX_CHAN  0 iff the exec channel itself worked (agent answered, JSON parsed)
#   GX_QM    the exit status qm reported for the wrapper (0 expected)
#   GX_RC    the exit status of the SNIPPET (the number that matters)
#   GX_OUT   file holding the snippet's stdout+stderr, rc line stripped
# GX_RC is transported as its own sentinel line rather than inferred from
# the wrapper's exit status, so "the channel broke" and "the command failed"
# can never collapse into the same signal — that collapse is what made the
# runuser/PATH crash look like an ordinary nonzero update for a while.
GX_CHAN=1; GX_QM=""; GX_RC=255; GX_OUT="-"
GX_TOKEN="U2RC$$"
gx(){
    local t="$1" tag="$2" snip="$3"
    local raw="$WORK/$tag.json"
    GX_OUT="$WORK/$tag.out"; GX_RC=255; GX_CHAN=1; GX_QM=""
    : > "$GX_OUT"
    local script b64 pyout
    # A SUBSHELL, not a brace group: several snippets below end in an
    # explicit `exit 0`, and inside `{ ... }` that would exit the wrapper
    # before it printed the rc sentinel — the command's real status lost,
    # and the whole run failing as "channel broken".
    script="export GIT_OPTIONAL_LOCKS=0
umask 022
(
$snip
) > /tmp/u2-gx.out 2>&1
printf '${GX_TOKEN}=%s\\n' \"\$?\"
cat /tmp/u2-gx.out
exit 0"
    b64="$(printf '%s\n' "$script" | base64 -w0)"
    $SSHN "qm guest exec $VMID --timeout $t -- bash -lc \"echo $b64 | base64 -d > /tmp/u2-gx.sh; bash /tmp/u2-gx.sh\"" > "$raw" 2>&1
    local sshrc=$?
    if [ "$sshrc" -ne 0 ] && [ ! -s "$raw" ]; then
        say "guest-exec channel: ssh/qm exited $sshrc with no output ($tag)"
        return 1
    fi
    # qm's JSON is parsed with python3 (already a hard dependency of the
    # sibling's qmp()) rather than sed: out-data is a JSON string with
    # escaped newlines, and hand-unescaping it is how a multi-line command
    # output turns into one unsearchable line.
    pyout="$(python3 - "$raw" "$GX_OUT" <<'PYEOF'
import json, sys
raw = open(sys.argv[1], errors='replace').read()
d = None
for cand in (raw, raw[raw.find('{'):raw.rfind('}') + 1]):
    if not cand:
        continue
    try:
        d = json.loads(cand)
        break
    except Exception:
        continue
if not isinstance(d, dict):
    print('CHAN=1')
    sys.exit(0)
out = (d.get('out-data') or '') + (d.get('err-data') or '')
with open(sys.argv[2], 'w') as fh:
    fh.write(out)
print('CHAN=0')
print('QM=%s' % d.get('exitcode'))
print('TRUNC=%s' % (1 if (d.get('out-truncated') or d.get('err-truncated')) else 0))
PYEOF
)"
    case "$pyout" in
        *CHAN=0*) GX_CHAN=0 ;;
        *)        say "guest-exec channel: no parseable JSON from qm ($tag)"; cp "$raw" "$GX_OUT"; return 1 ;;
    esac
    GX_QM="$(printf '%s\n' "$pyout" | sed -n 's/^QM=//p')"
    case "$pyout" in
        *TRUNC=1*) say "WARN: qm truncated the output of $tag — assertions below see a partial capture" ;;
    esac
    # The rc line is found by token ANYWHERE in the capture, not assumed to
    # be line 1: a chatty /etc/profile.d would otherwise shift it.
    local rcline
    rcline="$(grep -E "^${GX_TOKEN}=[0-9]+\$" "$GX_OUT" | tail -1)"
    if [ -n "$rcline" ]; then
        GX_RC="${rcline#*=}"
        grep -v -E "^${GX_TOKEN}=[0-9]+\$" "$GX_OUT" > "$GX_OUT.tmp"
        mv -f "$GX_OUT.tmp" "$GX_OUT"
    else
        say "guest-exec channel: wrapper produced no rc sentinel ($tag) — the snippet's shell died"
        return 1
    fi
    return 0
}

# gx_ok <timeout> <tag> <snippet> <human description>: run, and FATAL on a
# broken channel.  The snippet's own rc is left to the caller to judge —
# some of these commands treat nonzero as information, not failure.
gx_ok(){
    gx "$1" "$2" "$3" || fatal "$WORK/$2.out" "$4: the guest-exec channel failed (agent wedged? try: qm agent $VMID ping on the nested PM, then a guest-side systemctl restart qemu-guest-agent)"
    if [ -n "$GX_QM" ] && [ "$GX_QM" != "0" ]; then
        fatal "$WORK/$2.out" "$4: qm reported wrapper exit $GX_QM — the guest could not even run bash (this is the runuser/PATH crash class)"
    fi
}

# ── parsing helpers ─────────────────────────────────────────────────────
# components_rows <infile> <outfile>: extract the `components (live):` block
# that `smd version` prints (provenance.format_report) and that a release
# .manifest.txt embeds verbatim — header line, then four-space-indented
# "name sha" rows, ending at the first blank or unindented line.  Same shape
# rule as sigmond.doctor._parse_manifest_components, so this parser and
# smd's cannot disagree about what a components block is.
components_rows(){
    awk '
        /^[[:space:]]*components \(live\):[[:space:]]*$/ { inb=1; next }
        inb {
            if ($0 !~ /^    /) exit
            if (NF != 2) next
            print $1, $2
        }
    ' "$1" > "$2"
}
MIN_ROWS=10        # sigmond.doctor.MIN_COMPONENT_ROWS — a thinner block is
                   # what a truncated capture looks like, not a small host
rows_count(){ awk 'END{print NR}' "$1"; }

# sha_equal <a> <b>: mirrors sigmond.doctor._sha_equal (MIN_SHA_PREFIX=4).
# String equality would be WRONG here: `git rev-parse --short` picks its
# abbreviation length per repository, and a real manifest already carries 7,
# 8 and 9-character SHAs side by side, so the same commit legitimately reads
# differently in two captures.
sha_equal(){
    local a="$1" b="$2" n=${#1}
    [ "${#b}" -lt "$n" ] && n="${#b}"
    [ "$n" -ge 4 ] || return 1
    [ "${a:0:$n}" = "${b:0:$n}" ]
}
sha_of(){ awk -v n="$2" '$1==n {print $2; exit}' "$1"; }

# doctor_kinds <doctor-output> <outfile>: the KINDS of finding, sorted and
# deduped.  doctor.summarise prints "<component>:" then "    <kind>: detail".
# Comparing kinds (not whole lines) is what makes "no NEW findings" a
# meaningful assertion across a run that legitimately changes counts.
doctor_kinds(){
    awk '/^    [A-Za-z][A-Za-z0-9_-]*:/ { k=$1; sub(/:$/, "", k); print k }' "$1" | sort -u > "$2"
}
# new_kinds <pre> <post> : kinds present in post and absent from pre, minus
# any the operator has explicitly sanctioned, minus any named as expected.
new_kinds(){
    local pre="$1" post="$2"; shift 2
    local allow="$WORK/.allow.$$"
    { printf '%s\n' "${U2_ALLOW_NEW_KINDS:-}" | tr ', ' '\n'
      [ $# -gt 0 ] && printf '%s\n' "$@"
    } | sed '/^$/d' | sort -u > "$allow"
    comm -13 "$pre" "$post" | comm -23 - "$allow"
    rm -f "$allow"
}

# ── resolve the image under test ────────────────────────────────────────
if [ -n "$IMGARG" ]; then
    IMGBASE="$(basename "$IMGARG")"
    [ -f "$RIG_DIR/$IMGBASE" ] || fatal - "--image $IMGARG: not found in the rig dir ($RIG_DIR/$IMGBASE)"
else
    IMGBASE="$(ls -t sigmond-appliance-*-release.img 2>/dev/null | head -1)"
    [ -n "$IMGBASE" ] || fatal - "no sigmond-appliance-*-release.img in $RIG_DIR (pass --image, or build a release image first)"
    say "no --image given; chose the newest release image in the rig dir"
fi
say "image under test (roll FROM): $IMGBASE"
MANIFEST="$RIG_DIR/${IMGBASE%.img}.manifest.txt"
[ -f "$MANIFEST" ] || fatal - "no blessed manifest beside the image: $(basename "$MANIFEST") — PHASES F/G cannot run without it"
say "blessed manifest: $(basename "$MANIFEST")"
components_rows "$MANIFEST" "$WORK/manifest.rows"
MROWS="$(rows_count "$WORK/manifest.rows")"
[ "$MROWS" -ge "$MIN_ROWS" ] || fatal "$WORK/manifest.rows" "$(basename "$MANIFEST") yielded only $MROWS component rows (floor $MIN_ROWS) — truncated or malformed manifest"
say "manifest carries $MROWS component rows"

# ── resolve --target INDEPENDENTLY of the guest ─────────────────────────
# The whole point of the SHA assertion is that the answer comes from
# somewhere other than the machine being tested.  Asking the guest what
# origin/main is would re-use the very fetch whose staleness this rig
# exists to catch (dasi002 read itself as current while three behind), so
# an unresolvable target is a hard failure, never a fallback.
if [ -n "${SIGMOND_TARGET_SHA:-}" ]; then
    TARGET_SHA="$SIGMOND_TARGET_SHA"
    say "target $TARGET pinned by SIGMOND_TARGET_SHA=$TARGET_SHA"
else
    SIGMOND_REPO="${SIGMOND_REPO:-$HOME/appliance/repos/sigmond}"
    [ -d "$SIGMOND_REPO/.git" ] || fatal - "cannot resolve --target $TARGET: no sigmond checkout at $SIGMOND_REPO (set SIGMOND_REPO=, or pass the answer as SIGMOND_TARGET_SHA=)"
    FETCH_OUT="$WORK/target-fetch.txt"
    git --no-optional-locks -C "$SIGMOND_REPO" fetch --quiet origin > "$FETCH_OUT" 2>&1
    [ $? -eq 0 ] || fatal "$FETCH_OUT" "git fetch failed in $SIGMOND_REPO — a stale origin/main would make the level-with-target assertion a lie"
    TARGET_SHA="$(git --no-optional-locks -C "$SIGMOND_REPO" rev-parse --short "$TARGET" 2>/dev/null)"
    [ -n "$TARGET_SHA" ] || fatal - "git rev-parse $TARGET failed in $SIGMOND_REPO"
    say "target $TARGET resolves to $TARGET_SHA (devbox-side, in $SIGMOND_REPO)"
fi

# ── install phases: reuse the sibling, never reimplement ────────────────
# require_phase_d_pass bounds the sibling's append-only log to the block
# THIS run appended, and requires both the image marker and the PHASE D
# marker inside it.  Same reasoning as bless-release.sh gate 5: the log
# holds many runs of many images, and a bare `grep PASS` would happily
# match a PASS belonging to a different image or an earlier attempt.
# Bounding by the pre-run line count is strictly stronger than gate 5's
# "last block" heuristic — we know exactly which lines are ours.
# `|| [ -n "$line" ]` on the read loop and `awk END{print NR}` instead of
# `wc -l`: a killed run's last line can lack its newline, and that line
# could be the PASS marker itself.
require_phase_d_pass(){ # <log> <from-line> <imgbase>
    local lg="$1" from="$2" img="$3" ln=0 marker=0 pass=0 line
    [ -f "$lg" ] || { say "no sibling log at $lg"; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do
        ln=$((ln + 1))
        [ "$ln" -le "$from" ] && continue
        case "$line" in
            *"USB image under test: "*)
                [ "${line#*USB image under test: }" = "$img" ] && marker=1 ;;
            *"PHASE D PASS"*) [ "$marker" = 1 ] && pass=1 ;;
        esac
    done < "$lg"
    [ "$marker" = 1 ] || { say "the sibling never logged a run of $img in the lines it just appended"; return 1; }
    [ "$pass" = 1 ] || { say "the sibling's run of $img did not reach PHASE D PASS"; return 1; }
    return 0
}

if [ "$RESUME" = 0 ]; then
    say "════ INSTALL: delegating phases A-D to $(basename "$NESTED_TEST") ════"
    [ -x "$NESTED_TEST" ] || fatal - "sibling rig not executable: $NESTED_TEST"
    # The sibling cds to $HOME/appliance/v3 itself and has no RIG_DIR knob.
    # Said out loud rather than silently tolerated: on a scratch rig the
    # delegated install would run against a DIFFERENT directory than the
    # image this script resolved, and the evidence check below would then
    # fail for a confusing reason instead of this one.
    [ "$RIG_DIR" = "$HOME/appliance/v3" ] || say "WARN: RIG_DIR is $RIG_DIR but $(basename "$NESTED_TEST") hardcodes \$HOME/appliance/v3 — run with --resume, or point RIG_DIR at the default, if the install phases are needed"
    PRELINES=0
    [ -f "$NESTED_LOG" ] && PRELINES="$(awk 'END{print NR}' "$NESTED_LOG")"
    say "sibling log $NESTED_LOG is $PRELINES lines before this run"
    say "running: USBIMG=$IMGBASE $NESTED_TEST all   (its output goes to $NESTED_LOG, not here)"
    USBIMG="$IMGBASE" "$NESTED_TEST" all
    NRC=$?
    say "sibling rig exited $NRC"
    # rc first, evidence second: both must agree.  A sibling that exited 0
    # without logging a PASS, or logged a PASS and exited nonzero, is a
    # rig that is lying in one direction or the other — refuse either way.
    [ "$NRC" -eq 0 ] || fatal - "$(basename "$NESTED_TEST") exited $NRC — the install this update test builds on did not pass (see $NESTED_LOG)"
    require_phase_d_pass "$NESTED_LOG" "$PRELINES" "$IMGBASE" \
        || fatal - "no PHASE D PASS for $IMGBASE in the lines $(basename "$NESTED_TEST") just appended to $NESTED_LOG"
    say "INSTALL evidence OK: PHASE D PASS for $IMGBASE in this run's block"
else
    say "════ RESUME: reusing the nested production PM/VM from a previous run ════"
fi

# ── reach the nested rig, and PROVE it is the nested rig ────────────────
vm_running || fatal - "no nested qemu guest (guest=sigv3) is running on this host — nothing to drive.$([ "$RESUME" = 1 ] && echo ' Re-run WITHOUT --resume to install and boot one.')"
resolve_ssh 60 5 "update-rig" || fatal - "the nested PM did not answer ssh"

# TARGET GUARD — three independent facts must all hold before ANY mutation.
# The rig drives a REAL root channel; if $SSHN ever resolved to a live
# station this script would roll it back to a blessed baseline through
# `manifest restore`.  So: the ssh command must be the loopback forward
# this rig owns, a nested qemu guest must be running locally (proving the
# forward terminates inside our own VM and not in a tunnel), and the PM's
# own hostname must match the nested naming.  Any one of these failing
# stops the run before the first write.
case "$SSHN" in
    *"-p 5561"*"root@127.0.0.1"*) : ;;
    *) fatal - "target guard: \$SSHN does not name the nested rig's loopback forward (-p 5561 root@127.0.0.1): $SSHN" ;;
esac
PMHOST="$($SSHN hostname 2>/dev/null)"
NESTED_PM_RE="${NESTED_PM_RE:-^(N0CALL-T1-PM|sigmond-appliance-v3)}"
printf '%s\n' "$PMHOST" | grep -qE "$NESTED_PM_RE" \
    || fatal - "target guard: nested PM hostname '$PMHOST' does not match the nested naming $NESTED_PM_RE — refusing to touch it (this is how the rig stays incapable of reaching the real fleet)"
VMNAME="$($SSHN "qm config $VMID 2>/dev/null" | sed -n 's/^name: //p')"
case "$VMNAME" in
    N0CALL-T1|sigmond-decoder-v3) : ;;
    *) fatal - "target guard: VM $VMID on $PMHOST is named '$VMNAME', not the nested rig's wizard-configured name — refusing to exec into it" ;;
esac
say "target guard OK: loopback forward → nested PM '$PMHOST' → VM $VMID '$VMNAME'"

# The guest agent must answer twice in a row: a lone success during guest
# boot can be followed by an agent restart (observed 2026-07-26, false
# FATAL in the sibling).
AGENT_OK=0
for i in $(seq 1 40); do
    if $SSHN "qm agent $VMID ping" >/dev/null 2>&1; then
        AGENT_OK=$((AGENT_OK + 1)); [ "$AGENT_OK" -ge 2 ] && break; sleep 3
    else
        AGENT_OK=0; sleep 10
    fi
done
[ "$AGENT_OK" -ge 2 ] || fatal - "guest agent in VM $VMID never answered twice in a row — the update channel is unusable$([ "$RESUME" = 1 ] && echo ' (is the VM running? qm status '"$VMID"')')"
say "guest agent answering; the production root channel is open"

# Prove the channel really lands in the guest with a production PATH before
# any assertion depends on it — a `smd: command not found` discovered
# halfway through PHASE E reads like a broken update, not a broken channel.
gx_ok 60 e0-channel '
command -v smd
rc=$?
echo "PATH=$PATH"
id -un
exit $rc' "channel smoke test"
[ "$GX_RC" -eq 0 ] || fatal "$GX_OUT" "smd is not on the login PATH inside VM $VMID (rc=$GX_RC) — this is the runuser/PATH failure class the rig exists to catch"
grep -q '^/.*/smd$' "$GX_OUT" || fatal "$GX_OUT" "channel smoke test did not resolve smd to a path"
say "channel: smd resolves to $(sed -n '1p' "$GX_OUT") as $(sed -n '3p' "$GX_OUT")"

# ════════════════════════════════════════════════════════════════════════
say "════ PHASE E: forward roll to $TARGET ($TARGET_SHA) ════"

# ── pre-state ───────────────────────────────────────────────────────────
gx_ok 300 e1-version-pre 'smd version' "pre-state: smd version"
[ "$GX_RC" -eq 0 ] || fatal "$GX_OUT" "smd version failed (rc=$GX_RC) before the update — pre-state cannot be trusted"
components_rows "$GX_OUT" "$WORK/live-pre.rows"
PREROWS="$(rows_count "$WORK/live-pre.rows")"
[ "$PREROWS" -ge "$MIN_ROWS" ] || fatal "$GX_OUT" "smd version yielded only $PREROWS component rows (floor $MIN_ROWS) — a truncated capture, not a pre-state"
say "pre-update live components ($PREROWS):"
sed 's/^/      /' "$WORK/live-pre.rows"

gx_ok 900 e2-doctor-pre 'smd doctor' "pre-state: smd doctor"
DOCTOR_PRE_RC="$GX_RC"
cp "$GX_OUT" "$WORK/doctor-pre.txt"
doctor_kinds "$WORK/doctor-pre.txt" "$WORK/kinds-pre.txt"
say "pre-update smd doctor exit $DOCTOR_PRE_RC; finding kinds: $(tr '\n' ' ' < "$WORK/kinds-pre.txt")"
excerpt "$WORK/doctor-pre.txt" 20

# ── the update itself, through the production channel ───────────────────
say "── smd update --apply (this is the channel that crashed on runuser/PATH)"
gx_ok 3600 e3-update-apply 'smd update --apply' "smd update --apply"
UPD_RC="$GX_RC"
say "── full smd update --apply output ──"
cat "$WORK/e3-update-apply.out"
say "── end smd update --apply output (rc=$UPD_RC) ──"
# A traceback means smd itself died mid-update.  Grepping for it separately
# from the exit code is deliberate: the crash class this rig targets has
# shown up BOTH as a nonzero exit and as a caught-and-swallowed stack trace
# on an otherwise "successful" run.
if grep -q 'Traceback (most recent call last)' "$WORK/e3-update-apply.out"; then
    fatal "$WORK/e3-update-apply.out" "smd update --apply printed a Python traceback — smd crashed inside the production root channel"
fi
if grep -qE 'runuser: (may not be used|failed to execute|cannot)' "$WORK/e3-update-apply.out"; then
    fatal "$WORK/e3-update-apply.out" "smd update --apply hit a runuser failure — this is the exact regression this rig was built for"
fi
case "$UPD_RC" in
    0) say "smd update --apply exit 0" ;;
    3) # UPDATE_EXIT_HELD.  A deliberate hold (routine uv.lock churn is
       # exactly that) is a steady state, not a failure — smd itself
       # treats 3 as "nothing actionable", and the idempotence assertion
       # below accepts 3 for the same reason.  Failing here while passing
       # there would be the rig contradicting itself, so this is a loud
       # WARN with the holds NAMED, never a silent pass.
       say "WARN: smd update --apply exit 3 (HELD) — components declined, nothing failed:"
       grep -E 'HELD' "$WORK/e3-update-apply.out" | sed 's/^/      /'
       ;;
    *) fatal "$WORK/e3-update-apply.out" "smd update --apply exited $UPD_RC through the production root channel" ;;
esac

# ── idempotence ─────────────────────────────────────────────────────────
say "── smd update (dry) must now be a no-op"
gx_ok 900 e4-update-dry 'smd update' "smd update (dry, idempotence)"
DRY_RC="$GX_RC"
case "$DRY_RC" in
    0|3) : ;;
    *) fatal "$WORK/e4-update-dry.out" "re-running smd update after --apply exited $DRY_RC (expected 0, or 3 for HELD-only) — the update is not idempotent" ;;
esac
# `nothing to do` is the phrase smd emits from _no_actionable_outcome
# whenever no runnable steps remain — it is what `smd fleet update` uses to
# recognise a host as arrived, and it is emitted for the HELD-only case too
# (with the holds named on the same line, so it can never read as
# "everything is current").  Its ABSENCE means real steps were still
# planned, which is the "nothing to do used to lie" defect inverted.
grep -q 'nothing to do' "$WORK/e4-update-dry.out" \
    || fatal "$WORK/e4-update-dry.out" "smd update (dry) exited $DRY_RC but did not say 'nothing to do' — steps remain planned after --apply"
say "idempotent: smd update (dry) exit $DRY_RC, plan empty or HELD-only"

# ── level with --target ─────────────────────────────────────────────────
gx_ok 300 e5-version-post 'smd version' "post-update: smd version"
[ "$GX_RC" -eq 0 ] || fatal "$GX_OUT" "smd version failed (rc=$GX_RC) after the update"
components_rows "$GX_OUT" "$WORK/live-post.rows"
POSTROWS="$(rows_count "$WORK/live-post.rows")"
[ "$POSTROWS" -ge "$MIN_ROWS" ] || fatal "$GX_OUT" "post-update smd version yielded only $POSTROWS component rows (floor $MIN_ROWS)"
say "post-update live components ($POSTROWS):"
sed 's/^/      /' "$WORK/live-post.rows"

LIVE_SIGMOND="$(sha_of "$WORK/live-post.rows" sigmond)"
[ -n "$LIVE_SIGMOND" ] || fatal "$WORK/live-post.rows" "no 'sigmond' row in the post-update components block"
sha_equal "$LIVE_SIGMOND" "$TARGET_SHA" \
    || fatal "$WORK/e5-version-post.out" "sigmond is live at $LIVE_SIGMOND but $TARGET is $TARGET_SHA — the update did not reach the target (this is dasi002's silent 3-behind, caught)"
say "sigmond live $LIVE_SIGMOND == $TARGET $TARGET_SHA ✓"

# Every OTHER component tracks its own upstream, not this rig's --target,
# so "level" for them means "nothing left to pull".  Asking git directly
# (after smd's own fetch, which `smd update` did by default above) is the
# assertion dasi002 needed: `behind` must be 0 for every checkout that has
# an upstream at all.
gx_ok 600 e6-behind '
for d in /opt/git/sigmond/*/; do
    [ -d "$d/.git" ] || continue
    n=$(basename "$d")
    if git --no-optional-locks -C "$d" rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1; then
        b=$(git --no-optional-locks -C "$d" rev-list --count "HEAD..@{u}" 2>/dev/null)
        echo "BEHIND $n ${b:-unknown}"
    else
        echo "NOUPSTREAM $n"
    fi
done
exit 0' "post-update: behind counts"
sed 's/^/      /' "$WORK/e6-behind.out"
BEHIND_BAD="$(awk '$1=="BEHIND" && $3!="0" {printf "%s(%s) ", $2, $3}' "$WORK/e6-behind.out")"
[ -z "$BEHIND_BAD" ] || fatal "$WORK/e6-behind.out" "components still behind their upstream after smd update --apply: $BEHIND_BAD"
NOUP="$(awk '$1=="NOUPSTREAM" {printf "%s ", $2}' "$WORK/e6-behind.out")"
[ -z "$NOUP" ] && say "every component checkout is level with its upstream ✓" \
               || say "every component with an upstream is level ✓ (no upstream, not assessed: $NOUP)"

# ── doctor gained no NEW finding kinds ──────────────────────────────────
gx_ok 900 e7-doctor-post 'smd doctor' "post-update: smd doctor"
DOCTOR_POST_RC="$GX_RC"
cp "$GX_OUT" "$WORK/doctor-post.txt"
doctor_kinds "$WORK/doctor-post.txt" "$WORK/kinds-post.txt"
say "post-update smd doctor exit $DOCTOR_POST_RC; finding kinds: $(tr '\n' ' ' < "$WORK/kinds-post.txt")"
NEWK="$(new_kinds "$WORK/kinds-pre.txt" "$WORK/kinds-post.txt" | tr '\n' ' ')"
if [ -n "$NEWK" ]; then
    excerpt "$WORK/doctor-post.txt" 40
    fatal - "smd doctor gained NEW finding kinds across the update: $NEWK (pre: $(tr '\n' ' ' < "$WORK/kinds-pre.txt")). If one of these is a ruled-on, sanctioned consequence of an install.sh run — uv.lock churn is the known case — re-run with U2_ALLOW_NEW_KINDS=$(printf '%s' "$NEWK" | tr ' ' ',' | sed 's/,$//')"
fi
say "no NEW doctor finding kinds across the update ✓"

# ── the awareness payload survives an update, not just an install ───────
# Same ruled contract Phase D asserts on a fresh image (fleet-awareness plan
# Phase 6): no [heartbeat] block means emit --dry-run exits 2 WITH the
# not-enabled message.  Exit 0 would mean a config leaked in; any other exit
# means the CLI is broken.  Asserting it AFTER the update is the point: an
# update that quietly unwired the heartbeat would leave the fleet blind in
# exactly the situation the heartbeat exists for.
gx_ok 120 e8-heartbeat 'smd admin heartbeat emit --dry-run' "heartbeat contract"
[ "$GX_RC" -eq 2 ] || fatal "$WORK/e8-heartbeat.out" "smd admin heartbeat emit --dry-run exited $GX_RC after the update (expected 2 on an unconfigured image)"
grep -q 'heartbeat: not enabled' "$WORK/e8-heartbeat.out" \
    || fatal "$WORK/e8-heartbeat.out" "heartbeat emit --dry-run exited 2 but without the 'heartbeat: not enabled' message — the CLI contract changed under the update"
say "heartbeat CLI contract intact after the update: exit 2 + not-enabled ✓"

say "PHASE E PASS — rolled forward to $TARGET_SHA, idempotent, level, no new findings"

# ════════════════════════════════════════════════════════════════════════
say "════ PHASE F: adopt the blessed manifest (superset-tolerant) ════"

# File injection reuses the production idiom — sigmond-wizard.sh's gexec
# ships every file it plants in the guest as `echo <b64> | base64 -d > path`
# — and then VERIFIES the landing by checksum.  Assuming a copy landed
# intact is how a 127-byte payload once shipped as a whole appliance.
GMANIFEST=/root/u2/blessed.manifest.txt
MB64="$(base64 -w0 "$MANIFEST")"
MSHA="$(sha256sum "$MANIFEST" | awk '{print $1}')"
gx_ok 120 f1-inject "
mkdir -p /root/u2
echo $MB64 | base64 -d > $GMANIFEST
sha256sum $GMANIFEST" "inject the blessed manifest"
[ "$GX_RC" -eq 0 ] || fatal "$WORK/f1-inject.out" "could not write $GMANIFEST in the guest (rc=$GX_RC)"
GSHA="$(awk '{print $1; exit}' "$WORK/f1-inject.out")"
[ "$GSHA" = "$MSHA" ] || fatal "$WORK/f1-inject.out" "the manifest did not land intact: rig $MSHA vs guest $GSHA"
say "manifest landed in the guest at $GMANIFEST, sha256 verified ✓"

gx_ok 600 f2-adopt "smd admin manifest adopt $GMANIFEST --allow-superset --apply" "manifest adopt --allow-superset --apply"
sed 's/^/      /' "$WORK/f2-adopt.out"
[ "$GX_RC" -eq 0 ] || fatal "$WORK/f2-adopt.out" "smd admin manifest adopt --allow-superset --apply exited $GX_RC — the updated guest is not even a sanctioned superset of the blessed baseline"
grep -q 'plan OK' "$WORK/f2-adopt.out" \
    || fatal "$WORK/f2-adopt.out" "adopt exited 0 without printing 'plan OK' — the verb's contract changed"
# Superset presence is REPORTED, never asserted: whether main has moved past
# the image between the build and this run is a property of the calendar,
# not of the product.  Asserting it would make the rig fail on the one day
# a release is tested the hour it is cut.
if grep -q 'sanctioned superset' "$WORK/f2-adopt.out"; then
    say "adopt: sanctioned superset — main has moved past the image, ancestry-verified ✓"
else
    say "adopt: exact match — main has not moved past $IMGBASE since it was built"
fi
say "PHASE F PASS — the updated guest satisfies the blessed baseline"

# ════════════════════════════════════════════════════════════════════════
say "════ PHASE G: rollback to the blessed baseline, then prove it ════"

gx_ok 600 g1-restore-dry "smd admin manifest restore $GMANIFEST" "manifest restore (dry)"
sed 's/^/      /' "$WORK/g1-restore-dry.out"
if grep -qi "invalid choice: 'restore'\|argument manifest_command" "$WORK/g1-restore-dry.out"; then
    fatal "$WORK/g1-restore-dry.out" "this guest's smd has no 'admin manifest restore' verb — PHASE G's rollback contract is not implemented in the sigmond it just updated to"
fi
[ "$GX_RC" -eq 0 ] || fatal "$WORK/g1-restore-dry.out" "smd admin manifest restore (dry) exited $GX_RC"

# --no-fetch is only correct if every manifest sha is already an object in
# the guest's own checkouts.  After PHASE E it should be (the guest moved
# PAST those commits, it did not skip them) — but "should be" is what this
# project keeps getting wrong, so the rig asks instead of assuming, and
# falls back to a fetching restore rather than failing.
{
    cat <<'SNIP_HEAD'
miss=0
while read -r n s; do
    d=/opt/git/sigmond/$n
    if [ ! -d "$d/.git" ]; then echo "ABSENT $n"; continue; fi
    if git --no-optional-locks -C "$d" cat-file -e "${s}^{commit}" 2>/dev/null; then
        echo "LOCAL $n"
    else
        echo "MISSING $n"; miss=1
    fi
done <<'ROWS'
SNIP_HEAD
    cat "$WORK/manifest.rows"
    cat <<'SNIP_TAIL'
ROWS
echo "MISS=$miss"
exit 0
SNIP_TAIL
} > "$WORK/g2-local.snip"
gx_ok 300 g2-local "$(cat "$WORK/g2-local.snip")" "are the blessed shas already local?"
sed 's/^/      /' "$WORK/g2-local.out"
if grep -q '^MISS=0$' "$WORK/g2-local.out"; then
    NOFETCH="--no-fetch"
    say "every blessed sha is already an object in the guest's checkouts → restoring with --no-fetch"
else
    NOFETCH=""
    say "WARN: some blessed shas are not local ($(awk '$1=="MISSING"{printf "%s ", $2}' "$WORK/g2-local.out")) → restoring WITHOUT --no-fetch"
fi

gx_ok 1800 g3-restore-apply "smd admin manifest restore $GMANIFEST --apply $NOFETCH" "manifest restore --apply"
sed 's/^/      /' "$WORK/g3-restore-apply.out"
[ "$GX_RC" -eq 0 ] || fatal "$WORK/g3-restore-apply.out" "smd admin manifest restore --apply $NOFETCH exited $GX_RC — the rollback path is broken, which is worse than the forward path being broken"
grep -q 'adopt-strict verifies clean' "$WORK/g3-restore-apply.out" \
    || fatal "$WORK/g3-restore-apply.out" "restore --apply exited 0 without 'adopt-strict verifies clean' — it did not self-verify, so its success is unproven"
say "restore --apply exit 0, self-verified ✓"

# ── the live tree must now BE the manifest, read back independently ────
gx_ok 300 g4-version 'smd version' "post-restore: smd version"
[ "$GX_RC" -eq 0 ] || fatal "$WORK/g4-version.out" "smd version failed (rc=$GX_RC) after the restore"
components_rows "$GX_OUT" "$WORK/live-restored.rows"
RROWS="$(rows_count "$WORK/live-restored.rows")"
[ "$RROWS" -ge "$MIN_ROWS" ] || fatal "$WORK/g4-version.out" "post-restore smd version yielded only $RROWS component rows (floor $MIN_ROWS)"
say "post-restore live components ($RROWS):"
sed 's/^/      /' "$WORK/live-restored.rows"
MISMATCH=""
while read -r mname msha; do
    lsha="$(sha_of "$WORK/live-restored.rows" "$mname")"
    if [ -z "$lsha" ]; then
        MISMATCH="$MISMATCH $mname(manifest=$msha,live=absent)"
    elif ! sha_equal "$lsha" "$msha"; then
        MISMATCH="$MISMATCH $mname(manifest=$msha,live=$lsha)"
    fi
done < "$WORK/manifest.rows"
[ -z "$MISMATCH" ] || fatal "$WORK/g4-version.out" "after restore, live SHAs do not equal the manifest's:$MISMATCH"
say "every one of the $MROWS manifest components is live at its blessed sha ✓"

# ── the round-trip proof: a STRICT adopt, no superset flag ─────────────
gx_ok 600 g5-adopt-strict "smd admin manifest adopt $GMANIFEST --apply" "manifest adopt (STRICT)"
sed 's/^/      /' "$WORK/g5-adopt-strict.out"
[ "$GX_RC" -eq 0 ] || fatal "$WORK/g5-adopt-strict.out" "STRICT smd admin manifest adopt --apply exited $GX_RC after the restore — the round trip did not close"
grep -q 'plan OK' "$WORK/g5-adopt-strict.out" \
    || fatal "$WORK/g5-adopt-strict.out" "strict adopt exited 0 without 'plan OK'"
say "round trip closed: strict adopt (no --allow-superset) accepts the restored tree ✓"

# ── doctor after the rollback ──────────────────────────────────────────
gx_ok 900 g6-doctor 'smd doctor' "post-restore: smd doctor"
DOCTOR_G_RC="$GX_RC"
cp "$GX_OUT" "$WORK/doctor-post-restore.txt"
doctor_kinds "$WORK/doctor-post-restore.txt" "$WORK/kinds-restored.txt"
say "post-restore smd doctor exit $DOCTOR_G_RC; finding kinds: $(tr '\n' ' ' < "$WORK/kinds-restored.txt")"
# `detached` is EXPECTED here, and its absence is the interesting failure:
# restore pins each checkout to a sha, which detaches HEAD by construction.
# A clean-looking doctor after a restore would mean the restore did not
# actually move the checkouts — success reported for work not done, the
# failure shape this whole project keeps hitting.
grep -qx 'detached' "$WORK/kinds-restored.txt" \
    || fatal "$WORK/doctor-post-restore.txt" "smd doctor reports NO 'detached' finding after a restore — restore is supposed to pin checkouts to the manifest shas, so either it did not move them or doctor stopped seeing it"
say "expected 'detached' finding present — restore pinned the checkouts as designed ✓"
NEWG="$(new_kinds "$WORK/kinds-pre.txt" "$WORK/kinds-restored.txt" detached | tr '\n' ' ')"
if [ -n "$NEWG" ]; then
    excerpt "$WORK/doctor-post-restore.txt" 40
    fatal - "smd doctor gained NEW finding kinds across the rollback (beyond the expected 'detached'): $NEWG (pre-E baseline: $(tr '\n' ' ' < "$WORK/kinds-pre.txt"))"
fi
say "no NEW doctor finding kinds across the rollback beyond the expected 'detached' ✓"

say "PHASE G PASS — rolled back to the blessed baseline and proved it strictly"
say "UPDATE RIG COMPLETE — $IMGBASE rolled forward to $TARGET_SHA and back, both directions verified"
say "evidence: $WORK   log: $LOG"
exit 0
