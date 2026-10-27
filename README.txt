monitor_resources_to_disk

monitor-resources.sh
  Linux process resource monitor sampling CPU, RSS, VSZ, and I/O from /proc.
  Selectors: systemd service, numeric PID, or process name.
  Log rotation via -s SIZE and -r COUNT.
  CSV export on exit with -csv (requires -o).
  Exported CSV is world-readable (0644) with traversable parent dirs.
  Config file support via -c FILE.
  Periodic CSV updates via -u SECONDS (0 = only on exit).
  Service installation via install.sh (systemd).

Help (monitor-resources.sh -h):
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

Config file format (used with -c):
  # monitor-resources configuration
  INTERVAL=5
  OUTPUT=/var/log/monitor-resources/resources.log
  EXPORT_CSV=1
  MAX_LOG_SIZE=10M
  MAX_ROTATIONS=5
  CSV_UPDATE_INTERVAL=30
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

Periodic CSV updates:
  When -u SECONDS (or CSV_UPDATE_INTERVAL in config) is > 0, the CSV
  is regenerated at that interval during monitoring. CSV is also
  exported on exit regardless.

Examples:
  ./monitor-resources.sh -i 5 \
      -o map-rezi-resources.log -csv \
      map-rezi-api.service map-rezi-fetcher.service mariadb.service
  ./monitor-resources.sh -i 5 -s 20M -r 10 -o monitor.log -csv node
  ./monitor-resources.sh -s 5M -r 3 -o monitor.log node
  ./monitor-resources.sh -c /etc/monitor-resources/config

install.sh
  Automated installer for running monitor-resources.sh as a systemd service.
  Usage:
    ./install.sh          Interactively create/reconfigure service
    ./install.sh --uninstall  Stop and remove service (preserves log files)

  Features:
    - Checks prerequisites (python3, systemctl, getconf)
    - Prompts for interval, log file, CSV export, CSV update frequency,
      rotation size/count, and process selectors
    - Saves config to /etc/monitor-resources/config (root) or
      ~/.config/monitor-resources/config (user)
    - Installs script to /usr/local/bin/ (root) or ~/.local/bin/ (user)
    - Creates systemd unit, enables and starts service
    - Detects and reconfigures existing installations

  The CSV Update Frequency prompt controls periodic CSV generation:
    0  = only export CSV when the service stops (default)
    N  = export CSV every N seconds while running, plus on exit

test-monitor-resources.sh
  Automated test harness. Creates dummy systemd processes, runs scenarios,
  preserves artifacts under test-artifacts-<timestamp>/, then removes dummy services.
  Run as root: sudo ./test-monitor-resources.sh

Test cases (per run count: 1, 2, 5, 10; plus monitor's own PID for multi-process):
  1. basic: normal run with -i, -o, -csv; expects CSV produced.
  2. csv-without-o: run with -csv but no -o; expects failure.
  3. invalid-selector: nonexistent process; expects CSV still produced.
  4. append-mode: pre-existing log, sends 'A'; expects preserved history + CSV.
  5. overwrite-mode: pre-existing log, sends 'O'; expects logs removed + CSV.
  6. rotation: small -s 4K -r 3; expects CSV after possible rotation.
  7. rotations-zero: -s 2K -r 0; expects CSV with zero retained rotations.

Files:
  monitor-resources.sh - monitoring script
  install.sh             service installer (systemd)
  test-monitor-resources.sh - test harness
  working-report.md - working report
  intial_context.txt - original conversation context
  README.txt - this file
