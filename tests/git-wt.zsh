#!/usr/bin/env zsh

# Integration acceptance tests for bin/git-wt. Every case uses a temporary
# repository; a failed run leaves the fixtures on disk for inspection.
setopt no_nomatch pipe_fail

typeset SCRIPT_DIR="${0:A:h}"
typeset BIN="$SCRIPT_DIR/../bin/git-wt"
typeset RUN_ROOT="${$(mktemp -d "${TMPDIR:-/tmp}/git-wt-tests.XXXXXX"):A}"
typeset TEMPLATE="$RUN_ROOT/template"
typeset CURRENT_CASE=''
typeset CURRENT_FIXTURE=''
typeset -i PASSED=0 FAILED=0

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

function assert_not_contains() {
  local haystack="$1" needle="$2" message="${3:-output unexpectedly contains text}"
  [[ "$haystack" != *"$needle"* ]] || fail "$message: <$needle>"
}

function assert_file() {
  [[ -e "$1" || -L "$1" ]] || fail "missing path: $1"
}

function new_fixture() {
  CURRENT_FIXTURE="$(mktemp -d "$RUN_ROOT/case.XXXXXX")" || return 1
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
  git clone --bare "$source" "$container/.git" >/dev/null 2>&1 || return 1
  git --git-dir="$container/.git" config remote.origin.fetch \
    '+refs/heads/*:refs/remotes/origin/*'
  git --git-dir="$container/.git" fetch origin >/dev/null 2>&1 || return 1
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
  mkdir -p "$repo/nested/untracked" "$repo/nested/ignored" || return 1
  print -r -- 'nested untracked' >| "$repo/nested/untracked/data.txt"
  print -r -- 'nested ignored' >| "$repo/nested/ignored/trace.hidden.log"
}

function status_snapshot() {
  # Observation must not refresh or convert the index under test.
  GIT_OPTIONAL_LOCKS=0 git -C "$1" status --porcelain=v1 --untracked-files=all -z >| "$2" || return 1
  GIT_OPTIONAL_LOCKS=0 git -C "$1" diff --binary >| "$3" || return 1
  GIT_OPTIONAL_LOCKS=0 git -C "$1" diff --cached --binary >| "$4" || return 1
}

function tree_snapshot() {
  local root="$1" output="$2" item rel mode digest
  : >| "$output" || return 1
  while IFS= read -r -d '' item; do
    [[ "$item" == "$root" || "$item" == "$root/.git" ]] && continue
    rel="${item#$root/}"
    if [[ -L "$item" ]]; then
      print -r -- "$rel|symlink|$(readlink "$item")" >> "$output"
    elif [[ -f "$item" ]]; then
      if stat -f '%Lp' "$item" >/dev/null 2>&1; then
        mode="$(stat -f '%Lp' "$item")" || return 1
      else
        mode="$(stat -c '%a' "$item")" || return 1
      fi
      digest="$(cksum < "$item")" || return 1
      print -r -- "$rel|file|$mode|$digest" >> "$output"
    else
      print -r -- "$rel|other" >> "$output"
    fi
  done < <(find -P "$root" -path "$root/.git" -prune -o -print0)
}

function metadata_snapshot() {
  local root="$1" output="$2" item rel mode digest
  {
    print -r -- 'config'
    git -C "$root" config --local --list
    for item in "$root/.git/index" "$root/.git"/sharedindex.*(N); do
      [[ -f "$item" ]] || continue
      rel="${item#$root/.git/}"
      if stat -f '%Lp' "$item" >/dev/null 2>&1; then
        mode="$(stat -f '%Lp' "$item")" || return 1
      else
        mode="$(stat -c '%a' "$item")" || return 1
      fi
      digest="$(cksum < "$item")" || return 1
      print -r -- "$rel|$mode|$digest"
    done
  } >| "$output"
}

function refs_snapshot() {
  local root="$1" output="$2" head
  {
    git -C "$root" for-each-ref --format='%(refname) %(objectname) %(symref)'
    if head="$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null)"; then
      print -r -- "HEAD symbolic $head"
    else
      head="$(git -C "$root" rev-parse HEAD)" || return 1
      print -r -- "HEAD detached $head"
    fi
  } >| "$output"
}

function snapshot_repo_state() {
  local root="$1" prefix="$2"
  refs_snapshot "$root" "$prefix.refs" || return 1
  status_snapshot "$root" "$prefix.status" "$prefix.diff" "$prefix.cached" || return 1
  tree_snapshot "$root" "$prefix.tree"
}

function assert_repo_state() {
  local root="$1" prefix="$2" label="${3:-repository state}"
  local actual="$CURRENT_FIXTURE/state.actual"
  if ! snapshot_repo_state "$root" "$actual"; then
    fail "$label cannot be read after the operation"
    return 1
  fi
  cmp -s "$prefix.refs" "$actual.refs" || fail "$label changed refs" || return 1
  cmp -s "$prefix.status" "$actual.status" || fail "$label changed status" || return 1
  cmp -s "$prefix.diff" "$actual.diff" || fail "$label changed unstaged diff" || return 1
  cmp -s "$prefix.cached" "$actual.cached" || fail "$label changed staged diff" || return 1
  cmp -s "$prefix.tree" "$actual.tree" || fail "$label changed file content, mode, or symlink" || return 1
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
  local repo="$CURRENT_FIXTURE/repo" output rc head
  local state="$CURRENT_FIXTURE/migration.before"
  local before_status="$CURRENT_FIXTURE/status.before"
  local after_status="$CURRENT_FIXTURE/status.after"
  local before_diff="$CURRENT_FIXTURE/diff.before"
  local after_diff="$CURRENT_FIXTURE/diff.after"
  local before_cached="$CURRENT_FIXTURE/cached.before"
  local after_cached="$CURRENT_FIXTURE/cached.after"
  make_migration_repo "$repo" || return 1
  head="$(git -C "$repo" rev-parse HEAD)"
  [[ -x "$repo/executable.sh" ]] || fail 'fixture executable bit is missing' || return 1
  snapshot_repo_state "$repo" "$state" || return 1
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
  assert_repo_state "$repo/feature/login" "$state" 'successful migration' || return 1
  status_snapshot "$repo/feature/login" "$after_status" "$after_diff" "$after_cached" || return 1
  cmp -s "$before_status" "$after_status" || fail 'migration changed Git status' || return 1
  cmp -s "$before_diff" "$after_diff" || fail 'migration changed unstaged diff' || return 1
  cmp -s "$before_cached" "$after_cached" || fail 'migration changed staged diff' || return 1
  assert_file "$repo/feature/login/.hidden" || return 1
  assert_file "$repo/feature/login/.hidden.log" || return 1
  assert_file "$repo/feature/login/link.txt" || return 1
  [[ -L "$repo/feature/login/link.txt" ]] || fail 'migration preserves symlink type' || return 1
  [[ -x "$repo/feature/login/executable.sh" ]] || \
    fail 'migration did not preserve executable mode' || return 1
  local -a old_root
  old_root=($repo:h/${repo:t}.pre-bare-migration.*(N))
  (( ${#old_root} == 0 )) || fail 'successful migration leaves a temporary tree' || return 1
}

function set_dangling_origin_head() {
  git --git-dir="$1/.git" symbolic-ref refs/remotes/origin/HEAD \
    refs/remotes/origin/dangling-default
}

function case_default_base() {
  new_fixture || return 1
  local source="$CURRENT_FIXTURE/source" container="$CURRENT_FIXTURE/main-container"
  make_source "$source" || return 1
  make_container "$source" "$container" || return 1
  set_dangling_origin_head "$container" || return 1
  (cd "$container/main" && "$BIN" create fallback/main >/dev/null) || return 1
  assert_eq "$(git -C "$container/fallback/main" rev-parse HEAD)" \
    "$(git --git-dir="$container/.git" rev-parse main)" \
    'dangling origin/HEAD does not fall back to local main' || return 1

  container="$CURRENT_FIXTURE/master-container"
  make_container "$source" "$container" || return 1
  git --git-dir="$container/.git" branch -m main master || return 1
  set_dangling_origin_head "$container" || return 1
  (cd "$container/main" && "$BIN" create fallback/master >/dev/null) || return 1
  assert_eq "$(git -C "$container/fallback/master" rev-parse HEAD)" \
    "$(git --git-dir="$container/.git" rev-parse master)" \
    'dangling origin/HEAD does not fall back to local master' || return 1

  container="$CURRENT_FIXTURE/no-base-container"
  make_container "$source" "$container" || return 1
  git --git-dir="$container/.git" branch -m main trunk || return 1
  set_dangling_origin_head "$container" || return 1
  if (cd "$container/main" && "$BIN" create fallback/missing >/dev/null 2>&1); then
    fail 'create accepts a dangling origin/HEAD without main or master' || return 1
  fi
  [[ ! -e "$container/fallback/missing" ]] || fail 'missing default base mutates the container' || return 1
}

function case_split_index_rejection() {
  new_fixture || return 1
  local repo="$CURRENT_FIXTURE/actual-split" state="$CURRENT_FIXTURE/actual-split.before"
  local metadata="$CURRENT_FIXTURE/actual-split.metadata" output
  make_migration_repo "$repo" || return 1
  git -C "$repo" config core.splitIndex true || return 1
  git -C "$repo" update-index --split-index || return 1
  assert_file "$(git -C "$repo" rev-parse --path-format=absolute --shared-index-path)" || return 1
  git -C "$repo" config core.splitIndex false || return 1
  snapshot_repo_state "$repo" "$state" || return 1
  metadata_snapshot "$repo" "$metadata" || return 1
  if output="$(cd "$repo" && "$BIN" init 2>&1)"; then
    fail 'migration accepts an actual split index with config disabled' || return 1
  fi
  assert_contains "$output" 'Split index' 'actual split index rejection is unclear' || return 1
  assert_repo_state "$repo" "$state" 'actual split index rejection' || return 1
  metadata_snapshot "$repo" "$CURRENT_FIXTURE/actual-split.metadata.after" || return 1
  cmp -s "$metadata" "$CURRENT_FIXTURE/actual-split.metadata.after" || {
    fail 'actual split index rejection changes index or Git configuration'
    return 1
  }

  repo="$CURRENT_FIXTURE/config-split"
  state="$CURRENT_FIXTURE/config-split.before"
  metadata="$CURRENT_FIXTURE/config-split.metadata"
  make_migration_repo "$repo" || return 1
  git -C "$repo" config core.splitIndex true || return 1
  snapshot_repo_state "$repo" "$state" || return 1
  metadata_snapshot "$repo" "$metadata" || return 1
  if output="$(cd "$repo" && "$BIN" init 2>&1)"; then
    fail 'migration accepts core.splitIndex enabled' || return 1
  fi
  assert_contains "$output" 'Split index' 'split index config rejection is unclear' || return 1
  assert_repo_state "$repo" "$state" 'split index config rejection' || return 1
  metadata_snapshot "$repo" "$CURRENT_FIXTURE/config-split.metadata.after" || return 1
  cmp -s "$metadata" "$CURRENT_FIXTURE/config-split.metadata.after" || {
    fail 'split index config rejection changes index or Git configuration'
    return 1
  }
}

function case_tree_snapshot() {
  new_fixture || return 1
  local repo="$CURRENT_FIXTURE/repo" before="$CURRENT_FIXTURE/tree.before"
  local after="$CURRENT_FIXTURE/tree.after"
  make_migration_repo "$repo" || return 1
  tree_snapshot "$repo" "$before" || return 1
  print -r -- 'changed nested content' >| "$repo/nested/untracked/data.txt"
  tree_snapshot "$repo" "$after" || return 1
  cmp -s "$before" "$after" && {
    fail 'tree snapshot misses nested content changes'
    return 1
  }
  assert_not_contains "$(<"$before")" '.git/' 'tree snapshot includes root metadata' || return 1
}

function case_migration_detached() {
  new_fixture || return 1
  local repo="$CURRENT_FIXTURE/repo" head short output rc
  make_migration_repo "$repo" || return 1
  git -C "$repo" checkout --detach HEAD >/dev/null || return 1
  head="$(git -C "$repo" rev-parse HEAD)"
  short="${head[1,12]}"
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
  print -r -- 'if [ "${GIT_WT_FAIL_WORKTREE_ADD:-0}" = 1 ]; then' >> "$shim/git"
  print -r -- '  saw_worktree=0; saw_add=0; saw_relative=0' >> "$shim/git"
  print -r -- '  for argument in "$@"; do' >> "$shim/git"
  print -r -- '    [ "$argument" = worktree ] && saw_worktree=1' >> "$shim/git"
  print -r -- '    [ "$argument" = add ] && saw_add=1' >> "$shim/git"
  print -r -- '    [ "$argument" = --relative-paths ] && saw_relative=1' >> "$shim/git"
  print -r -- '  done' >> "$shim/git"
  print -r -- '  if [ "$saw_worktree$saw_add$saw_relative" = 111 ]; then echo "forced worktree add failure" >&2; exit 77; fi' >> "$shim/git"
  print -r -- 'fi' >> "$shim/git"
  print -r -- 'if [ "${GIT_WT_FAIL_WORKTREE_ADD_AFTER:-0}" = 1 ]; then' >> "$shim/git"
  print -r -- '  saw_worktree=0; saw_add=0; saw_relative=0' >> "$shim/git"
  print -r -- '  for argument in "$@"; do' >> "$shim/git"
  print -r -- '    [ "$argument" = worktree ] && saw_worktree=1' >> "$shim/git"
  print -r -- '    [ "$argument" = add ] && saw_add=1' >> "$shim/git"
  print -r -- '    [ "$argument" = --relative-paths ] && saw_relative=1' >> "$shim/git"
  print -r -- '  done' >> "$shim/git"
  print -r -- '  if [ "$saw_worktree$saw_add$saw_relative" = 111 ]; then' >> "$shim/git"
  print -r -- '    "$GIT_WT_REAL_GIT" "$@" || exit $?' >> "$shim/git"
  print -r -- '    [ -z "${GIT_WT_AFTER_ADD_MARKER:-}" ] || : > "$GIT_WT_AFTER_ADD_MARKER"' >> "$shim/git"
  print -r -- '    echo "forced worktree add failure after creation" >&2; exit 77' >> "$shim/git"
  print -r -- '  fi' >> "$shim/git"
  print -r -- 'fi' >> "$shim/git"
  print -r -- 'if [ -n "${GIT_WT_FAIL_REMOVE_PATH:-}" ]; then' >> "$shim/git"
  print -r -- '  saw_worktree=0; saw_remove=0' >> "$shim/git"
  print -r -- '  for argument in "$@"; do' >> "$shim/git"
  print -r -- '    [ "$argument" = worktree ] && saw_worktree=1' >> "$shim/git"
  print -r -- '    [ "$argument" = remove ] && saw_remove=1' >> "$shim/git"
  print -r -- '  done' >> "$shim/git"
  print -r -- '  if [ "$saw_worktree$saw_remove" = 11 ]; then' >> "$shim/git"
  print -r -- '    for argument in "$@"; do' >> "$shim/git"
  print -r -- '      if [ "$argument" = "$GIT_WT_FAIL_REMOVE_PATH" ]; then echo "forced worktree remove failure" >&2; exit 77; fi' >> "$shim/git"
  print -r -- '    done' >> "$shim/git"
  print -r -- '  fi' >> "$shim/git"
  print -r -- 'fi' >> "$shim/git"
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
  print -r -- '#!/bin/sh' >| "$shim/rmdir"
  print -r -- 'if [ "${GIT_WT_FAIL_RMDIR_PATH:-}" = "${1:-}" ] && [ ! -e "${GIT_WT_FAIL_RMDIR_ONCE_MARKER:-/nonexistent}" ]; then' >> "$shim/rmdir"
  print -r -- '  : > "$GIT_WT_FAIL_RMDIR_ONCE_MARKER"' >> "$shim/rmdir"
  print -r -- '  echo "forced rmdir failure" >&2; exit 77' >> "$shim/rmdir"
  print -r -- 'fi' >> "$shim/rmdir"
  print -r -- 'exec /bin/rmdir "$@"' >> "$shim/rmdir"
  chmod +x "$shim/rmdir"
  SHIM_PATH="$shim:$git_dir:${real_git:h}:/usr/bin:/bin"
  SHIM_REAL_GIT="$real_git"
  SHIM_REAL_MV="$real_mv"
  SHIM_FAIL_AT="$fail_at"
}

function assert_no_migration_duplicates() {
  local repo="$1"
  local -a old_root
  old_root=($repo:h/${repo:t}.pre-bare-migration.*(N))
  (( ${#old_root} == 0 )) || fail 'recovery left the original data tree in place' || return 1
  [[ ! -e "$repo/feature/login" ]] || fail 'recovery left a duplicate linked worktree' || return 1
}

function case_cli_and_discovery() {
  new_fixture || return 1
  local source="$CURRENT_FIXTURE/source repo" container="$CURRENT_FIXTURE/container repo"
  local output rc link="$CURRENT_FIXTURE/git-wt-link"
  make_source "$source" || return 1
  make_container "$source" "$container" || return 1

  output="$(cd "$container" && "$BIN" list 2>&1)" || return 1
  assert_contains "$output" "$container/main" 'container root discovers worktrees' || return 1
  output="$(cd "$container/main" && "$BIN" list 2>&1)" || return 1
  assert_contains "$output" "$container/main" 'worktree discovers common directory' || return 1
  mkdir -p "$container/main/nested/dir"
  output="$(cd "$container/main/nested/dir" && "$BIN" list 2>&1)" || return 1
  assert_contains "$output" "$container/main" 'nested directory discovers common directory' || return 1

  ln -s "$BIN" "$link" || return 1
  output="$($link help 2>&1)" || return 1
  assert_contains "$output" 'Git worktree management' 'symlink invocation loads print utilities' || return 1
  output="$(cd "$CURRENT_FIXTURE" && "$BIN" help 2>&1)" || return 1
  assert_not_contains "$output" 'pull request' 'help has no PR feature' || return 1
  output="$(cd "$CURRENT_FIXTURE" && "$BIN" shellenv 2>&1)" || return 1
  assert_contains "$output" 'git-wt()' 'shellenv works outside a repository' || return 1

  for command_line in 'nonesuch' 'switch' 'create' 'remove' 'prune extra' \
    'init -x' 'switch -x' 'create -x'; do
    if (cd "$container/main" && ${(z)BIN} ${(z)command_line} >/dev/null 2>&1); then
      fail "invalid invocation succeeds: $command_line" || return 1
    fi
  done
  output="$(cd "$container/main" && "$BIN" switch -- feature/login 2>/dev/null)"
  rc=$?
  assert_eq "$rc" 0 'switch accepts -- before its branch' || return 1
  marker_from "$output"
  assert_eq "$REPLY" "$container/feature/login" '-- invocation emits marker' || return 1
}

function case_remove() {
  new_fixture || return 1
  local source="$CURRENT_FIXTURE/source" container="$CURRENT_FIXTURE/container"
  local ordinary_linked="$CURRENT_FIXTURE/ordinary-linked"
  local rc head short output
  make_source "$source" || return 1
  git -C "$source" worktree add --detach "$ordinary_linked" main >/dev/null || return 1
  if output="$(cd "$ordinary_linked" && "$BIN" remove main 2>&1)"; then
    fail 'ordinary repository main worktree is removable' || return 1
  fi
  assert_contains "$output" 'Refusing to remove protected worktree' \
    'ordinary repository main is protected independently of current worktree' || return 1
  git -C "$source" worktree remove "$ordinary_linked" || return 1

  make_container "$source" "$container" || return 1
  git --git-dir="$container/.git" branch exact main || return 1
  git --git-dir="$container/.git" worktree add "$container/exact" exact >/dev/null || return 1

  (cd "$container/main" && "$BIN" remove exact </dev/null >/dev/null 2>&1)
  rc=$?
  assert_eq "$rc" 0 'exact branch removes without confirmation' || return 1
  [[ ! -d "$container/exact" ]] || fail 'exact branch worktree remains' || return 1
  git --git-dir="$container/.git" show-ref --verify --quiet refs/heads/exact || \
    fail 'remove unexpectedly deleted the branch' || return 1

  git --git-dir="$container/.git" branch batch/one main || return 1
  git --git-dir="$container/.git" branch batch/two main || return 1
  git --git-dir="$container/.git" worktree add "$container/batch/one" batch/one >/dev/null || return 1
  git --git-dir="$container/.git" worktree add "$container/batch/two" batch/two >/dev/null || return 1
  if (cd "$container/main" && "$BIN" remove 'batch/*' </dev/null >/dev/null 2>&1); then
    fail 'noninteractive pattern removal bypasses confirmation' || return 1
  fi
  if (cd "$container/main" && "$BIN" remove -s 'batch/*' >/dev/null 2>&1); then
    fail 'silent pattern removal is treated as approval' || return 1
  fi
  (cd "$container/main" && "$BIN" remove -f 'batch/*' >/dev/null 2>&1) || return 1
  [[ ! -d "$container/batch/one" && ! -d "$container/batch/two" ]] || \
    fail 'forced pattern removal left a worktree' || return 1

  git --git-dir="$container/.git" branch partial/one main || return 1
  git --git-dir="$container/.git" branch partial/two main || return 1
  git --git-dir="$container/.git" worktree add "$container/partial/one" partial/one >/dev/null || return 1
  git --git-dir="$container/.git" worktree add "$container/partial/two" partial/two >/dev/null || return 1
  write_failure_shims "$CURRENT_FIXTURE/remove-shim" 999 || return 1
  if (cd "$container/main" && PATH="$SHIM_PATH" GIT_WT_REAL_GIT="$SHIM_REAL_GIT" \
    GIT_WT_FAIL_REMOVE_PATH="$container/partial/one" "$BIN" remove -ff 'partial/*' \
    >/dev/null 2>&1); then
    fail 'partial remove failure was hidden' || return 1
  fi
  [[ -d "$container/partial/one" ]] || fail 'partial remove failure removed its failed target' || return 1
  [[ ! -d "$container/partial/two" ]] || fail 'partial remove failure stopped before later targets' || return 1
  git --git-dir="$container/.git" show-ref --verify --quiet refs/heads/partial/one || \
    fail 'partial remove failure deleted the first branch' || return 1
  git --git-dir="$container/.git" show-ref --verify --quiet refs/heads/partial/two || \
    fail 'partial remove failure deleted the second branch' || return 1

  head="$(git --git-dir="$container/.git" rev-parse main)"
  short="${head[1,10]}"
  git --git-dir="$container/.git" worktree add --detach "$container/detached-one" "$head" >/dev/null || return 1
  (cd "$container/main" && "$BIN" remove "$short" </dev/null >/dev/null 2>&1) || \
    fail 'unique exact detached SHA requires confirmation' || return 1
  git --git-dir="$container/.git" worktree add --detach "$container/detached-a" "$head" >/dev/null || return 1
  git --git-dir="$container/.git" worktree add --detach "$container/detached-b" "$head" >/dev/null || return 1
  if (cd "$container/main" && "$BIN" remove "$head" </dev/null >/dev/null 2>&1); then
    fail 'shared detached SHA bypasses confirmation' || return 1
  fi
  (cd "$container/main" && "$BIN" remove -ff "$head" >/dev/null 2>&1) || return 1

  git --git-dir="$container/.git" branch dirty main || return 1
  git --git-dir="$container/.git" worktree add "$container/dirty" dirty >/dev/null || return 1
  print -r -- dirty >| "$container/dirty/untracked"
  if (cd "$container/main" && "$BIN" remove dirty >/dev/null 2>&1); then
    fail 'dirty worktree removal succeeds without force' || return 1
  fi
  (cd "$container/main" && "$BIN" remove -f dirty >/dev/null 2>&1) || return 1

  git --git-dir="$container/.git" branch locked main || return 1
  git --git-dir="$container/.git" worktree add "$container/locked" locked >/dev/null || return 1
  git --git-dir="$container/.git" worktree lock "$container/locked" || return 1
  if (cd "$container/main" && "$BIN" remove -f locked >/dev/null 2>&1); then
    fail 'single force removes a locked worktree' || return 1
  fi
  (cd "$container/main" && "$BIN" remove -ff locked >/dev/null 2>&1) || return 1

  if (cd "$container/main" && "$BIN" remove main >/dev/null 2>&1); then
    fail 'main worktree is not protected' || return 1
  fi
  git --git-dir="$container/.git" branch guard main || return 1
  git --git-dir="$container/.git" worktree add "$container/guard" guard >/dev/null || return 1
  if (cd "$container/guard" && "$BIN" remove guard >/dev/null 2>&1); then
    fail 'current worktree is removable from another linked worktree' || return 1
  fi
  (cd "$container/guard" && "$BIN" remove main >/dev/null 2>&1) || \
    fail 'bare-container main worktree is not removable' || return 1
  [[ ! -d "$container/main" ]] || fail 'bare-container main worktree remains' || return 1
  git --git-dir="$container/.git" show-ref --verify --quiet refs/heads/main || \
    fail 'removing a worktree deleted its branch' || return 1
  if (cd "$container/guard" && "$BIN" remove 'no-match-*' >/dev/null 2>&1); then
    fail 'zero-match removal succeeds' || return 1
  fi
  if (cd "$container/guard" && "$BIN" remove '[' >/dev/null 2>&1); then
    fail 'malformed pattern succeeds' || return 1
  fi
}

function pty_read_until() {
  local name="$1" expected="$2" output='' chunk
  local -i attempt
  for attempt in {1..100}; do
    chunk=''
    if zpty -r -t "$name" chunk; then
      output+="$chunk"
      if [[ "$output" == *"$expected"* ]]; then
        REPLY="$output"
        return 0
      fi
    fi
    sleep 0.05
  done
  zpty -d "$name" 2>/dev/null || true
  fail "PTY timed out waiting for: $expected"
}

function case_shellenv_remove_pty() {
  new_fixture || return 1
  zmodload zsh/zpty || {
    fail 'zsh zpty module is unavailable'
    return 1
  }
  local source="$CURRENT_FIXTURE/source" container="$CURRENT_FIXTURE/container"
  local shell_path="${BIN:h}:$PATH" shell entry answer name query branch_one branch_two
  local prompt result expected_rc script launch
  make_source "$source" || return 1
  make_container "$source" "$container" || return 1
  script='eval "$(git-wt shellenv)"
builtin cd -- "$1/main"
case "$2" in
  direct) git-wt remove "$3" ;;
  alias) git wt remove "$3" ;;
esac
rc=$?
printf "\nPTY_RESULT:%s|%s\n" "$rc" "$(pwd -P)"
exit "$rc"'

  for shell in bash zsh; do
    for entry in direct alias; do
      if [[ "$shell/$entry" == bash/direct || "$shell/$entry" == zsh/direct ]]; then
        answer=y
        expected_rc=0
      else
        answer=n
        expected_rc=1
      fi
      query="prompt/${shell}-${entry}-${answer}-*"
      branch_one="prompt/${shell}-${entry}-${answer}-one"
      branch_two="prompt/${shell}-${entry}-${answer}-two"
      git --git-dir="$container/.git" branch "$branch_one" main || return 1
      git --git-dir="$container/.git" branch "$branch_two" main || return 1
      git --git-dir="$container/.git" worktree add "$container/$branch_one" "$branch_one" >/dev/null || return 1
      git --git-dir="$container/.git" worktree add "$container/$branch_two" "$branch_two" >/dev/null || return 1
      name="git_wt_${shell}_${entry}_${answer}"
      if [[ "$shell" == bash ]]; then
        launch="env PATH=${(q)shell_path} bash --noprofile --norc -c ${(q)script} _ ${(q)container} ${(q)entry} ${(q)query}"
      else
        launch="env PATH=${(q)shell_path} zsh -f -c ${(q)script} _ ${(q)container} ${(q)entry} ${(q)query}"
      fi
      zpty -b "$name" "$launch" || return 1
      pty_read_until "$name" 'Remove these worktrees? [y/N] ' || return 1
      prompt="$REPLY"
      assert_contains "$prompt" 'Matched worktrees:' \
        "$shell $entry does not show candidates before confirmation" || return 1
      assert_contains "$prompt" "$container/$branch_one" \
        "$shell $entry omits the first candidate before confirmation" || return 1
      assert_contains "$prompt" "$container/$branch_two" \
        "$shell $entry omits the second candidate before confirmation" || return 1
      zpty -w "$name" "$answer"$'\n' || return 1
      pty_read_until "$name" 'PTY_RESULT:' || return 1
      result="$REPLY"
      zpty -d "$name" 2>/dev/null || true
      assert_contains "$result" "PTY_RESULT:$expected_rc|$container/main" \
        "$shell $entry does not preserve exit state and PWD" || return 1
      if [[ "$answer" == y ]]; then
        [[ ! -e "$container/$branch_one" && ! -e "$container/$branch_two" ]] || {
          fail "$shell $entry did not remove confirmed worktrees"
          return 1
        }
      else
        [[ -e "$container/$branch_one" && -e "$container/$branch_two" ]] || {
          fail "$shell $entry removed worktrees after rejection"
          return 1
        }
        git --git-dir="$container/.git" worktree remove --force "$container/$branch_one" || return 1
        git --git-dir="$container/.git" worktree remove --force "$container/$branch_two" || return 1
      fi
    done
  done
}

function case_shellenv() {
  new_fixture || return 1
  local source="$CURRENT_FIXTURE/source repo" container="$CURRENT_FIXTURE/container repo"
  local shell_path="${BIN:h}:$PATH" output
  make_source "$source" || return 1
  make_container "$source" "$container" || return 1

  output="$(PATH="$shell_path" bash --noprofile --norc -c '
    eval "$(git-wt shellenv)"
    eval "$(git-wt shellenv)"
    cd -- "$1/main"
    git wt sw feature/login >/dev/null
    git-wt create shell/bash origin/main >/dev/null
    pwd -P
  ' _ "$container")" || return 1
  assert_eq "$output" "$container/shell/bash" 'Bash wrappers switch and create worktrees' || return 1

  output="$(PATH="$shell_path" zsh -f -c '
    source <(git-wt shellenv)
    source <(git-wt shellenv)
    cd -- "$1/main"
    git wt sw feature/login >/dev/null
    git-wt create shell/zsh origin/main >/dev/null
    pwd -P
  ' _ "$container")" || return 1
  assert_eq "$output" "$container/shell/zsh" 'Zsh wrappers switch and create worktrees' || return 1

  output="$(PATH="$shell_path" bash --noprofile --norc -c '
    eval "$(git-wt shellenv)"
    cd -- "$1/main"
    before=$(pwd -P)
    git-wt switch missing >/dev/null 2>&1 || rc=$?
    printf "%s|%s\n" "${rc:-0}" "$(pwd -P)"
  ' _ "$container")" || return 1
  assert_eq "$output" "1|$container/main" 'failed command preserves PWD and status' || return 1

  print -r -- passthrough >| "$container/main/pass-through"
  output="$(PATH="$shell_path" bash --noprofile --norc -c '
    eval "$(git-wt shellenv)"
    builtin cd -- "$1/main"
    actual="$(git status --porcelain)"; actual_rc=$?
    expected="$(command git status --porcelain)"; expected_rc=$?
    actual_c="$(git -C "$1/main" status --porcelain)"; actual_c_rc=$?
    expected_c="$(command git -C "$1/main" status --porcelain)"; expected_c_rc=$?
    printf "%s|%s|%s|%s\n" "$actual|$actual_rc" "$expected|$expected_rc" "$actual_c|$actual_c_rc" "$expected_c|$expected_c_rc"
  ' _ "$container")" || return 1
  assert_eq "$output" "?? pass-through|0|?? pass-through|0|?? pass-through|0|?? pass-through|0" \
    'git wrappers do not alter ordinary git output or status' || return 1

  output="$(PATH="$shell_path" bash --noprofile --norc -c '
    eval "$(git-wt shellenv)"
    builtin cd -- "$1/main"
    cd() { return 73; }
    git-wt switch feature/login >/dev/null 2>&1
    printf "%s|%s\n" "$?" "$(builtin pwd -P)"
  ' _ "$container")" || return 1
  assert_eq "$output" "73|$container/main" 'cd failure is returned by the wrapper' || return 1

  output="$(PATH="$shell_path" bash --noprofile --norc -c '
    eval "$(git-wt shellenv)"
    builtin cd -- "$1/main"
    git-wt list >/dev/null
    printf "%s|%s\n" "$?" "$(builtin pwd -P)"
  ' _ "$container")" || return 1
  assert_eq "$output" "0|$container/main" 'non-cd commands preserve PWD' || return 1

  local clone_source="$CURRENT_FIXTURE/clone source"
  make_source "$clone_source" || return 1
  output="$(PATH="$shell_path" bash --noprofile --norc -c '
    eval "$(git-wt shellenv)"
    cd -- "$1"
    git-wt init "$2" "new container" >/dev/null
    pwd -P
  ' _ "$CURRENT_FIXTURE" "$clone_source")" || return 1
  assert_eq "$output" "$CURRENT_FIXTURE/new container/main" 'Bash init changes to a path with spaces' || return 1

  local zsh_clone_source="$CURRENT_FIXTURE/zsh clone source"
  make_source "$zsh_clone_source" || return 1
  output="$(PATH="$shell_path" zsh -f -c '
    source <(git-wt shellenv)
    builtin cd -- "$1"
    git wt init "$2" "zsh container" >/dev/null
    pwd -P
  ' _ "$CURRENT_FIXTURE" "$zsh_clone_source")" || return 1
  assert_eq "$output" "$CURRENT_FIXTURE/zsh container/main" 'Zsh init changes to a path with spaces' || return 1
}

function case_completion() {
  new_fixture || return 1
  local source="$CURRENT_FIXTURE/source" container="$CURRENT_FIXTURE/container"
  local shell_path="${BIN:h}:$PATH" output before after detached_head sentinel
  local literal_command literal_backtick literal_variable
  make_source "$source" || return 1
  make_container "$source" "$container" || return 1
  git --git-dir="$container/.git" branch local/slash main || return 1
  git --git-dir="$container/.git" branch guard main || return 1
  git --git-dir="$container/.git" worktree add "$container/guard" guard >/dev/null || return 1
  git --git-dir="$container/.git" worktree add --detach "$container/detached" main >/dev/null || return 1
  detached_head="$(git -C "$container/detached" rev-parse HEAD)"
  sentinel="$CURRENT_FIXTURE/completion-command-ran"
  literal_command='literal-command-$(touch${IFS}'"$sentinel"')'
  literal_backtick='literal-backtick-`touch${IFS}'"$sentinel"'`'
  literal_variable='literal-variable-$GIT_WT_TEST_SENTINEL'
  git --git-dir="$container/.git" branch "$literal_command" main || return 1
  git --git-dir="$container/.git" branch "$literal_backtick" main || return 1
  git --git-dir="$container/.git" branch "$literal_variable" main || return 1
  git --git-dir="$container/.git" worktree add "$container/literal-remove" "$literal_variable" >/dev/null || return 1
  before="$(git -C "$container/main" status --porcelain)"

  output="$(PATH="$shell_path" bash --noprofile --norc -c '
    eval "$(git-wt shellenv)"
    cd -- "$1/guard"
    COMP_WORDS=(git-wt sw "")
    COMP_CWORD=2
    _git_wt_complete_bash
    printf "SW:%s\n" "${COMPREPLY[@]}"
    COMP_WORDS=(git-wt create new "")
    COMP_CWORD=3
    _git_wt_complete_bash
    printf "CREATE:%s\n" "${COMPREPLY[@]}"
    COMP_WORDS=(git-wt remove -f "")
    COMP_CWORD=3
    _git_wt_complete_bash
    printf "REMOVE:%s\n" "${COMPREPLY[@]}"
    COMP_WORDS=(git-wt remove -- "")
    COMP_CWORD=3
    _git_wt_complete_bash
    printf "DOUBLE_DASH:%s\n" "${COMPREPLY[@]}"
    COMP_WORDS=(git-wt sw literal-command-)
    COMP_CWORD=2
    _git_wt_complete_bash
    printf "LITERAL_SWITCH:<%s>\n" "${COMPREPLY[@]}"
    COMP_WORDS=(git-wt create new literal-backtick-)
    COMP_CWORD=3
    _git_wt_complete_bash
    printf "LITERAL_CREATE:<%s>\n" "${COMPREPLY[@]}"
    COMP_WORDS=(git-wt remove literal-variable-)
    COMP_CWORD=2
    _git_wt_complete_bash
    printf "LITERAL_REMOVE:<%s>\n" "${COMPREPLY[@]}"
  ' _ "$container")" || return 1
  assert_contains "$output" 'SW:local/slash' 'Bash switch completion includes local branches' || return 1
  assert_contains "$output" 'SW:feature/login' 'Bash switch completion strips origin prefix' || return 1
  assert_not_contains "$output" 'origin/HEAD' 'Bash completion excludes origin/HEAD' || return 1
  assert_contains "$output" 'CREATE:origin/main' 'Bash create completion includes origin ref' || return 1
  assert_contains "$output" "REMOVE:$detached_head" 'Bash remove completes target after -f' || return 1
  assert_contains "$output" 'REMOVE:main' 'Bash bare-container completion offers main' || return 1
  assert_not_contains "$output" 'REMOVE:guard' 'Bash completion excludes current worktree' || return 1
  assert_not_contains "$output" 'DOUBLE_DASH:-f' 'Bash completion stops offering options after --' || return 1
  local literal_command_quoted literal_backtick_quoted literal_variable_quoted
  literal_command_quoted="$(bash --noprofile --norc -c 'printf %q "$1"' _ "$literal_command")"
  literal_backtick_quoted="$(bash --noprofile --norc -c 'printf %q "$1"' _ "$literal_backtick")"
  literal_variable_quoted="$(bash --noprofile --norc -c 'printf %q "$1"' _ "$literal_variable")"
  assert_contains "$output" "LITERAL_SWITCH:<$literal_command_quoted>" \
    'Bash switch completion expands literal command substitutions' || return 1
  assert_contains "$output" "LITERAL_CREATE:<$literal_backtick_quoted>" \
    'Bash create completion expands literal backticks' || return 1
  assert_contains "$output" "LITERAL_REMOVE:<$literal_variable_quoted>" \
    'Bash remove completion expands literal variables' || return 1
  [[ ! -e "$sentinel" ]] || fail 'Bash completion executed a literal Git ref' || return 1

  # Exercise Readline insertion too: safe candidates must remain literal on Enter.
  zmodload zsh/zpty || return 1
  local pty_name=git_wt_completion launch setup
  launch="env PATH=${(q)shell_path} bash --noprofile --norc -i"
  zpty -b "$pty_name" "$launch" || return 1
  setup='eval "$(git-wt shellenv)"; cd -- '"${(q)container}/guard"'; PS1="READY> "'
  zpty -w "$pty_name" "$setup"$'\n' || return 1
  pty_read_until "$pty_name" 'READY> ' || return 1
  zpty -w "$pty_name" $'git-wt sw literal-command-\t\n' || return 1
  zpty -w "$pty_name" 'printf "PTY_HEAD:%s\n" "$(command git symbolic-ref --short HEAD)"'\
    $'\n' || return 1
  pty_read_until "$pty_name" "PTY_HEAD:$literal_command" || return 1
  zpty -d "$pty_name" 2>/dev/null || true
  [[ ! -e "$sentinel" ]] || fail 'Bash Tab followed by Enter executed a Git ref' || return 1

  output="$(PATH="$shell_path" zsh -f -c '
    function compdef() { :; }
    source <(git-wt shellenv)
    function compadd() { shift; for candidate in "$@"; do print -r -- "COMP:$candidate"; done; }
    cd -- "$1/guard"
    words=(git-wt sw "")
    CURRENT=3
    _git_wt_complete_zsh
    words=(git-wt remove -f "")
    CURRENT=4
    _git_wt_complete_zsh
    words=(git-wt create new "")
    CURRENT=4
    _git_wt_complete_zsh
  ' _ "$container")" || return 1
  assert_contains "$output" 'COMP:local/slash' 'Zsh switch completion includes local branches' || return 1
  assert_contains "$output" "COMP:$detached_head" 'Zsh remove completion includes detached SHA' || return 1
  assert_contains "$output" 'COMP:origin/main' 'Zsh create base completion includes origin ref' || return 1
  assert_contains "$output" 'COMP:local/slash' 'Zsh create base completion includes local ref' || return 1

  (cd "$CURRENT_FIXTURE" && PATH="$shell_path" zsh -f -c 'source <(git-wt shellenv)') || \
    fail 'Zsh shellenv requires initialized completion' || return 1
  output="$(cd "$CURRENT_FIXTURE" && PATH="$shell_path" bash --noprofile --norc -c '
    eval "$(git-wt shellenv)"
    COMP_WORDS=(git-wt sw "")
    COMP_CWORD=2
    _git_wt_complete_bash
  ' _ 2>&1)" || return 1
  assert_not_contains "$output" 'fatal:' 'completion outside a repository prints Git errors' || return 1
  after="$(git -C "$container/main" status --porcelain)"
  assert_eq "$after" "$before" 'completion changes repository state' || return 1
}

function extract_recovery_commands() {
  local errors="$1" script="$2"
  awk '
    /^To restore from Zsh/ { found=1; next }
    found && /^  / { sub(/^  /, ""); print; next }
    found { exit }
  ' "$errors" >| "$script"
  [[ -s "$script" ]] || fail 'migration did not emit executable recovery commands'
}

function case_migration_failure_recovery() {
  new_fixture || return 1
  local repo="$CURRENT_FIXTURE/metadata-repo" errors shim count state recovery
  make_migration_repo "$repo" || return 1
  state="$CURRENT_FIXTURE/metadata.before"
  snapshot_repo_state "$repo" "$state" || return 1
  shim="$CURRENT_FIXTURE/shim"
  write_failure_shims "$shim" 999 || return 1
  count="$CURRENT_FIXTURE/mv-count"
  print -r -- 0 >| "$count"
  if (cd "$repo" && PATH="$SHIM_PATH" GIT_WT_REAL_GIT="$SHIM_REAL_GIT" \
    GIT_WT_REAL_MV="$SHIM_REAL_MV" GIT_WT_MV_COUNT="$count" \
    GIT_WT_MV_FAIL_AT="$SHIM_FAIL_AT" GIT_WT_FAIL_WORKTREE_ADD=1 \
    "$BIN" init >/dev/null 2> "$CURRENT_FIXTURE/metadata.err"); then
    fail 'metadata shim did not make migration fail' || return 1
  fi
  assert_repo_state "$repo" "$state" 'metadata failure recovery' || return 1
  assert_file "$repo/.git" || return 1
  [[ ! -d "$repo/feature/login" ]] || fail 'pre-split failure was not restored' || return 1
  errors="$(<"$CURRENT_FIXTURE/metadata.err")"
  assert_contains "$errors" 'original repository was restored' \
    'metadata-stage failure does not report restoration' || return 1

  repo="$CURRENT_FIXTURE/after-add-repo"
  make_migration_repo "$repo" || return 1
  state="$CURRENT_FIXTURE/after-add.before"
  snapshot_repo_state "$repo" "$state" || return 1
  write_failure_shims "$shim" 999 || return 1
  count="$CURRENT_FIXTURE/mv-count-after-add"
  print -r -- 0 >| "$count"
  local after_add_marker="$CURRENT_FIXTURE/worktree-add-completed"
  if (cd "$repo" && PATH="$SHIM_PATH" GIT_WT_REAL_GIT="$SHIM_REAL_GIT" \
    GIT_WT_REAL_MV="$SHIM_REAL_MV" GIT_WT_MV_COUNT="$count" \
    GIT_WT_MV_FAIL_AT="$SHIM_FAIL_AT" GIT_WT_FAIL_WORKTREE_ADD_AFTER=1 \
    GIT_WT_AFTER_ADD_MARKER="$after_add_marker" "$BIN" init >/dev/null \
    2> "$CURRENT_FIXTURE/after-add.err"); then
    fail 'after-add shim did not make migration fail' || return 1
  fi
  assert_file "$after_add_marker" || return 1
  assert_repo_state "$repo" "$state" 'after-add failure recovery' || return 1
  assert_file "$repo/.git" || return 1
  [[ ! -e "$repo/feature/login" ]] || fail 'after-add recovery left a linked worktree' || return 1

  repo="$CURRENT_FIXTURE/rollback-failure-repo"
  make_migration_repo "$repo" || return 1
  state="$CURRENT_FIXTURE/rollback-failure.before"
  snapshot_repo_state "$repo" "$state" || return 1
  write_failure_shims "$shim" 999 || return 1
  count="$CURRENT_FIXTURE/mv-count-rollback-failure"
  print -r -- 0 >| "$count"
  local rollback_marker="$CURRENT_FIXTURE/rmdir-failed-once"
  if (cd "$repo" && PATH="$SHIM_PATH" GIT_WT_REAL_GIT="$SHIM_REAL_GIT" \
    GIT_WT_REAL_MV="$SHIM_REAL_MV" GIT_WT_MV_COUNT="$count" \
    GIT_WT_MV_FAIL_AT="$SHIM_FAIL_AT" GIT_WT_FAIL_WORKTREE_ADD=1 \
    GIT_WT_FAIL_RMDIR_PATH="$repo" GIT_WT_FAIL_RMDIR_ONCE_MARKER="$rollback_marker" \
    "$BIN" init >/dev/null 2> "$CURRENT_FIXTURE/rollback-failure.err"); then
    fail 'rollback failure shim did not make migration fail' || return 1
  fi
  assert_file "$rollback_marker" || return 1
  errors="$(<"$CURRENT_FIXTURE/rollback-failure.err")"
  local -a rollback_old_roots
  rollback_old_roots=($repo:h/${repo:t}.pre-bare-migration.*(N))
  (( ${#rollback_old_roots} == 1 )) || fail 'rollback failure left an ambiguous original location' || return 1
  assert_contains "$errors" "Git metadata: $rollback_old_roots[1]/.git" \
    'rollback failure does not report the actual metadata location' || return 1
  assert_contains "$errors" 'To restore from Zsh' \
    'rollback failure omits executable recovery steps' || return 1
  recovery="$CURRENT_FIXTURE/rollback-recover.zsh"
  extract_recovery_commands "$CURRENT_FIXTURE/rollback-failure.err" "$recovery" || return 1
  zsh -f "$recovery" >| "$CURRENT_FIXTURE/rollback-recovery.out" \
    2> "$CURRENT_FIXTURE/rollback-recovery.err" || {
    fail 'rollback failure recovery commands do not execute' || return 1
  }
  assert_repo_state "$repo" "$state" 'rollback failure manual recovery' || return 1
  assert_no_migration_duplicates "$repo" || return 1

  repo="$CURRENT_FIXTURE/partial-files-repo"
  make_migration_repo "$repo" || return 1
  state="$CURRENT_FIXTURE/partial.before"
  snapshot_repo_state "$repo" "$state" || return 1
  write_failure_shims "$shim" 5 || return 1
  count="$CURRENT_FIXTURE/mv-count-partial"
  print -r -- 0 >| "$count"
  if (cd "$repo" && PATH="$SHIM_PATH" GIT_WT_REAL_GIT="$SHIM_REAL_GIT" \
    GIT_WT_REAL_MV="$SHIM_REAL_MV" GIT_WT_MV_COUNT="$count" \
    GIT_WT_MV_FAIL_AT="$SHIM_FAIL_AT" "$BIN" init >/dev/null \
    2> "$CURRENT_FIXTURE/partial.err"); then
    fail 'partial file move shim did not make migration fail' || return 1
  fi
  errors="$(<"$CURRENT_FIXTURE/partial.err")"
  assert_contains "$errors" 'Remaining original data:' 'partial failure omits original data location' || return 1
  assert_contains "$errors" 'Moved working data:' 'partial failure omits moved data location' || return 1
  assert_contains "$errors" 'To restore from Zsh' 'partial failure omits recovery commands' || return 1
  recovery="$CURRENT_FIXTURE/recover.zsh"
  extract_recovery_commands "$CURRENT_FIXTURE/partial.err" "$recovery" || return 1
  zsh -f "$recovery" >| "$CURRENT_FIXTURE/recovery.out" 2> "$CURRENT_FIXTURE/recovery.err" || {
    fail 'emitted migration recovery commands do not execute' || return 1
  }
  assert_repo_state "$repo" "$state" 'manual migration recovery' || return 1
  assert_no_migration_duplicates "$repo" || return 1
}

function run_case() {
  local name="$1" function_name="$2" rc
  [[ -z "${GIT_WT_CASES:-}" || " ${GIT_WT_CASES} " == *" $name "* ]] || return 0
  CURRENT_CASE="$name"
  print -r -- "RUN  $name"
  "$function_name"
  rc=$?
  if (( rc == 0 )); then
    (( PASSED += 1 ))
    print -r -- "PASS $name"
  else
    (( FAILED += 1 ))
    print -r -- "FAIL $name"
  fi
  return 0
}

run_case cli_and_discovery case_cli_and_discovery
run_case init_clone case_init_clone
run_case switch_create case_switch_create
run_case migration case_migration
run_case migration_detached case_migration_detached
run_case default_base case_default_base
run_case split_index_rejection case_split_index_rejection
run_case tree_snapshot case_tree_snapshot
run_case migration_failure_recovery case_migration_failure_recovery
run_case remove case_remove
run_case shellenv_remove_pty case_shellenv_remove_pty
run_case shellenv case_shellenv
run_case completion case_completion

print -r -- "Result: $PASSED passed, $FAILED failed"
(( FAILED == 0 ))
