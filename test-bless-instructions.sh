#!/bin/bash
# test-bless-instructions.sh — bless-release.sh gate 7 (the install instructions
# name this release) and the two files --apply publishes beside the image.
#
# Hermetic.  Each scene builds a scratch origin, a scratch checkout, a scratch
# rig directory and a fake remote tree.  Stub gh, rclone, ssh and scp stand in
# for the real ones: the rclone, ssh and scp stubs write into the fake remote
# tree, so a test can read back what a target received.  No network, no Drive,
# no wd30, no rig; about 10 s.
#
# ⛔ WHY THIS EXISTS.  On 2026-10-08 Michael set the policy: every build gets
# updated install instructions, and the bless carries them.  The rule had lived
# since the day before as one paragraph in docs/RELEASE.md, and nothing
# enforced it.  A paragraph that nothing enforces describes the last release,
# not the next.
# Gate 7 makes the bless refuse while INSTALL.md or the install page still
# describe the previous image.  --apply then publishes both beside the image.
#
# The timing is the subtle part.  The tag is cut BEFORE the hardware test and
# INSTALL.md gets its "Verified against" line AFTER it, in a commit later than
# the tag.  So the gate must read origin/main.  Not the tag's tree, which holds
# the previous release's words.  Not the working tree, which may differ from
# what the team pushed.  Every scene here is built that way: the tag commit
# carries the v3.69 instructions, and the current ones arrive in a later commit
# that reaches origin/main only after the checkout is cloned.
#
# Run it against a mutated copy to measure its power:
#
#   usage: [SHOW="ok apply"] ./test-bless-instructions.sh [path/to/bless-release.sh]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BLESS="${1:-$HERE/bless-release.sh}"
[ -f "$BLESS" ] || { echo "FATAL: no bless-release.sh at $BLESS"; exit 1; }
BLESS="$(cd "$(dirname "$BLESS")" && pwd)/$(basename "$BLESS")"
LIB="$HERE/publish-lib.sh"
[ -f "$LIB" ] || { echo "FATAL: no publish-lib.sh at $LIB"; exit 1; }
command -v script >/dev/null || { echo "FATAL: script(1) missing -- --apply needs a pty for its confirmation"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=scratch GIT_AUTHOR_EMAIL=scratch@example.invalid
export GIT_COMMITTER_NAME=scratch GIT_COMMITTER_EMAIL=scratch@example.invalid

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
chk() { # chk <desc> <got> <want>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want: $3 | got: $2"; fi; }
has() { # has <desc> <haystack> <needle>
    case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing: $3 | in: ${2:0:300}" ;; esac; }
lacks() { # lacks <desc> <haystack> <needle>
    case "$2" in *"$3"*) bad "$1" "found: $3 | in: ${2:0:300}" ;; *) ok "$1" ;; esac; }

# ── stubs ───────────────────────────────────────────────────────────────────
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >> "$STUB_CALLS"
case "${1:-} ${2:-}" in
    "release view") echo "release not found" >&2; exit 1 ;;
    "release create")
        a=("$@")
        for ((i=0; i<${#a[@]}; i++)); do
            [ "${a[$i]}" = "--notes-file" ] && cp "${a[$((i+1))]}" "$STUB_REMOTE/../notes.copy"
        done
        exit "${STUB_GH_CREATE_RC:-0}" ;;
esac
exit 0
EOF
# rclone: "remote:path" lands in $STUB_REMOTE/remote/path.  STUB_FAIL_PUT is a
# glob; a copyto whose destination matches it fails.
cat > "$T/bin/rclone" <<'EOF'
#!/bin/bash
echo "rclone $*" >> "$STUB_CALLS"
map() { echo "$STUB_REMOTE/${1/:/\/}"; }
op="$1"; shift
case "$op" in
    copyto)
        shift  # -q
        if [ -n "${STUB_FAIL_PUT:-}" ]; then
            # shellcheck disable=SC2053
            [[ "$2" == $STUB_FAIL_PUT ]] && { echo "stub: forced copyto failure" >&2; exit 1; }
        fi
        dst="$(map "$2")"; mkdir -p "$(dirname "$dst")"; cp "$1" "$dst" ;;
    moveto)
        shift
        src="$(map "$1")"; dst="$(map "$2")"
        [ -f "$src" ] || { echo "stub: no such file $1" >&2; exit 3; }
        mkdir -p "$(dirname "$dst")"; mv "$src" "$dst" ;;
    link) echo "https://drive.google.com/open?id=STUBID" ;;
    lsf)
        p=""; for x in "$@"; do case "$x" in --*) ;; *) p="$x" ;; esac; done
        d="$(map "$p")"; [ -d "$d" ] || exit 3; ls -1 "$d" ;;
    deletefile) rm -f "$(map "$1")" ;;
    purge) rm -rf "$(map "$1")" ;;
esac
exit 0
EOF
# ssh: runs the command in a fake home directory for the host.
cat > "$T/bin/ssh" <<'EOF'
#!/bin/bash
echo "ssh $*" >> "$STUB_CALLS"
[ -n "${STUB_FAIL_SSH:-}" ] && exit 255
shift 2   # -o BatchMode=yes
h="$1"; cmd="$2"
home="$STUB_REMOTE/home-$h"; mkdir -p "$home"
cd "$home" && exec bash -c "$cmd"
EOF
# scp: copies into the fake home.  STUB_FAIL_SCP set = every scp fails.
cat > "$T/bin/scp" <<'EOF'
#!/bin/bash
echo "scp $*" >> "$STUB_CALLS"
[ -n "${STUB_FAIL_SCP:-}" ] && exit 1
shift 3   # -q -o BatchMode=yes
args=("$@"); dest="${args[-1]}"; unset 'args[-1]'
h="${dest%%:*}"; p="${dest#*:}"
dir="$STUB_REMOTE/home-$h/$p"; mkdir -p "$dir"
cp "${args[@]}" "$dir/"
EOF
chmod +x "$T"/bin/*

# ── fixtures ────────────────────────────────────────────────────────────────
inst() { # inst <status> <verified-against text>
    printf '# Sigmond Station -- Installation Guide\n\n> **Audience:** operator\n> **Status:** %s\n> **Verified against:** %s\n> **Canonical for:** burning and booting\n\nBody text.\n' "$1" "$2"; }
page() { # page <image file name>
    printf '<title>Installing a Sigmond Station</title>\n<p>Download <span>%s</span> and flash it.</p>\n' "$1"; }

OLD_IMG=sigmond-appliance-v3.69-20261007-release.img
IMG=sigmond-appliance-v3.70-20261008-release.img
STEM="${IMG%.img}"
OLD_INST="$(inst current 'sigmond-appliance v3.69 (1c63a35) with sigmond f01e86f, hardware install 2026-10-07')"
OLD_PAGE="$(page "$OLD_IMG")"
GOOD_INST="$(inst current 'sigmond-appliance v3.70 (4c976c8) with sigmond 61f22db, hardware install 2026-10-08')"
GOOD_PAGE="$(page "$IMG")"

sc_reset() {
    SC_VERSION=v3.70; SC_DATE=20261008
    SC_INSTALL=""; SC_PAGE=""            # commit 2, pushed to origin/main ("" = no change; DELETE = remove)
    SC_LOCAL_INSTALL=""; SC_LOCAL_PAGE=""  # an UNPUSHED commit in the checkout
    SC_NOIMAGE=0; SC_NOPENDING=""
}

# mkscene <name> — builds $T/<name>/{origin.git,seed,repo,rig,bless,remote,tmp}.
mkscene() {
    local n="$1" S="$T/$1" v="$SC_VERSION" d="$SC_DATE"
    local img="sigmond-appliance-$v-$d-release.img" stem="sigmond-appliance-$v-$d-release"
    mkdir -p "$S/rig" "$S/bless" "$S/remote" "$S/tmp"
    git init -q -b main --bare "$S/origin.git"
    git clone -q "$S/origin.git" "$S/seed" 2>/dev/null
    (   cd "$S/seed" || exit 1
        printf '#!/bin/bash\necho firstboot @@VERSION@@\n' > firstboot-v3.sh
        mkdir -p docs
        printf '%s\n' "$OLD_INST" > INSTALL.md
        printf '%s\n' "$OLD_PAGE" > docs/install-page.html
        git add -A && git commit -q -m "initial: firstboot and the v3.69 instructions"
        git tag "$v"
        git push -q origin main "refs/tags/$v" 2>/dev/null
    )
    # The bless's checkout, cloned at the tag.  The instructions commit lands on
    # origin/main AFTER this clone, as it does on the rig: gate 1's fetch has to
    # bring it in before gate 7 reads it.
    git clone -q "$S/origin.git" "$S/repo" 2>/dev/null
    (   cd "$S/seed" || exit 1
        if [ -n "$SC_INSTALL" ] || [ -n "$SC_PAGE" ]; then
            case "$SC_INSTALL" in
                '')     ;;
                DELETE) git rm -q INSTALL.md ;;
                *)      printf '%s\n' "$SC_INSTALL" > INSTALL.md ;;
            esac
            case "$SC_PAGE" in
                '')     ;;
                DELETE) git rm -q docs/install-page.html ;;
                *)      printf '%s\n' "$SC_PAGE" > docs/install-page.html ;;
            esac
            git add -A && git commit -q -m "docs: instructions for the new image"
            git push -q origin main 2>/dev/null
        fi
    )
    if [ -n "$SC_LOCAL_INSTALL" ] || [ -n "$SC_LOCAL_PAGE" ]; then
        (   cd "$S/repo" || exit 1
            [ -n "$SC_LOCAL_INSTALL" ] && printf '%s\n' "$SC_LOCAL_INSTALL" > INSTALL.md
            [ -n "$SC_LOCAL_PAGE" ] && printf '%s\n' "$SC_LOCAL_PAGE" > docs/install-page.html
            git add -A && git commit -q -m "local only: never pushed"
        )
    fi
    if [ "$SC_NOIMAGE" != 1 ]; then
        printf 'image bytes for %s\n' "$img" > "$S/rig/$img"
        (cd "$S/rig" && sha256sum "$img" > "$stem.sha256")
        local fb; fb="$(sed "s|@@VERSION@@|$v|g" "$S/seed/firstboot-v3.sh" | sha256sum | cut -d' ' -f1)"
        printf 'version: %s\ncomponents\n    sigmond  abc1234\n    hs-uploader  def5678\nfirstboot_sha256: %s\n' "$v" "$fb" > "$S/rig/$stem.manifest.txt"
        printf 'USB image under test: %s\nPHASE D PASS -- NESTED TEST COMPLETE\n' "$img" > "$S/rig/test-v3.log"
    fi
    cp "$BLESS" "$S/bless/bless-release.sh"; cp "$LIB" "$S/bless/publish-lib.sh"
    cat > "$S/bless/publish-targets.conf" <<'EOF'
rob   gdrive:sigmond-images             pending
mjh   gdrive,root_folder_id=ABC123:     pending
wd30  ssh:wd30:                         pending
bl    gdrive:blessed-only               blessed
EOF
    # The pending-stage targets hold the build in pending/ already.
    local t
    for t in "gdrive/sigmond-images" "gdrive,root_folder_id=ABC123" "home-wd30"; do
        case "$t" in home-wd30) case " $SC_NOPENDING " in *" wd30 "*) continue ;; esac ;; esac
        mkdir -p "$S/remote/$t/pending"
        if [ "$SC_NOIMAGE" != 1 ]; then
            cp "$S/rig/$img" "$S/rig/$stem.sha256" "$S/rig/$stem.manifest.txt" "$S/remote/$t/pending/"
        fi
    done
}

# run_bless <scene> <apply 0|1> — sets OUT (CR-stripped) and RC.  --apply runs
# under script(1) because the confirmation reads /dev/tty and fails closed
# without one.  The typed phrase goes in through script's stdin.
run_bless() {
    local S="$T/$1" apply="$2"
    : > "$S/calls"
    if [ "$apply" = 1 ]; then
        OUT="$(cd "$S" && printf 'publish %s\n' "$SC_VERSION" | env \
            APPLIANCE_REPO="$S/repo" RIG_DIR="$S/rig" GH_REPO_SLUG=Scratch/appliance \
            STUB_REMOTE="$S/remote" STUB_CALLS="$S/calls" TMPDIR="$S/tmp" PATH="$T/bin:$PATH" \
            script -qefc "bash '$S/bless/bless-release.sh' $SC_VERSION --apply" /dev/null 2>&1)"
        RC=$?
    else
        OUT="$(cd "$S" && env \
            APPLIANCE_REPO="$S/repo" RIG_DIR="$S/rig" GH_REPO_SLUG=Scratch/appliance \
            STUB_REMOTE="$S/remote" STUB_CALLS="$S/calls" TMPDIR="$S/tmp" PATH="$T/bin:$PATH" \
            bash "$S/bless/bless-release.sh" "$SC_VERSION" 2>&1)"
        RC=$?
    fi
    OUT="$(printf '%s' "$OUT" | tr -d '\r')"
    # SHOW="ok apply" prints those scenes' output, for debugging a failure.
    case " ${SHOW:-} " in *" $1 "*) printf '%s\n' "$OUT" | sed 's/^/      | /' ;; esac
}
g7() { grep -F '[gate 7 (install instructions name this release)' <<<"$OUT" || true; }
leftover() { find "$T/$1/tmp" -mindepth 1 2>/dev/null | wc -l | tr -d ' '; }

# expect_fail <desc> <must-name...> — gate 7 FAILs, names each of the strings,
# the run exits 1, and nothing is left in TMPDIR.
G7=""
expect_g7_fail() { # <scene> <desc> <needle>...
    local s="$1" desc="$2"; shift 2
    G7="$(g7)"
    has "$desc: gate 7 FAILs" "$G7" " FAIL "
    local nd; for nd in "$@"; do has "$desc: detail names '$nd'" "$G7" "$nd"; done
    chk "$desc: the bless exits 1" "$RC" "1"
    lacks "$desc: no unbound variable" "$OUT" "unbound variable"
    chk "$desc: no temp files left" "$(leftover "$s")" "0"
}

# ═══════════════════════════════════════════════════════════════════════════
echo "gate 7: a correct INSTALL.md and page at origin/main"
sc_reset; SC_INSTALL="$GOOD_INST"; SC_PAGE="$GOOD_PAGE"; mkscene ok; run_bless ok 0
G7="$(g7)"
has   "gate 7 is reported, named as specified" "$G7" "7 (install instructions name this release)"
has   "gate 7 PASSes"                           "$G7" " PASS "
has   "the PASS detail names the image"         "$G7" "$IMG"
chk   "the bless exits 0"                       "$RC" "0"
has   "all gates pass"                          "$OUT" "ALL GATES PASS"
lacks "no unbound variable"                     "$OUT" "unbound variable"
chk   "no temp files left"                      "$(leftover ok)" "0"

echo "the dry run says what it would publish, and publishes nothing"
has   "dry-run line names the .INSTALL.md"      "$OUT" "$STEM.INSTALL.md"
has   "dry-run line names the .INSTALL.html"    "$OUT" "$STEM.INSTALL.html"
has   "the dry-run line sits in the DRY RUN section" "$(grep -F "$STEM.INSTALL.md" <<<"$OUT" | head -1)" "DRY RUN"
chk   "no rclone, ssh or scp call"              "$(grep -cE '^(rclone|ssh|scp) ' "$T/ok/calls")" "0"
chk   "no Release created"                      "$(grep -c 'release create' "$T/ok/calls")" "0"
chk   "nothing put in any target"               "$(find "$T/ok/remote" -name '*INSTALL*' | wc -l | tr -d ' ')" "0"

echo "gate 7: Status must read current"
sc_reset; SC_INSTALL="$(inst draft 'sigmond-appliance v3.70 (4c976c8)')"; SC_PAGE="$GOOD_PAGE"; mkscene draft; run_bless draft 0
expect_g7_fail draft "Status draft" "Status"
lacks "Status draft: does not blame Verified against" "$G7" "Verified against"
lacks "Status draft: does not blame the page"          "$G7" "install-page.html does not"
has   "Status draft: says what to do"                  "$G7" "docs/RELEASE.md, rung 3"

sc_reset; SC_INSTALL="$(inst 'not current' 'sigmond-appliance v3.70 (4c976c8)')"; SC_PAGE="$GOOD_PAGE"; mkscene notcur; run_bless notcur 0
expect_g7_fail notcur "Status 'not current'" "Status"

sc_reset; SC_INSTALL="$(inst 'currently being rewritten' 'sigmond-appliance v3.70 (4c976c8)')"; SC_PAGE="$GOOD_PAGE"; mkscene currently; run_bless currently 0
expect_g7_fail currently "Status 'currently ...'" "Status"

echo "gate 7: Verified against must name sigmond-appliance <VERSION>"
sc_reset; SC_INSTALL="$(inst current 'sigmond-appliance v3.69 (1c63a35) with sigmond f01e86f')"; SC_PAGE="$GOOD_PAGE"; mkscene prev; run_bless prev 0
expect_g7_fail prev "Verified against names the previous version" "Verified against"
lacks "previous version: does not blame Status" "$G7" "Status is not"

sc_reset; SC_INSTALL="$(inst current 'sigmond-appliance v3.7 (4c976c8)')"; SC_PAGE="$GOOD_PAGE"; mkscene near1; run_bless near1 0
expect_g7_fail near1 "near miss: v3.7 does not satisfy v3.70" "Verified against"

sc_reset; SC_INSTALL="$(inst current 'sigmond-appliance v3.701 (4c976c8)')"; SC_PAGE="$GOOD_PAGE"; mkscene near2; run_bless near2 0
expect_g7_fail near2 "near miss: v3.701 does not satisfy v3.70" "Verified against"

sc_reset; SC_INSTALL="$(inst current 'sigmond-appliance v3.70.1 (4c976c8)')"; SC_PAGE="$GOOD_PAGE"; mkscene near3; run_bless near3 0
expect_g7_fail near3 "near miss: v3.70.1 does not satisfy v3.70" "Verified against"

sc_reset; SC_INSTALL="$(inst current 'sigmond-appliance v3x70 (4c976c8)')"; SC_PAGE="$GOOD_PAGE"; mkscene near4; run_bless near4 0
expect_g7_fail near4 "near miss: the dot in the version is not a wildcard" "Verified against"

sc_reset; SC_INSTALL="$(inst current 'sigmond-appliance v3.70-rc1 (4c976c8)')"; SC_PAGE="$GOOD_PAGE"; mkscene near5; run_bless near5 0
expect_g7_fail near5 "near miss: v3.70-rc1 does not satisfy v3.70" "Verified against"

sc_reset; SC_INSTALL="$(inst current 'sigmond v3.70 (4c976c8)')"; SC_PAGE="$GOOD_PAGE"; mkscene noapp; run_bless noapp 0
expect_g7_fail noapp "'sigmond v3.70' is not 'sigmond-appliance v3.70'" "Verified against"

sc_reset; SC_VERSION=v3.7; SC_DATE=20261006
SC_INSTALL="$(inst current 'sigmond-appliance v3.70 (4c976c8)')"; SC_PAGE="$(page sigmond-appliance-v3.7-20261006-release.img)"; mkscene near6; run_bless near6 0
expect_g7_fail near6 "near miss, other direction: blessing v3.7 against a v3.70 line" "Verified against"

# The version may sit next to punctuation and still count as a whole token.
sc_reset; SC_INSTALL="$(inst current 'the nested rig test of sigmond-appliance v3.70, then hardware')"; SC_PAGE="$GOOD_PAGE"; mkscene punct1; run_bless punct1 0
has "a comma after the version still matches" "$(g7)" " PASS "
sc_reset; SC_INSTALL="$(inst current 'checked against sigmond-appliance v3.70.')"; SC_PAGE="$GOOD_PAGE"; mkscene punct2; run_bless punct2 0
has "a full stop after the version still matches" "$(g7)" " PASS "
sc_reset; SC_INSTALL="$(inst current '(sigmond-appliance v3.70)')"; SC_PAGE="$GOOD_PAGE"; mkscene punct3; run_bless punct3 0
has "parentheses around the version still match" "$(g7)" " PASS "

echo "gate 7: the page must name this image's exact file name"
sc_reset; SC_INSTALL="$GOOD_INST"; SC_PAGE="$OLD_PAGE"; mkscene nopage; run_bless nopage 0
expect_g7_fail nopage "page still names the previous image" "install-page.html does not name"
lacks "page: does not blame Status"           "$G7" "Status is not"
lacks "page: does not blame Verified against" "$G7" "Verified against"

sc_reset; SC_INSTALL="$GOOD_INST"; SC_PAGE="$(page sigmond-appliance-v3.70-20261007-release.img)"; mkscene nopage2; run_bless nopage2 0
expect_g7_fail nopage2 "page names v3.70 but another build date" "install-page.html does not name"

echo "gate 7: every failure is named when several hold"
sc_reset; SC_INSTALL="$OLD_INST"; SC_PAGE="$OLD_PAGE"; mkscene stale
# The v3.69 documents arrive in no new commit: origin/main still holds them, and
# they read Status: current -- so only the other two conditions fail.
run_bless stale 0
expect_g7_fail stale "documents still describe v3.69" "Verified against" "install-page.html does not name"
lacks "documents still describe v3.69: Status is not blamed" "$G7" "Status is not"
sc_reset; SC_INSTALL="$(inst draft 'sigmond-appliance v3.69')"; SC_PAGE="$OLD_PAGE"; mkscene all3; run_bless all3 0
expect_g7_fail all3 "all three wrong" "Status" "Verified against" "install-page.html does not name" "update INSTALL.md and docs/install-page.html for this image" "commit and push"

echo "gate 7: a missing file fails cleanly"
sc_reset; SC_INSTALL=DELETE; SC_PAGE="$GOOD_PAGE"; mkscene noinst; run_bless noinst 0
expect_g7_fail noinst "INSTALL.md absent from origin/main" "INSTALL.md is not readable"
sc_reset; SC_INSTALL="$GOOD_INST"; SC_PAGE=DELETE; mkscene nopg; run_bless nopg 0
expect_g7_fail nopg "docs/install-page.html absent from origin/main" "install-page.html is not readable"
sc_reset; SC_INSTALL="$(printf '# No header lines at all\n\nBody.\n')"; SC_PAGE="$GOOD_PAGE"; mkscene nohdr; run_bless nohdr 0
expect_g7_fail nohdr "INSTALL.md without Status or Verified lines" "Status" "Verified against"

echo "gate 7: line-ending and quoting variants of a correct file"
sc_reset; SC_INSTALL="$(inst current 'sigmond-appliance v3.70 (4c976c8)' | sed 's/$/\r/')"; SC_PAGE="$GOOD_PAGE"; mkscene crlf; run_bless crlf 0
has "CRLF line endings pass" "$(g7)" " PASS "
sc_reset; SC_INSTALL="$(printf '# Guide\n\n**Status:** current\n**Verified against:** sigmond-appliance v3.70 (4c976c8)\n')"; SC_PAGE="$GOOD_PAGE"; mkscene plain; run_bless plain 0
has "lines without the '> ' quote prefix pass" "$(g7)" " PASS "

echo "gate 7 reads origin/main: not the working tree, not the tag"
# origin/main holds the previous words; the checkout carries correct ones in an
# unpushed commit.  The gate must fail.
sc_reset; SC_LOCAL_INSTALL="$GOOD_INST"; SC_LOCAL_PAGE="$GOOD_PAGE"; mkscene wtgood; run_bless wtgood 0
expect_g7_fail wtgood "origin/main stale, working tree correct" "Verified against" "install-page.html does not name"
chk "the working tree really differed from origin/main" \
    "$(git -C "$T/wtgood/repo" show origin/main:INSTALL.md | cmp -s - "$T/wtgood/repo/INSTALL.md" && echo same || echo differ)" "differ"
# The reverse: origin/main correct, the checkout carries stale words.  The gate
# must pass, and the tag's own tree (stale in every scene) must not matter.
sc_reset; SC_INSTALL="$GOOD_INST"; SC_PAGE="$GOOD_PAGE"
SC_LOCAL_INSTALL="$(inst draft 'sigmond-appliance v3.69')"; SC_LOCAL_PAGE="$OLD_PAGE"; mkscene wtbad; run_bless wtbad 0
has   "origin/main correct, working tree stale: gate 7 PASSes" "$(g7)" " PASS "
lacks "the tag's tree (v3.69 words) is not consulted"          "$(g7)" " FAIL "

echo "gate 7: no image"
sc_reset; SC_NOIMAGE=1; SC_INSTALL="$GOOD_INST"; SC_PAGE="$GOOD_PAGE"; mkscene noimg; run_bless noimg 0
expect_g7_fail noimg "no image resolved" "no image to check the page against"
has "gate 3 still reports the missing image" "$OUT" "no image matching"

# ═══════════════════════════════════════════════════════════════════════════
echo "--apply: both files reach every target after the image does"
sc_reset; SC_INSTALL="$GOOD_INST"; SC_PAGE="$GOOD_PAGE"
# Unpushed, different words in the checkout: the published bytes must come from origin/main.
SC_LOCAL_INSTALL="$(inst current 'sigmond-appliance v3.70 (LOCALONLY)')"; SC_LOCAL_PAGE="$(page "$IMG LOCALONLY")"
mkscene apply; run_bless apply 1
R="$T/apply/remote"
chk   "the bless exits 0"                         "$RC" "0"
has   "the Release was created"                   "$(cat "$T/apply/calls")" "release create"
lacks "gate 7 passed first (no BLOCKED)"          "$OUT" "BLOCKED"
chk   "no temp files left"                        "$(leftover apply)" "0"
for pair in "rob:$R/gdrive/sigmond-images" "mjh:$R/gdrive,root_folder_id=ABC123" "wd30:$R/home-wd30" "bl:$R/gdrive/blessed-only"; do
    lab="${pair%%:*}"; dir="${pair#*:}"
    chk "[$lab] the image sits in the blessed directory" "$([ -f "$dir/$IMG" ] && echo yes || echo no)" "yes"
    chk "[$lab] $STEM.INSTALL.md arrived, byte for byte from origin/main" \
        "$(git -C "$T/apply/origin.git" show main:INSTALL.md | cmp -s - "$dir/$STEM.INSTALL.md" && echo same || echo differ)" "same"
    chk "[$lab] $STEM.INSTALL.html arrived, byte for byte from origin/main" \
        "$(git -C "$T/apply/origin.git" show main:docs/install-page.html | cmp -s - "$dir/$STEM.INSTALL.html" && echo same || echo differ)" "same"
    chk "[$lab] the instructions are not in pending/" "$(ls "$dir/pending" 2>/dev/null | grep -c INSTALL)" "0"
    has "[$lab] the log names both files" "$OUT" "[$lab] instructions: $STEM.INSTALL.md, $STEM.INSTALL.html"
done
lacks "the working tree's words were not published" "$(cat "$R/gdrive/sigmond-images/$STEM.INSTALL.md")" "LOCALONLY"
# Order: the instructions follow the image at each target.
n_mv="$(grep -n "moveto -q gdrive:sigmond-images/pending/$IMG" "$T/apply/calls" | head -1 | cut -d: -f1)"
n_in="$(grep -n "copyto -q .*$STEM.INSTALL.md gdrive:sigmond-images/$STEM.INSTALL.md" "$T/apply/calls" | head -1 | cut -d: -f1)"
chk "[rob] promotion comes before the instructions upload" "$([ -n "$n_mv" ] && [ -n "$n_in" ] && [ "$n_mv" -lt "$n_in" ] && echo before || echo "mv=$n_mv in=$n_in")" "before"
n_up="$(grep -n "copyto -q .*$IMG gdrive:blessed-only/$IMG" "$T/apply/calls" | head -1 | cut -d: -f1)"
n_in="$(grep -n "copyto -q .*$STEM.INSTALL.md gdrive:blessed-only/$STEM.INSTALL.md" "$T/apply/calls" | head -1 | cut -d: -f1)"
chk "[bl] the image upload comes before the instructions upload" "$([ -n "$n_up" ] && [ -n "$n_in" ] && [ "$n_up" -lt "$n_in" ] && echo before || echo "up=$n_up in=$n_in")" "before"
# Not on the Release.
lacks "the Release call attaches no instructions" "$(grep 'release create' "$T/apply/calls")" "INSTALL"
lacks "the release notes mention no instructions" "$(cat "$T/apply/notes.copy" 2>/dev/null)" "INSTALL"
has   "the release notes were captured (the check above looked at something)" "$(cat "$T/apply/notes.copy" 2>/dev/null)" "## sigmond-appliance v3.70"

echo "--apply: a failed upload to one Drive warns, marks the target, and leaves the bless at exit 0"
sc_reset; SC_INSTALL="$GOOD_INST"; SC_PAGE="$GOOD_PAGE"; mkscene upfail
STUB_FAIL_PUT='gdrive:sigmond-images/*INSTALL.html'; export STUB_FAIL_PUT
run_bless upfail 1
unset STUB_FAIL_PUT
R="$T/upfail/remote"
chk   "the bless still exits 0"                     "$RC" "0"
has   "WARNING names the failing target"            "$OUT" "[rob] WARNING"
has   "WARNING says the instructions failed"        "$OUT" "install instructions"
has   "WARNING carries a by-hand command"           "$OUT" "[rob]   by hand"
has   "the by-hand command names the files"         "$(grep -F '[rob]   by hand' <<<"$OUT")" "$STEM.INSTALL.html"
has   "the final NOTE reports a partial publish"    "$OUT" "NOTE: some targets"
chk   "[rob] the image was still promoted"          "$([ -f "$R/gdrive/sigmond-images/$IMG" ] && echo yes || echo no)" "yes"
lacks "[rob] no 'instructions:' success line"       "$OUT" "[rob] instructions:"
for pair in "mjh:$R/gdrive,root_folder_id=ABC123" "wd30:$R/home-wd30" "bl:$R/gdrive/blessed-only"; do
    lab="${pair%%:*}"; dir="${pair#*:}"
    chk "[$lab] still received the .md"   "$([ -f "$dir/$STEM.INSTALL.md" ] && echo yes || echo no)" "yes"
    chk "[$lab] still received the .html" "$([ -f "$dir/$STEM.INSTALL.html" ] && echo yes || echo no)" "yes"
done
chk "no temp files left" "$(leftover upfail)" "0"

echo "--apply: a failed scp to the archive host warns the same way"
sc_reset; SC_INSTALL="$GOOD_INST"; SC_PAGE="$GOOD_PAGE"; mkscene scpfail
STUB_FAIL_SCP=1; export STUB_FAIL_SCP
run_bless scpfail 1
unset STUB_FAIL_SCP
chk "the bless still exits 0"             "$RC" "0"
has "WARNING names wd30"                  "$OUT" "[wd30] WARNING"
has "the other targets still report success" "$OUT" "[rob] instructions: $STEM.INSTALL.md, $STEM.INSTALL.html"
chk "[wd30] the image was still promoted" "$([ -f "$T/scpfail/remote/home-wd30/$IMG" ] && echo yes || echo no)" "yes"

echo "--apply: a target whose promotion failed gets no instructions"
sc_reset; SC_INSTALL="$GOOD_INST"; SC_PAGE="$GOOD_PAGE"; SC_NOPENDING=wd30; mkscene nopromo; run_bless nopromo 1
chk   "the bless still exits 0"                  "$RC" "0"
has   "WARNING says wd30 could not be promoted"  "$OUT" "[wd30] WARNING: could not promote"
lacks "no instructions line for wd30"            "$OUT" "[wd30] instructions:"
chk   "[wd30] no instructions file written"      "$(find "$T/nopromo/remote/home-wd30" -name '*INSTALL*' 2>/dev/null | wc -l | tr -d ' ')" "0"
has   "[rob] still got its instructions"         "$OUT" "[rob] instructions:"

echo "--apply: a failing gate 7 blocks everything"
sc_reset; mkscene blocked; run_bless blocked 1
chk   "the bless exits 1"                 "$RC" "1"
has   "BLOCKED"                           "$OUT" "BLOCKED"
chk   "no Release created"                "$(grep -c 'release create' "$T/blocked/calls")" "0"
chk   "nothing moved or uploaded"         "$(grep -cE '^(rclone|ssh|scp) ' "$T/blocked/calls")" "0"
chk   "no temp files left"                "$(leftover blocked)" "0"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
