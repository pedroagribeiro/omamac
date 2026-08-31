#!/usr/bin/env bash
set -uo pipefail
log_info()  { printf '  %s\n' "$*" >&2; }
log_warn()  { printf '  WARN: %s\n' "$*" >&2; }
log_error() { printf '  ERROR: %s\n' "$*" >&2; }
