#!/usr/bin/env bash

# Run with /bin/bash on macOS to cover the system Bash 3.2.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/setup-agents-tests.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
export TEST_GIT
TEST_GIT=$(command -v git)
command -v yq >/dev/null
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

mkdir -p "$TEST_ROOT/scripts" "$TEST_ROOT/config/agents" "$TEST_ROOT/bin" \
  "$TEST_ROOT/shims" "$TEST_ROOT/source/first" "$TEST_ROOT/source/nested/second"
cp "$TEST_DIR/../scripts/setup-agents.sh" "$TEST_DIR/../scripts/utils.sh" "$TEST_ROOT/scripts/"
printf 'Test agent configuration\n' > "$TEST_ROOT/config/agents/POLICIES.md"
printf '%s\n' '---' 'name: first' '---' 'First skill.' > "$TEST_ROOT/source/first/SKILL.md"
printf '%s\n' '---' 'name: second' '---' 'Second skill.' > "$TEST_ROOT/source/nested/second/SKILL.md"
"$TEST_GIT" -C "$TEST_ROOT/source" init -q
"$TEST_GIT" -C "$TEST_ROOT/source" add .
"$TEST_GIT" -C "$TEST_ROOT/source" -c user.name=Test -c user.email=test@example.invalid \
  -c core.hooksPath=/dev/null commit -qm fixture

# Redirect the only remote operation to a local fixture; keep real Git for
# discovery, archives, and tree hashes used by the installation code.
cat > "$TEST_ROOT/shims/git" <<'EOF'
#!/bin/bash
if [ "$1" = clone ]; then
  exec "$TEST_GIT" clone -q "$TEST_SOURCE" "$5"
fi
exec "$TEST_GIT" "$@"
EOF
chmod +x "$TEST_ROOT/shims/git"
export TEST_SOURCE="$TEST_ROOT/source"

run_setup() {
  env HOME="$TEST_ROOT/$1" PATH="$TEST_ROOT/shims:$PATH" \
    DRY_RUN=false VERBOSE=false DEBUG=false \
    "$BASH" "$TEST_ROOT/scripts/setup-agents.sh"
}

printf 'https://github.com/test/skills.git\n' > "$TEST_ROOT/config/agents/skills.list"
run_setup all
test -f "$TEST_ROOT/all/.codex/AGENTS.md"
test -f "$TEST_ROOT/all/.agents/skills/first/SKILL.md"
test -f "$TEST_ROOT/all/.agents/skills/second/SKILL.md"
test "$(yq -r '.skills | length' "$TEST_ROOT/all/.agents/.skill-lock.json")" = 2
echo 'PASS repository-only entry installs all skills'

printf 'https://github.com/test/skills.git|nested/second/SKILL.md|first\n' \
  > "$TEST_ROOT/config/agents/skills.list"
run_setup selected
test -f "$TEST_ROOT/selected/.agents/skills/first/SKILL.md"
test -f "$TEST_ROOT/selected/.agents/skills/second/SKILL.md"
echo 'PASS explicit paths and bare names preserve multiple arguments'

# A repository-only entry after a selective entry must not reuse its paths.
printf '%s\n' 'https://github.com/test/skills.git|first' \
  'https://github.com/test/skills.git' > "$TEST_ROOT/config/agents/skills.list"
run_setup mixed
test -f "$TEST_ROOT/mixed/.agents/skills/second/SKILL.md"
echo 'PASS repository-only entry resets requested paths'

mkdir -p "$TEST_ROOT/empty-source"
export TEST_SOURCE="$TEST_ROOT/empty-source"
"$TEST_GIT" -C "$TEST_SOURCE" init -q
printf 'https://github.com/test/skills.git\n' > "$TEST_ROOT/config/agents/skills.list"
if run_setup empty > "$TEST_ROOT/empty.log" 2>&1; then
  echo 'FAIL empty repository unexpectedly succeeded' >&2
  exit 1
fi
grep -q 'No agent skills found' "$TEST_ROOT/empty.log"
if grep -q 'unbound variable' "$TEST_ROOT/empty.log"; then
  cat "$TEST_ROOT/empty.log" >&2
  exit 1
fi
echo 'PASS empty repository reports the intended error'
