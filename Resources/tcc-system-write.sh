#!/bin/bash
# Executed as root via `do shell script ... with administrator privileges`.
# Usage: tcc-system-write.sh <sql> [restart]
set -euo pipefail
DB="/Library/Application Support/com.apple.TCC/TCC.db"
/usr/bin/sqlite3 "$DB" "$1"
if [ "${2:-}" = "restart" ]; then
	/usr/bin/killall -9 tccd 2>/dev/null || true
fi
echo "OK"
