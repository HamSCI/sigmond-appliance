#!/bin/bash
# test-publish-fetchurl.sh — pub_fetch_url yields something curl can actually GET.
#
# ⛔ WHY.  `rclone link` returns a Drive VIEWER url. curl follows that to HTML,
# and for a multi-GB file Drive adds a virus-scan interstitial on top -- so the
# obvious implementation hands every station a URL that downloads a web page
# instead of an image, and nobody notices until a 5 GB dd writes garbage.
# The streaming endpoint is a different host with confirm=t.
set -u
LIB="${1:-$(dirname "$0")/publish-lib.sh}"
. "$LIB"
PASS=0; FAIL=0
chk(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok    %s\n' "$1"
       else FAIL=$((FAIL+1)); printf '  FAIL  %s\n        want: %s\n        got : %s\n' "$1" "$3" "$2"; fi; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
printf '#!/bin/bash\n[ "$1" = link ] && echo "https://drive.google.com/open?id=FILEID123"\nexit 0\n' > "$W/rclone"
chmod +x "$W/rclone"; export PATH="$W:$PATH"

got=$(pub_fetch_url "gdrive:sigmond-images" "pending/x.img")
chk "rewrites the viewer link to the streaming endpoint" "$got" \
    "https://drive.usercontent.google.com/download?id=FILEID123&export=download&confirm=t"
case "$got" in
  *drive.google.com/open*) chk "does not hand out the viewer URL" "leaked" "clean" ;;
  *) chk "does not hand out the viewer URL" "clean" "clean" ;;
esac
case "$got" in *confirm=t*) chk "carries confirm=t for large files" yes yes ;;
               *)           chk "carries confirm=t for large files" no  yes ;; esac

# an ssh target is already a plain file; scp is the fetch
got=$(pub_fetch_url "ssh:wd30:" "pending/x.img")
chk "ssh targets return a host:path, not a URL" "$got" "wd30:~/pending/x.img"

# a link shape we do not recognise must pass through, never be mangled
printf '#!/bin/bash\n[ "$1" = link ] && echo "https://example.invalid/direct/x.img"\nexit 0\n' > "$W/rclone"
got=$(pub_fetch_url "gdrive:x" "pending/x.img")
chk "an unrecognised link passes through untouched" "$got" "https://example.invalid/direct/x.img"

echo; printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
