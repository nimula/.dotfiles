#!/usr/bin/env zsh

# Integration acceptance tests for bin/git-wt. Every case uses a temporary
# repository; a failed run leaves the fixtures on disk for inspection.
setopt no_nomatch pipe_fail

typeset SCRIPT_DIR="${0:A:h}"
typeset BIN="$SCRIPT_DIR/../bin/git-wt"
typeset RUN_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/git-wt-tests.XXXXXX")"
typeset TEMPLATE="$RUN_ROOT/template"
typeset CURRENT_CASE=''
typeset CURRENT_FIXTURE=''
typeset -i PASSED=0 FAILED=0
typeset -a FIXTURES

mkdir -p "$TEMPLATE/hooks" || exit 1
print -r -- '#!/bin/sh' >| "$TEMPLATE/hooks/pre-commit"
print -r -- 'exit 0' >> "$TEMPLATE/hooks/pre-commit"
chmod +x "$TEMPLATE/hooks/pre-commit"

export GIT_CONFIG_GLOBAL="$RUN_ROOT/global.gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_SYSTEM="$RUN_ROOT/system.gitconfig"
export GIT_TERMINAL_PROMPT=0
git config --global user.name 'git-wt test'
git config --global user.email 'git-wt-test@example.invalid'
git config --global init.defaultBranch main

function cleanup() {
  if (( FAILED )); then
    print -u2 -- "Fixtures retained under: $RUN_ROOT"
    return
  fi
  rm -rf -- "$RUN_ROOT"
}
trap cleanup EXIT INT TERM

function fail() {
  print -u2 -- "  FAIL[$CURRENT_CASE]: $*"
  return 1
}

function assert_eq() {
  local actual="$1" expected="$2" message="${3:-values differ}"
  [[ "$actual" == "$expected" ]] || fail "$message (expected <$expected>, got <$actual>)"
}

function assert_contains() {
  local haystack="$1" needle="$2" message="${3:-output does not contain expected text}"
  [[ "$haystack" == *"$needle"* ]] || fail "$message: <$needle>"
}

function assert_file() {
  [[ -e "$1" || -L "$1" ]] || fail "missing path: $1"
}

function new_fixture() {
  CURRENT_FIXTURE="$(mktemp -d "$RUN_ROOT/case.XXXXXX")" || return 1
  FIXTURES+=($CURRENT_FIXTURE)
}

function marker_from() {
  local line
  REPLY=''
  for line in ${(f)1}; do
    [[ "$line" == GIT_WT_CD:* ]] && REPLY="${line#GIT_WT_CD:}"
  done
}

function make_source() {
  local source="$1"
  git init --template="$TEMPLATE" -b main "$source" >/dev/null || return 1
  git -C "$source" config user.name 'git-wt test'
  git -C "$source" config user.email 'git-wt-test@example.invalid'
  print -r -- 'base' >| "$source/tracked.txt"
  print -r -- 'executable' >| "$source/executable.sh"
  chmod +x "$source/executable.sh"
  git -C "$source" add -A
  git -C "$source" commit -m base >/dev/null || return 1
  git -C "$source" branch feature/login
  git -C "$source" branch bugfix/ui
}

function make_container() {
  local source="$1" container="$2"
  mkdir -p "$container" || return 1
  git clone --bare "$source" "$container/.git" >/dev/null || return 1
  git --git-dir="$container/.git" config remote.origin.fetch \
    '+refs/heads/*:refs/remotes/origin/*'
  git --git-dir="$container/.git" fetch origin >/dev/null || return 1
  git --git-dir="$container/.git" remote set-head origin -a >/dev/null 2>&1 || return 1
  git --git-dir="$container/.git" update-ref -d refs/heads/feature/login
  git --git-dir="$container/.git" update-ref -d refs/heads/bugfix/ui
  git --git-dir="$container/.git" worktree add "$container/main" main >/dev/null || return 1
}

function make_migration_repo() {
  local repo="$1"
  git init --template="$TEMPLATE" -b main "$repo" >/dev/null || return 1
  git -C "$repo" config user.name 'git-wt test'
  git -C "$repo" config user.email 'git-wt-test@example.invalid'
  print -r -- '*.hidden.log' >| "$repo/.gitignore"
  print -r -- 'tracked' >| "$repo/tracked.txt"
  print -r -- 'executable' >| "$repo/executable.sh"
  chmod +x "$repo/executable.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -m base >/dev/null || return 1
  git -C "$repo" branch -M feature/login

  print -r -- 'staged' >> "$repo/tracked.txt"
  git -C "$repo" add tracked.txt
  print -r -- 'unstaged' >> "$repo/tracked.txt"
  print -r -- 'untracked' >| "$repo/untracked.txt"
  print -r -- 'hidden' >| "$repo/.hidden"
  print -r -- 'ignored' >| "$repo/.hidden.log"
  ln -s tracked.txt "$repo/link.txt"
  # Add enough files for the partial-file-move failure shim to fail after
  # some entries have already moved.
  print -r -- 'one' >| "$repo/one.txt"
  print -r -- 'two' >| "$repo/two.txt"
  print -r -- 'three' >| "$repo/three.txt"
}

function status_snapshot() {
  git -C "$1" status --porcelain=v1 --untracked-files=all -z >| "$2" || return 1
  git -C "$1" diff --binary >| "$3" || return 1
  git -C "$1" diff --cached --binary >| "$4" || return 1
}

function case_init_clone() {
  new_fixture || return 1
  local source="$CURRENT_FIXTURE/source" destination="$CURRENT_FIXTURE/container"
  local output marker rc
  make_source "$source" || return 1

  output="$($BIN init "$source" "$destination" 2> "$CURRENT_FIXTURE/init.err")"
  rc=$?
  assert_eq "$rc" 0 'init clone succeeds' || return 1
  marker_from "$output"
  marker="$REPLY"
  assert_eq "$marker" "$destination/main" 'init emits initial worktree marker' || return 1
  assert_file "$destination/.git" || return 1
  assert_eq "$(git --git-dir="$destination/.git" rev-parse --is-bare-repository)" \
    true 'clone destination is bare' || return 1
  assert_eq "$(git -C "$destination/main" branch --show-current)" main \
    'initial worktree uses the remote default branch' || return 1
  assert_eq "$(git -C "$destination/main" rev-parse --abbrev-ref '@{upstream}')" \
    origin/main 'initial branch tracks origin/main' || return 1
  assert_eq "$(git --git-dir="$destination/.git" symbolic-ref --short refs/remotes/origin/HEAD)" \
    origin/main 'origin/HEAD points to the default branch' || return 1

  mkdir "$CURRENT_FIXTURE/existing" || return 1
  if "$BIN" init "$source" "$CURRENT_FIXTURE/existing" >/dev/null 2>&1; then
    fail 'init accepts an existing destination' || return 1
  fi
  if "$BIN" init "$CURRENT_FIXTURE/no-such-source" "$CURRENT_FIXTURE/bad" \
    >/dev/null 2>&1; then
    fail 'init accepts an invalid source' || return 1
  fi
  git init --bare "$CURRENT_FIXTURE/empty-source" >/dev/null || return 1
  if "$BIN" init "$CURRENT_FIXTURE/empty-source" "$CURRENT_FIXTURE/empty" \
    >/dev/null 2>&1; then
    fail 'init checks out an empty repository' || return 1
  fi
}

function case_switch_create() {
  new_fixture || return 1
  local source="$CURRENT_FIXTURE/source" container="$CURRENT_FIXTURE/container"
  local output marker rc before after
  make_source "$source" || return 1
  make_container "$source" "$container" || return 1

  before="$(git -C "$container/main" status --porcelain)"
  output="$(cd "$container/main" && "$BIN" switch feature/login 2> "$CURRENT_FIXTURE/switch.err")"
  rc=$?
  assert_eq "$rc" 0 'switch creates a worktree for an origin branch' || return 1
  marker_from "$output"
  assert_eq "$REPLY" "$container/feature/login" 'switch preserves slash in path' || return 1
  assert_eq "$(git -C "$container/feature/login" branch --show-current)" \
    feature/login 'switch creates the requested branch' || return 1
  assert_eq "$(git -C "$container/feature/login" rev-parse --abbrev-ref '@{upstream}')" \
    origin/feature/login 'origin branch is tracked' || return 1
  after="$(git -C "$container/main" status --porcelain)"
  assert_eq "$after" "$before" 'switch leaves the original worktree unchanged' || return 1

  output="$(cd "$container/main" && "$BIN" switch feature/login 2>/dev/null)"
  rc=$?
  assert_eq "$rc" 0 'switch reuses an existing worktree' || return 1
  marker_from "$output"
  assert_eq "$REPLY" "$container/feature/login" 'reused worktree path is registered path' || return 1

  git --git-dir="$container/.git" branch local-only main || return 1
  output="$(cd "$container/main" && "$BIN" sw local-only 2>/dev/null)"
  rc=$?
  assert_eq "$rc" 0 'switch adds a local branch without a worktree' || return 1
  marker_from "$output"
  assert_eq "$REPLY" "$container/local-only" 'local branch uses its branch path' || return 1

  output="$(cd "$container/main" && "$BIN" create feature/new origin/main 2> "$CURRENT_FIXTURE/create.err")"
  rc=$?
  assert_eq "$rc" 0 'create accepts an explicit base' || return 1
  marker_from "$output"
  assert_eq "$REPLY" "$container/feature/new" 'create preserves slash in path' || return 1
  assert_eq "$(git -C "$container/feature/new" branch --show-current)" feature/new \
    'create checks out the new branch' || return 1

  output="$(cd "$container/main" && "$BIN" create bugfix/new 2>/dev/null)"
  rc=$?
  assert_eq "$rc" 0 'create resolves origin/HEAD as its default base' || return 1
  marker_from "$output"
  assert_eq "$REPLY" "$container/bugfix/new" 'default-base worktree path is correct' || return 1

  mkdir -p "$container/feature"
  print -r -- collision >| "$container/feature/collision"
  if (cd "$container/main" && "$BIN" create feature/collision >/dev/null 2>&1); then
    fail 'create ignores a destination path collision' || return 1
  fi
  if (cd "$container/main" && "$BIN" switch missing/branch >/dev/null 2>&1); then
    fail 'switch creates a missing branch without origin' || return 1
  fi
}

function case_migration() {
  new_fixture || return 1
  local repo="$CURRENT_FIXTURE/repo" output marker rc head
  local before_status="$CURRENT_FIXTURE/status.before"
  local after_status="$CURRENT_FIXTURE/status.after"
  local before_diff="$CURRENT_FIXTURE/diff.before"
  local after_diff="$CURRENT_FIXTURE/diff.after"
  local before_cached="$CURRENT_FIXTURE/cached.before"
  local after_cached="$CURRENT_FIXTURE/cached.after"
  local original_mode migrated_mode
  make_migration_repo "$repo" || return 1
  head="$(git -C "$repo" rev-parse HEAD)"
  original_mode="$(stat -f '%Lp' "$repo/executable.sh")"
  status_snapshot "$repo" "$before_status" "$before_diff" "$before_cached" || return 1

  output="$(cd "$repo" && "$BIN" init 2> "$CURRENT_FIXTURE/migrate.err")"
  rc=$?
  assert_eq "$rc" 0 'init migrates an ordinary repository' || return 1
  marker_from "$output"
  assert_eq "$REPLY" "$repo/feature/login" 'migration emits the new worktree path' || return 1
  assert_eq "$(git --git-dir="$repo/.git" rev-parse --is-bare-repository)" true \
    'migrated repository is bare' || return 1
  assert_eq "$(git -C "$repo/feature/login" rev-parse HEAD)" "$head" \
    'migration preserves HEAD' || return 1
  status_snapshot "$repo/feature/login" "$after_status" "$after_diff" "$after_cached" || return 1
  cmp -s "$before_status" "$after_status" || fail 'migration changed Git status' || return 1
  cmp -s "$before_diff" "$after_diff" || fail 'migration changed unstaged diff' || return 1
  cmp -s "$before_cached" "$after_cached" || fail 'migration changed staged diff' || return 1
  assert_file "$repo/feature/login/.hidden" || return 1
  assert_file "$repo/feature/login/.hidden.log" || return 1
  assert_file "$repo/feature/login/link.txt" || return 1
  [[ -L "$repo/feature/login/link.txt" ]] || fail 'migration preserves symlink type' || return 1
  migrated_mode="$(stat -f '%Lp' "$repo/feature/login/executable.sh")"
  assert_eq "$migrated_mode" "$original_mode" 'migration preserves executable mode' || return 1
  local -a old_root
  old_root=($repo:h/${repo:t}.pre-bare-migration.*(N))
  (( ${#old_root} == 0 )) || fail 'successful migration leaves a temporary tree' || return 1
}

function case_migration_detached() {
  new_fixture || return 1
  local repo="$CURRENT_FIXTURE/repo" head short output marker rc
  make_migration_repo "$repo" || return 1
  git -C "$repo" checkout --detach HEAD >/dev/null || return 1
  head="$(git -C "$repo" rev-parse HEAD)"
  short="$(git -C "$repo" rev-parse --short HEAD)"
  output="$(cd "$repo" && "$BIN" init 2> "$CURRENT_FIXTURE/detached.err")"
  rc=$?
  assert_eq "$rc" 0 'init migrates a detached repository' || return 1
  marker_from "$output"
  assert_eq "$REPLY" "$repo/detached-$short" 'detached migration uses short SHA path' || return 1
  assert_eq "$(git -C "$REPLY" rev-parse HEAD)" "$head" \
    'detached migration preserves HEAD' || return 1
  if git -C "$REPLY" symbolic-ref -q HEAD >/dev/null 2>&1; then
    fail 'detached migration unexpectedly created a branch' || return 1
  fi
}

function write_failure_shims() {
  local shim="$1" fail_at="$2" real_git real_mv git_dir
  real_git="${commands[git]}"
  real_mv="${commands[mv]}"
  git_dir="${commands[zsh]:h}"
  mkdir -p "$shim" || return 1
  print -r -- '#!/bin/sh' >| "$shim/git"
  print -r -- 'exec "$GIT_WT_REAL_GIT" "$@"' >> "$shim/git"
  chmod +x "$shim/git"
  print -r -- '#!/bin/sh' >| "$shim/mv"
  print -r -- 'n=$(cat "$GIT_WT_MV_COUNT")' >> "$shim/mv"
  print -r -- 'n=$((n + 1))' >> "$shim/mv"
  print -r -- 'printf "%s\\n" "$n" >| "$GIT_WT_MV_COUNT"' >> "$shim/mv"
  print -r -- 'if [ "$n" -eq "$GIT_WT_MV_FAIL_AT" ]; then' >> "$shim/mv"
  print -r -- '  echo "forced mv failure" >&2' >> "$shim/mv"
  print -r -- '  exit 77' >> "$shim/mv"
  print -r -- 'fi' >> "$shim/mv"
  print -r -- 'exec "$GIT_WT_REAL_MV" "$@"' >> "$shim/mv"
  chmod +x "$shim/mv"
  SHIM_PATH="$shim:$git_dir:${real_git:h}:/usr/bin:/bin"
  SHIM_REAL_GIT="$real_git"
  SHIM_REAL_MV="$real_mv"
  SHIM_FAIL_AT="$fail_at"
}

function assert_migration_data_survives() {
  local repo="$1" candidate rel found
  local -a old_root
  old_root=($repo:h/${repo:t}.pre-bare-migration.*(N))
  for rel in tracked.txt executable.sh untracked.txt .hidden .hidden.log link.txt \
    one.txt two.txt three.txt; do
    found=0
    [[ -e "$repo/$rel" || -L "$repo/$rel" ]] && found=1
    for candidate in $old_root; do
      [[ -e "$candidate/$rel" || -L "$candidate/$rel" ]] && found=1
    done
    (( found )) || fail "migration failure lost $rel" || return 1
  done
}

function case_migration_failure_recovery() {
  new_fixture || return 1
  local repo="$CURRENT_FIXTURE/metadata-repo" output rc shim count
  make_migration_repo "$repo" || return 1
  shim="$CURRENT_FIXTURE/shim"
  write_failure_shims "$shim" 2 || return 1
  count="$CURRENT_FIXTURE/mv-count"
  print -r -- 0 >| "$count"
  output="$(cd "$repo" && PATH="$SHIM_PATH" GIT_WT_REAL_GIT="$SHIM_REAL_GIT" \
    GIT_WT_REAL_MV="$SHIM_REAL_MV" GIT_WT_MV_COUNT="$count" \
    GIT_WT_MV_FAIL_AT="$SHIM_FAIL_AT" "$BIN" init 2> "$CURRENT_FIXTURE/metadata.err")"
  rc=$?
  if (( rc == 0 )); then
    fail 'metadata shim did not make migration fail' || return 1
  fi
  assert_migration_data_survives "$repo" || return 1

  repo="$CURRENT_FIXTURE/partial-files-repo"
  make_migration_repo "$repo" || return 1
  write_failure_shims "$shim" 5 || return 1
  count="$CURRENT_FIXTURE/mv-count-partial"
  print -r -- 0 >| "$count"
  output="$(cd "$repo" && PATH="$SHIM_PATH" GIT_WT_REAL_GIT="$SHIM_REAL_GIT" \
    GIT_WT_REAL_MV="$SHIM_REAL_MV" GIT_WT_MV_COUNT="$count" \
    GIT_WT_MV_FAIL_AT="$SHIM_FAIL_AT" "$BIN" init 2> "$CURRENT_FIXTURE/partial.err")"
  rc=$?
  if (( rc == 0 )); then
    fail 'partial file move shim did not make migration fail' || return 1
  fi
  assert_migration_data_survives "$repo" || return 1
}
