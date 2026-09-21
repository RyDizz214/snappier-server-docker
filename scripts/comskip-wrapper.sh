#!/bin/bash
# Wrapper that runs comskip then immediately rebases any orphan sidecars
# (.edl, .txt, .log, .logo.txt) the run produced under the legacy `--<program>`
# stem so live playback gets the channel-prefixed files without waiting for
# the metadata_fixer 60s scan tick.
#
# Install:
#   mv /usr/local/bin/comskip /usr/local/bin/comskip.real
#   cp comskip-wrapper.sh /usr/local/bin/comskip && chmod +x /usr/local/bin/comskip

set -u

COMSKIP_REAL="${COMSKIP_REAL:-/usr/local/bin/comskip.real}"
METADATA_FIXER_DIR="${METADATA_FIXER_DIR:-/opt/scripts}"

recover_orphans() {
  python3 - <<PY 2>&1 || true
import sys
sys.path.insert(0, "$METADATA_FIXER_DIR")
try:
    from metadata_fixer import recover_orphan_sidecars
    n = recover_orphan_sidecars()
    if n:
        print(f"[comskip-wrapper] rebased {n} orphan sidecar(s)")
except Exception as e:
    print(f"[comskip-wrapper] orphan recovery failed: {e}", file=sys.stderr)
PY
}

"$COMSKIP_REAL" "$@"
rc=$?
recover_orphans
exit $rc
