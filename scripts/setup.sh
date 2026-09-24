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
  REMOTE_CONTAINERS=false
"

function cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  if command -v tput >/dev/null 2>&1; then
    tput cnorm # enable cursor
  fi
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

  # These options are also initialized to the literal string "false" by the
  # installers.  Testing only for a non-empty value makes "false" truthy and
  # accidentally enables every mode during a normal installation.
  if [ "${DRY_RUN:-false}" = true ]; then
    DRY_RUN=true
    print_info "Dry-run mode enabled: commands will not be executed"
  fi
  if [ "${SKIP_PKG_INSTALL:-false}" = true ]; then
    SKIP_PKG_INSTALL=true
    print_info "Skipping package installation."
  fi
  if [ "${VERBOSE:-false}" = true ]; then
    VERBOSE=true
  fi
  if [ "${DEBUG:-false}" = true ]; then
    DEBUG=true
    set -x
  fi
  if [ "${REMOTE_CONTAINERS:-false}" = true ]; then
    SKIP_PKG_INSTALL=true
    print_info "Skip the packages installation and ssh setup that the remote container doesn't need."
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
  # Homebrew setup runs in a child shell, so load its PATH for later scripts.
  if [ "$(uname)" = Darwin ] &&
    [ "${DRY_RUN:-false}" = false ] &&
    [ "${SKIP_PKG_INSTALL:-false}" = false ]; then
    load_homebrew_environment || true
  fi
  run_with_env "$CURR_DIR/setup-common.sh"
  run_with_env "$CURR_DIR/setup-agents.sh"
  run_with_env "$CURR_DIR/setup-mac.sh"

  print_success "Done."
}

main "$@"
