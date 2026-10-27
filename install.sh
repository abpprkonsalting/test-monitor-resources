#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="monitor-resources"
SYSTEM_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
USER_UNIT="$HOME/.config/systemd/user/${SERVICE_NAME}.service"
CONFIG_DIR_SYSTEM="/etc/${SERVICE_NAME}"
CONFIG_DIR_USER="$HOME/.config/${SERVICE_NAME}"
SCRIPT_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/monitor-resources.sh"

check_prereqs() {
    echo "Checking prerequisites..."
    local missing=()
    command -v python3 >/dev/null 2>&1 || missing+=("python3")
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
    
    cp "$SCRIPT_SOURCE" "$script_path" || die "Cannot install script to $script_path"
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
    if ask_yes_no "Export CSV on exit?" y; then
        csv_flag="-csv"
    fi

    # CSV periodic update frequency
    local csv_update_interval=""
    while true; do
        read -rp "CSV periodic update interval in seconds (0 = only on exit) [0]: " csv_update_interval
        csv_update_interval=${csv_update_interval:-0}
        if [[ "$csv_update_interval" =~ ^[0-9]+$ ]]; then
            break
        fi
        echo "ERROR: Must be a non-negative integer." >&2
    done
    
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
        read -rp "Number of rotated logs to retain [5]: " rotations
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
            echo "EXPORT_CSV=1"
        else
            echo "EXPORT_CSV=0"
        fi
        echo "MAX_LOG_SIZE=$size"
        echo "MAX_ROTATIONS=$rotations"
        echo "CSV_UPDATE_INTERVAL=$csv_update_interval"
        echo "SELECTORS=(${selectors[*]})"
    } > "$config_file"
    
    echo ""
    echo "Configuration saved to: $config_file" >&2
    echo "Parameters:" >&2
    echo "  Interval: $interval" >&2
    echo "  Log file: $logfile" >&2
    echo "  CSV export: $([ -n "$csv_flag" ] && echo yes || echo no)" >&2
    echo "  CSV update interval: ${csv_update_interval}s" >&2
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
    
    # Handle --uninstall flag
    if [[ "${1:-}" == "--uninstall" ]]; then
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
