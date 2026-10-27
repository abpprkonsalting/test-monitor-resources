monitor_resources_to_disk

monitor-resources.sh
  Linux process resource monitor sampling CPU, RSS, VSZ, and I/O from /proc.
  Selectors: systemd service, numeric PID, or process name.
  Log rotation via -s SIZE and -r COUNT.
  Direct CSV output on the fly with -save-to-csv (requires -o).
  Exported CSV is world-readable (0644) with traversable parent dirs.
  Config file support via -c FILE.
  Periodic CSV updates via -u SECONDS (0 = only on exit).
  Service installation via install.sh (systemd system service, requires root).

Help (monitor-resources.sh -h):
Usage:
  monitor-resources.sh [-i seconds] [-o file] [-save-to-csv] [-s size] [-r count] selector...
  monitor-resources.sh -c /path/to/config

Options:
  -c FILE          Load configuration from file
  -i SECONDS       Sampling interval (default: 5 seconds)
  -o FILE          Output file (log or CSV)
  -save-to-csv     Write CSV rows directly to the output file on the fly; requires -o
  -s SIZE          Maximum size per file (default: 10M)
                         Supported suffixes: K, M, G
  -r COUNT         Number of rotated files to retain (default: 5)
  -h, --help       Show help

Config file format (used with -c):
  # monitor-resources configuration
  INTERVAL=5
  OUTPUT=/var/log/monitor-resources/resources.log
  SAVE_TO_CSV=1
  MAX_LOG_SIZE=10M
  MAX_ROTATIONS=5
  SELECTORS=(map-rezi-api.service mariadb.service)

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

CSV file rotation:
  MAX_LOG_SIZE: Maximum size per CSV file (default 10M). When a CSV
  exceeds this size, it is rotated before appending a new row.
  MAX_ROTATIONS: Number of rotated CSV files to retain (default 5).
  CSV rotation works like log rotation: resources.csv.1, resources.csv.2, etc.

Examples:
  ./monitor-resources.sh -i 5 \
      -o map-rezi-resources.log \
      map-rezi-api.service map-rezi-fetcher.service mariadb.service
  ./monitor-resources.sh -i 5 -o monitor.csv -save-to-csv node
  ./monitor-resources.sh -s 5M -r 3 -o monitor.log node
  ./monitor-resources.sh -c /etc/monitor-resources/config

install.sh
  Automated installer for running monitor-resources.sh as a systemd system service.
  Must be run as root (sudo).
  Usage:
    sudo ./install.sh         Interactively create/reconfigure service
    sudo ./install.sh --uninstall  Stop and remove service (preserves log files)

  Features:
    - Checks prerequisites (python3, systemctl, getconf)
    - Prompts for interval, log file, CSV export, CSV update frequency,
      rotation size/count, and process selectors
    - Saves config to /etc/monitor-resources/config
    - Installs script to /usr/local/bin/
    - Creates systemd unit at /etc/systemd/system/monitor-resources.service,
      enables and starts service as root
    - Detects and reconfigures existing installations
    - Run as root to monitor system services (requires /proc access)

  The CSV Update Frequency prompt controls periodic CSV generation:
    0  = only export CSV when the service stops (default)
    N  = export CSV every N seconds while running, plus on exit

test-monitor-resources.sh
  Automated test harness. Creates dummy systemd processes, runs scenarios,
  preserves artifacts under test-artifacts-<timestamp>/, then removes dummy services.
  Run as root: sudo ./test-monitor-resources.sh

Test cases (per run count: 1, 2, 5, 10; plus monitor's own PID for multi-process):
  1. basic: normal run with -i, -o, -save-to-csv; expects CSV produced.
  2. save-to-csv-without-o: run with -save-to-csv but no -o; expects failure.
  3. invalid-selector: nonexistent process; expects CSV still produced.
  4. append-mode: pre-existing CSV, sends 'A'; expects preserved history + CSV.
  5. overwrite-mode: pre-existing CSV, sends 'O'; expects CSV removed + fresh CSV.
  6. rotation: small -s 4K -r 3; expects CSV after possible rotation.
  7. rotations-zero: -s 2K -r 0; expects CSV with zero retained rotations.

Files:
  monitor-resources.sh - monitoring script
  install.sh             service installer (systemd)
  test-monitor-resources.sh - test harness
  working-report.md - working report
  intial_context.txt - original conversation context
  README.txt - this file
