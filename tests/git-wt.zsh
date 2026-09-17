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
    line="${line%$'\r'}"
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

  pty_confirm_migration "$repo" YeS "$BIN" init || return 1
  output="$REPLY"
  rc="$PTY_RC"
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
  pty_confirm_migration "$repo" y "$BIN" init || return 1
  output="$REPLY"
  rc="$PTY_RC"
  assert_eq "$rc" 0 'init migrates a detached repository' || return 1
  marker_from "$output"
  assert_eq "$REPLY" "$repo/detached-$short" 'detached migration uses short SHA path' || return 1
  assert_eq "$(git -C "$REPLY" rev-parse HEAD)" "$head" \
    'detached migration preserves HEAD' || return 1
  if git -C "$REPLY" symbolic-ref -q HEAD >/dev/null 2>&1; then
    fail 'detached migration unexpectedly created a branch' || return 1
  fi
}

function case_init_confirmation_and_new_directory() {
  new_fixture || return 1
  local repo="$CURRENT_FIXTURE/migrate" state="$CURRENT_FIXTURE/migrate.before"
  local metadata="$CURRENT_FIXTURE/migrate.metadata" output root shim count recovery
  make_migration_repo "$repo" || return 1
  snapshot_repo_state "$repo" "$state" || return 1
  metadata_snapshot "$repo" "$metadata" || return 1
  if output="$(cd "$repo" && print -r -- yes | "$BIN" init 2>&1)"; then
    fail 'piped yes confirms migration' || return 1
  fi
  assert_contains "$output" 'interactive terminal' 'non-interactive migration rejection is unclear' || return 1
  assert_not_contains "$output" 'GIT_WT_CD:' 'non-interactive migration emits a cd marker' || return 1
  assert_repo_state "$repo" "$state" 'non-interactive migration rejection' || return 1
  metadata_snapshot "$repo" "$CURRENT_FIXTURE/migrate.metadata.after" || return 1
  cmp -s "$metadata" "$CURRENT_FIXTURE/migrate.metadata.after" || {
    fail 'non-interactive migration changes index or configuration'
    return 1
  }
  pty_confirm_migration "$repo" n "$BIN" init || return 1
  (( PTY_RC != 0 )) || fail 'negative migration confirmation succeeds' || return 1
  assert_not_contains "$REPLY" 'GIT_WT_CD:' 'negative migration confirmation emits a cd marker' || return 1
  assert_repo_state "$repo" "$state" 'negative migration confirmation' || return 1
  metadata_snapshot "$repo" "$CURRENT_FIXTURE/migrate.metadata.denied" || return 1
  cmp -s "$metadata" "$CURRENT_FIXTURE/migrate.metadata.denied" || {
    fail 'negative migration confirmation changes index or configuration'
    return 1
  }
  pty_confirm_migration "$repo" '' "$BIN" init || return 1
  (( PTY_RC != 0 )) || fail 'empty migration confirmation succeeds' || return 1
  assert_repo_state "$repo" "$state" 'empty migration confirmation' || return 1
  pty_confirm_migration "$repo" $'\x04' "$BIN" init || return 1
  (( PTY_RC != 0 )) || fail 'EOF confirms migration' || return 1
  assert_not_contains "$REPLY" 'GIT_WT_CD:' 'EOF emits a cd marker' || return 1
  assert_repo_state "$repo" "$state" 'EOF migration confirmation' || return 1
  metadata_snapshot "$repo" "$CURRENT_FIXTURE/migrate.metadata.eof" || return 1
  cmp -s "$metadata" "$CURRENT_FIXTURE/migrate.metadata.eof" || {
    fail 'empty or EOF confirmation changes index or configuration'
    return 1
  }

  root="$CURRENT_FIXTURE/empty"
  mkdir -p "$root" || return 1
  (cd "$root" && "$BIN" init >/dev/null) || return 1
  assert_eq "$(git --git-dir="$root/.git" rev-parse --is-bare-repository)" true \
    'empty directory does not become a bare container' || return 1
  assert_eq "$(git -C "$root/main" status --porcelain)" '' \
    'empty directory worktree is not empty' || return 1
  git -C "$root/main" rev-parse --verify HEAD >/dev/null 2>&1 && {
    fail 'empty directory init creates a commit'
    return 1
  }

  root="$CURRENT_FIXTURE/new directory"
  mkdir -p "$root/nested" || return 1
  print -r -- data >| "$root/.hidden"
  print -r -- nested >| "$root/nested/data"
  print -r -- executable >| "$root/run"
  chmod +x "$root/run"
  ln -s .hidden "$root/link" || return 1
  tree_snapshot "$root" "$CURRENT_FIXTURE/new.before" || return 1
  output="$(cd "$root" && "$BIN" init 2> "$CURRENT_FIXTURE/new.err")" || return 1
  marker_from "$output"
  assert_eq "$REPLY" "$root/main" 'new directory init emits its worktree marker' || return 1
  tree_snapshot "$root/main" "$CURRENT_FIXTURE/new.after" || return 1
  cmp -s "$CURRENT_FIXTURE/new.before" "$CURRENT_FIXTURE/new.after" || {
    fail 'new directory init changes moved data'
    return 1
  }
  [[ -L "$root/main/link" && -x "$root/main/run" ]] || {
    fail 'new directory init changes symlink or executable mode'
    return 1
  }
  git -C "$root/main" rev-parse HEAD >/dev/null 2>&1 && {
    fail 'new directory init creates a commit'
    return 1
  }
  assert_eq "$(git -C "$root/main" ls-files)" '' 'new directory init stages files' || return 1
  assert_eq "$(git --git-dir="$root/.git" config --bool worktree.useRelativePaths)" true \
    'new directory init does not use relative paths' || return 1
  assert_contains "$(<"$root/main/.git")" 'gitdir: ../.git/worktrees/main' \
    'new worktree gitdir is not relative' || return 1
  git -C "$root/main" add -A && git -C "$root/main" commit -m first >/dev/null || return 1
  mv "$root" "$CURRENT_FIXTURE/moved container" || return 1
  root="$CURRENT_FIXTURE/moved container"
  git -C "$root/main" status --porcelain >/dev/null || {
    fail 'moved new container no longer recognizes its worktree'
    return 1
  }

  git config --global init.defaultBranch feature/start || return 1
  root="$CURRENT_FIXTURE/slash branch"
  mkdir -p "$root" || return 1
  print -r -- data >| "$root/keep"
  (cd "$root" && "$BIN" init >/dev/null) || return 1
  assert_file "$root/feature/start/keep" || return 1
  assert_eq "$(git -C "$root/feature/start" branch --show-current)" feature/start \
    'new directory ignores configured slash initial branch' || return 1
  git config --global init.defaultBranch main || return 1

  root="$CURRENT_FIXTURE/collision"
  mkdir -p "$root/feature" || return 1
  print -r -- keep >| "$root/feature/keep"
  git config --global init.defaultBranch feature/start || return 1
  if (cd "$root" && "$BIN" init >/dev/null 2>&1); then
    fail 'initial slash branch overwrites an ancestor collision' || return 1
  fi
  [[ ! -e "$root/.git" && -f "$root/feature/keep" ]] || {
    fail 'ancestor collision mutates original data'
    return 1
  }
  root="$CURRENT_FIXTURE/symlink-collision"
  mkdir -p "${root}-target" "$root" || return 1
  ln -s "${root}-target" "$root/feature" || return 1
  if (cd "$root" && "$BIN" init >/dev/null 2>&1); then
    fail 'initial slash branch follows a symlink ancestor' || return 1
  fi
  [[ ! -e "$root/.git" && -L "$root/feature" ]] || {
    fail 'symlink collision mutates original data'
    return 1
  }
  git config --global init.defaultBranch main || return 1

  root="$CURRENT_FIXTURE/broken"
  mkdir -p "$root/.git" || return 1
  if (cd "$root" && "$BIN" init >/dev/null 2>&1); then
    fail 'broken .git directory becomes a new container' || return 1
  fi
  [[ -d "$root/.git" ]] || fail 'broken .git directory was changed' || return 1
  git init "$CURRENT_FIXTURE/unborn" >/dev/null || return 1
  if (cd "$CURRENT_FIXTURE/unborn" && "$BIN" init >/dev/null 2>&1); then
    fail 'existing unborn repository becomes a new container' || return 1
  fi

  root="$CURRENT_FIXTURE/new-failure"
  mkdir -p "$root" || return 1
  print -r -- one >| "$root/one"
  print -r -- two >| "$root/two"
  tree_snapshot "$root" "$CURRENT_FIXTURE/new-failure.before" || return 1
  shim="$CURRENT_FIXTURE/new-shim"
  write_failure_shims "$shim" 2 || return 1
  count="$CURRENT_FIXTURE/new-mv-count"
  print -r -- 0 >| "$count"
  if output="$(cd "$root" && PATH="$SHIM_PATH" GIT_WT_REAL_GIT="$SHIM_REAL_GIT" \
    GIT_WT_REAL_MV="$SHIM_REAL_MV" GIT_WT_MV_COUNT="$count" GIT_WT_MV_FAIL_AT="$SHIM_FAIL_AT" \
    "$BIN" init 2>&1)"; then
    fail 'new directory file-move shim does not fail' || return 1
  fi
  assert_not_contains "$output" 'GIT_WT_CD:' 'failed new directory init emits a cd marker' || return 1
  assert_contains "$output" 'To restore from Zsh' 'new directory failure omits recovery steps' || return 1
  print -r -- "$output" >| "$CURRENT_FIXTURE/new-failure.err"
  recovery="$CURRENT_FIXTURE/new-failure-recover.zsh"
  extract_recovery_commands "$CURRENT_FIXTURE/new-failure.err" "$recovery" || return 1
  zsh -f "$recovery" >/dev/null 2>&1 || {
    fail 'new directory recovery commands do not execute' || return 1
  }
  tree_snapshot "$root" "$CURRENT_FIXTURE/new-failure.after" || return 1
  cmp -s "$CURRENT_FIXTURE/new-failure.before" "$CURRENT_FIXTURE/new-failure.after" || {
    fail 'new directory manual recovery changes data'
    return 1
  }
  [[ ! -e "$root/.git" ]] || fail 'new directory recovery leaves metadata' || return 1

  root="$CURRENT_FIXTURE/new-add-failure"
  mkdir -p "$root" || return 1
  print -r -- keep >| "$root/keep"
  tree_snapshot "$root" "$CURRENT_FIXTURE/new-add-failure.before" || return 1
  write_failure_shims "$shim" 999 || return 1
  count="$CURRENT_FIXTURE/new-add-mv-count"
  print -r -- 0 >| "$count"
  if output="$(cd "$root" && PATH="$SHIM_PATH" GIT_WT_REAL_GIT="$SHIM_REAL_GIT" \
    GIT_WT_REAL_MV="$SHIM_REAL_MV" GIT_WT_MV_COUNT="$count" GIT_WT_MV_FAIL_AT="$SHIM_FAIL_AT" \
    GIT_WT_FAIL_WORKTREE_ADD=1 "$BIN" init 2>&1)"; then
    fail 'new directory worktree-add shim does not fail' || return 1
  fi
  assert_contains "$output" 'To restore from Zsh' 'worktree-add failure omits recovery steps' || return 1
  print -r -- "$output" >| "$CURRENT_FIXTURE/new-add-failure.err"
  recovery="$CURRENT_FIXTURE/new-add-failure-recover.zsh"
  extract_recovery_commands "$CURRENT_FIXTURE/new-add-failure.err" "$recovery" || return 1
  zsh -f "$recovery" >/dev/null 2>&1 || {
    fail 'new directory worktree-add recovery commands do not execute' || return 1
  }
  tree_snapshot "$root" "$CURRENT_FIXTURE/new-add-failure.after" || return 1
  cmp -s "$CURRENT_FIXTURE/new-add-failure.before" "$CURRENT_FIXTURE/new-add-failure.after" || {
    fail 'new directory worktree-add recovery changes data'
    return 1
  }
  [[ ! -e "$root/.git" ]] || fail 'worktree-add recovery leaves metadata' || return 1

  root="$CURRENT_FIXTURE/new-bare-init-failure"
  mkdir -p "$root" || return 1
  print -r -- keep >| "$root/keep"
  write_failure_shims "$shim" 999 || return 1
  if output="$(cd "$root" && PATH="$SHIM_PATH" GIT_WT_REAL_GIT="$SHIM_REAL_GIT" \
    GIT_WT_FAIL_BARE_INIT_PATH="$root/.git" \
    "$BIN" init 2>&1)"; then
    fail 'new directory bare-init shim does not fail' || return 1
  fi
  assert_contains "$output" 'Could not initialize bare Git metadata' 'bare-init failure is unclear' || return 1
  [[ -f "$root/keep" && ! -e "$root/.git" ]] || {
    fail 'bare-init failure changes original data'
    return 1
  }
}

function case_init_partial_failure_recovery() {
  new_fixture || return 1
  local root branch phase output recovery count marker
  local shim="$CURRENT_FIXTURE/shim"
  local -a failure_env
  write_failure_shims "$shim" 2 || return 1
  for branch in main feature/start; do
    git config --global init.defaultBranch "$branch" || return 1
    for phase in bare partial_add after_add move; do
      root="$CURRENT_FIXTURE/${branch//\//-} $phase"
      mkdir -p "$root" || return 1
      print -r -- first >| "$root/a"
      print -r -- second >| "$root/b"
      tree_snapshot "$root" "$CURRENT_FIXTURE/before" || return 1
      count="$CURRENT_FIXTURE/count"
      marker="$CURRENT_FIXTURE/${branch//\//-}-$phase.marker"
      print -r -- 0 >| "$count"
      failure_env=()
      case "$phase" in
        bare) failure_env=("GIT_WT_FAIL_BARE_INIT_PATH=$root/.git" GIT_WT_FAIL_BARE_INIT_PARTIAL=1) ;;
        partial_add) failure_env=(GIT_WT_FAIL_WORKTREE_ADD=1 "GIT_WT_PARTIAL_ADD_PATH=$root/$branch") ;;
        after_add) failure_env=(GIT_WT_FAIL_WORKTREE_ADD_AFTER=1 "GIT_WT_AFTER_ADD_MARKER=$marker") ;;
        move) failure_env=(GIT_WT_MV_FAIL_AT=2) ;;
      esac
      if output="$(cd "$root" && env "PATH=$SHIM_PATH" "GIT_WT_REAL_GIT=$SHIM_REAL_GIT" \
        "GIT_WT_REAL_MV=$SHIM_REAL_MV" "GIT_WT_MV_COUNT=$count" "${failure_env[@]}" "$BIN" init 2>&1)"; then
        fail "$branch $phase failure was not injected" || return 1
      fi
      assert_not_contains "$output" 'GIT_WT_CD:' "$branch $phase failure emits a marker" || return 1
      assert_contains "$output" "Git metadata: $root/.git" "$branch $phase omits actual metadata location" || return 1
      assert_contains "$output" 'To restore from Zsh' "$branch $phase omits recovery instructions" || return 1
      case "$phase" in
        bare) assert_file "$root/.git/PARTIAL" || return 1 ;;
        partial_add) assert_contains "$(<"$root/$branch/.git")" 'missing' 'partial add did not leave incomplete registration' || return 1 ;;
        after_add) assert_file "$marker" || return 1 ;;
        move) assert_file "$root/$branch/a" && assert_file "$root/b" || return 1 ;;
      esac
      print -r -- "$output" >| "$CURRENT_FIXTURE/failure.err"
      recovery="$CURRENT_FIXTURE/recover.zsh"
      extract_recovery_commands "$CURRENT_FIXTURE/failure.err" "$recovery" || return 1
      if [[ "$phase" == move ]]; then
        print -r -- conflicting >| "$root/a"
        if zsh -f "$recovery" >| "$CURRENT_FIXTURE/conflict.out" 2>&1; then
          fail 'recovery overwrites a new destination file' || return 1
        fi
        assert_eq "$(<"$root/a")" conflicting 'recovery changes the conflicting file' || return 1
        assert_eq "$(<"$root/$branch/a")" first 'recovery loses the original file' || return 1
        assert_file "$root/.git" || return 1
        mv "$root/a" "$CURRENT_FIXTURE/saved-conflict-${branch//\//-}" || return 1
      fi
      zsh -f "$recovery" >| "$CURRENT_FIXTURE/recovery.out" 2> "$CURRENT_FIXTURE/recovery.err" || {
        fail "$branch $phase recovery commands do not execute"
        return 1
      }
      [[ ! -e "$root/.git" ]] || fail "$branch $phase recovery leaves metadata" || return 1
      tree_snapshot "$root" "$CURRENT_FIXTURE/after" || return 1
      cmp -s "$CURRENT_FIXTURE/before" "$CURRENT_FIXTURE/after" || {
        fail "$branch $phase recovery changes original data or leaves created directories"
        return 1
      }
    done
  done
  git config --global init.defaultBranch main || return 1
}

function case_init_discovery() {
  new_fixture || return 1
  local source="$CURRENT_FIXTURE/source" linked="$CURRENT_FIXTURE/linked"
  local bare="$CURRENT_FIXTURE/bare" target output before="$CURRENT_FIXTURE/discovery.before"
  make_source "$source" || return 1
  mkdir -p "$source/nested/dir" || return 1
  git -C "$source" worktree add --detach "$linked" main >/dev/null || return 1
  git init --bare "$bare" >/dev/null || return 1
  for target in "$source/nested/dir" "$linked" "$bare"; do
    tree_snapshot "$target" "$before" || return 1
    if output="$(cd "$target" && "$BIN" init </dev/null 2>&1)"; then
      fail 'init accepts a subdirectory, linked worktree, or bare repository' || return 1
    fi
    assert_not_contains "$output" 'GIT_WT_CD:' 'rejected Git discovery emits a marker' || return 1
    tree_snapshot "$target" "$CURRENT_FIXTURE/discovery.after" || return 1
    cmp -s "$before" "$CURRENT_FIXTURE/discovery.after" || fail 'rejected Git discovery changes the tree' || return 1
  done
  [[ ! -e "$source/nested/dir/.git" && -f "$linked/.git" && ! -e "$bare/.git" ]] || {
    fail 'Git discovery creates nested metadata or changes linked metadata'
    return 1
  }
  for target in broken-file broken-symlink; do
    mkdir -p "$CURRENT_FIXTURE/$target" || return 1
    if [[ "$target" == broken-file ]]; then
      print -r -- 'gitdir: missing' >| "$CURRENT_FIXTURE/$target/.git"
    else
      ln -s missing "$CURRENT_FIXTURE/$target/.git" || return 1
    fi
    if output="$(cd "$CURRENT_FIXTURE/$target" && "$BIN" init 2>&1)"; then
      fail 'init overwrites broken Git metadata' || return 1
    fi
    assert_contains "$output" 'refusing to initialize over .git' 'broken Git metadata is not detected' || return 1
  done
  for target in ancestor-file ancestor-symlink ancestor-directory; do
    local parent="$CURRENT_FIXTURE/$target" child="$CURRENT_FIXTURE/$target/nested/child"
    mkdir -p "$child" || return 1
    print -r -- original >| "$child/keep"
    case "$target" in
      ancestor-file) print -r -- 'gitdir: missing' >| "$parent/.git" ;;
      ancestor-symlink) ln -s missing "$parent/.git" || return 1 ;;
      ancestor-directory) mkdir "$parent/.git" || return 1 ;;
    esac
    tree_snapshot "$parent" "$before" || return 1
    if output="$(cd "$child" && "$BIN" init </dev/null 2>&1)"; then
      fail 'init accepts broken ancestor Git metadata' || return 1
    fi
    assert_contains "$output" 'refusing to initialize over .git' 'broken ancestor metadata is misclassified' || return 1
    assert_contains "$output" "$parent/.git" 'rejection omits ancestor metadata location' || return 1
    assert_not_contains "$output" 'GIT_WT_CD:' 'broken ancestor metadata emits a cd marker' || return 1
    [[ ! -e "$child/.git" ]] || fail 'broken ancestor metadata creates nested metadata' || return 1
    tree_snapshot "$parent" "$CURRENT_FIXTURE/discovery.after" || return 1
    cmp -s "$before" "$CURRENT_FIXTURE/discovery.after" || fail 'ancestor rejection changes original data' || return 1
    case "$target" in
      ancestor-file) assert_eq "$(<"$parent/.git")" 'gitdir: missing' 'ancestor gitfile changed' || return 1 ;;
      ancestor-symlink) assert_eq "$(readlink "$parent/.git")" missing 'ancestor symlink changed' || return 1 ;;
      ancestor-directory) [[ -d "$parent/.git" && -z "$(ls -A "$parent/.git")" ]] || fail 'ancestor metadata directory changed' || return 1 ;;
    esac
  done
}

function write_failure_shims() {
  local shim="$1" fail_at="$2" real_git real_mv git_dir
  real_git="${commands[git]}"
  real_mv="${commands[mv]}"
  git_dir="${commands[zsh]:h}"
  mkdir -p "$shim" || return 1
  print -r -- '#!/bin/sh' >| "$shim/git"
  print -r -- 'if [ -n "${GIT_WT_FAIL_BARE_INIT_PATH:-}" ]; then' >> "$shim/git"
  print -r -- '  saw_init=0; saw_bare=0' >> "$shim/git"
  print -r -- '  for argument in "$@"; do [ "$argument" = init ] && saw_init=1; [ "$argument" = --bare ] && saw_bare=1; [ "$argument" = "$GIT_WT_FAIL_BARE_INIT_PATH" ] && saw_path=1; done' >> "$shim/git"
  print -r -- '  if [ "$saw_init$saw_bare${saw_path:-0}" = 111 ]; then' >> "$shim/git"
  print -r -- '    if [ "${GIT_WT_FAIL_BARE_INIT_PARTIAL:-0}" = 1 ]; then mkdir -p "$GIT_WT_FAIL_BARE_INIT_PATH"; printf partial > "$GIT_WT_FAIL_BARE_INIT_PATH/PARTIAL"; fi' >> "$shim/git"
  print -r -- '    echo "forced bare init failure" >&2; exit 77' >> "$shim/git"
  print -r -- '  fi' >> "$shim/git"
  print -r -- 'fi' >> "$shim/git"
  print -r -- 'if [ "${GIT_WT_FAIL_WORKTREE_ADD:-0}" = 1 ]; then' >> "$shim/git"
  print -r -- '  saw_worktree=0; saw_add=0; saw_relative=0' >> "$shim/git"
  print -r -- '  for argument in "$@"; do' >> "$shim/git"
  print -r -- '    [ "$argument" = worktree ] && saw_worktree=1' >> "$shim/git"
  print -r -- '    [ "$argument" = add ] && saw_add=1' >> "$shim/git"
  print -r -- '    [ "$argument" = --relative-paths ] && saw_relative=1' >> "$shim/git"
  print -r -- '  done' >> "$shim/git"
  print -r -- '  if [ "$saw_worktree$saw_add$saw_relative" = 111 ]; then' >> "$shim/git"
  print -r -- '    if [ -n "${GIT_WT_PARTIAL_ADD_PATH:-}" ]; then mkdir -p "$GIT_WT_PARTIAL_ADD_PATH"; printf "gitdir: missing\\n" > "$GIT_WT_PARTIAL_ADD_PATH/.git"; fi' >> "$shim/git"
  print -r -- '    echo "forced worktree add failure" >&2; exit 77' >> "$shim/git"
  print -r -- '  fi' >> "$shim/git"
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
  assert_contains "$output" 'initialize a new directory' 'help omits new directory init' || return 1
  assert_contains "$output" 'confirm migration' 'help omits migration confirmation' || return 1
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
  REPLY="$output"
  zpty -d "$name" 2>/dev/null || true
  fail "PTY timed out waiting for: $expected; output: ${(qqq)output}"
}

function pty_confirm_migration() {
  local repo="$1" answer="$2" name launch prompt result
  shift 2
  zmodload zsh/zpty || return 1
  name="git_wt_migration_${RANDOM}"
  launch="cd ${(q)repo} || exit; ${(j: :)${(q)@}}; rc=\$?; print -r -- \"PTY_RESULT:\$rc\""
  zpty -b "$name" "$launch" || return 1
  pty_read_until "$name" '[y/N] ' || return 1
  prompt="$REPLY"
  assert_contains "$prompt" '[y/N] ' 'migration confirmation prompt is incomplete' || return 1
  if [[ "$answer" == $'\x04' ]]; then
    zpty -w -n "$name" "$answer" || return 1
  else
    zpty -w "$name" "$answer"$'\n' || return 1
  fi
  pty_read_until "$name" 'PTY_RESULT:' || return 1
  result="$REPLY"
  zpty -d "$name" 2>/dev/null || true
  [[ "$result" =~ 'PTY_RESULT:([0-9]+)' ]] || {
    fail 'migration PTY did not report an exit status'
    return 1
  }
  PTY_RC="$match[1]"
  REPLY="${result//$'\r'/}"
  return 0
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

  zmodload zsh/zpty || return 1
  local migration_repo migration_script shell entry answer expected_rc name launch result combination
  migration_script='eval "$(git-wt shellenv)"'
  migration_script+=$'\n'
  migration_script+='builtin cd -- "$1"'
  migration_script+=$'\n'
  migration_script+='case "$2" in direct) git-wt init ;; alias) git wt init ;; esac'
  migration_script+=$'\n'
  migration_script+='rc=$?; printf "\\nPTY_RESULT:%s|%s\\n" "$rc" "$(pwd -P)"'
  for shell in bash zsh; do
    for combination in direct:y direct:n alias:y alias:n; do
      entry="${combination%:*}"
      answer="${combination#*:}"
      migration_repo="$CURRENT_FIXTURE/migration-${shell}-${entry}-${answer}"
      make_migration_repo "$migration_repo" || return 1
      if [[ "$answer" == y ]]; then
        expected_rc=0
      else
        expected_rc=1
      fi
      name="git_wt_shellenv_migration_${shell}_${entry}"
      if [[ "$shell" == bash ]]; then
        launch="env PATH=${(q)shell_path} bash --noprofile --norc -c ${(q)migration_script} _ ${(q)migration_repo} ${(q)entry}"
      else
        launch="env PATH=${(q)shell_path} zsh -f -c ${(q)migration_script} _ ${(q)migration_repo} ${(q)entry}"
      fi
      zpty -b "$name" "$launch" || return 1
      pty_read_until "$name" '[y/N] ' || return 1
      assert_contains "$REPLY" '[y/N] ' "$shell $entry wrapper hides the migration prompt" || return 1
      zpty -w "$name" "$answer"$'\n' || return 1
      pty_read_until "$name" 'PTY_RESULT:' || return 1
      result="${REPLY//$'\r'/}"
      zpty -d "$name" 2>/dev/null || true
      if [[ "$answer" == y ]]; then
        assert_contains "$result" "PTY_RESULT:$expected_rc|$migration_repo/feature/login" \
          "$shell $entry wrapper does not change to the migrated worktree" || return 1
      else
        assert_contains "$result" "PTY_RESULT:$expected_rc|$migration_repo" \
          "$shell $entry wrapper changes directory after rejection" || return 1
      fi
      assert_not_contains "$result" 'GIT_WT_CD:' "$shell $entry wrapper exposes a cd marker" || return 1
    done
  done
}

function case_shellenv_init_directory() {
  new_fixture || return 1
  local shell entry outcome root output expected
  local shell_path="${BIN:h}:$PATH"
  local -a shell_args
  for shell in bash zsh; do
    shell_args=(-f)
    [[ "$shell" != bash ]] || shell_args=(--noprofile --norc)
    for entry in direct alias; do
      for outcome in success collision; do
        root="$CURRENT_FIXTURE/$shell $entry $outcome"
        mkdir -p "$root" || return 1
        print -r -- original >| "$root/keep"
        if [[ "$outcome" == collision ]]; then
          print -r -- collision >| "$root/main"
          expected="INIT_RESULT:1|$root"
        else
          expected="INIT_RESULT:0|$root/main"
        fi
        output="$(PATH="$shell_path" "$shell" "${shell_args[@]}" -c '
          eval "$(git-wt shellenv)"
          builtin cd -- "$1" || exit 1
          case "$2" in direct) git-wt init ;; alias) git wt init ;; esac
          rc=$?
          printf "\nINIT_RESULT:%s|%s\n" "$rc" "$(pwd -P)"
        ' _ "$root" "$entry" 2>&1)" || return 1
        assert_contains "$output" "$expected" "$shell $entry $outcome has incorrect status or PWD" || return 1
        assert_not_contains "$output" 'GIT_WT_CD:' "$shell $entry exposes the marker" || return 1
        if [[ "$outcome" == collision ]]; then
          [[ ! -e "$root/.git" ]] || fail 'failed wrapper init leaves metadata' || return 1
          assert_eq "$(<"$root/main")" collision 'failed wrapper init changes conflicting data' || return 1
          assert_eq "$(<"$root/keep")" original 'failed wrapper init changes original data' || return 1
        else
          assert_eq "$(<"$root/main/keep")" original 'wrapper init changes original data' || return 1
        fi
      done
    done
  done
}

function completion_provider_path() {
  local override="$1"
  shift
  if [[ -n "$override" ]]; then
    [[ -r "$override" ]] || fail "completion provider override is unavailable: $override" || return 1
    REPLY="$override"
    return
  fi
  local candidate
  for candidate in "$@"; do
    if [[ -r "$candidate" ]]; then
      REPLY="$candidate"
      return
    fi
  done
  fail "completion provider is unavailable; checked: ${(j:, :)@}"
}

# Completion sessions keep terminal acknowledgements separate from payload data.
# The dynamically scoped session variables below belong to one provider at a time.
function completion_send() {
  if ! zpty -w -n "$completion_name" "$1"; then
    fail "$provider PTY write failed; output=${(qqq)REPLY}"
    return 1
  fi
}

function completion_ack() {
  pty_read_until "$completion_name" "ACK:$completion_token:$1:END" || return 1
  print -r -- "$REPLY" >> "$completion_dir/transcript"
}

function completion_read_record() {
  local field
  COMPLETION_FIELDS=()
  while IFS= read -r -d '' field; do
    COMPLETION_FIELDS+=("$field")
  done < "$1"
}

function completion_assert_capture() {
  local expected="$1" expected_pwd="$2" expected_provider="$3"
  assert_eq "${#COMPLETION_FIELDS}" 5 'capture field count' || return 1
  assert_eq "$COMPLETION_FIELDS[1]" "$capture_tag" 'capture sequence' || return 1
  assert_eq "$COMPLETION_FIELDS[4]" "$expected_pwd" 'completion changes PWD' || return 1
  assert_eq "$COMPLETION_FIELDS[5]" "$expected_provider" 'wrong completion provider' || return 1
  PTY_BUFFER="$COMPLETION_FIELDS[2]"
  PTY_CURSOR="$COMPLETION_FIELDS[3]"
  [[ "$expected" == __ANY_BUFFER__ ]] || assert_eq "$PTY_BUFFER" "$expected" 'completed buffer' || return 1
}

function completion_capture() {
  local input="$1" expected="$2" expected_pwd="$3" left_count="${4:-0}" use_tab="${5:-yes}"
  local keys="$input"
  local -i index
  for (( index=0; index<left_count; index++ )); do keys+=$'\e[D'; done
  [[ "$use_tab" != yes ]] || keys+=$'\t'
  (( capture_tag += 1 ))
  completion_send "$keys"$'\x18\x07' || return 1
  completion_ack "capture:$capture_tag" || return 1
  completion_read_record "$completion_dir/capture.$capture_tag" || return 1
  completion_assert_capture "$expected" "$expected_pwd" "$provider_marker" || return 1
}

function completion_command() {
  (( command_tag += 1 ))
  # Capture status immediately; an ACK means completion, not success.
  completion_send "$1; CT_RC=\$?; printf '%s\\n' \"\$CT_RC\" > \"\$CT_DIR/command.$command_tag\"; printf '\\nACK:%s:command:%s:END\\n' \"\$CT_TOKEN\" $command_tag"$'\n' || return 1
  completion_ack "command:$command_tag" || return 1
  assert_eq "$(<"$completion_dir/command.$command_tag")" 0 "$provider command failed: $1"
}

function completion_load_shellenv() {
  completion_command 'CT_SHELLENV="$(command git-wt shellenv)" && eval "$CT_SHELLENV"'
}

function completion_setup_file() {
  cat > "$completion_dir/setup" <<'COMMON'
CT_CAPTURE=0
CT_EXEC=0
stty rows 40 cols 240
export GIT_WT_TEST_SENTINEL=expanded-variable-must-not-appear
if [ -n "${BASH_VERSION:-}" ]; then
  source "$CT_BASH" || return 1
  shopt -s extdebug
  CT_INFO="$(declare -F __git_main)" || return 1
  shopt -u extdebug
  CT_ACTUAL_PROVIDER="${CT_INFO##* }"
  set -o emacs
  __capture_line() {
    (( CT_CAPTURE += 1 ))
    printf '%s\0' "$CT_CAPTURE" "$READLINE_LINE" "$READLINE_POINT" "$PWD" "$CT_ACTUAL_PROVIDER" > "$CT_DIR/capture.$CT_CAPTURE"
    printf '\nACK:%s:capture:%s:END\n' "$CT_TOKEN" "$CT_CAPTURE"
    READLINE_LINE=''
    READLINE_POINT=0
  }
  bind -x '"\C-x\C-g":__capture_line'
  __disable_capture() { bind -r '\C-x\C-g'; }
else
  if [[ "$CT_PROVIDER" == git_zsh ]]; then
    fpath=("${CT_ZSH:h}" $fpath)
    zstyle ':completion:*:*:git:*' script "$CT_BASH"
  else
    fpath=("$CT_NATIVE" $fpath)
  fi
  autoload -Uz compinit _git
  compinit -D
  compdef _git git
  autoload +X _git
  CT_ACTUAL_PROVIDER="${functions_source[_git]}"
  __capture_line() {
    (( CT_CAPTURE += 1 ))
    printf '%s\0' "$CT_CAPTURE" "$BUFFER" "$CURSOR" "$PWD" "$CT_ACTUAL_PROVIDER" > "$CT_DIR/capture.$CT_CAPTURE"
    printf '\nACK:%s:capture:%s:END\n' "$CT_TOKEN" "$CT_CAPTURE"
    BUFFER=''
    CURSOR=0
    zle reset-prompt
  }
  zle -N __capture_line
  bindkey -e
  bindkey '^X^G' __capture_line
  __disable_capture() { bindkey '^X^G' undefined-key; }
fi
cd -- "$CT_GUARD" || return 1
PS1='READY> '
printf '\nACK:%s:setup:END\n' "$CT_TOKEN"
COMMON
  # Validate only the shell branch which will actually parse this file. Both
  # shells accept the other branch's syntax without evaluating its expansions.
  if [[ "$provider" == bash ]]; then
    bash --noprofile --norc -n "$completion_dir/setup"
  else
    zsh -f -n "$completion_dir/setup"
  fi
}

function completion_start() {
  local shell_args launch
  completion_name="git_wt_${provider}_${RANDOM}"
  completion_token="${provider}_${RANDOM}_${RANDOM}"
  capture_tag=0 command_tag=0
  shell_args='zsh -f -i'
  [[ "$provider" != bash ]] || shell_args='bash --noprofile --norc -i'
  launch="env INPUTRC=/dev/null TERM=xterm PS1=BOOT\\>\\  PATH=${(q)shell_path} CT_DIR=${(q)completion_dir} CT_OUTSIDE=${(q)outside} CT_GUARD=${(q)guard} CT_TOKEN=${(q)completion_token} CT_PROVIDER=${(q)provider} CT_BASH=${(q)git_bash} CT_ZSH=${(q)git_zsh} CT_NATIVE=${(q)native_zsh} $shell_args"
  completion_setup_file || return 1
  zpty -b "$completion_name" "$launch" || return 1
  pty_read_until "$completion_name" 'BOOT> ' || return 1
  completion_send 'source "$CT_DIR/setup"'$'\n' || return 1
  completion_ack setup || return 1
  # No Git command, Tab, or Enter: test capture before testing completion.
  local probe="HARNESS | > ' literal"
  completion_capture "$probe" "$probe" "$guard" 0 no || return 1
  assert_eq "$PTY_CURSOR" "${#probe}" 'capture cursor' || return 1
  if completion_assert_capture "$probe" "$guard/wrong" "$provider_marker" > "$completion_dir/rejected-pwd" 2>&1; then
    fail 'capture accepts an incorrect PWD' || return 1
  fi
  if completion_assert_capture "$probe" "$guard" "$provider_marker.wrong" > "$completion_dir/rejected-provider" 2>&1; then
    fail 'capture accepts an incorrect provider' || return 1
  fi
  if completion_command '(exit 23)' > "$completion_dir/rejected-command" 2>&1; then
    fail 'command helper accepts a failed command' || return 1
  fi
  assert_eq "$(<"$completion_dir/command.$command_tag")" 23 'command helper lost exit status' || return 1
  print -r -- "PASS completion/$provider/harness"
}

function completion_exec_ref() {
  local input="$1"
  shift
  (( exec_tag += 1 ))
  completion_send "$input"$'\t\n' || return 1
  completion_ack "exec:$exec_tag" || return 1
  printf '%s\0' "$guard" "$#" "$@" > "$completion_dir/expected-argv"
  cmp -s "$completion_dir/expected-argv" "$completion_dir/exec.$exec_tag" || {
    fail "$provider Tab+Enter changed literal argv: $input"
    return 1
  }
  [[ ! -e "$sentinel" ]] || fail "$provider executed a literal ref" || return 1
}

function assert_git_completion_provider() {
  local provider="$1" shell_path="$2" container="$3" outside="$4"
  local literal_command="$5" literal_backtick="$6" literal_variable="$7" detached_head="$8"
  local git_bash="$9" git_zsh="${10}" native_zsh="${11}"
  local completion_dir="$CURRENT_FIXTURE/$provider" completion_name completion_token provider_marker
  local guard="$container/guard" entry before_status input expected quote output
  local -i capture_tag=0 command_tag=0 exec_tag=0 initial_tag
  local -a COMPLETION_FIELDS
  case "$provider" in
    bash) provider_marker="$git_bash" ;;
    git_zsh) provider_marker="$git_zsh" ;;
    native_zsh) provider_marker="$native_zsh/_git" ;;
  esac
  mkdir -p "$completion_dir" || return 1
  zmodload zsh/zpty || return 1
  {
    completion_start || return 1
    completion_capture 'git checkout loc' 'git checkout local/slash ' "$guard" || return 1
    completion_capture 'git status --porc' __ANY_BUFFER__ "$guard" || return 1
    before_status="$PTY_BUFFER"
    [[ "$before_status" != 'git status --porc' ]] || fail 'baseline status did not complete' || return 1
    completion_load_shellenv || return 1
    completion_load_shellenv || return 1
    completion_capture 'git checkout loc' 'git checkout local/slash ' "$guard" || return 1
    completion_capture 'git status --porc' "$before_status" "$guard" || return 1
    for entry in git-wt 'git wt'; do
      initial_tag=$capture_tag
      for input expected in \
        'swi' 'switch ' \
        'chec' 'checkout ' \
        'sw local/s' 'sw local/slash ' \
        'sw feature/l' 'sw feature/login ' \
        'create new origin/m' 'create new origin/main ' \
        'create new local/s' 'create new local/slash ' \
        'create brand-new' 'create brand-new' \
        'rm -f mai' 'rm -f main ' \
        "rm -f ${detached_head[1,12]}" "rm -f $detached_head " \
        "rm -- ${detached_head[1,12]}" "rm -- $detached_head " \
        'rm --for' 'rm --force ' \
        'rm -f -f mai' 'rm -f -f main ' \
        'rm -- --for' 'rm -- --for' \
        'list extra' 'list extra'; do
        completion_capture "$entry $input" "$entry $expected" "$guard" || return 1
      done
      completion_capture "$entry sw local/s tail" __ANY_BUFFER__ "$guard" 5 || return 1
      assert_contains "$PTY_BUFFER" "$entry sw local/slash" 'middle completion omitted ref' || return 1
      assert_contains "$PTY_BUFFER" 'tail' 'middle completion lost trailing input' || return 1
      completion_capture "$entry sw 'local/s" __ANY_BUFFER__ "$guard" || return 1
      assert_contains "$PTY_BUFFER" 'local/slash' 'quoted prefix did not complete' || return 1
      print -r -- "PASS completion/$provider/$entry/tab ($(( capture_tag - initial_tag )) cases)"
    done
    completion_command 'cd -- "$CT_OUTSIDE"' || return 1
    for entry in git-wt 'git wt'; do
      completion_capture "$entry swi" "$entry switch " "$outside" || return 1
      completion_capture "$entry sw local/" "$entry sw local/" "$outside" || return 1
      assert_not_contains "$REPLY" 'fatal:' 'completion prints errors outside repo' || return 1
    done
    # Removing just the hook must prevent git wt's branch completion, while
    # ordinary Git and the standalone command remain independently registered.
    completion_command 'cd -- "$CT_GUARD"; unset -f _git_wt _git-wt' || return 1
    completion_capture 'git wt sw local/s' 'git wt sw local/s' "$guard" || return 1
    print -r -- "PASS completion/$provider/missing-hook-rejected"
  } always {
    [[ -z "$completion_name" ]] || zpty -d "$completion_name" 2>/dev/null || true
  }
  # A fresh session uses real Enter. Only the execution endpoint records argv;
  # the actual Git provider and ref queries remain in use.
  {
    completion_start || return 1
    cat > "$completion_dir/execute" <<'EXECUTION'
CT_SHELLENV="$(command git-wt shellenv)" && eval "$CT_SHELLENV" || return 1
git-wt() {
  (( CT_EXEC += 1 ))
  printf '%s\0' "$PWD" "$#" "$@" > "$CT_DIR/exec.$CT_EXEC"
  printf '\nACK:%s:exec:%s:END\n' "$CT_TOKEN" "$CT_EXEC"
}
EXECUTION
    completion_command 'source "$CT_DIR/execute"' || return 1
    for entry in git-wt 'git wt'; do
      for quote in '' "'" '"'; do
        completion_exec_ref "$entry sw ${quote}literal-command-" sw "$literal_command" || return 1
        completion_exec_ref "$entry create safe ${quote}literal-backtick-" create safe "$literal_backtick" || return 1
        completion_exec_ref "$entry rm ${quote}literal-variable-" rm "$literal_variable" || return 1
        completion_exec_ref "$entry sw ${quote}literal-semicolon-" sw 'literal-semicolon-;echo' || return 1
        completion_exec_ref "$entry sw ${quote}local/s" sw local/slash || return 1
      done
      print -r -- "PASS completion/$provider/$entry/enter (15 cases)"
    done
    # Restore the actual wrapper and start each entry from guard, never from
    # the previous successful target (the original false-positive pattern).
    completion_load_shellenv || return 1
    for entry in git-wt 'git wt'; do
      completion_command 'cd -- "$CT_GUARD"' || return 1
      completion_command "$entry sw local/s"$'\t' || return 1
      completion_capture '' '' "$container/local/slash" 0 no || return 1
      completion_command 'git symbolic-ref --short HEAD > "$CT_DIR/actual-branch"' || return 1
      assert_eq "$(<"$completion_dir/actual-branch")" local/slash 'real switch branch' || return 1
    done
    print -r -- "PASS completion/$provider/real-switch (2 cases)"
    completion_command '__disable_capture' || return 1
    if completion_capture 'NO_CAPTURE_PROBE' 'NO_CAPTURE_PROBE' "$container/local/slash" 0 no > "$completion_dir/rejected-capture" 2>&1; then
      fail 'missing capture binding was accepted' || return 1
    fi
    assert_contains "$(<"$completion_dir/rejected-capture")" 'PTY timed out' 'missing capture failure was not detected' || return 1
    print -r -- "PASS completion/$provider/missing-capture-rejected"
  } always {
    [[ -z "$completion_name" ]] || zpty -d "$completion_name" 2>/dev/null || true
  }
}

function case_completion() {
  new_fixture || return 1
  local source="$CURRENT_FIXTURE/source" container="$CURRENT_FIXTURE/container with spaces"
  local shell_path="${BIN:h}:$PATH" output detached_head sentinel state
  local git_bash git_zsh native_zsh outside="$CURRENT_FIXTURE/outside"
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
  git --git-dir="$container/.git" branch 'literal-semicolon-;echo' main || return 1
  git --git-dir="$container/.git" worktree add "$container/literal-remove" "$literal_variable" >/dev/null || return 1
  mkdir -p "$outside" || return 1
  state="$CURRENT_FIXTURE/completion.before"
  snapshot_repo_state "$container/guard" "$state" || return 1
  completion_provider_path "${GIT_WT_TEST_BASH_COMPLETION:-}" \
    /opt/homebrew/etc/bash_completion.d/git-completion.bash \
    /usr/share/bash-completion/completions/git || return 1
  git_bash="$REPLY"
  completion_provider_path "${GIT_WT_TEST_GIT_ZSH_COMPLETION:-}" \
    /opt/homebrew/share/zsh/site-functions/_git || return 1
  git_zsh="$REPLY"
  completion_provider_path "${GIT_WT_TEST_NATIVE_ZSH_COMPLETION:-}" \
    /usr/share/zsh/5.9/functions/_git || return 1
  native_zsh="${REPLY:h}"

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
    COMP_WORDS=(git wt sw "")
    COMP_CWORD=3
    _git_wt
    printf "WT_SW:%s\n" "${COMPREPLY[@]}"
    printf "WT_CONTEXT:<%s>|<%s>|<%s>|<%s>:%s\n" \
      "${COMP_WORDS[0]}" "${COMP_WORDS[1]}" "${COMP_WORDS[2]}" "${COMP_WORDS[3]}" "$COMP_CWORD"
    COMP_WORDS=(git wt remove -f "")
    COMP_CWORD=4
    _git_wt
    printf "WT_REMOVE:%s\n" "${COMPREPLY[@]}"
    COMP_WORDS=(git wt remove -- "")
    COMP_CWORD=4
    _git_wt
    printf "WT_DOUBLE_DASH:%s\n" "${COMPREPLY[@]}"
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
  assert_contains "$output" 'WT_SW:local/slash' 'Bash git wt completion includes local branches' || return 1
  assert_contains "$output" 'WT_CONTEXT:<git>|<wt>|<sw>|<>:3' \
    'Bash git wt adapter changes caller words or cursor' || return 1
  assert_contains "$output" "WT_REMOVE:$detached_head" 'Bash git wt completion includes targets after -f' || return 1
  assert_not_contains "$output" 'WT_DOUBLE_DASH:-f' 'Bash git wt completion stops offering options after --' || return 1
  [[ ! -e "$sentinel" ]] || fail 'Bash completion executed a literal Git ref' || return 1

  # These use each installed Git completion provider through a real interactive
  # `git wt` dispatch. A missing provider is an unverified environment, not a
  # substituted success from the direct completer tests above.
  local provider provider_failures=0
  for provider in bash git_zsh native_zsh; do
    if assert_git_completion_provider "$provider" "$shell_path" "$container" "$outside" \
      "$literal_command" "$literal_backtick" "$literal_variable" "$detached_head" \
      "$git_bash" "$git_zsh" "$native_zsh"; then
      print -r -- "PASS completion/$provider"
    else
      (( provider_failures += 1 ))
      print -r -- "FAIL completion/$provider (remaining cases unverified)"
    fi
  done
  (( provider_failures == 0 )) || return 1
  [[ ! -e "$sentinel" ]] || fail 'Git completion provider executed a literal Git ref' || return 1

  output="$(PATH="$shell_path" zsh -f -c '
    function compdef() { :; }
    source <(git-wt shellenv)
    function compadd() { shift; for candidate in "$@"; do print -r -- "COMP:${TEST_TAG}:$candidate"; done; }
    cd -- "$1/guard"
    TEST_TAG=switch
    words=(git-wt sw "")
    CURRENT=3
    _git_wt_complete_zsh
    TEST_TAG=remove
    words=(git-wt remove -f "")
    CURRENT=4
    _git_wt_complete_zsh
    TEST_TAG=create
    words=(git-wt create new "")
    CURRENT=4
    _git_wt_complete_zsh
    TEST_TAG=git-zsh-adapter
    words=(git wt sw "")
    CURRENT=4
    cword=$(( CURRENT - 1 ))
    _git_wt
    print -r -- "CONTEXT:git-zsh:${(j:|:)words}:$CURRENT:$cword"
    TEST_TAG=native-zsh-adapter
    words=(wt remove -f "")
    CURRENT=4
    _git-wt
    print -r -- "CONTEXT:native-zsh:${(j:|:)words}:$CURRENT"
  ' _ "$container")" || return 1
  assert_contains "$output" 'COMP:switch:local/slash' 'Zsh switch completion includes local branches' || return 1
  assert_contains "$output" "COMP:remove:$detached_head" 'Zsh remove completion includes detached SHA' || return 1
  assert_contains "$output" 'COMP:create:origin/main' 'Zsh create base completion includes origin ref' || return 1
  assert_contains "$output" 'COMP:create:local/slash' 'Zsh create base completion includes local ref' || return 1
  assert_contains "$output" 'COMP:git-zsh-adapter:local/slash' 'Git Zsh adapter omits switch refs' || return 1
  assert_contains "$output" "COMP:native-zsh-adapter:$detached_head" 'native Zsh adapter omits remove refs' || return 1
  assert_contains "$output" 'CONTEXT:git-zsh:git|wt|sw|:4:3' \
    'Git Zsh adapter changes caller words or cursor' || return 1
  assert_contains "$output" 'CONTEXT:native-zsh:wt|remove|-f|:4' \
    'native Zsh adapter changes caller words or cursor' || return 1

  (cd "$CURRENT_FIXTURE" && PATH="$shell_path" zsh -f -c \
    'source <(git-wt shellenv); source <(git-wt shellenv)') || \
    fail 'Zsh shellenv requires initialized completion' || return 1
  (cd "$CURRENT_FIXTURE" && PATH="$shell_path" bash --noprofile --norc -c \
    'eval "$(git-wt shellenv)"; eval "$(git-wt shellenv)"') || \
    fail 'Bash shellenv requires Git completion' || return 1
  output="$(cd "$CURRENT_FIXTURE" && PATH="$shell_path" bash --noprofile --norc -c '
    eval "$(git-wt shellenv)"
    COMP_WORDS=(git-wt sw "")
    COMP_CWORD=2
    _git_wt_complete_bash
  ' _ 2>&1)" || return 1
  assert_not_contains "$output" 'fatal:' 'completion outside a repository prints Git errors' || return 1
  assert_repo_state "$container/guard" "$state" 'completion' || return 1
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
  pty_confirm_migration "$repo" y env "PATH=$SHIM_PATH" "GIT_WT_REAL_GIT=$SHIM_REAL_GIT" \
    "GIT_WT_REAL_MV=$SHIM_REAL_MV" "GIT_WT_MV_COUNT=$count" \
    "GIT_WT_MV_FAIL_AT=$SHIM_FAIL_AT" GIT_WT_FAIL_WORKTREE_ADD=1 "$BIN" init || return 1
  print -r -- "$REPLY" >| "$CURRENT_FIXTURE/metadata.err"
  if (( PTY_RC == 0 )); then
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
  pty_confirm_migration "$repo" y env "PATH=$SHIM_PATH" "GIT_WT_REAL_GIT=$SHIM_REAL_GIT" \
    "GIT_WT_REAL_MV=$SHIM_REAL_MV" "GIT_WT_MV_COUNT=$count" \
    "GIT_WT_MV_FAIL_AT=$SHIM_FAIL_AT" GIT_WT_FAIL_WORKTREE_ADD_AFTER=1 \
    "GIT_WT_AFTER_ADD_MARKER=$after_add_marker" "$BIN" init || return 1
  print -r -- "$REPLY" >| "$CURRENT_FIXTURE/after-add.err"
  if (( PTY_RC == 0 )); then
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
  pty_confirm_migration "$repo" y env "PATH=$SHIM_PATH" "GIT_WT_REAL_GIT=$SHIM_REAL_GIT" \
    "GIT_WT_REAL_MV=$SHIM_REAL_MV" "GIT_WT_MV_COUNT=$count" \
    "GIT_WT_MV_FAIL_AT=$SHIM_FAIL_AT" GIT_WT_FAIL_WORKTREE_ADD=1 \
    "GIT_WT_FAIL_RMDIR_PATH=$repo" "GIT_WT_FAIL_RMDIR_ONCE_MARKER=$rollback_marker" \
    "$BIN" init || return 1
  print -r -- "$REPLY" >| "$CURRENT_FIXTURE/rollback-failure.err"
  if (( PTY_RC == 0 )); then
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
  pty_confirm_migration "$repo" y env "PATH=$SHIM_PATH" "GIT_WT_REAL_GIT=$SHIM_REAL_GIT" \
    "GIT_WT_REAL_MV=$SHIM_REAL_MV" "GIT_WT_MV_COUNT=$count" \
    "GIT_WT_MV_FAIL_AT=$SHIM_FAIL_AT" "$BIN" init || return 1
  print -r -- "$REPLY" >| "$CURRENT_FIXTURE/partial.err"
  if (( PTY_RC == 0 )); then
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
run_case init_confirmation_and_new_directory case_init_confirmation_and_new_directory
run_case init_partial_failure_recovery case_init_partial_failure_recovery
run_case init_discovery case_init_discovery
run_case default_base case_default_base
run_case split_index_rejection case_split_index_rejection
run_case tree_snapshot case_tree_snapshot
run_case migration_failure_recovery case_migration_failure_recovery
run_case remove case_remove
run_case shellenv_remove_pty case_shellenv_remove_pty
run_case shellenv case_shellenv
run_case shellenv_init_directory case_shellenv_init_directory
run_case completion case_completion

print -r -- "Result: $PASSED passed, $FAILED failed"
(( FAILED == 0 ))
