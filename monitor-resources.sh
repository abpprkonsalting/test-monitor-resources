#!/usr/bin/env bash

set -uo pipefail

# ============================================================
# Linux process resource monitor with bounded log rotation
# and CSV export.
#
# Usage:
#   ./monitor-resources.sh [-i seconds] [-o logfile] [-csv] selector...
#   ./monitor-resources.sh -c /path/to/config
#
# Examples:
#   sudo ./monitor-resources.sh -i 5 \
#       -o map-rezi-resources.log -csv \
#       map-rezi-api.service \
#       map-rezi-fetcher.service \
#       mariadb.service
#
# Selectors:
#   - systemd service name
#   - numeric PID
#   - process name (oldest matching PID)
#
# Existing log files:
#   A = append by rotating existing logs into the next slot
#   O = overwrite and remove the existing log and rotations
#
# CSV:
#   Generated on normal exit, Ctrl+C, or SIGTERM.
#   Includes records from all retained rotated logs.
#
# Rotation:
#   Active log: <logfile>
#   Rotations:  <logfile>.1 through <logfile>.5
#
# Default maximum size per file: 10 MiB
# Default retained rotated files: 5
# ============================================================

INTERVAL=5
OUTPUT=""
EXPORT_CSV=0

# Rotation defaults.
MAX_LOG_SIZE="10M"
MAX_LOG_BYTES=$((10 * 1024 * 1024))
MAX_ROTATIONS=5

# CSV rotation defaults.
CSV_MAX_SIZE="10M"
CSV_MAX_BYTES=$((10 * 1024 * 1024))
CSV_MAX_ROTATIONS=5

# CSV update frequency in seconds (0 = only on exit)
CSV_UPDATE_INTERVAL=0
LAST_CSV_UPDATE=0

declare -a SELECTORS=()
declare -A PREV_CPU=()
declare -A PREV_READ=()
declare -A PREV_WRITE=()
declare -A PREV_TIME=()
declare -A PREV_START=()

LAST_MAPPING=""
LOG_FILE=""
CSV_FILE=""
TEMP_CSV=""

CLK_TCK="$(getconf CLK_TCK 2>/dev/null || echo 100)"
PAGE_SIZE="$(getconf PAGESIZE 2>/dev/null || echo 4096)"

load_config() {
    local config_file="$1"
    [[ -f "$config_file" ]] || die "Config file not found: $config_file"
    [[ -r "$config_file" ]] || die "Config file not readable: $config_file"
    
    # Source the config file safely
    # shellcheck disable=SC1090
    source "$config_file" || die "Failed to load config file: $config_file"
    
     # Apply config values if set
    [[ -n "${INTERVAL:-}" ]] && INTERVAL="$INTERVAL"
    [[ -n "${OUTPUT:-}" ]] && OUTPUT="$OUTPUT"
    [[ -n "${EXPORT_CSV:-}" ]] && EXPORT_CSV="$EXPORT_CSV"
    [[ -n "${MAX_LOG_SIZE:-}" ]] && MAX_LOG_SIZE="$MAX_LOG_SIZE"
    [[ -n "${MAX_ROTATIONS:-}" ]] && MAX_ROTATIONS="$MAX_ROTATIONS"
    [[ -n "${CSV_MAX_SIZE:-}" ]] && CSV_MAX_SIZE="$CSV_MAX_SIZE"
    [[ -n "${CSV_MAX_ROTATIONS:-}" ]] && CSV_MAX_ROTATIONS="$CSV_MAX_ROTATIONS"
    [[ -n "${CSV_UPDATE_INTERVAL:-}" ]] && CSV_UPDATE_INTERVAL="$CSV_UPDATE_INTERVAL"
    
    # Load selectors if defined as array
    if [[ -n "${SELECTORS[@]:-}" ]]; then
        SELECTORS=("${SELECTORS[@]}")
    fi
}

usage() {
    cat <<'EOF'
Usage:
  monitor-resources.sh [-i seconds] [-o logfile] [-csv] [-s size] [-r count] [-u seconds] selector...
  monitor-resources.sh -c /path/to/config

Options:
  -c FILE      Load configuration from file
  -i SECONDS   Sampling interval (default: 5 seconds)
  -o FILE      Log file
  -csv         Export CSV when monitoring exits; requires -o
  -s SIZE      Maximum size per log file (default: 10M)
                     Supported suffixes: K, M, G
  -r COUNT     Number of rotated log files to retain (default: 5)
  -u SECONDS   Periodic CSV update interval (default: 0, only on exit)
  -h, --help   Show help

Rotation:
  Active log: logfile
  Rotations:  logfile.COUNT
  
Rotation defaults:
  Maximum active log size: 10 MiB
  Retained rotated files:  5
  Approximate total log storage: 60 MiB

Existing logs:
  If the active log or a rotated log exists, you will be asked
  whether to append or overwrite.

Examples:
  ./monitor-resources.sh -i 5 \
      -o map-rezi-resources.log -csv \
      map-rezi-api.service map-rezi-fetcher.service mariadb.service
  ./monitor-resources.sh -i 5 -s 20M -r 10 -o monitor.log -csv node
  ./monitor-resources.sh -s 5M -r 3 -o monitor.log node
  ./monitor-resources.sh -c /etc/monitor-resources/config
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

parse_size() {
    local value="$1"
    local number suffix multiplier

    if [[ ! "$value" =~ ^([0-9]+)([KkMmGg]?)$ ]]; then
        return 1
    fi

    number="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]}"

    case "$suffix" in
        K|k) multiplier=1024 ;;
        M|m) multiplier=$((1024 * 1024)) ;;
        G|g) multiplier=$((1024 * 1024 * 1024)) ;;
        *)   multiplier=1 ;;
    esac

    ((number > 0)) || return 1

    # Avoid integer overflow in Bash arithmetic.
    ((number <= 9223372036854775807 / multiplier)) || return 1

    printf '%s\n' "$((number * multiplier))"
}

# ------------------------------------------------------------
# Parse command-line arguments.
# ------------------------------------------------------------

while (($#)); do
    case "$1" in
        -c)
            (($# >= 2)) || die "Option -c requires a config file."
            load_config "$2"
            shift 2
            ;;
        -u)
            (($# >= 2)) || die "Option -u requires a value in seconds."
            CSV_UPDATE_INTERVAL="$2"
            shift 2
            ;;
        -i)
            (($# >= 2)) || die "Option -i requires a value."
            INTERVAL="$2"
            shift 2
            ;;
        -o)
            (($# >= 2)) || die "Option -o requires a filename."
            OUTPUT="$2"
            shift 2
            ;;
        -csv)
            EXPORT_CSV=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -s)
            (($# >= 2)) || die "Option -s requires a size, e.g. 10M."
            MAX_LOG_SIZE="$2"
            shift 2
            ;;
        -r)
            (($# >= 2)) || die "Option -r requires a rotation count."
            MAX_ROTATIONS="$2"
            shift 2
            ;;
        --)
            shift
            SELECTORS+=("$@")
            break
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            SELECTORS+=("$1")
            shift
            ;;
    esac
done

# ------------------------------------------------------------
# Validate parameters (from CLI or config)
# ------------------------------------------------------------

# Convert the configured maximum file size into bytes.
MAX_LOG_BYTES="$(parse_size "$MAX_LOG_SIZE")" ||
    die "Invalid log size '$MAX_LOG_SIZE'. Use a positive integer with optional K, M, or G suffix, e.g. 512K, 10M, or 1G."

CSV_MAX_BYTES="$(parse_size "$CSV_MAX_SIZE")" ||
    die "Invalid CSV size '$CSV_MAX_SIZE'. Use a positive integer with optional K, M, or G suffix, e.g. 512K, 10M, or 1G."

# Validate the number of retained rotations.
[[ "$MAX_ROTATIONS" =~ ^[0-9]+$ ]] ||
    die "Invalid rotation count '$MAX_ROTATIONS'. Use a non-negative integer."

[[ "$CSV_MAX_ROTATIONS" =~ ^[0-9]+$ ]] ||
    die "Invalid CSV rotation count '$CSV_MAX_ROTATIONS'. Use a non-negative integer."

# Validate CSV update interval (0 = only on exit).
[[ "$CSV_UPDATE_INTERVAL" =~ ^[0-9]+$ ]] ||
    die "Invalid CSV update interval '$CSV_UPDATE_INTERVAL'. Use a non-negative integer."

# CSV export requires a named log file.
if ((EXPORT_CSV)) && [[ -z "$OUTPUT" ]]; then
    die "CSV export requires -o FILE. Example: -o monitor.log -csv"
fi

if ((EXPORT_CSV)) && ! command -v python3 >/dev/null 2>&1; then
    die "CSV export requires python3, but python3 was not found."
fi

[[ "$INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
    die "Sampling interval must be a positive number."

awk -v n="$INTERVAL" 'BEGIN { exit !(n > 0) }' ||
    die "Sampling interval must be greater than zero."

((${#SELECTORS[@]} > 0)) ||
    die "No process selectors supplied. Use -h for help."

# ------------------------------------------------------------
# Determine CSV filename from the log filename.
# ------------------------------------------------------------

get_csv_filename() {
    local logfile="$1"
    local directory basename

    directory="$(dirname -- "$logfile")"
    basename="$(basename -- "$logfile")"

    if [[ "$basename" == *.* ]]; then
        basename="${basename%.*}.csv"
    else
        basename="${basename}.csv"
    fi

    printf '%s/%s\n' "$directory" "$basename"
}

# ------------------------------------------------------------
# Rotation.
#
# Before:
#   log, log.1, log.2, log.3, log.4, log.5
#
# After:
#   new log, old log as .1, old .1 as .2, etc.
#
# The previous .5 is discarded.
# ------------------------------------------------------------

rotate_logs() {
    local i

    # With zero retained rotations, discard the active log.
    if ((MAX_ROTATIONS == 0)); then
        : > "$LOG_FILE" || return 1
        chmod 0640 -- "$LOG_FILE" || return 1
        return 0
    fi

    # Remove the oldest retained rotation.
    rm -f -- "$LOG_FILE.$MAX_ROTATIONS" || return 1

    # Shift existing rotations upward.
    for ((i = MAX_ROTATIONS - 1; i >= 1; i--)); do
        if [[ -e "$LOG_FILE.$i" ]]; then
            mv -f -- "$LOG_FILE.$i" "$LOG_FILE.$((i + 1))" ||
                return 1
        fi
    done

    # Move the active log to rotation .1.
    if [[ -e "$LOG_FILE" ]]; then
        mv -f -- "$LOG_FILE" "$LOG_FILE.1" || return 1
    fi

    # Start a new active log.
    : > "$LOG_FILE" || return 1
    chmod 0640 -- "$LOG_FILE" || return 1

    return 0
}

# ------------------------------------------------------------
# Write one complete line.
#
# Rotation occurs before writing a line that would exceed the
# maximum file size. Lines are never intentionally split across
# files. An individual line larger than the limit may exceed it.
# ------------------------------------------------------------

write_log_line() {
    local line="$1"
    local line_bytes current_size

    if [[ -z "$LOG_FILE" ]]; then
        printf '%s\n' "$line"
        return
    fi

    line_bytes="$(LC_ALL=C printf '%s\n' "$line" | wc -c)"
    current_size="$(stat -c '%s' -- "$LOG_FILE" 2>/dev/null || echo 0)"

    if ((current_size > 0 &&
         current_size + line_bytes > MAX_LOG_BYTES)); then
        rotate_logs || {
            printf 'ERROR: Log rotation failed for %s\n' "$LOG_FILE" >&2
            return 1
        }
    fi

    printf '%s\n' "$line" >> "$LOG_FILE"
}

log() {
    write_log_line "$*" || die "Could not write to the monitoring log."
}

# ------------------------------------------------------------
# Detect existing log files.
# ------------------------------------------------------------

existing_logs_found() {
    local i

    [[ -e "$OUTPUT" ]] && return 0

    for ((i = 1; i <= MAX_ROTATIONS; i++)); do
        [[ -e "$OUTPUT.$i" ]] && return 0
    done

    return 1
}

# ------------------------------------------------------------
# Handle existing logs before monitoring starts.
#
# Append:
#   Rotate the existing active log and all retained rotations,
#   then start a new active log.
#
# Overwrite:
#   Delete the active log and all configured rotations.
# ------------------------------------------------------------

prepare_existing_logs() {
    local answer i

    if ! existing_logs_found; then
        : > "$LOG_FILE" || die "Cannot create log file: $LOG_FILE"
        chmod 0640 -- "$LOG_FILE" ||
            die "Cannot set log file permissions."
        return
    fi

    printf '\nWARNING: Existing log data was found for:\n' >&2
    printf '  %s\n' "$OUTPUT" >&2

    for ((i = 1; i <= MAX_ROTATIONS; i++)); do
        if [[ -e "$OUTPUT.$i" ]]; then
            printf '  %s\n' "$OUTPUT.$i" >&2
        fi
    done

    printf '\nChoose what to do:\n' >&2
    printf '  [A] Append: preserve history and start a new rotation\n' >&2
    printf '  [O] Overwrite: delete existing logs and start fresh\n' >&2

    [[ -r /dev/tty ]] ||
        die "Cannot ask for confirmation without a terminal. Run interactively."

    while true; do
        printf 'Your choice [A/O]: ' >&2

        IFS= read -r answer < /dev/tty ||
            die "Could not read your choice."

        case "$answer" in
            A|a)
                rotate_logs ||
                    die "Could not rotate existing logs."
                printf 'Existing logs preserved; monitoring will start in a new log.\n' >&2
                return
                ;;
            O|o)
                rm -f -- "$OUTPUT" ||
                    die "Could not remove existing log."

                for ((i = 1; i <= MAX_ROTATIONS; i++)); do
                    rm -f -- "$OUTPUT.$i" ||
                        die "Could not remove rotation $OUTPUT.$i"
                done

                : > "$LOG_FILE" ||
                    die "Could not create log file."

                chmod 0640 -- "$LOG_FILE" ||
                    die "Could not set log file permissions."

                printf 'Existing logs removed; starting fresh.\n' >&2
                return
                ;;
            *)
                printf 'Please enter A or O.\n' >&2
                ;;
        esac
    done
}

# ------------------------------------------------------------
# Resolve a selector to a PID.
# ------------------------------------------------------------

resolve_pid() {
    local selector="$1"
    local pid=""

    if [[ "$selector" =~ ^[0-9]+$ ]]; then
        [[ -d "/proc/$selector" ]] && printf '%s\n' "$selector"
        return
    fi

    if [[ "$selector" == *.service ]]; then
        if command -v systemctl >/dev/null 2>&1; then
            pid="$(systemctl show "$selector" \
                -p MainPID --value 2>/dev/null || true)"

            if [[ "$pid" =~ ^[0-9]+$ ]] &&
               ((pid > 0)) &&
               [[ -d "/proc/$pid" ]]; then
                printf '%s\n' "$pid"
            fi
        fi
        return
    fi

    if command -v pgrep >/dev/null 2>&1; then
        pid="$(pgrep -xo -- "$selector" 2>/dev/null || true)"

        if [[ "$pid" =~ ^[0-9]+$ ]] && [[ -d "/proc/$pid" ]]; then
            printf '%s\n' "$pid"
        fi
    fi
}

# ------------------------------------------------------------
# Read process statistics from /proc.
#
# Output:
#   cpu_ticks rss_bytes vsz_bytes read_bytes write_bytes start_ticks
# ------------------------------------------------------------

read_process_stats() {
    local pid="$1"
    local stat_line stat_rest
    local -a fields=()
    local vm_rss vm_vsz io_read="" io_write=""
    local cpu_ticks start_ticks

    [[ -r "/proc/$pid/stat" ]] || return 1

    IFS= read -r stat_line < "/proc/$pid/stat" || return 1

    # Remove PID and parenthesized command name.
    stat_rest="${stat_line##*) }"
    read -r -a fields <<< "$stat_rest"

    # After stripping PID and command name:
    # index 11 = utime (original field 14)
    # index 12 = stime (original field 15)
    # index 19 = starttime (original field 22)
    ((${#fields[@]} > 19)) || return 1

    cpu_ticks=$((fields[11] + fields[12]))
    start_ticks="${fields[19]}"

    [[ -r "/proc/$pid/statm" ]] || return 1
    read -r vm_vsz vm_rss _ < "/proc/$pid/statm" || return 1

    vm_vsz=$((vm_vsz * PAGE_SIZE))
    vm_rss=$((vm_rss * PAGE_SIZE))

    if [[ -r "/proc/$pid/io" ]]; then
        while read -r key value; do
            case "$key" in
                read_bytes:)  io_read="$value" ;;
                write_bytes:) io_write="$value" ;;
            esac
        done < "/proc/$pid/io"
    fi

    printf '%s %s %s %s %s %s\n' \
        "$cpu_ticks" "$vm_rss" "$vm_vsz" \
        "$io_read" "$io_write" "$start_ticks"
}

sample_key() {
    printf '%s|%s' "$1" "$2"
}

# ------------------------------------------------------------
# Ensure all users can read the exported CSV by its known path.
#
# The immediate directory gets o+x, not o+r: users can traverse
# it but cannot list its contents merely because of this change.
# All ancestor directories must also be traversable.
# ------------------------------------------------------------

ensure_public_csv_access() {
    local csv="$1"
    local directory ancestor mode other_digit

    directory="$(dirname -- "$csv")"
    directory="$(cd -- "$directory" 2>/dev/null && pwd -P)" ||
        return 1

    chmod o+x -- "$directory" || {
        printf 'ERROR: Cannot enable directory traversal: %s\n' \
            "$directory" >&2
        return 1
    }

    ancestor="$(dirname -- "$directory")"

    while :; do
        mode="$(stat -c '%a' -- "$ancestor" 2>/dev/null)" || return 1
        other_digit="${mode: -1}"

        if (( (8#$other_digit & 1) == 0 )); then
            printf 'ERROR: Parent directory is not traversable by all users: %s\n' \
                "$ancestor" >&2
            printf 'Fix with: sudo chmod o+x %q\n' "$ancestor" >&2
            return 1
        fi

        [[ "$ancestor" == "/" ]] && break
        ancestor="$(dirname -- "$ancestor")"
    done

    return 0
}

# ------------------------------------------------------------
# Export all retained log files to CSV.
#
# Input order: oldest rotation to newest, then active log.
# Files older than the retained rotation window have already
# been discarded and cannot be included.
#
# Internal record:
#   @CSV timestamp selector cpu rss vsz read_rate write_rate pid
#
# PID is omitted from the exported CSV.
# ------------------------------------------------------------

rotate_csv() {
    local destination="$1"
    local current_size
    local i

    current_size="$(stat -c '%s' -- "$destination" 2>/dev/null || echo 0)"

    # If current CSV exceeds max size, rotate
    if ((current_size > CSV_MAX_BYTES)); then
        # With zero retained rotations, discard the active CSV.
        if ((CSV_MAX_ROTATIONS == 0)); then
            : > "$destination" || return 1
            chmod 0644 -- "$destination" || return 1
            return 0
        fi

        # Remove the oldest retained rotation.
        rm -f -- "$destination.$CSV_MAX_ROTATIONS" || return 1

        # Shift existing rotations upward.
        for ((i = CSV_MAX_ROTATIONS - 1; i >= 1; i--)); do
            if [[ -e "$destination.$i" ]]; then
                mv -f -- "$destination.$i" "$destination.$((i + 1))" ||
                    return 1
            fi
        done

        # Move the active CSV to rotation .1.
        if [[ -e "$destination" ]]; then
            mv -f -- "$destination" "$destination.1" || return 1
        fi
    fi

    return 0
}

export_csv() {
    local destination="$1"
    local destination_dir
    local i
    local -a input_logs=()

    destination_dir="$(dirname -- "$destination")"

    [[ -d "$destination_dir" ]] || {
        printf 'ERROR: CSV destination directory does not exist: %s\n' \
            "$destination_dir" >&2
        return 1
    }

    # Oldest retained rotation first.
    for ((i = MAX_ROTATIONS; i >= 1; i--)); do
        if [[ -f "$LOG_FILE.$i" ]]; then
            input_logs+=("$LOG_FILE.$i")
        fi
    done

    if [[ -f "$LOG_FILE" ]]; then
        input_logs+=("$LOG_FILE")
    fi

    ((${#input_logs[@]} > 0)) || {
        printf 'ERROR: No log files available for CSV export.\n' >&2
        return 1
    }

    # Rotate CSV files before writing new one.
    rotate_csv "$destination" || {
        printf 'ERROR: CSV rotation failed for %s\n' "$destination" >&2
        return 1
    }

    # Try to make CSV world-readable; if the directory is not
    # traversable by others (e.g. a home directory), still export
    # the CSV but skip the traversal check.
    if ! ensure_public_csv_access "$destination"; then
        printf 'WARNING: Cannot make CSV world-traversable; keeping owner-only access.\n' >&2
    fi

    TEMP_CSV="$(mktemp "${destination}.tmp.XXXXXX")" || {
        printf 'ERROR: Cannot create temporary CSV file.\n' >&2
        return 1
    }

    if ! python3 - "$TEMP_CSV" "${input_logs[@]}" <<'PYTHON'
import csv
import os
import sys

csv_path = sys.argv[1]
log_paths = sys.argv[2:]

header = [
    "timestamp",
    "process",
    "cpu_percent",
    "rss_bytes",
    "vsz_bytes",
    "read_bytes_per_sec",
    "write_bytes_per_sec",
]

with open(csv_path, "w", newline="", encoding="utf-8") as target:
    writer = csv.writer(target)
    writer.writerow(header)

    for log_path in log_paths:
        with open(
            log_path, "r", encoding="utf-8", errors="replace"
        ) as source:
            for line in source:
                if not line.startswith("@CSV\t"):
                    continue

                fields = line.rstrip("\r\n").split("\t")

                # @CSV + eight data fields = nine fields.
                if len(fields) != 9:
                    continue

                (
                    _marker,
                    timestamp,
                    selector,
                    cpu,
                    rss,
                    vsz,
                    read_rate,
                    write_rate,
                    _pid,
                ) = fields

                writer.writerow([
                    timestamp,
                    selector,
                    cpu,
                    rss,
                    vsz,
                    read_rate,
                    write_rate,
                ])

    target.flush()
    os.fsync(target.fileno())

# Make the temporary file readable by every local user before
# the atomic rename.
os.chmod(csv_path, 0o644)
PYTHON
    then
        rm -f -- "$TEMP_CSV"
        TEMP_CSV=""
        printf 'ERROR: CSV export failed.\n' >&2
        return 1
    fi

    # Atomic replacement: readers do not see a partially written CSV.
    mv -f -- "$TEMP_CSV" "$destination" || {
        rm -f -- "$TEMP_CSV"
        TEMP_CSV=""
        printf 'ERROR: Cannot install exported CSV: %s\n' \
            "$destination" >&2
        return 1
    }

    TEMP_CSV=""

    # Explicitly reassert public-read permissions after replacement.
    chmod 0644 -- "$destination" || {
        printf 'ERROR: Cannot set CSV permissions to 0644.\n' >&2
        return 1
    }

    printf 'CSV exported: %s\n' "$destination" >&2
    printf 'CSV permissions: %s\n' \
        "$(stat -c '%A (%a)' -- "$destination")" >&2
    printf 'CSV includes currently retained logs: %s\n' \
        "${#input_logs[@]}" >&2

    return 0
}

# ------------------------------------------------------------
# Cleanup and signal handling.
# ------------------------------------------------------------

cleanup() {
    local status=$?

    trap - EXIT INT TERM

    if [[ -n "$TEMP_CSV" ]]; then
        rm -f -- "$TEMP_CSV"
    fi

    if ((EXPORT_CSV)) && [[ -n "$LOG_FILE" && -n "$CSV_FILE" ]]; then
        export_csv "$CSV_FILE" || status=1
    fi

    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ------------------------------------------------------------
# Prepare output file and handle existing logs.
# ------------------------------------------------------------

if [[ -n "$OUTPUT" ]]; then
    mkdir -p -- "$(dirname -- "$OUTPUT")" ||
        die "Cannot create log directory."

    LOG_FILE="$OUTPUT"

    # Ask before creating/truncating any existing logs.
    prepare_existing_logs

    if ((EXPORT_CSV)); then
        CSV_FILE="$(get_csv_filename "$LOG_FILE")"
    fi
fi

# ------------------------------------------------------------
# Main monitoring loop.
# ------------------------------------------------------------

log "Resource monitor started at $(date '+%Y-%m-%d %H:%M:%S')"
log "Sampling interval: $INTERVAL seconds"
log "Maximum log size: $MAX_LOG_SIZE ($MAX_LOG_BYTES bytes)"
log "Maximum retained rotations: $MAX_ROTATIONS"
log "Approximate total retained log capacity: $((MAX_LOG_BYTES * (MAX_ROTATIONS + 1))) bytes"
log "Selectors: ${SELECTORS[*]}"

if [[ -n "$LOG_FILE" ]]; then
    log "Log file: $LOG_FILE"
fi

if [[ -n "$CSV_FILE" ]]; then
    log "CSV will be exported on exit: $CSV_FILE"
fi

while :; do
    sample_time="$(date '+%Y-%m-%d %H:%M:%S')"
    now="$(date +%s.%N)"

    mapping=""

    for selector in "${SELECTORS[@]}"; do
        pid="$(resolve_pid "$selector" || true)"

        if [[ -n "$pid" ]]; then
            mapping+="${selector}=${pid};"
        else
            mapping+="${selector}=NOT_FOUND;"
        fi
    done

    if [[ "$mapping" != "$LAST_MAPPING" ]]; then
        log ""
        log "[$sample_time] Process mapping changed:"

        for selector in "${SELECTORS[@]}"; do
            pid="$(resolve_pid "$selector" || true)"

            if [[ -n "$pid" ]]; then
                log "  $selector -> PID $pid"
            else
                log "  $selector -> NOT FOUND"
            fi
        done

        LAST_MAPPING="$mapping"
    fi

    log ""
    log "Timestamp: $sample_time"
    log "CPU is percentage of one logical CPU; I/O is bytes per second."
    log "Initial rates may be blank while baseline counters are collected."

    for selector in "${SELECTORS[@]}"; do
        pid="$(resolve_pid "$selector" || true)"

        if [[ -z "$pid" ]]; then
            log "WARNING: Process not found: $selector"
            continue
        fi

        stats="$(read_process_stats "$pid" 2>/dev/null || true)"

        if [[ -z "$stats" ]]; then
            log "WARNING: Could not read /proc statistics for $selector (PID $pid)"
            continue
        fi

        read -r cpu_ticks rss_bytes vsz_bytes read_bytes write_bytes start_ticks \
            <<< "$stats"

        key="$(sample_key "$selector" "$pid")"

        cpu_percent=""
        read_rate=""
        write_rate=""

        # Check that this PID still represents the same process.
        if [[ -n "${PREV_START[$key]+x}" ]] &&
           [[ "${PREV_START[$key]}" == "$start_ticks" ]]; then

            elapsed="$(awk -v n="$now" -v p="${PREV_TIME[$key]}" \
                'BEGIN { printf "%.6f", n-p }')"

            if awk -v e="$elapsed" 'BEGIN { exit !(e > 0) }'; then
                cpu_percent="$(awk \
                    -v c="$cpu_ticks" \
                    -v p="${PREV_CPU[$key]}" \
                    -v hz="$CLK_TCK" \
                    -v e="$elapsed" \
                    'BEGIN {
                        printf "%.2f", ((c-p)/hz)/e*100
                    }')"

                if [[ -n "$read_bytes" &&
                      -n "${PREV_READ[$key]:-}" ]]; then
                    read_rate="$(awk \
                        -v c="$read_bytes" \
                        -v p="${PREV_READ[$key]}" \
                        -v e="$elapsed" \
                        'BEGIN {
                            if (c >= p && e > 0)
                                printf "%.2f", (c-p)/e
                        }')"
                fi

                if [[ -n "$write_bytes" &&
                      -n "${PREV_WRITE[$key]:-}" ]]; then
                    write_rate="$(awk \
                        -v c="$write_bytes" \
                        -v p="${PREV_WRITE[$key]}" \
                        -v e="$elapsed" \
                        'BEGIN {
                            if (c >= p && e > 0)
                                printf "%.2f", (c-p)/e
                        }')"
                fi
            fi
        fi

        log "Process: $selector (PID $pid)"
        log "  CPU: ${cpu_percent:-warming up}%"
        log "  RSS: $rss_bytes bytes"
        log "  VSZ: $vsz_bytes bytes"
        log "  Read I/O: ${read_rate:-warming up} bytes/sec"
        log "  Write I/O: ${write_rate:-warming up} bytes/sec"

        if [[ -n "$LOG_FILE" ]]; then
            # The Python exporter expects exactly these eight data fields.
            csv_record="$(printf '@CSV\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
                "$sample_time" "$selector" "${cpu_percent:-}" \
                "$rss_bytes" "$vsz_bytes" \
                "${read_rate:-}" "${write_rate:-}" "$pid")"

            write_log_line "$csv_record" ||
                die "Could not write monitoring record."
        fi

        PREV_CPU["$key"]="$cpu_ticks"
        PREV_TIME["$key"]="$now"
        PREV_START["$key"]="$start_ticks"

        if [[ -n "$read_bytes" ]]; then
            PREV_READ["$key"]="$read_bytes"
        fi

        if [[ -n "$write_bytes" ]]; then
            PREV_WRITE["$key"]="$write_bytes"
        fi
    done

    sleep "$INTERVAL"

    # Periodic CSV update if configured
    if ((EXPORT_CSV)) && ((CSV_UPDATE_INTERVAL > 0)); then
        now_sec="${now%.*}"
        if ((LAST_CSV_UPDATE == 0 || now_sec - LAST_CSV_UPDATE >= CSV_UPDATE_INTERVAL)); then
            export_csv "$CSV_FILE" && LAST_CSV_UPDATE="$now_sec"
        fi
    fi
done
