#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="monitor-resources"
SYSTEM_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
USER_UNIT="$HOME/.config/systemd/user/${SERVICE_NAME}.service"
CONFIG_DIR_SYSTEM="/etc/${SERVICE_NAME}"
CONFIG_DIR_USER="$HOME/.config/${SERVICE_NAME}"

check_prereqs() {
    echo "Checking prerequisites..."
    local missing=()
    command -v systemctl >/dev/null 2>&1 || missing+=("systemctl")
    command -v getconf >/dev/null 2>&1 || missing+=("getconf")
    if [ ${#missing[@]} -gt 0 ]; then
        echo "ERROR: Missing required prerequisites: ${missing[*]}" >&2
        echo "Please install them and try again." >&2
        exit 1
    fi
    echo "All prerequisites satisfied."
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local ans
    while true; do
        if [ "$default" = "y" ]; then
            read -rp "$prompt [Y/n]: " ans
            ans=${ans:-Y}
        else
            read -rp "$prompt [y/N]: " ans
            ans=${ans:-N}
        fi
        case "$(echo "$ans" | tr '[:lower:]' '[:upper:]')" in
            Y) return 0 ;;
            N) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

detect_service_type() {
    if [ "$(id -u)" -eq 0 ]; then
        echo "system"
    else
        echo "user"
    fi
}

get_service_unit() {
    local type="$1"
    if [ "$type" = "system" ]; then
        echo "$SYSTEM_UNIT"
    else
        echo "$USER_UNIT"
    fi
}

get_config_dir() {
    local type="$1"
    if [ "$type" = "system" ]; then
        echo "$CONFIG_DIR_SYSTEM"
    else
        echo "$CONFIG_DIR_USER"
    fi
}

do_uninstall() {
    echo "=== Uninstalling Monitor Resources Service ==="
    
    # Detect service type
    SVC_TYPE=""
    if systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1 || systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1 || [ -f "$SYSTEM_UNIT" ]; then
        SVC_TYPE="system"
    elif systemctl --user is-active "$SERVICE_NAME" >/dev/null 2>&1 || systemctl --user is-enabled "$SERVICE_NAME" >/dev/null 2>&1 || [ -f "$USER_UNIT" ]; then
        SVC_TYPE="user"
    else
        echo "No service found to uninstall."
        exit 0
    fi
    
    echo "Detected: $SVC_TYPE service"
    
    # Stop and disable service
    echo "Stopping and disabling service..."
    if [ "$SVC_TYPE" = "system" ]; then
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        systemctl disable "$SERVICE_NAME" 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
    else
        systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
        systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
        systemctl --user daemon-reload 2>/dev/null || true
    fi
    
    # Remove service unit
    unit="$(get_service_unit "$SVC_TYPE")"
    if [ -f "$unit" ]; then
        rm -f "$unit"
        echo "Removed service unit: $unit"
    fi
    
    # Remove installed script
    script_path="$(get_script_path "$SVC_TYPE")"
    if [ -f "$script_path" ]; then
        rm -f "$script_path"
        echo "Removed script: $script_path"
    fi
    
    # Remove config directory (but not log files)
    config_dir="$(get_config_dir "$SVC_TYPE")"
    if [ -d "$config_dir" ]; then
        # Keep log files - only remove config file
        if [ -f "$config_dir/config" ]; then
            rm -f "$config_dir/config"
            echo "Removed config: $config_dir/config"
        fi
        # Remove config dir if empty
        rmdir "$config_dir" 2>/dev/null || true
    fi
    
    echo ""
    echo "=== Uninstall Complete ==="
    echo "Log files were preserved."
}

service_exists() {
    local type="$1"
    local unit
    unit="$(get_service_unit "$type")"
    if [ "$type" = "system" ]; then
        systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1 || systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1 || [ -f "$unit" ]
    else
        systemctl --user is-enabled "$SERVICE_NAME" >/dev/null 2>&1 || systemctl --user is-active "$SERVICE_NAME" >/dev/null 2>&1 || [ -f "$unit" ]
    fi
}

stop_service() {
    local type="$1"
    echo "Stopping existing service if running..."
    if [ "$type" = "system" ]; then
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    else
        systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
        systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
    fi
}

get_script_path() {
    local type="$1"
    if [ "$type" = "system" ]; then
        echo "/usr/local/bin/monitor-resources.sh"
    else
        echo "$HOME/.local/bin/monitor-resources.sh"
    fi
}

install_script() {
    local type="$1"
    local script_path
    script_path="$(get_script_path "$type")"
    
    echo "Installing monitor-resources.sh to $script_path ..." >&2
    local bindir
    bindir="$(dirname "$script_path")"
    mkdir -p "$bindir" || die "Cannot create bin directory: $bindir"
    
                    cat > "$script_path" <<'MONITOR_RESOURCES_SCRIPT_EOF'
#!/usr/bin/env bash

set -uo pipefail

# ============================================================
# Linux process resource monitor with bounded log rotation
# and direct CSV output.
#
# Usage:
#   ./monitor-resources.sh [-i seconds] [-o file] [-save-to-csv]
#       [-s size] [-r count] selector...
#   ./monitor-resources.sh -c /path/to/config
#
# Examples:
#   sudo ./monitor-resources.sh -i 5 \
#       -o map-rezi-resources.log \
#       map-rezi-api.service \
#       map-rezi-fetcher.service \
#       mariadb.service
#
#   sudo ./monitor-resources.sh -i 5 -o resources.csv -save-to-csv \
#       map-rezi-api.service map-rezi-fetcher.service mariadb.service
#
# Selectors:
#   - systemd service name
#   - numeric PID
#   - process name (oldest matching PID)
#
# Output:
#   Without -save-to-csv: human-readable log written to -o FILE.
#   With -save-to-csv: CSV rows written directly to -o FILE on the fly.
#
# Existing output files:
#   A = append by rotating into the next slot
#   O = overwrite and remove the existing file and rotations
#
# Rotation:
#   Active file: <file>
#   Rotations:  <file>.1 through <file>.5
#
# Default maximum size per file: 10 MiB
# Default retained rotated files: 5
# ============================================================

INTERVAL=5
OUTPUT=""
SAVE_TO_CSV=0

# Rotation defaults.
MAX_LOG_SIZE="10M"
MAX_LOG_BYTES=$((10 * 1024 * 1024))
MAX_ROTATIONS=5

declare -a SELECTORS=()
declare -A PREV_CPU=()
declare -A PREV_READ=()
declare -A PREV_WRITE=()
declare -A PREV_TIME=()
declare -A PREV_START=()

LAST_MAPPING=""
LOG_FILE=""
CSV_FILE=""

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
    [[ -n "${SAVE_TO_CSV:-}" ]] && SAVE_TO_CSV="$SAVE_TO_CSV"
    [[ -n "${MAX_LOG_SIZE:-}" ]] && MAX_LOG_SIZE="$MAX_LOG_SIZE"
    [[ -n "${MAX_ROTATIONS:-}" ]] && MAX_ROTATIONS="$MAX_ROTATIONS"
    
    # Load selectors if defined as array
    if [[ -n "${SELECTORS[@]:-}" ]]; then
        SELECTORS=("${SELECTORS[@]}")
    fi
}

usage() {
    cat <<'EOF'
Usage:
  monitor-resources.sh [-i seconds] [-o file] [-save-to-csv] [-s size] [-r count] selector...
  monitor-resources.sh -c /path/to/config

Options:
  -c FILE          Load configuration from file
  -i SECONDS       Sampling interval (default: 5 seconds)
  -o FILE          Output file (log or CSV)
  -save-to-csv     Write CSV rows directly to the output file on the fly; requires -o.
                         The output file always gets a .csv extension.
  -s SIZE          Maximum size per output file (default: 10M)
                         Supported suffixes: K, M, G
  -r COUNT         Number of rotated output files to retain (default: 5)
  -h, --help       Show help

Output:
  Without -save-to-csv: human-readable log written to -o FILE.
  With -save-to-csv: CSV rows written directly to -o FILE on the fly.

Rotation:
  Active file: file
  Rotations:  file.COUNT

Rotation defaults:
  Maximum active file size: 10 MiB
  Retained rotated files:  5
  Approximate total storage: 60 MiB

Existing files:
  If the active file or a rotated file exists, you will be asked
  whether to append or overwrite.

Examples:
  ./monitor-resources.sh -i 5 \
      -o map-rezi-resources.log \
      map-rezi-api.service map-rezi-fetcher.service mariadb.service
  ./monitor-resources.sh -i 5 -o resources.csv -save-to-csv \
      map-rezi-api.service map-rezi-fetcher.service mariadb.service
  ./monitor-resources.sh -i 5 -s 20M -r 10 -o monitor.log node
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
        -save-to-csv)
            SAVE_TO_CSV=1
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

# Validate the number of retained rotations.
[[ "$MAX_ROTATIONS" =~ ^[0-9]+$ ]] ||
    die "Invalid rotation count '$MAX_ROTATIONS'. Use a non-negative integer."

# Direct CSV output requires a named output file.
if ((SAVE_TO_CSV)) && [[ -z "$OUTPUT" ]]; then
    die "Direct CSV output requires -o FILE. Example: -o resources.csv -save-to-csv"
fi

[[ "$INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
    die "Sampling interval must be a positive number."

awk -v n="$INTERVAL" 'BEGIN { exit !(n > 0) }' ||
    die "Sampling interval must be greater than zero."

((${#SELECTORS[@]} > 0)) ||
    die "No process selectors supplied. Use -h for help."

# ------------------------------------------------------------
# Derive the CSV filename from the output filename.
#
# When saving to CSV the output file always gets a .csv
# extension, regardless of what the user passed to -o.
# ------------------------------------------------------------

get_csv_filename() {
    local outfile="$1"
    local directory basename

    directory="$(dirname -- "$outfile")"
    basename="$(basename -- "$outfile")"

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
#   file, file.1, file.2, file.3, file.4, file.5
#
# After:
#   new file, old file as .1, old .1 as .2, etc.
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
    if ((SAVE_TO_CSV)); then
        printf '%s\n' "$*" >&2
        return
    fi

    write_log_line "$*" || die "Could not write to the monitoring log."
}

# ------------------------------------------------------------
# Detect existing output files.
# max_rotations defaults to MAX_ROTATIONS for the log path.
# ------------------------------------------------------------

existing_logs_found() {
    local i max_rot="${1:-$MAX_ROTATIONS}"

    [[ -e "$OUTPUT" ]] && return 0

    for ((i = 1; i <= max_rot; i++)); do
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
# Handle existing CSV output before monitoring starts.
#
# Append:
#   Rotate the existing active CSV and all retained rotations,
#   then start a new active CSV with a header row.
#
# Overwrite:
#   Delete the active CSV and all configured rotations.
# ------------------------------------------------------------

prepare_existing_csv() {
    local answer i

    if ! existing_logs_found "$MAX_ROTATIONS"; then
        : > "$CSV_FILE" || die "Cannot create CSV file: $CSV_FILE"
        chmod 0644 -- "$CSV_FILE" ||
            die "Cannot set CSV file permissions."
        return
    fi

    printf '\nWARNING: Existing CSV data was found for:\n' >&2
    printf '  %s\n' "$OUTPUT" >&2

    for ((i = 1; i <= MAX_ROTATIONS; i++)); do
        if [[ -e "$OUTPUT.$i" ]]; then
            printf '  %s\n' "$OUTPUT.$i" >&2
        fi
    done

    printf '\nChoose what to do:\n' >&2
    printf '  [A] Append: preserve history and start a new rotation\n' >&2
    printf '  [O] Overwrite: delete existing CSV and start fresh\n' >&2

    [[ -r /dev/tty ]] ||
        die "Cannot ask for confirmation without a terminal. Run interactively."

    while true; do
        printf 'Your choice [A/O]: ' >&2

        IFS= read -r answer < /dev/tty ||
            die "Could not read your choice."

        case "$answer" in
            A|a)
                if ((MAX_ROTATIONS == 0)); then
                    : > "$CSV_FILE" || die "Cannot truncate CSV file: $CSV_FILE"
                    chmod 0644 -- "$CSV_FILE" || die "Cannot set CSV file permissions."
                else
                    rm -f -- "$CSV_FILE.$MAX_ROTATIONS" ||
                        die "Could not remove rotation $CSV_FILE.$MAX_ROTATIONS"

                    for ((i = MAX_ROTATIONS - 1; i >= 1; i--)); do
                        if [[ -e "$CSV_FILE.$i" ]]; then
                            mv -f -- "$CSV_FILE.$i" "$CSV_FILE.$((i + 1))" ||
                                die "Could not rotate CSV $CSV_FILE.$i"
                        fi
                    done

                    if [[ -e "$CSV_FILE" ]]; then
                        mv -f -- "$CSV_FILE" "$CSV_FILE.1" ||
                            die "Could not rotate active CSV to $CSV_FILE.1"
                    fi

                    : > "$CSV_FILE" || die "Cannot create CSV file: $CSV_FILE"
                    chmod 0644 -- "$CSV_FILE" || die "Cannot set CSV file permissions."
                fi

                printf 'Existing CSV preserved; monitoring will start in a new file.\n' >&2
                return
                ;;
            O|o)
                rm -f -- "$OUTPUT" ||
                    die "Could not remove existing CSV."

                for ((i = 1; i <= MAX_ROTATIONS; i++)); do
                    rm -f -- "$OUTPUT.$i" ||
                        die "Could not remove rotation $OUTPUT.$i"
                done

                : > "$CSV_FILE" ||
                    die "Cannot create CSV file."

                chmod 0644 -- "$CSV_FILE" ||
                    die "Cannot set CSV file permissions."

                printf 'Existing CSV removed; starting fresh.\n' >&2
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
# Rotate the CSV output file before appending a new row.
#
# Before:
#   file, file.1, file.2, file.3, file.4, file.5
#
# After:
#   new file, old file as .1, old .1 as .2, etc.
#
# The previous .5 is discarded.
# ------------------------------------------------------------

rotate_csv() {
    local destination="$1"
    local current_size
    local i

    current_size="$(stat -c '%s' -- "$destination" 2>/dev/null || echo 0)"

    # If current CSV exceeds max size, rotate
    if ((current_size > MAX_LOG_BYTES)); then
        # With zero retained rotations, discard the active CSV.
        if ((MAX_ROTATIONS == 0)); then
            : > "$destination" || return 1
            chmod 0644 -- "$destination" || return 1
            return 0
        fi

        # Remove the oldest retained rotation.
        rm -f -- "$destination.$MAX_ROTATIONS" || return 1

        # Shift existing rotations upward.
        for ((i = MAX_ROTATIONS - 1; i >= 1; i--)); do
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

# ------------------------------------------------------------
# Escape a single CSV field: wrap in double quotes and double any
# internal double quotes when the field contains a comma or double
# quote.
# ------------------------------------------------------------

csv_escape() {
    local field="$1"

    if [[ "$field" == *','* || "$field" == *'"'* ]]; then
        field="${field//\"/\"\"}"
        printf '"%s"' "$field"
    else
        printf '%s' "$field"
    fi
}

# ------------------------------------------------------------
# Write the CSV header to the output file (truncates first).
# ------------------------------------------------------------

write_csv_header() {
    : > "$CSV_FILE" || return 1
    chmod 0644 -- "$CSV_FILE" || return 1
    printf 'timestamp,process,cpu_percent,rss_bytes,vsz_bytes,read_bytes_per_sec,write_bytes_per_sec\n' \
        >> "$CSV_FILE" ||
        { printf 'ERROR: Cannot write CSV header to %s\n' "$CSV_FILE" >&2; return 1; }
    return 0
}

# ------------------------------------------------------------
# Append one CSV row to the output file, rotating first if the
# active file would exceed the maximum size.
# ------------------------------------------------------------

write_csv_line() {
    local timestamp="$1" selector="$2" cpu="$3" rss="$4" vsz="$5" read_rate="$6" write_rate="$7"
    local line

    line="$(printf '%s,%s,%s,%s,%s,%s,%s' \
        "$(csv_escape "$timestamp")" "$(csv_escape "$selector")" \
        "$(csv_escape "$cpu")" "$(csv_escape "$rss")" "$(csv_escape "$vsz")" \
        "$(csv_escape "$read_rate")" "$(csv_escape "$write_rate")")"

    rotate_csv "$CSV_FILE" || {
        printf 'ERROR: CSV rotation failed for %s\n' "$CSV_FILE" >&2
        return 1
    }

    printf '%s\n' "$line" >> "$CSV_FILE" ||
        { printf 'ERROR: Cannot write CSV record to %s\n' "$CSV_FILE" >&2; return 1; }
    return 0
}

# ------------------------------------------------------------
# Cleanup and signal handling.
# ------------------------------------------------------------

cleanup() {
    local status=$?

    trap - EXIT INT TERM

    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ------------------------------------------------------------
# Prepare output file and handle existing files.
# ------------------------------------------------------------

if [[ -n "$OUTPUT" ]]; then
    mkdir -p -- "$(dirname -- "$OUTPUT")" ||
        die "Cannot create output directory."

    if ((SAVE_TO_CSV)); then
        CSV_FILE="$(get_csv_filename "$OUTPUT")"

        # Ask before creating/truncating any existing CSV output.
        prepare_existing_csv
        write_csv_header
    else
        LOG_FILE="$OUTPUT"

        # Ask before creating/truncating any existing log.
        prepare_existing_logs
    fi
fi

# ------------------------------------------------------------
# Main monitoring loop.
# ------------------------------------------------------------

log "Resource monitor started at $(date '+%Y-%m-%d %H:%M:%S')"
log "Sampling interval: $INTERVAL seconds"
log "Maximum output size: $MAX_LOG_SIZE ($MAX_LOG_BYTES bytes)"
log "Maximum retained rotations: $MAX_ROTATIONS"
log "Approximate total retained capacity: $((MAX_LOG_BYTES * (MAX_ROTATIONS + 1))) bytes"
log "Selectors: ${SELECTORS[*]}"
log "Save to CSV: $SAVE_TO_CSV"

if [[ -n "$LOG_FILE" ]]; then
    log "Log file: $LOG_FILE"
fi

if [[ -n "$CSV_FILE" ]]; then
    log "CSV file: $CSV_FILE"
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

        if ((SAVE_TO_CSV)); then
            write_csv_line "$sample_time" "$selector" "${cpu_percent:-}" \
                "$rss_bytes" "$vsz_bytes" \
                "${read_rate:-}" "${write_rate:-}" ||
                die "Could not write CSV record."
        else
            log "Process: $selector (PID $pid)"
            log "  CPU: ${cpu_percent:-warming up}%"
            log "  RSS: $rss_bytes bytes"
            log "  VSZ: $vsz_bytes bytes"
            log "  Read I/O: ${read_rate:-warming up} bytes/sec"
            log "  Write I/O: ${write_rate:-warming up} bytes/sec"
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
done
MONITOR_RESOURCES_SCRIPT_EOF
    chmod 0755 "$script_path" || die "Cannot set permissions on $script_path"
    
    echo "Script installed to: $script_path" >&2
    
    echo "$script_path"
}

collect_params() {
    local type="$1"
    local config_dir="$2"
    
    echo "=== Configuration Parameters ===" >&2
    
    local interval
    while true; do
        read -rp "Sampling interval in seconds [5]: " interval
        interval=${interval:-5}
        if [[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            if awk -v n="$interval" 'BEGIN { if (n > 0) exit 0; else exit 1 }'; then
                break
            fi
        fi
        echo "ERROR: Interval must be a positive number." >&2
    done
    
    local logfile
    while true; do
        if [ "$type" = "system" ]; then
            read -rp "Log file path [/var/log/${SERVICE_NAME}/resources.log]: " logfile
            logfile=${logfile:-/var/log/${SERVICE_NAME}/resources.log}
        else
            read -rp "Log file path [$HOME/.local/log/${SERVICE_NAME}/resources.log]: " logfile
            logfile=${logfile:-$HOME/.local/log/${SERVICE_NAME}/resources.log}
        fi
        local logdir
        logdir="$(dirname "$logfile")"
        if mkdir -p "$logdir" 2>/dev/null; then
            break
        else
            echo "ERROR: Cannot create or access directory $logdir" >&2
        fi
    done
    
    local csv_flag=""
    if ask_yes_no "Save to CSV on the fly?" y; then
        csv_flag="-save-to-csv"
    fi

    local size
    while true; do
        read -rp "Max log size per file [10M]: " size
        size=${size:-10M}
        if [[ "$size" =~ ^[0-9]+([KkMmGg]?)$ ]]; then
            break
        fi
        echo "ERROR: Invalid size format. Use number with optional K,M,G suffix." >&2
    done
    
    local rotations
    while true; do
        read -rp "Number of rotated output files to retain [5]: " rotations
        rotations=${rotations:-5}
        if [[ "$rotations" =~ ^[0-9]+$ ]]; then
            break
        fi
        echo "ERROR: Must be a non-negative integer." >&2
    done
    
    echo ""
    echo "Enter process selectors (systemd service names like foo.service, PIDs, or process names)" >&2
    echo "Enter one per line. Press Enter on empty line when done." >&2
    local selectors=()
    while true; do
        read -rp "Selector: " sel
        [ -z "$sel" ] && break
        selectors+=("$sel")
    done
    if [ ${#selectors[@]} -eq 0 ]; then
        echo "ERROR: At least one selector required." >&2
        exit 1
    fi
    
    mkdir -p "$config_dir"
    local config_file="$config_dir/config"
    
    {
        echo "# monitor-resources configuration"
        echo "INTERVAL=$interval"
        echo "OUTPUT=$logfile"
        if [ -n "$csv_flag" ]; then
            echo "SAVE_TO_CSV=1"
        else
            echo "SAVE_TO_CSV=0"
        fi
        echo "MAX_LOG_SIZE=$size"
        echo "MAX_ROTATIONS=$rotations"
        echo "SELECTORS=(${selectors[*]})"
    } > "$config_file"
    
    echo ""
    echo "Configuration saved to: $config_file" >&2
    echo "Parameters:" >&2
    echo "  Interval: $interval" >&2
    echo "  Log file: $logfile" >&2
    echo "  Save to CSV: $([ -n "$csv_flag" ] && echo yes || echo no)" >&2
    echo "  Max size: $size" >&2
    echo "  Rotations: $rotations" >&2
    echo "  Selectors: ${selectors[*]}" >&2
    
    echo "$config_file"
}

create_service() {
    local type="$1"
    local config_file="$2"
    local unit_file
    unit_file="$(get_service_unit "$type")"
    
    mkdir -p "$(dirname "$unit_file")"
    
    local script_path
    script_path="$(install_script "$type")"
    
    # Ensure -c and config_file are on the same line
    local esc_config
    esc_config="$config_file"
    # Remove any leading/trailing whitespace that might have been introduced
    esc_config="$(echo "$esc_config" | xargs)"
    config_file="$esc_config"
    
    if [ "$type" = "system" ]; then
        cat > "$unit_file" <<EOF
[Unit]
Description=Monitor Resources Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$script_path -c $config_file
ExecStop=/bin/kill -TERM \$MAINPID
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    else
        cat > "$unit_file" <<EOF
[Unit]
Description=Monitor Resources Service
After=default.target

[Service]
Type=simple
ExecStart=$script_path -c $config_file
ExecStop=/bin/kill -TERM \$MAINPID
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    fi
    
    echo "Service unit created: $unit_file"
}

start_service() {
    local type="$1"
    echo "Reloading systemd and starting service..."
    if [ "$type" = "system" ]; then
        systemctl daemon-reload
        systemctl enable "$SERVICE_NAME"
        systemctl start "$SERVICE_NAME"
        echo "Service status:"
        systemctl status "$SERVICE_NAME" --no-pager || true
    else
        systemctl --user daemon-reload
        systemctl --user enable "$SERVICE_NAME"
        systemctl --user start "$SERVICE_NAME"
        echo "Service status:"
        systemctl --user status "$SERVICE_NAME" --no-pager || true
    fi
}

main() {
    echo "=== Monitor Resources Service Installer ==="
    
    # Parse arguments. Reject unknown values instead of silently
    # proceeding to installation (e.g. a misspelled --uninstall).
    local uninstall=0
    local arg
    for arg in "$@"; do
        case "$arg" in
            --uninstall)
                uninstall=1
                ;;
            --help|-h)
                echo "Usage: $0 [--uninstall]"
                exit 0
                ;;
            *)
                echo "ERROR: Unknown argument: $arg" >&2
                echo "Usage: $0 [--uninstall]" >&2
                exit 1
                ;;
        esac
    done
    
    if ((uninstall)); then
        do_uninstall
        exit 0
    fi
    
    check_prereqs
    
    local svc_type
    svc_type="$(detect_service_type)"
    echo "Installing as: $svc_type service"
    
    local config_dir
    config_dir="$(get_config_dir "$svc_type")"
    
    if service_exists "$svc_type"; then
        echo ""
        echo "Existing service detected."
        if ask_yes_no "Stop and reconfigure existing service?"; then
            stop_service "$svc_type"
        else
            echo "Aborting."
            exit 0
        fi
    fi
    
    local config_file
    config_file="$(collect_params "$svc_type" "$config_dir")"
    
    create_service "$svc_type" "$config_file"
    start_service "$svc_type"
    
    echo ""
    echo "=== Installation Complete ==="
}

main "$@"
