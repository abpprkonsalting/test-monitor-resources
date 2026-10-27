monitor_resources_to_disk

monitor-resources.sh
  Linux process resource monitor sampling CPU, RSS, VSZ, and I/O from /proc.
  Selectors: systemd service, numeric PID, or process name.
  Log rotation via -s SIZE and -r COUNT.
  CSV export on exit with -csv (requires -o).
  Exported CSV is world-readable (0644) with traversable parent dirs.

Help (monitor-resources.sh -h):
Usage:
  monitor-resources.sh [-i seconds] [-o logfile] [-csv] [-s size] [-r count] selector...

Options:
  -i SECONDS   Sampling interval (default: 5 seconds)
  -o FILE      Log file
  -csv         Export CSV when monitoring exits; requires -o
  -s SIZE      Maximum size per log file (default: 10M)
                    Supported suffixes: K, M, G
  -r COUNT     Number of rotated log files to retain (default: 5)
  -h, --help   Show help

Rotation:
  Active log: logfile
  Rotations:  logfile.1 through logfile.COUNT

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
  test-monitor-resources.sh - test harness
  working-report.md - working report
  intial_context.txt - original conversation context
  README.txt - this file
