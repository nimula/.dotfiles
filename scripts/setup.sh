#!/usr/bin/env bash
# Author : nimula+github@gmail.com
#
set -Eeo pipefail
source "$(dirname "$0")/utils.sh"
trap cleanup SIGINT SIGTERM ERR EXIT

ENV_VARS="
  DRY_RUN=false
  VERBOSE=false
  DEBUG=false
  SKIP_PKG_INSTALL=false
"

function cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  tput cnorm # enable cursor
  # script cleanup here
}

function parser_options() {
  while getopts ":dhsvx" opt; do
    case "$opt" in
      d) DRY_RUN=true ;;
      s) SKIP_PKG_INSTALL=true ;;
      v) VERBOSE=true ;;
      x) DEBUG=true ;;
      h)
        print_help
        exit 0
        ;;
      \?)
        echo "Unknown option: -$OPTARG" >&2
        print_help
        exit 1
        ;;
    esac
  done
  shift $((OPTIND - 1))

  if [ "$DRY_RUN" ]; then
    DRY_RUN=true
    print_info "Dry-run mode enabled: commands will not be executed"
  fi
  if [ "$SKIP_PKG_INSTALL" ]; then
    SKIP_PKG_INSTALL=true
    print_info "Skipping package installation."
  fi
  if [ "$VERBOSE" ]; then
    VERBOSE=true
  fi
  if [ "$DEBUG" ]; then
    DEBUG=true
    set -x
  fi
}

function run_with_env() {
  (
    for line in $ENV_VARS; do
      key=$(echo "$line" | cut -d= -f1)
      val=$(echo "$line" | cut -d= -f2-)
      eval "export $key=\"\${$key:-$val}\""
    done
    bash "$@"
  )
}

function main() {
  print_info "Installing dotfiles for $(uname)..."
  # Parse options: d = dry-run, v = verbose, s = skip package install,
  # x = set -x, h = help
  parser_options "$@"

  run_with_env "$CURR_DIR/setup-linux.sh"
  run_with_env "$CURR_DIR/setup-homebrew.sh"
  run_with_env "$CURR_DIR/setup-common.sh"
  run_with_env "$CURR_DIR/setup-mac.sh"

  print_success "Done."
}

main "$@"
