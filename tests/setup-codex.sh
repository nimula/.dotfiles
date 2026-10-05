#!/usr/bin/env bash
# Isolated regression fixtures; no remote repositories or extra tool installs.
set -euo pipefail
repository=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
yq_binary=${DOTFILES_YQ:-$(command -v yq)}
test_root=$(mktemp -d "${TMPDIR:-/tmp}/codex-shell-tests.XXXXXX")
cleanup() {
  local status=$?
  if [ "$status" -ne 0 ] && [ -f "$test_root/output" ]; then cat "$test_root/output" >&2; fi
  rm -rf "$test_root"
}
trap cleanup EXIT
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }
fixture() {
  source="$test_root/$1/source"
  destination="$test_root/$1/home"
  mkdir -p "$source"
  printf '# Policy\nPolicy text.\n\n' > "$source/AGENT-POLICIES.md"
  printf '# Engineering\nEngineering text.\n' > "$source/ENGINEERING-GUIDELINES.md"
  cp -R "$repository/config/agents/codex" "$source/codex"
  printf '# Orchestration\nOrchestration text.\n' > "$source/codex/ORCHESTRATE.md"
}
run() { DOTFILES_YQ="$yq_binary" "$BASH" "$repository/scripts/setup-codex.sh" --source-dir "$source" --codex-home "$destination" "$@" > "$test_root/output" 2>&1; }
reject() { if run "$@"; then echo 'Expected rejection' >&2; exit 1; fi; }
read_config() { "$yq_binary" -p toml -o json -e "$1" "$destination/config.toml" >/dev/null; }
inode() { stat -c '%i' "$1" 2>/dev/null || stat -f '%i' "$1"; }
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
unchanged_rerun() {
  cp -R "$destination" "$test_root/before-rerun"
  run
  diff -r "$test_root/before-rerun" "$destination"
  rm -rf "$test_root/before-rerun"
}

fixture fresh
run --dry-run
test ! -e "$destination"
run
read_config '.model == "gpt-6.1-sol" and .agents.enabled == true and .agents.max_concurrent_threads_per_session == 4'
test "$(mode "$destination/AGENTS.md")" = 600
test ! -e "$destination/.dotfiles-agent-state.json"
test ! -e "$destination/.dotfiles-agent-backups"
test ! -e "$destination/.dotfiles-agent-install.lock"
unchanged_rerun
pass 'fresh setup, destination-free dry-run and unchanged rerun'

fixture discovered-roles
mkdir -p "$destination/agents"
mv "$source/codex/agents/explorer.toml" "$source/codex/agents/custom role.toml"
rm "$source/codex/agents/researcher.toml"
printf 'User role\n' > "$destination/agents/researcher.toml"
printf 'Ignored source\n' > "$source/codex/agents/notes.md"
run
cmp "$source/codex/agents/custom role.toml" "$destination/agents/custom role.toml"
test ! -e "$destination/agents/explorer.toml"
test ! -e "$destination/agents/notes.md"
test "$(cat "$destination/agents/researcher.toml")" = 'User role'
unchanged_rerun
pass 'role files are discovered from source TOML files and destination-only roles remain untouched'

fixture markdown
mkdir -p "$destination"
printf '@one.md\n@two.md\n\n\nUser prefix\n\n<!-- dotfiles:agents:start -->\nOld instructions\n<!-- dotfiles:agents:end -->\n\n\nUser suffix' > "$destination/AGENTS.md"
run
cat > "$test_root/markdown-expected" <<'EOF'
@one.md
@two.md

<!-- dotfiles:agents:start -->

# Policy
Policy text.

# Engineering
Engineering text.

# Orchestration
Orchestration text.

<!-- dotfiles:agents:end -->

User prefix

EOF
printf 'User suffix' >> "$test_root/markdown-expected"
cmp "$test_root/markdown-expected" "$destination/AGENTS.md"
unchanged_rerun
pass 'literal leading references, fixed source order and old-block filtering with exact blank lines'

for kind in missing-end missing-start duplicate reversed embedded; do
  fixture "$kind"
  mkdir -p "$destination"
  case "$kind" in
    missing-end) printf 'Personal\n<!-- dotfiles:agents:start -->\nOld text\n' ;;
    missing-start) printf 'Personal\nOld text\n<!-- dotfiles:agents:end -->\n' ;;
    duplicate) printf 'Personal\n<!-- dotfiles:agents:start -->\nOld text\n<!-- dotfiles:agents:end -->\n<!-- dotfiles:agents:start -->\nSecond text\n<!-- dotfiles:agents:end -->\n' ;;
    reversed) printf 'Personal\n<!-- dotfiles:agents:end -->\nOld text\n<!-- dotfiles:agents:start -->\n' ;;
    embedded) printf 'Personal\ninline <!-- dotfiles:agents:start --> text\n' ;;
  esac > "$destination/AGENTS.md"
  cp "$destination/AGENTS.md" "$test_root/original"
  run
  bytes=$(wc -c < "$test_root/original")
  tail -c "$bytes" "$destination/AGENTS.md" > "$test_root/preserved"
  cmp "$test_root/original" "$test_root/preserved"
  grep -q 'duplicate old instructions' "$test_root/output"
  grep -q 'Policy text' "$destination/AGENTS.md"
done
pass 'all ambiguous marker cases preserve original text, warn and complete installation'

fixture inline
mkdir -p "$destination"
cat > "$destination/config.toml" <<'EOF'
# top comment
agents = { enabled = false, max_depth = 2, label = "a#b,c", options = { limit = 3 } }   # 個人設定
model = "old#model"  # keep model comment
model_provider = "custom"
# root comment stays in place
[profiles.personal] # profile comment
model = "personal"
EOF
run
grep -Fxq '[agents] # 個人設定' "$destination/config.toml"
grep -Fxq 'model = "gpt-6.1-sol"  # keep model comment' "$destination/config.toml"
grep -Fxq '# root comment stays in place' "$destination/config.toml"
test "$(grep -c '^\[agents\]' "$destination/config.toml")" = 1
if grep -q '^agents =' "$destination/config.toml"; then exit 1; fi
read_config '.agents.enabled == true and .agents.max_depth == 2 and .agents.options.limit == 3 and .agents.label == "a#b,c" and .model_provider == "custom" and .profiles.personal.model == "personal"'
unchanged_rerun
pass 'inline agents conversion preserves values and moves only its trailing comment'

for form in inline explicit; do
  fixture "typed-$form"
  mkdir -p "$destination"
  printf 'outside_nan = nan\n' > "$destination/config.toml"
  if [ "$form" = inline ]; then
    printf 'agents = { enabled = false, created = 1979-05-27T07:32:00Z, large = 9007199254740993, threshold = nan, infinity = -inf, text_nan = "nan", options = { limit = 3 } } # typed values\n' >> "$destination/config.toml"
  else
    printf '[agents] # typed values\nenabled = false\ncreated = 1979-05-27T07:32:00Z\nlarge = 9007199254740993\nthreshold = nan\ninfinity = -inf\ntext_nan = "nan"\noptions = { limit = 3 }\n' >> "$destination/config.toml"
  fi
  run
  test "$("$yq_binary" -p toml -o yaml -r '.agents.large' "$destination/config.toml")" = 9007199254740993
  grep -Fxq 'created = 1979-05-27T07:32:00Z' "$destination/config.toml"
  test "$("$yq_binary" -p toml -o yaml -r '.agents.threshold | tag' "$destination/config.toml")" = '!!float'
  test "$("$yq_binary" -p toml -o yaml -r '.agents.infinity | tag' "$destination/config.toml")" = '!!float'
  test "$("$yq_binary" -p toml -o yaml -r '.agents.text_nan | tag' "$destination/config.toml")" = '!!str'
  grep -Fxq 'outside_nan = nan' "$destination/config.toml"
  grep -Fxq '[agents] # typed values' "$destination/config.toml"
  read_config '.agents.enabled == true and .agents.options.limit == 3'
  unchanged_rerun
done
pass 'native TOML retains timestamps, large integers, NaN, infinity and string types'

fixture explicit
mkdir -p "$destination"
cat > "$destination/config.toml" <<'EOF'
model = "old" # main model comment
[agents] # original header
enabled = false   # enabled comment
max_concurrent_threads_per_session = 1 # limit comment
max_depth = 2 # unrelated agent comment

[agents.other]
name = "other"
[profiles.personal]
model = "personal"
EOF
run
grep -Fxq '[agents] # original header' "$destination/config.toml"
grep -Fxq 'enabled = true   # enabled comment' "$destination/config.toml"
grep -Fxq 'max_concurrent_threads_per_session = 4 # limit comment' "$destination/config.toml"
grep -Fxq 'max_depth = 2 # unrelated agent comment' "$destination/config.toml"
read_config '.agents.max_depth == 2 and .agents.other.name == "other" and .profiles.personal.model == "personal"'
unchanged_rerun
pass 'ordinary managed declarations retain comments and unrelated tables'

for whitespace in spaces tabs; do
  fixture "header-$whitespace"
  mkdir -p "$destination"
  header='[ agents ]'
  if [ "$whitespace" = tabs ]; then header=$' \t[\tagents\t]'; fi
  printf 'model = "old"\n%s # original header\nenabled = false # keep comment\nmax_depth = 2\n[profiles.personal]\nmodel = "personal"\n' "$header" > "$destination/config.toml"
  run
  grep -Fxq "$header # original header" "$destination/config.toml"
  grep -Fxq 'enabled = true # keep comment' "$destination/config.toml"
  test "$(grep -c '^[[:blank:]]*\[[[:blank:]]*agents[[:blank:]]*\]' "$destination/config.toml")" = 1
  read_config '.agents.enabled == true and .agents.max_concurrent_threads_per_session == 4 and .agents.max_depth == 2 and .profiles.personal.model == "personal"'
  unchanged_rerun
done
pass 'agents headers accept spaces and tabs while preserving original text and comments'

for kind in basic literal; do
  quote='"'
  if [ "$kind" = literal ]; then quote="'"; fi
  for ending in 4 5; do
    fixture "closing-$kind-$ending"
    mkdir -p "$destination"
    closing="$quote$quote$quote$quote"
    if [ "$ending" = 5 ]; then closing+="$quote"; fi
    {
      printf 'developer_instructions = %s\n[agents]\nenabled = false\nClosing quote: %s # instructions comment\n' "$quote$quote$quote" "$closing"
      printf 'model = %sold%s # model comment\n[agents]\nenabled = false # enabled comment\n' "$quote$quote$quote" "$closing"
    } > "$destination/config.toml"
    head -n 4 "$destination/config.toml" > "$test_root/instructions-before"
    run
    head -n 4 "$destination/config.toml" > "$test_root/instructions-after"
    cmp "$test_root/instructions-before" "$test_root/instructions-after"
    grep -Fxq 'model = "gpt-6.1-sol" # model comment' "$destination/config.toml"
    grep -Fxq 'enabled = true # enabled comment' "$destination/config.toml"
    read_config '.model == "gpt-6.1-sol" and .agents.enabled == true and .agents.max_concurrent_threads_per_session == 4'
    unchanged_rerun
  done
done
pass 'four/five closing quotes in basic and literal multiline strings preserve content and following settings'

fixture multiline
mkdir -p "$destination"
cat > "$destination/config.toml" <<'EOF'
model = """old
model""" # model comment
note = '''
[agents]
model = "keep this literal"
agents = { enabled = false }
'''
items = [
 "[agents]",
 "model = old",
]
[profiles.personal]
model = "personal"
EOF
sed -n '3,11p' "$destination/config.toml" > "$test_root/literal-before"
run
sed -n '2,10p' "$destination/config.toml" > "$test_root/literal-after"
cmp "$test_root/literal-before" "$test_root/literal-after"
grep -Fxq 'model = "gpt-6.1-sol" # model comment' "$destination/config.toml"
read_config '.agents.enabled == true and .items[0] == "[agents]" and .profiles.personal.model == "personal"'
unchanged_rerun
pass 'multiline strings and arrays do not masquerade as config declarations'

fixture inplace
mkdir -p "$destination/agents"
printf '@keep.md\n\n個人規則 😀\n' > "$destination/AGENTS.md"
printf 'model = "old"\n' > "$destination/config.toml"
printf 'custom old role\n' > "$destination/agents/explorer.toml"
printf 'unrelated\n' > "$destination/agents/other.toml"
chmod 640 "$destination/AGENTS.md"
files=(AGENTS.md config.toml agents/explorer.toml)
for name in "${files[@]}"; do inode "$destination/$name" >> "$test_root/inodes-before"; done
run
for name in "${files[@]}"; do inode "$destination/$name" >> "$test_root/inodes-after"; done
cmp "$test_root/inodes-before" "$test_root/inodes-after"
test "$(mode "$destination/AGENTS.md")" = 640
cmp "$source/codex/agents/explorer.toml" "$destination/agents/explorer.toml"
test "$(cat "$destination/agents/other.toml")" = unrelated
grep -Fxq '個人規則 😀' "$destination/AGENTS.md"
unchanged_rerun
pass 'in-place writes retain existing inodes/modes and directly update only specified roles'

fixture utf16
mkdir -p "$destination"
printf '\377\376\100\000\153\000\145\000\145\000\160\000\015\000\012\000\015\000\012\000\013\120\272\116\015\000\012\000' > "$destination/AGENTS.md"
printf '\357\273\277model = "old"\r\n[agents] # existing\r\nenabled = false # keep\r\n' > "$destination/config.toml"
{ printf '\357\273\277'; cat "$source/AGENT-POLICIES.md"; } > "$test_root/bom-source"
cp "$test_root/bom-source" "$source/AGENT-POLICIES.md"
run
printf '@keep\r\n' > "$test_root/reference-expected"
head -n 1 "$destination/AGENTS.md" > "$test_root/reference-actual"
cmp "$test_root/reference-expected" "$test_root/reference-actual"
printf '個人\r\n' > "$test_root/personal-expected"
tail -n 1 "$destination/AGENTS.md" > "$test_root/personal-actual"
cmp "$test_root/personal-expected" "$test_root/personal-actual"
test "$(head -c 3 "$destination/config.toml")" != $'\357\273\277'
LC_ALL=C awk '/<!-- dotfiles:agents:(start|end) -->/ { if ($0 !~ /\r$/) exit 1; count++ } END { if (count != 2) exit 1 }' "$destination/AGENTS.md"
unchanged_rerun
pass 'BOM/UTF-16 input becomes BOM-free UTF-8 with CRLF preserved'

fixture invalid
mkdir -p "$destination"
printf 'Personal\n' > "$destination/AGENTS.md"
printf 'model = [\n' > "$destination/config.toml"
cp "$destination/AGENTS.md" "$test_root/invalid-markdown"
cp "$destination/config.toml" "$test_root/invalid-config"
reject
cmp "$test_root/invalid-markdown" "$destination/AGENTS.md"
cmp "$test_root/invalid-config" "$destination/config.toml"
printf 'model = "old"\n' > "$destination/config.toml"
printf '\377' > "$destination/AGENTS.md"
cp "$destination/AGENTS.md" "$test_root/invalid-encoding"
reject
cmp "$test_root/invalid-encoding" "$destination/AGENTS.md"
pass 'unreadable config or encoding is reported before destination writes'

fixture link
real_home="$test_root/link/real-home"
targets="$test_root/link/targets"
mkdir -p "$real_home" "$targets/roles"
ln -s "$real_home" "$destination"
ln -s "$targets/roles" "$real_home/agents"
printf '@keep.md\n\nPersonal\n' > "$targets/AGENTS.md"
printf 'agents = { enabled = false, max_depth = 2 } # linked config\n' > "$targets/config.toml"
printf 'old role\n' > "$targets/explorer.toml"
chmod 640 "$targets/AGENTS.md"
ln -s ../targets/AGENTS.md "$real_home/AGENTS.md"
ln -s ../targets/config.toml "$real_home/config.toml"
ln -s ../explorer.toml "$targets/roles/explorer.toml"
for path in "$targets/AGENTS.md" "$targets/config.toml" "$targets/explorer.toml"; do
  inode "$path" >> "$test_root/link-inodes-before"
done
run
for path in "$targets/AGENTS.md" "$targets/config.toml" "$targets/explorer.toml"; do
  inode "$path" >> "$test_root/link-inodes-after"
done
cmp "$test_root/link-inodes-before" "$test_root/link-inodes-after"
for path in "$destination" "$real_home/agents" "$real_home/AGENTS.md" "$real_home/config.toml" "$targets/roles/explorer.toml"; do
  test -L "$path"
done
test "$(mode "$targets/AGENTS.md")" = 640
grep -Fxq 'Personal' "$targets/AGENTS.md"
grep -Fxq '[agents] # linked config' "$targets/config.toml"
read_config '.agents.enabled == true and .agents.max_depth == 2'
cmp "$source/codex/agents/explorer.toml" "$targets/explorer.toml"
run
if grep -q '^Updated ' "$test_root/output"; then exit 1; fi
pass 'linked homes, directories and files update actual targets while retaining links, inodes and modes'

printf 'Passed %s groups.\n' "$passed"
