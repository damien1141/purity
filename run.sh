# run.sh — commit this next to install.sh
#!/usr/bin/env bash
set -euo pipefail
bash -n "$(dirname "$0")/install.sh" || { echo "parse check failed — do not run" >&2; exit 1; }
exec "$(dirname "$0")/install.sh" "$@"
