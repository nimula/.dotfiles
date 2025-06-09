#!/usr/bin/env bash
# Author : nimula+github@gmail.com
#
# Get the directory of the current script
CURR_DIR="$( cd "$( dirname "$0" )" >/dev/null || exit 1; pwd )"
CONFIG_DIR="$(cd "$CURR_DIR/../config" >/dev/null || exit 1; pwd )"

export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"

function print_default() {
  echo -e "$*"
}

function print_info() {
  echo -e "\e[1;36m[INFO] $*\e[m" # cyan
}

function print_notice() {
  echo -e "\e[1;35m$*\e[m" # magenta
}

function print_success() {
  echo -e "\e[1;32m$*\e[m" # green
}

function print_warning() {
  echo -e "\e[1;33m[WARN] $*\e[m" # yellow
}

function print_error() {
  echo -e "\e[1;31m[ERROR] $*\e[m" # red
}

function print_debug() {
  if [[ "$VERBOSE" = true || "$DEBUG" = true ]]; then
    echo -e "\e[1;34m[DEBUG] $*\e[m" # blue
  fi
}

function run() {
  if [[ "$VERBOSE" = true || "$DRY_RUN" = true ]]; then
    print_default "+ $*"
  fi
  if [ "$DRY_RUN" = false ]; then
    "$@"
  fi
}

# Print usage help
function print_help() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -d     Dry-run mode (print commands without executing)
  -s     Skip package installation
  -v     Verbose output
  -x     Debug mode (enable command tracing with 'set -x')
  -h     Show this help message
EOF
}
