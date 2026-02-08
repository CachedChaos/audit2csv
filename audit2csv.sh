#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  audit_acct_sessions_to_csv.sh [-A] [-a <auid> | -u <username>] (-i <audit.log> | -d <audit_dir>) [-o <out.csv>] [-F <fields>] [-D]
                                [--human-time] [--local-time]

Modes:
  Session export by AUID (recommended DFIR mode):
    -a <auid>        Numeric AUID only. Finds sessions where auid=<auid>, exports ALL records for those sessions.
    -u <username>    Convenience: resolves auid(s) for acct="username" in login/auth records, then exports by auid.

  All mode:
    -A               Convert ALL records from the input audit log(s) to CSV (no session filtering).

Inputs:
  -i <file>          Use a specific audit log file (e.g., combinedaudit.log)
  -d <dir>           Directory containing audit.log* files (concatenates audit.log* into a temp file)

Output:
  -o <out.csv>       Output CSV path. Default:
                       -A mode: ./audit_all.csv
                       -a/-u mode: ./auid_<auid>_sessions.csv (or ./<username>_sessions.csv when using -u)

Dynamic columns:
  -F "field1,field2,..."   Adds extra columns by extracting:
                           - field=value
                           - field="value"
                           - interpreted FIELD="value" (uppercase) like AUID="name"

Field discovery:
  -D               Auto-discover extra fields (two-pass).
                   In -A mode scans first N lines of full log.
                   In -a/-u mode scans first N lines sampled from the discovered sessions.

Time (FAST DEFAULT):
  By default (fastest): no per-record date conversion.
    - ts_epoch is the epoch seconds
    - ts_ms is milliseconds (0-999)
    - ts_utc is "EPOCH.MMM" placeholder (example: 1770383284.543)

  Optional (slower):
    --human-time     Convert ts_epoch to human-readable UTC timestamp in ts_utc (YYYY-mm-dd HH:MM:SS.mmm).
                     Uses a small cache, but still slower than default.
    --local-time     When used with --human-time, also outputs ts_local (local TZ) with milliseconds.

Examples:
  # Fastest: all records, discover fields
  ./audit_acct_sessions_to_csv.sh -A -D -d /var/log/audit -o all_audit.csv

  # Fastest: session export by known auid
  ./audit_acct_sessions_to_csv.sh -a 99074 -D -i combinedaudit.log -o auid_99074.csv

  # Slower: human readable timestamps
  ./audit_acct_sessions_to_csv.sh -A -D -d /var/log/audit -o all_audit.csv --human-time
EOF
}

# -------- Args --------
AUID=""
USERNAME=""
INFILE=""
INDIR=""
OUTCSV=""
FIELDS=""
ALL=0
DISCOVER=0
DISCOVER_MAX=100000

HUMAN_TIME=0
LOCAL_TIME=0

# Long flags
for arg in "$@"; do
  case "$arg" in
    --human-time) HUMAN_TIME=1 ;;
    --local-time) LOCAL_TIME=1 ;;
  esac
done

# Strip long flags for getopts parsing
ARGS=()
for arg in "$@"; do
  [[ "$arg" == "--human-time" || "$arg" == "--local-time" ]] && continue
  ARGS+=("$arg")
done

while getopts ":ADa:u:i:d:o:F:h" opt "${ARGS[@]}"; do
  case "$opt" in
    A) ALL=1 ;;
    D) DISCOVER=1 ;;
    a) AUID="$OPTARG" ;;
    u) USERNAME="$OPTARG" ;;
    i) INFILE="$OPTARG" ;;
    d) INDIR="$OPTARG" ;;
    o) OUTCSV="$OPTARG" ;;
    F) FIELDS="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

# -------- Validate args --------
if [[ -n "$INFILE" && -n "$INDIR" ]]; then
  echo "ERROR: Use either -i OR -d, not both" >&2
  exit 2
fi
if [[ -z "$INFILE" && -z "$INDIR" ]]; then
  echo "ERROR: Provide -i <audit.log> OR -d <audit_dir>" >&2
  exit 2
fi

if [[ "$ALL" -eq 1 ]]; then
  if [[ -n "$AUID" || -n "$USERNAME" ]]; then
    echo "ERROR: -A cannot be combined with -a or -u" >&2
    exit 2
  fi
else
  if [[ -n "$AUID" && -n "$USERNAME" ]]; then
    echo "ERROR: Use either -a OR -u, not both" >&2
    exit 2
  fi
  if [[ -z "$AUID" && -z "$USERNAME" ]]; then
    echo "ERROR: Provide -a <auid> OR -u <username> (or use -A)" >&2
    usage; exit 2
  fi
  if [[ -n "$AUID" && ! "$AUID" =~ ^[0-9]+$ ]]; then
    echo "ERROR: -a must be a numeric auid (example: -a 99074). Use -u for username lookup." >&2
    exit 2
  fi
fi

if [[ "$LOCAL_TIME" -eq 1 && "$HUMAN_TIME" -eq 0 ]]; then
  echo "WARN: --local-time only applies when --human-time is enabled. Ignoring --local-time." >&2
  LOCAL_TIME=0
fi

# -------- Default output name --------
if [[ -z "$OUTCSV" ]]; then
  if [[ "$ALL" -eq 1 ]]; then
    OUTCSV="./audit_all.csv"
  elif [[ -n "$AUID" ]]; then
    OUTCSV="./auid_${AUID}_sessions.csv"
  else
    OUTCSV="./${USERNAME}_sessions.csv"
  fi
fi

# Ensure output path is writable
OUTDIR="$(dirname "$OUTCSV")"
if [[ ! -d "$OUTDIR" ]]; then
  echo "ERROR: Output directory does not exist: $OUTDIR" >&2
  exit 2
fi
if [[ ! -w "$OUTDIR" ]]; then
  echo "ERROR: Output directory not writable: $OUTDIR" >&2
  exit 2
fi
if [[ -e "$OUTCSV" && ! -w "$OUTCSV" ]]; then
  echo "ERROR: Output file exists but is not writable: $OUTCSV" >&2
  ls -la "$OUTCSV" >&2 || true
  exit 2
fi

# -------- Build ausearch input args --------
AUSEARCH_IN_ARGS=()
TMP=""

if [[ -n "$INFILE" ]]; then
  AUSEARCH_IN_ARGS=(-if "$INFILE")
else
  TMP="$(mktemp)"
  # expects audit.log, audit.log.1, etc.
  cat "$INDIR"/audit.log* > "$TMP"
  AUSEARCH_IN_ARGS=(-if "$TMP")
fi

# -------- Field discovery helpers --------
discover_fields_from_stream() {
  local max="${1:-$DISCOVER_MAX}"

  head -n "$max" \
    | tr -d '\r' \
    | tr '\035' ' ' \
    | sed "s/msg='\''/msg='\'' /g" \
    | grep -oE '(^| )[A-Za-z_][A-Za-z0-9_-]*=("[^"]*"|[^ ]+)' \
    | sed -E 's/^ +//' \
    | cut -d= -f1 \
    | sort -u \
    | grep -vE '^(type|msg|audit|ses|serial|auid|acct|uid|euid|pid|ppid|comm|exe|items|a[0-9]+)$' \
    | paste -sd, - \
    || true
}

discover_fields_full_log() {
  local max="${1:-$DISCOVER_MAX}"
  { sudo ausearch "${AUSEARCH_IN_ARGS[@]}" --format raw 2>/dev/null \
      | discover_fields_from_stream "$max"
  } || true
}

discover_fields_from_sessions() {
  local sessions="$1"
  local max="${2:-$DISCOVER_MAX}"

  {
    while read -r s; do
      [[ -z "$s" ]] && continue
      sudo ausearch "${AUSEARCH_IN_ARGS[@]}" --session "$s" --format raw 2>/dev/null
    done <<< "$sessions"
  } | discover_fields_from_stream "$max" || true
}

# -------- Shared AWK program (FAST DEFAULT: no per-record date) --------
AWK_PROG='
  BEGIN{
    OFS=",";
    n=split(extra_fields, F, /,/);
    for(i=1;i<=n;i++){ gsub(/^[ \t]+|[ \t]+$/, "", F[i]); }
  }
  function q(s) { gsub(/"/,"\"\"",s); return "\"" s "\"" }
  function fmt_epoch_ms(epoch, ms,   m3) {
    m3 = substr(ms "000", 1, 3);
    return epoch "." m3;
  }

  # ---- PROCTITLE decode helpers (portable awk: no strtonum dependency) ----
  function hexval(c) {
    c = tolower(c);
    if (c >= "0" && c <= "9") return c + 0;
    if (c == "a") return 10;
    if (c == "b") return 11;
    if (c == "c") return 12;
    if (c == "d") return 13;
    if (c == "e") return 14;
    if (c == "f") return 15;
    return -1;
  }
  function decode_proctitle(h,   i,c1,c2,b,out) {
    # Only decode if it looks like pure hex and even length
    if (h !~ /^[0-9A-Fa-f]+$/) return h;
    if ((length(h) % 2) != 0) return h;

    out="";
    for (i=1; i<=length(h); i+=2) {
      c1 = substr(h,i,1);
      c2 = substr(h,i+1,1);
      b = hexval(c1);
      if (b < 0) return h;
      b = 16*b + hexval(c2);
      if (b < 0) return h;

      # audit proctitle uses NUL separators between argv parts; render as spaces
      if (b == 0) out = out " ";
      else out = out sprintf("%c", b);
    }

    # normalize whitespace
    gsub(/[[:space:]]+/, " ", out);
    sub(/^ /, "", out);
    sub(/ $/, "", out);
    return out;
  }

  /type=/{
    line=$0;
    gsub(/\035/," ",line);
    # Extract nested msg='...'
    inner_msg="";
    if (match(line,/ msg='\''([^'\'']*)'\''/,mm)) {
      inner_msg = " " mm[1];   # leading space helps (^| ) matching for first token
    }

    type="";
    if (match(line,/type=([^ ]+)/,m)) type=m[1];

    inner=""; ts_epoch=""; ts_ms=""; serial="";
    ts_utc=""; ts_local="";

    if (match(line,/audit\(([^)]*)\)/,a)) {
      inner=a[1];
      last = match(inner, /:[^:]*$/);
      if (last) {
        left = substr(inner, 1, RSTART-1);
        serial = substr(inner, RSTART+1);
      } else {
        left = inner;
      }

      if (left ~ /^[0-9]+(\.[0-9]+)?$/) {
        split(left, parts, ".");
        ts_epoch = parts[1];
        msraw = (length(parts[2]) ? parts[2] : "000");
        ts_ms = substr(msraw "000", 1, 3);

        # FAST MODE: avoid calling `date` per record
        if (want_human == 0) {
          ts_utc = fmt_epoch_ms(ts_epoch, ts_ms);
          ts_local = "";
        } else {
          key = fmt_epoch_ms(ts_epoch, ts_ms);
          if (!(key in cache_utc)) {
            cmd = "date -u -d @" ts_epoch " +\"%Y-%m-%d %H:%M:%S\"";
            cmd | getline base; close(cmd);
            cache_utc[key] = base "." ts_ms;
            if (want_local == 1) {
              cmd2 = "date -d @" ts_epoch " +\"%Y-%m-%d %H:%M:%S\"";
              cmd2 | getline base2; close(cmd2);
              cache_local[key] = base2 "." ts_ms;
            }
          }
          ts_utc = cache_utc[key];
          ts_local = (want_local==1 ? cache_local[key] : "");
        }
      } else {
        # already-human timestamps (rare) -> keep in ts_utc
        ts_utc = left;
        ts_epoch = "";
        ts_ms = "";
        ts_local = "";
      }
    }

    # Parse ses from record so -A mode fills ses column
    ses_f="";
    if (match(line,/(^| )ses=([^ ]+)/,x0)) ses_f=x0[2];

    auid=acct=uid=euid=pid=ppid=comm=exe="";
    if (match(line,/(^| )auid=([^ ]+)/,x)) auid=x[2];
    if (match(line,/(^| )acct="([^"]+)"/,x)) acct=x[2];
    if (match(line,/(^| )uid=([^ ]+)/,x)) uid=x[2];
    if (match(line,/(^| )euid=([^ ]+)/,x)) euid=x[2];
    if (match(line,/(^| )pid=([^ ]+)/,x)) pid=x[2];
    if (match(line,/(^| )ppid=([^ ]+)/,x)) ppid=x[2];
    if (match(line,/(^| )comm=([^ ]+)/,x)) comm=x[2];
    if (match(line,/(^| )exe=([^ ]+)/,x)) exe=x[2];

    # Prefer ses passed from shell loop; fallback to ses parsed from record
    ses_out = (ses != "" ? ses : ses_f);

    auid_name="";
    if (match(line,/ AUID="([^"]+)"/,z)) auid_name=z[1];

    extras="";
    for(i=1;i<=n;i++){
      key=F[i]; if (key=="") continue;
      val="";

      re="(^| )[[:space:]]*" key "=\"([^\"]*)\"";
      if (match(line, re, y)) val=y[2];
      else if (inner_msg != "" && match(inner_msg, re, y)) val=y[2];
      else {
        re2="(^| )[[:space:]]*" key "=([^ ]+)";
        if (match(line, re2, y2)) val=y2[2];
        else if (inner_msg != "" && match(inner_msg, re2, y2)) val=y2[2];
        else {
          up=toupper(key);
          re3="(^| )[[:space:]]*" up "=\"([^\"]*)\"";
          if (match(line, re3, y3)) val=y3[2];
          else if (inner_msg != "" && match(inner_msg, re3, y3)) val=y3[2];
        }
      }

      # Decode common hex-encoded command fields
      lk = tolower(key);
      if ((lk == "proctitle" || lk == "cmd" || lk == "user_cmd") && val != "") {
        val = decode_proctitle(val);
      }
      
      extras = extras OFS q(val);
    }

    raw=$0;
    gsub(/"/,"\"\"",raw);
    gsub(/\r/,"",raw);
    gsub(/\035/," ",raw);

    if (want_local == 1) {
      print q(ses_out),q(type),q(ts_utc),q(ts_epoch),q(ts_ms),q(serial),q(auid),q(acct),q(auid_name),q(uid),q(euid),q(pid),q(ppid),q(comm),q(exe),q(ts_local) extras, q(raw);
    } else {
      print q(ses_out),q(type),q(ts_utc),q(ts_epoch),q(ts_ms),q(serial),q(auid),q(acct),q(auid_name),q(uid),q(euid),q(pid),q(ppid),q(comm),q(exe) extras, q(raw);
    }
  }
'


# -------- Resolve auid list (if needed) --------
AUIDS=""
SESSIONS=""

if [[ "$ALL" -eq 0 ]]; then
  if [[ -n "$AUID" ]]; then
    AUIDS="$AUID"
  else
    # Resolve auid(s) for username from login/auth records only.
    AUIDS=$(
      sudo ausearch "${AUSEARCH_IN_ARGS[@]}" -m USER_LOGIN,USER_AUTH,USER_ACCT,LOGIN --format raw 2>/dev/null \
        | grep -F "acct=\"$USERNAME\"" \
        | grep -oE 'auid=[0-9]+' \
        | cut -d= -f2 \
        | sort -u \
        | grep -vE '^(4294967295|4294967294)$' || true
    )
    if [[ -z "${AUIDS:-}" ]]; then
      echo "WARN: No auid values found for username acct=\"$USERNAME\" in login/auth records." >&2
      echo "Wrote header-only CSV: $OUTCSV" >&2
      [[ -n "$TMP" ]] && rm -f "$TMP"
      exit 0
    fi
  fi

  # Find sessions by auid(s) using a single awk pass
  AUIDS_CSV="$(printf '%s\n' "$AUIDS" | paste -sd, -)"

  SESSIONS=$(
    sudo ausearch "${AUSEARCH_IN_ARGS[@]}" -m USER_LOGIN,USER_AUTH,USER_ACCT,LOGIN --format raw 2>/dev/null \
      | awk -v auids="$AUIDS_CSV" '
          BEGIN{
            n=split(auids, a, ",");
            for(i=1;i<=n;i++){
              gsub(/^[ \t]+|[ \t]+$/, "", a[i]);
              if(a[i]!="") wanted[a[i]]=1;
            }
          }
          {
            if (match($0,/(^| )auid=([0-9]+)/,m) && match($0,/(^| )ses=([0-9]+)/,s)) {
              au=m[2]; se=s[2];
              if (wanted[au] && se != 4294967295) print se;
            }
          }
        ' \
      | sort -u || true
  )

  if [[ -z "${SESSIONS:-}" ]]; then
    echo "WARN: No sessions found for auid(s): $(echo "$AUIDS" | tr '\n' ' ')" >&2
    echo "Wrote header-only CSV: $OUTCSV" >&2
    [[ -n "$TMP" ]] && rm -f "$TMP"
    exit 0
  fi
fi

# -------- Field discovery (if -D and no -F) --------
if [[ "$DISCOVER" -eq 1 && -z "${FIELDS:-}" ]]; then
  if [[ "$ALL" -eq 1 ]]; then
    echo "Discovering fields from full log (first $DISCOVER_MAX lines)..." >&2
    FIELDS="$(discover_fields_full_log "$DISCOVER_MAX")"
  else
    echo "Discovering fields from sessions (sampling up to $DISCOVER_MAX lines)..." >&2
    FIELDS="$(discover_fields_from_sessions "$SESSIONS" "$DISCOVER_MAX")"
  fi
  echo "Discovered fields: ${FIELDS:-<none>}" >&2
fi

# Prepare dynamic fields list AFTER discovery so header matches discovered fields
IFS=',' read -r -a FIELD_ARR <<< "${FIELDS:-}"

# -------- Write header --------
{
  printf "ses,type,ts_utc,ts_epoch,ts_ms,serial,auid,acct,auid_name,uid,euid,pid,ppid,comm,exe"
  if [[ "$LOCAL_TIME" -eq 1 ]]; then
    printf ",ts_local"
  fi
  for f in "${FIELD_ARR[@]}"; do
    f="${f#"${f%%[![:space:]]*}"}"
    f="${f%"${f##*[![:space:]]}"}"
    [[ -n "$f" ]] && printf ",%s" "$f"
  done
  printf ",raw\n"
} > "$OUTCSV"

# -------- Main processing --------
if [[ "$ALL" -eq 1 ]]; then
  sudo ausearch "${AUSEARCH_IN_ARGS[@]}" --format raw \
    | awk -v ses="" -v extra_fields="$FIELDS" -v want_human="$HUMAN_TIME" -v want_local="$LOCAL_TIME" "$AWK_PROG" >> "$OUTCSV"
  echo "Wrote: $OUTCSV"
  [[ -n "$TMP" ]] && rm -f "$TMP"
  exit 0
fi

# Session mode: export all records per session
while read -r s; do
  [[ -z "$s" ]] && continue
  sudo ausearch "${AUSEARCH_IN_ARGS[@]}" --session "$s" --format raw \
    | awk -v ses="$s" -v extra_fields="$FIELDS" -v want_human="$HUMAN_TIME" -v want_local="$LOCAL_TIME" "$AWK_PROG" >> "$OUTCSV"
done <<< "$SESSIONS"

echo "Wrote: $OUTCSV"

# cleanup temp file if used
if [[ -n "${TMP:-}" && -f "${TMP:-}" ]]; then
  rm -f "$TMP"
fi