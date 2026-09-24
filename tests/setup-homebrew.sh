#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

prepare_fixture() {
  local case_root="$1"
  local brew_prefix="$2"

  mkdir -p "$case_root/bin" "$case_root/config/homebrew" "$case_root/scripts"
  cp "$REPO_ROOT/scripts/setup.sh" "$case_root/scripts/setup.sh"
  sed "s|$brew_prefix|$TEST_HOMEBREW_PREFIX|g" \
    "$REPO_ROOT/scripts/setup-homebrew.sh" > "$case_root/scripts/setup-homebrew.sh"
  sed "s|$brew_prefix|$TEST_HOMEBREW_PREFIX|g" \
    "$REPO_ROOT/scripts/utils.sh" > "$case_root/scripts/utils.sh"

  printf '%s\n' '#!/usr/bin/env bash' 'echo Darwin' > "$case_root/bin/uname"
  printf '%s\n' \
    '#!/bin/bash' \
    'cp "$TEST_FAKE_BREW" "$TEST_HOMEBREW_PREFIX/bin/brew"' \
    'chmod +x "$TEST_HOMEBREW_PREFIX/bin/brew"' \
    'printf "%s\n" curl >> "$TEST_CURL_LOG"' \
    'printf ":\n"' > "$case_root/bin/curl"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if ! command -v yq >/dev/null 2>&1; then' \
    '  exit 1' \
    'fi' \
    'yq --version' \
    'touch "$TEST_AGENTS_RAN"' > "$case_root/scripts/setup-agents.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$case_root/scripts/setup-linux.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$case_root/scripts/setup-common.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$case_root/scripts/setup-mac.sh"
  chmod +x "$case_root/bin/uname" "$case_root/bin/curl" "$case_root/scripts/"*.sh
}

prepare_fake_brew() {
  local case_root="$1"

  mkdir -p "$TEST_HOMEBREW_PREFIX/bin"
  TEST_FAKE_BREW="$case_root/fake-brew"
  export TEST_FAKE_BREW
  printf '%s\n' \
    '#!/bin/bash' \
    'printf "%s\n" "$*" >> "$TEST_BREW_LOG"' \
    'case "$1" in' \
    '  shellenv) printf '\''export PATH="%s:$PATH"\n'\'' "$TEST_HOMEBREW_PREFIX/bin" ;;' \
    '  update) ;;' \
    '  bundle)' \
    '    printf '\''#!/bin/bash\nprintf "yq test"\n'\'' > "$TEST_HOMEBREW_PREFIX/bin/yq"' \
    '    /bin/chmod +x "$TEST_HOMEBREW_PREFIX/bin/yq"' \
    '    ;;' \
    '  *) exit 1 ;;' \
    'esac' > "$TEST_FAKE_BREW"
  chmod +x "$TEST_FAKE_BREW"
}

assert_log_contains() {
  local expected="$1"

  if ! grep -Fqx "$expected" "$TEST_BREW_LOG"; then
    printf 'expected Homebrew invocation not found: %s\n' "$expected" >&2
    cat "$TEST_BREW_LOG" >&2
    return 1
  fi
}

run_setup() {
  local case_root="$1"
  local path_prefix="$2"

  # Match the literal defaults exported by install.sh. This guards against
  # setup.sh treating the non-empty string "false" as an enabled option.
  PATH="$path_prefix$case_root/bin:/usr/bin:/bin" \
    TERM=xterm \
    DRY_RUN=false VERBOSE=false DEBUG=false SKIP_PKG_INSTALL=false REMOTE_CONTAINERS=false \
    TEST_HOMEBREW_PREFIX="$TEST_HOMEBREW_PREFIX" \
    TEST_BREW_LOG="$TEST_BREW_LOG" \
    TEST_CURL_LOG="$TEST_CURL_LOG" \
    TEST_AGENTS_RAN="$TEST_AGENTS_RAN" \
    TEST_FAKE_BREW="$TEST_FAKE_BREW" \
    "$BASH" "$case_root/scripts/setup.sh"
}

test_fresh_install_updates_parent_path() {
  local case_root="$TEST_ROOT/fresh"
  TEST_HOMEBREW_PREFIX="$case_root/opt/homebrew"
  TEST_BREW_LOG="$case_root/brew.log"
  TEST_CURL_LOG="$case_root/curl.log"
  TEST_AGENTS_RAN="$case_root/agents-ran"
  export TEST_HOMEBREW_PREFIX TEST_BREW_LOG TEST_CURL_LOG TEST_AGENTS_RAN
  prepare_fake_brew "$case_root"
  prepare_fixture "$case_root" /opt/homebrew

  run_setup "$case_root" ""

  test -f "$TEST_AGENTS_RAN"
  assert_log_contains shellenv
  assert_log_contains update
  assert_log_contains "bundle install --file $case_root/config/homebrew/Brewfile"
  grep -Fqx curl "$TEST_CURL_LOG"
}

test_existing_install_remains_usable() {
  local case_root="$TEST_ROOT/existing"
  TEST_HOMEBREW_PREFIX="$case_root/usr/local"
  TEST_BREW_LOG="$case_root/brew.log"
  TEST_CURL_LOG="$case_root/curl.log"
  TEST_AGENTS_RAN="$case_root/agents-ran"
  export TEST_HOMEBREW_PREFIX TEST_BREW_LOG TEST_CURL_LOG TEST_AGENTS_RAN
  prepare_fake_brew "$case_root"
  prepare_fixture "$case_root" /usr/local
  cp "$TEST_FAKE_BREW" "$TEST_HOMEBREW_PREFIX/bin/brew"
  chmod +x "$TEST_HOMEBREW_PREFIX/bin/brew"

  run_setup "$case_root" "$TEST_HOMEBREW_PREFIX/bin:"

  test -f "$TEST_AGENTS_RAN"
  assert_log_contains update
  assert_log_contains "bundle install --file $case_root/config/homebrew/Brewfile"
  test ! -e "$TEST_CURL_LOG"
}

test_dry_run_does_not_require_brew() {
  local case_root="$TEST_ROOT/dry-run"
  TEST_HOMEBREW_PREFIX="$case_root/opt/homebrew"
  mkdir -p "$TEST_HOMEBREW_PREFIX/bin"
  prepare_fixture "$case_root" /opt/homebrew
  printf '%s\n' '#!/bin/bash' 'printf ":\n"' > "$case_root/bin/curl"
  chmod +x "$case_root/bin/curl"

  PATH="$case_root/bin:/usr/bin:/bin" \
    SKIP_PKG_INSTALL=false DRY_RUN=true VERBOSE=false DEBUG=false \
    "$BASH" "$case_root/scripts/setup-homebrew.sh"
}

test_skip_package_install_does_not_require_brew() {
  local case_root="$TEST_ROOT/skip-packages"
  TEST_HOMEBREW_PREFIX="$case_root/opt/homebrew"
  mkdir -p "$TEST_HOMEBREW_PREFIX/bin"
  prepare_fixture "$case_root" /opt/homebrew
  printf '%s\n' '#!/bin/bash' 'exit 1' > "$case_root/bin/curl"
  chmod +x "$case_root/bin/curl"

  PATH="$case_root/bin:/usr/bin:/bin" \
    SKIP_PKG_INSTALL=true DRY_RUN=false VERBOSE=false DEBUG=false \
    "$BASH" "$case_root/scripts/setup-homebrew.sh"
}

test_fresh_install_updates_parent_path
test_existing_install_remains_usable
test_dry_run_does_not_require_brew
test_skip_package_install_does_not_require_brew

printf 'setup-homebrew tests passed\n'
