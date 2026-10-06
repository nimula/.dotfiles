#!/usr/bin/env bash
# Linux/macOS installer; Bash 3.2+, Unix utilities and existing mikefarah/yq v4.
source "$(dirname "$0")/utils.sh"
set -Eeuo pipefail
umask 077

fail() { print_error "Codex setup error: $*" >&2; exit 1; }

# Command-line paths override the defaults below.
script_dir="$CURR_DIR"
source_dir="$CONFIG_DIR/agents"
codex_home="${CODEX_HOME:-${HOME}/.codex}"
dry_run=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-dir|--codex-home)
      [ "$#" -ge 2 ] || fail "Missing argument: $1"
      case "$1" in
        --source-dir) source_dir=$2 ;;
        --codex-home) codex_home=$2 ;;
      esac
      shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    *) fail "Unknown option: $1" ;;
  esac
done

# Use an existing yq; the installer never installs dependencies.
yq_bin=${DOTFILES_YQ:-yq}
command -v "$yq_bin" >/dev/null 2>&1 || fail "Provide an existing mikefarah/yq v4 on PATH or set DOTFILES_YQ. This installer does not download or install tools."
version_output=$("$yq_bin" --version)
[[ "$version_output" =~ github\.com/mikefarah/yq.*version[[:space:]]v4\. ]] || fail "Expected mikefarah/yq v4."

[ -n "$codex_home" ] || fail "Codex home cannot be empty."
source_dir=$(CDPATH= cd -- "$source_dir" && pwd)
case "$codex_home" in /*) ;; *) codex_home="$PWD/$codex_home" ;; esac

# Resolve existing ancestors to reject root aliases without creating directories.
destination_location() {
  local component current=/ next
  local components=()
  IFS=/ read -r -a components <<< "$codex_home"

  for component in "${components[@]}"; do
    case "$component" in
      ''|.) continue ;;
      ..) current=${current%/*}; [ -n "$current" ] || current=/ ;;
      *)
        next="${current%/}/$component"
        if [ -e "$next" ]; then
          current=$(CDPATH= cd -P -- "$next" && pwd -P) || return 1
        else
          current=$next
        fi ;;
    esac
  done
  printf '%s\n' "$current"
}

codex_location=$(destination_location) || fail "Cannot resolve Codex home."
[ "$codex_location" != / ] || fail "Codex home cannot be the filesystem root."

# Check existing target types, following symbolic links to their targets.
inspect() {
  local path=$1 kind=$2
  if [ -e "$path" ]; then
    case "$kind" in
      file) [ -f "$path" ] ;;
      directory) [ -d "$path" ] ;;
    esac ||
      fail "Expected a regular $kind: $path"
  fi
}

inspect "$codex_home" directory
inspect "$codex_home/agents" directory

# Build all candidate files in temporary storage before writing to the destination.
work=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-codex.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$work/old" "$work/new/agents"

files=(AGENTS.md config.toml)

# Discover and copy role files verbatim; source encoding is owned by the repo.
for path in "$source_dir/codex/agents/"*.toml; do
  [ -f "$path" ] || continue
  name="agents/${path##*/}"
  files+=("$name")
  cp "$path" "$work/new/$name"
done

# Decode text used to assemble Markdown and configuration as BOM-free UTF-8.
utf8_file() {
  LC_ALL=C od -An -v -tu1 "$1" | LC_ALL=C awk -f "$script_dir/codex-utf8.awk" > "$2" ||
    fail "Expected UTF-8 or BOM-marked UTF-16 text: $1"
}

for name in "${files[@]}"; do
  inspect "$codex_home/$name" file
done

# Read existing user content; absent files start with empty content.
for name in AGENTS.md config.toml; do
  if [ -f "$codex_home/$name" ]; then
    utf8_file "$codex_home/$name" "$work/old/$name"
  else
    : > "$work/old/$name"
  fi
done

# Preserve each original file's line endings and final-newline convention.
text_format() {
  export DOTFILES_NEWLINE=lf DOTFILES_EOF=false
  if LC_ALL=C grep -q $'\r$' "$1"; then DOTFILES_NEWLINE=crlf; fi
  if [ -s "$1" ] && [ -z "$(tail -c 1 "$1")" ]; then DOTFILES_EOF=true; fi
}

# The only managed Markdown sources, in the agreed order.
text_format "$work/old/AGENTS.md"
newline=$'\n'; [ "$DOTFILES_NEWLINE" != crlf ] || newline=$'\r\n'
export DOTFILES_BLOCK="$work/block" DOTFILES_WARNING="$work/markdown-warning"
printf '<!-- dotfiles:agents:start -->%s%s' "$newline" "$newline" > "$DOTFILES_BLOCK"
for path in "$source_dir/AGENT-POLICIES.md" "$source_dir/ENGINEERING-GUIDELINES.md" "$source_dir/codex/ORCHESTRATE.md"; do
  utf8_file "$path" "$work/document"

  # Boundary blank lines belong to the managed block; interior text is intact.
  # macOS awk rejects literal newlines in -v values; build them inside awk.
  LC_ALL=C awk '
    BEGIN { newline = ENVIRON["DOTFILES_NEWLINE"] == "crlf" ? "\r\n" : "\n" }
    { sub(/\r$/, ""); lines[++count] = $0 }
    END {
      first = 1; last = count
      while (first <= last && lines[first] ~ /^[ \t]*$/) first++
      while (last >= first && lines[last] ~ /^[ \t]*$/) last--
      for (i = first; i <= last; i++) printf "%s%s", lines[i], newline
    }
  ' "$work/document" >> "$DOTFILES_BLOCK"
  printf '%s' "$newline" >> "$DOTFILES_BLOCK"
done
printf '<!-- dotfiles:agents:end -->%s%s' "$newline" "$newline" >> "$DOTFILES_BLOCK"

# Keep leading @PATH lines and user text; filter a valid previous managed block.
LC_ALL=C awk -v mode=instructions -f "$script_dir/codex-managed.awk" "$work/old/AGENTS.md" > "$work/new/AGENTS.md"

# yq handles data; awk changes only managed declarations in the original text.
utf8_file "$source_dir/codex/config.toml" "$work/template.toml"

# First convert a root inline agents declaration to a table, retaining its comment.
# Keep the converted text in memory, with native TOML types intact.
export DOTFILES_AGENTS
DOTFILES_AGENTS=$("$yq_bin" -p toml -o toml '.agents // {}' "$work/old/config.toml")
text_format "$work/old/config.toml"
LC_ALL=C awk -v mode=normalize -f "$script_dir/codex-managed.awk" "$work/old/config.toml" > "$work/normalized.toml"

# Only after normalization, apply the required settings to the original text.
export DOTFILES_SETTINGS
DOTFILES_SETTINGS=$("$yq_bin" -p toml -o toml '.' "$work/template.toml")
text_format "$work/normalized.toml"
LC_ALL=C awk -v mode=config -f "$script_dir/codex-managed.awk" "$work/normalized.toml" > "$work/new/config.toml" ||
  fail "Cannot locate managed config declarations unambiguously."

# Compare read-only renderings in memory; neither rendering is parsed back or
# used to produce installed content. No JSON conversion or intermediate files.
expected=$("$yq_bin" eval-all -p toml -o yaml '(select(fileIndex == 0) // {}) * select(fileIndex == 1) | sort_keys(..) | ... comments = ""' "$work/old/config.toml" "$work/template.toml")
actual=$("$yq_bin" -p toml -o yaml 'sort_keys(..) | ... comments = ""' "$work/new/config.toml")
[ "$expected" = "$actual" ] || fail "The local config update did not preserve the expected settings."

# Skip unchanged files; overwrite existing files in place to retain their inodes.
for name in "${files[@]}"; do
  if [ -f "$codex_home/$name" ] && cmp -s "$codex_home/$name" "$work/new/$name"; then
    continue
  fi

  if $dry_run; then
    print_default "Would update $codex_home/$name"
  else
    mkdir -p "$(dirname "$codex_home/$name")"
    inspect "$codex_home/$name" file
    cat "$work/new/$name" > "$codex_home/$name"
    print_default "Updated $codex_home/$name"
  fi
done

# Ambiguous old Markdown blocks remain available for the user to review.
if [ -f "$DOTFILES_WARNING" ]; then
  print_warning 'Latest instructions added; the original file may contain duplicate old instructions. Please review and remove duplicate sections manually.' >&2
fi

$dry_run || print_success 'Codex configuration installed. Start a new Codex session to load it.'
