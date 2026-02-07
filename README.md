# Linux Audit Log CSV Exporter

## Overview

`audit2csv.sh` is a high‑performance DFIR utility that converts Linux audit logs into structured CSV format using native `ausearch`.  
It supports:

- Exporting **all audit events** to CSV
- Exporting only events related to a specific **AUID (user identity)**
- Automatic **dynamic field discovery**
- Optional human‑readable timestamps
- Processing a single log file or an entire directory of audit logs

The script is designed for **speed and forensic accuracy**, avoiding expensive per‑record timestamp conversions by default.

---

## Key Design Principles

- Preserves all raw audit data  
- Supports dynamic columns without manual definitions  
- Works completely offline with archived audit logs  
- No dependencies beyond standard Linux tools

---

## Requirements

- Bash 4+
- `ausearch` (from the auditd suite)
- Standard GNU utilities (awk, grep, sort, cut)

---

## Usage

```
audit2csv.sh [-A] [-a <auid> | -u <username>] (-i <audit.log> | -d <audit_dir>)                               [-o <out.csv>] [-F <fields>] [-D] [--human-time] [--local-time]
```

### Modes

#### All Records Mode (Recommended for Investigations)

Export every record from the logs:

```
./audit2csv.sh -A -D -d /var/log/audit -o all_audit.csv
```

This mode:

- Processes the entire log set
- Dynamically discovers all fields
- Is the **fastest and most comprehensive** option

#### Session Mode by AUID

Export only records tied to a specific authenticated user ID:

```
./audit2csv.sh -a 1000 -D -i combinedaudit.log -o user_1000.csv
```

#### Username Convenience Mode

Resolve a username to its AUID automatically:

```
./audit2csv.sh -u testuser -D -d /var/log/audit -o testuser.csv
```

---

## Timestamp Behavior (Important)

### Default – Fast Mode

By default, the script outputs:

- `ts_epoch` – Unix epoch seconds  
- `ts_ms` – milliseconds  
- `ts_utc` – string in format `EPOCH.MMM`

This avoids expensive timestamp conversion and keeps processing extremely fast.

### Optional Human Time

If you prefer readable timestamps:

```
--human-time
```

Example:

```
./audit2csv.sh -A -D -i combinedaudit.log --human-time
```

This will populate `ts_utc` as:

```
YYYY-MM-DD HH:MM:SS.mmm
```

Add `--local-time` to also generate a `ts_local` column.

> Note: Human time mode is slower due to required conversions.

---

## Excel Timestamp Conversion (Fastest Workflow)

If you used the fast default mode, convert timestamps directly in Excel.

### When using `ts_epoch` and `ts_ms` columns

Excel formula:

```
=($D2/86400) + DATE(1970,1,1) + ($E2/86400000)
```

Format the cell as:

```
yyyy-mm-dd hh:mm:ss.000
```

### When using combined `ts_utc` (epoch.ms)

```
=(INT($C2)/86400) + DATE(1970,1,1) + (MOD($C2,1)/86400)
```

---

## Dynamic Field Discovery

Use `-D` to automatically detect all available fields:

```
./audit2csv.sh -A -D -i audit.log
```

You can also manually specify extra fields:

```
-F "res,tty,addr,hostname,key"
```

---

## Input Options

### Single File

```
-i combinedaudit.log
```

### Directory of Logs

```
-d /var/log/audit
```

The script automatically concatenates:

```
audit.log
audit.log.1
audit.log.2
...
```

---

## Output Columns

Core columns always included:

- ses  
- type  
- ts_utc  
- ts_epoch  
- ts_ms  
- serial  
- auid  
- acct  
- auid_name  
- uid  
- euid  
- pid  
- ppid  
- comm  
- exe  
- raw (full original audit line)

Additional fields are added dynamically via discovery or `-F`.

---

## Performance Tips

- Prefer **fast default timestamps** + Excel conversion
- Use `-A -D` for large investigations
- Human timestamps only when necessary

---

## Example Investigation Workflow

1. Convert everything:

```
./audit2csv.sh -A -D -d ./audit -o all.csv
```

2. Filter in Excel by:

- auid
- ses
- type
- exe
- res

3. Build timelines using Excel formulas above

---
