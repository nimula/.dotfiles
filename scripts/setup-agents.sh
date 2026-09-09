#!/usr/bin/env bash
# Author : nimula+github@gmail.com
#
source "$(dirname "$0")/utils.sh"
set -Eeuo pipefail

function setup_agent_config() (
  local agent_name="$1"
  local agent_file_name="$2"
  local shared_configs_dir="${CONFIG_DIR}/agents"
  local orchestrate_file="${shared_configs_dir}/${agent_name}/ORCHESTRATE.md"
  local agent_dir="${HOME}/.${agent_name}"
  local agent_file="${agent_dir}/${agent_file_name}"
  local temp_dir
  local references_file
  local output_file
  local config_file
  local config_files=()

  for config_file in "${shared_configs_dir}"/*.md; do
    if [ -f "$config_file" ]; then
      config_files+=("$config_file")
    fi
  done
  if [ -f "$orchestrate_file" ]; then
    config_files+=("$orchestrate_file")
  fi

  if [ "${#config_files[@]}" -eq 0 ]; then
    print_warning "No agent configuration files found in $shared_configs_dir"
    return 0
  fi

  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' EXIT
  references_file="${temp_dir}/references"
  output_file="${temp_dir}/output"

  for config_file in "${config_files[@]}"; do
    printf '@%s\n' "$config_file" >> "$references_file"
  done
  cp "$references_file" "$output_file"

  if [ -f "$agent_file" ]; then
    awk -v managed_prefix="@${shared_configs_dir}/" '
      {
        line = $0
        sub(/\r$/, "", line)
        if (index(line, managed_prefix) != 1) {
          print
        }
      }
    ' "$agent_file" >> "$output_file"

    if cmp -s "$output_file" "$agent_file"; then
      print_default "$agent_name configuration is already installed."
      return 0
    fi
  fi

  print_default "Installing $agent_name configuration: $agent_file"
  run install -d -m 700 "$agent_dir"
  run install -m 600 "$output_file" "$agent_file"
)

function setup_agent_configs() {
  local agent_configs=(
    "codex|AGENTS.md"
  )
  local agent_config
  local agent_name
  local agent_file_name

  for agent_config in "${agent_configs[@]}"; do
    agent_name="${agent_config%%|*}"
    agent_file_name="${agent_config#*|}"

    setup_agent_config "$agent_name" "$agent_file_name"
  done
}

# Find every SKILL.md in a cloned repository and return repo-relative paths.
function discover_agent_skills() (
  local repo_dir="$1"

  cd "$repo_dir" || return 1
  find . \
    -path './.git' -prune -o \
    -type f -name SKILL.md -print |
    sed 's#^\./##' |
    LC_ALL=C sort
)

# Read the skill name from the YAML frontmatter at the start of SKILL.md.
function read_agent_skill_name() (
  local skill_file="$1"
  local temp_file
  local skill_name

  temp_file=$(mktemp) || return 1
  trap 'rm -f "$temp_file"' EXIT

  if ! awk '
    NR == 1 {
      line = $0
      sub(/\r$/, "", line)
      if (line != "---") {
        exit 1
      }
      next
    }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line == "---") {
        found_end = 1
        exit
      }
      print
    }
    END {
      if (!found_end) {
        exit 1
      }
    }
  ' "$skill_file" > "$temp_file"; then
    print_error "Invalid YAML frontmatter in agent skill: $skill_file"
    return 1
  fi

  skill_name=$(yq -r '.name // ""' "$temp_file") || return 1
  if [ -z "$skill_name" ]; then
    print_error "Agent skill name is missing: $skill_file"
    return 1
  fi

  printf '%s\n' "$skill_name"
)

# Match the Git tree hashes used by the agent skill lock format.
function compute_agent_skill_tree_hash() {
  local repo_dir="$1"
  local skill_path="$2"
  local skill_folder="${skill_path%/SKILL.md}"

  if [ "$skill_path" = "SKILL.md" ]; then
    git -C "$repo_dir" rev-parse --verify 'HEAD^{tree}'
  else
    git -C "$repo_dir" rev-parse --verify "HEAD:${skill_folder}"
  fi
}

# Merge one installed skill into the shared lock without removing other entries.
function update_agent_skill_lock() (
  local skill_name="$1"
  local source="$2"
  local source_type="$3"
  local source_url="$4"
  local skill_path="$5"
  local skill_folder_hash="$6"
  local content_changed="$7"
  local lock_file="${8:-${HOME}/.agents/.skill-lock.json}"
  local lock_dir
  local temp_file
  local now
  local installed_at
  local updated_at

  lock_dir=$(dirname "$lock_file") || return 1
  mkdir -p "$lock_dir" || return 1
  temp_file=$(mktemp "${lock_dir}/.skill-lock.json.XXXXXX") || return 1
  trap 'rm -f "$temp_file"' EXIT

  if [ -f "$lock_file" ]; then
    if ! yq eval '.' "$lock_file" >/dev/null; then
      print_error "Invalid agent skill lock file: $lock_file"
      return 1
    fi
    cp "$lock_file" "$temp_file" || return 1
  else
    printf '{"version":3,"skills":{},"dismissed":{"findSkillsPrompt":true}}\n' > "$temp_file"
  fi

  now=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z') || return 1
  installed_at=$(SKILL_NAME="$skill_name" yq -r '.skills[strenv(SKILL_NAME)].installedAt // ""' "$temp_file") || return 1
  updated_at=$(SKILL_NAME="$skill_name" yq -r '.skills[strenv(SKILL_NAME)].updatedAt // ""' "$temp_file") || return 1
  installed_at="${installed_at:-$now}"
  if [ "$content_changed" = true ] || [ -z "$updated_at" ]; then
    updated_at="$now"
  fi

  if ! SKILL_NAME="$skill_name" \
    SOURCE="$source" \
    SOURCE_TYPE="$source_type" \
    SOURCE_URL="$source_url" \
    SKILL_PATH="$skill_path" \
    SKILL_FOLDER_HASH="$skill_folder_hash" \
    INSTALLED_AT="$installed_at" \
    UPDATED_AT="$updated_at" \
    yq -i -o=json -I=2 '
      .version = 3 |
      .skills = (.skills // {}) |
      .skills[strenv(SKILL_NAME)] = {
        "source": strenv(SOURCE),
        "sourceType": strenv(SOURCE_TYPE),
        "sourceUrl": strenv(SOURCE_URL),
        "skillPath": strenv(SKILL_PATH),
        "skillFolderHash": strenv(SKILL_FOLDER_HASH),
        "installedAt": strenv(INSTALLED_AT),
        "updatedAt": strenv(UPDATED_AT)
      } |
      .dismissed = {"findSkillsPrompt": true}
    ' "$temp_file"; then
    return 1
  fi

  if ! yq eval '.' "$temp_file" >/dev/null; then
    print_error "Failed to generate agent skill lock file."
    return 1
  fi

  mv "$temp_file" "$lock_file"
)

# Stage and validate one skill, then install or update it with rollback support.
function sync_agent_skill() (
  local repo_dir="$1"
  local source="$2"
  local source_type="$3"
  local source_url="$4"
  local skill_path="$5"
  local skill_name="$6"
  local skill_folder="${skill_path%/SKILL.md}"
  local agents_dir="${HOME}/.agents"
  local skills_dir="${agents_dir}/skills"
  local target_dir
  local stage_dir=""
  local backup_dir=""
  local lock_probe_dir=""
  local lock_probe_parent
  local dry_run_lock_file
  local stage_parent
  local parent_dir
  local skill_folder_hash
  local lock_file="${HOME}/.agents/.skill-lock.json"
  local lock_source=""
  local lock_source_type=""
  local lock_source_url=""
  local lock_skill_path=""
  local lock_skill_folder_hash=""
  local action
  local diff_status
  local content_changed=false
  local lock_changed=false
  local activated=false
  local committed=false

  if [ "$skill_path" = "SKILL.md" ]; then
    skill_folder="."
  fi

  case "$skill_name" in
    ''|*[!A-Za-z0-9._-]*)
      print_error "Invalid agent skill name: $skill_name"
      return 1
      ;;
  esac

  target_dir="${skills_dir}/${skill_name}"

  cleanup_agent_skill_sync() {
    local status=$?

    if [ "$committed" != true ] && [ "$activated" = true ] && [ -e "$target_dir" ]; then
      rm -rf "$target_dir"
    fi
    if [ "$committed" != true ] && [ -n "$backup_dir" ] && [ -d "$backup_dir" ] && [ ! -e "$target_dir" ]; then
      mv "$backup_dir" "$target_dir" || true
    fi
    if [ -n "$stage_dir" ] && [ -d "$stage_dir" ]; then
      rm -rf "$stage_dir"
    fi
    if [ -n "$lock_probe_dir" ] && [ -d "$lock_probe_dir" ]; then
      rm -rf "$lock_probe_dir"
    fi
    if [ "$committed" = true ] && [ -n "$backup_dir" ] && [ -d "$backup_dir" ]; then
      rm -rf "$backup_dir"
    fi
    return "$status"
  }
  trap cleanup_agent_skill_sync EXIT

  # Normal installs stage beside the target so the final move stays on one filesystem.
  if [ "$DRY_RUN" = true ]; then
    stage_parent="$skills_dir"
    while [ ! -d "$stage_parent" ]; do
      if [ -e "$stage_parent" ]; then
        print_error "Agent skill destination is not a directory: $stage_parent"
        return 1
      fi
      parent_dir=$(dirname "$stage_parent") || return 1
      if [ "$parent_dir" = "$stage_parent" ]; then
        print_error "No writable parent found for agent skills: $skills_dir"
        return 1
      fi
      stage_parent="$parent_dir"
    done
    stage_dir=$(mktemp -d "${stage_parent}/.agent-skill-stage.XXXXXX") || {
      print_error "Agent skill destination is not writable: $stage_parent"
      return 1
    }
  else
    mkdir -p "$skills_dir" || return 1
    stage_dir=$(mktemp -d "${skills_dir}/.${skill_name}.stage.XXXXXX") || return 1
  fi

  # Export tracked files only, excluding repository metadata such as .git.
  if [ "$skill_folder" = "." ]; then
    if ! git -C "$repo_dir" archive HEAD | tar -xf - -C "$stage_dir"; then
      print_error "Failed to stage agent skill $skill_name."
      return 1
    fi
  else
    local strip_components=1
    local remaining_path="$skill_folder"
    while [[ "$remaining_path" == */* ]]; do
      strip_components=$((strip_components + 1))
      remaining_path="${remaining_path#*/}"
    done
    if ! git -C "$repo_dir" archive HEAD "$skill_folder" |
      tar -xf - -C "$stage_dir" --strip-components="$strip_components"; then
      print_error "Failed to stage agent skill $skill_name."
      return 1
    fi
  fi

  if [ ! -f "${stage_dir}/SKILL.md" ]; then
    print_error "Agent skill $skill_name does not contain SKILL.md."
    return 1
  fi

  skill_folder_hash=$(compute_agent_skill_tree_hash "$repo_dir" "$skill_path") || return 1

  # The lock identifies ownership and prevents same-named skills from colliding.
  if [ -f "$lock_file" ]; then
    if ! yq eval '.' "$lock_file" >/dev/null; then
      print_error "Invalid agent skill lock file: $lock_file"
      return 1
    fi
    lock_source=$(SKILL_NAME="$skill_name" yq -r '.skills[strenv(SKILL_NAME)].source // ""' "$lock_file") || return 1
    lock_source_type=$(SKILL_NAME="$skill_name" yq -r '.skills[strenv(SKILL_NAME)].sourceType // ""' "$lock_file") || return 1
    lock_source_url=$(SKILL_NAME="$skill_name" yq -r '.skills[strenv(SKILL_NAME)].sourceUrl // ""' "$lock_file") || return 1
    lock_skill_path=$(SKILL_NAME="$skill_name" yq -r '.skills[strenv(SKILL_NAME)].skillPath // ""' "$lock_file") || return 1
    lock_skill_folder_hash=$(SKILL_NAME="$skill_name" yq -r '.skills[strenv(SKILL_NAME)].skillFolderHash // ""' "$lock_file") || return 1
  fi

  if [ -n "$lock_source" ] && [ "$lock_source" != "$source" ]; then
    print_error "Agent skill $skill_name is managed by a different source: $lock_source"
    return 1
  fi

  if [ -L "$target_dir" ] || { [ -e "$target_dir" ] && [ ! -d "$target_dir" ]; }; then
    print_error "Agent skill target is not a regular directory: $target_dir"
    return 1
  fi

  if [ ! -d "$target_dir" ]; then
    action=install
    content_changed=true
  else
    if diff -qr "$stage_dir" "$target_dir" >/dev/null 2>&1; then
      action=current
    else
      diff_status=$?
      if [ "$diff_status" -ne 1 ]; then
        print_error "Failed to compare agent skill $skill_name with its installed version."
        return 1
      fi
      action=update
      content_changed=true
    fi
  fi

  if [ "$lock_source" != "$source" ] ||
    [ "$lock_source_type" != "$source_type" ] ||
    [ "$lock_source_url" != "$source_url" ] ||
    [ "$lock_skill_path" != "$skill_path" ] ||
    [ "$lock_skill_folder_hash" != "$skill_folder_hash" ]; then
    lock_changed=true
  fi

  if [ "$DRY_RUN" = true ]; then
    lock_probe_parent="$agents_dir"
    while [ ! -d "$lock_probe_parent" ]; do
      if [ -e "$lock_probe_parent" ]; then
        print_error "Agent skill lock destination is not a directory: $lock_probe_parent"
        return 1
      fi
      parent_dir=$(dirname "$lock_probe_parent") || return 1
      if [ "$parent_dir" = "$lock_probe_parent" ]; then
        print_error "No writable parent found for the agent skill lock: $lock_file"
        return 1
      fi
      lock_probe_parent="$parent_dir"
    done
    lock_probe_dir=$(mktemp -d "${lock_probe_parent}/.agent-skill-lock.XXXXXX") || {
      print_error "Agent skill lock destination is not writable: $lock_probe_parent"
      return 1
    }
    dry_run_lock_file="${lock_probe_dir}/.skill-lock.json"
    if [ -f "$lock_file" ]; then
      cp "$lock_file" "$dry_run_lock_file" || return 1
    fi
    update_agent_skill_lock \
      "$skill_name" "$source" "$source_type" "$source_url" \
      "$skill_path" "$skill_folder_hash" "$content_changed" \
      "$dry_run_lock_file" || return 1

    if ! mv "$stage_dir" "${stage_dir}.validated"; then
      print_error "Agent skill destination does not support staging moves: $stage_parent"
      return 1
    fi
    stage_dir="${stage_dir}.validated"

    case "$action" in
      install) print_default "Would install agent skill $skill_name." ;;
      update) print_default "Would update agent skill $skill_name." ;;
      current)
        if [ "$lock_changed" = true ]; then
          print_default "Would update lock metadata for agent skill $skill_name."
        else
          print_default "Agent skill $skill_name is already up to date."
        fi
        ;;
    esac
    return 0
  fi

  if [ "$action" = current ]; then
    if [ "$lock_changed" = true ]; then
      print_default "Updating lock metadata for agent skill $skill_name."
      update_agent_skill_lock \
        "$skill_name" "$source" "$source_type" "$source_url" \
        "$skill_path" "$skill_folder_hash" false || return 1
    else
      print_default "Agent skill $skill_name is already up to date."
    fi
    committed=true
    return 0
  fi

  # Keep the old version until both activation and lock update succeed.
  if [ -d "$target_dir" ]; then
    backup_dir=$(mktemp -d "${skills_dir}/.${skill_name}.backup.XXXXXX") || return 1
    rmdir "$backup_dir" || return 1
    mv "$target_dir" "$backup_dir" || return 1
  fi

  if ! mv "$stage_dir" "$target_dir"; then
    return 1
  fi
  activated=true

  if ! update_agent_skill_lock \
    "$skill_name" "$source" "$source_type" "$source_url" \
    "$skill_path" "$skill_folder_hash" "$content_changed"; then
    return 1
  fi

  committed=true
  if [ "$action" = install ]; then
    print_default "Installed agent skill $skill_name."
  else
    print_default "Updated agent skill $skill_name."
  fi
)

# Clone one repository, resolve its requested skills, and sync each one.
function sync_agent_skill_repo() (
  local repo_url="$1"
  shift
  local requested_paths=("$@")
  local source_type=github
  local source="${repo_url#https://github.com/}"
  local temp_dir
  local repo_dir
  local discovered_file
  local requested_path
  local skill_path
  local skill_paths=()
  local skill_names=()
  local seen_skill_names="|"
  local skill_name
  local skill_index

  source="${source%.git}"

  if [ "$source" = "$repo_url" ] || [ -z "$source" ]; then
    print_error "Unsupported agent skill repository URL: $repo_url"
    return 1
  fi

  temp_dir=$(mktemp -d) || return 1
  trap 'rm -rf "$temp_dir"' EXIT
  repo_dir="${temp_dir}/repo"
  discovered_file="${temp_dir}/skills"

  # Dry-run still clones so discovery, archives, and hashes are fully validated.
  if [ "$VERBOSE" = true ] || [ "$DRY_RUN" = true ]; then
    print_default "+ git clone --depth 1 $repo_url $repo_dir"
  fi
  if ! git clone --depth 1 "$repo_url" "$repo_dir"; then
    print_error "Failed to clone agent skill repository: $repo_url"
    return 1
  fi

  # No explicit paths means every discovered skill in the repository.
  if [ "${#requested_paths[@]}" -eq 0 ]; then
    if ! discover_agent_skills "$repo_dir" > "$discovered_file"; then
      print_error "Failed to discover agent skills in $repo_url"
      return 1
    fi
    while IFS= read -r skill_path || [ -n "$skill_path" ]; do
      [ -n "$skill_path" ] && skill_paths+=("$skill_path")
    done < "$discovered_file"
  else
    for requested_path in "${requested_paths[@]}"; do
      requested_path="${requested_path%/}"
      requested_path="${requested_path#./}"
      if [ "$requested_path" = "SKILL.md" ] || [[ "$requested_path" == */SKILL.md ]]; then
        skill_path="$requested_path"
      else
        skill_path="${requested_path}/SKILL.md"
      fi
      skill_paths+=("$skill_path")
    done
  fi

  if [ "${#skill_paths[@]}" -eq 0 ]; then
    print_error "No agent skills found in $repo_url"
    return 1
  fi

  for skill_path in "${skill_paths[@]}"; do
    case "/$skill_path/" in
      */../*|*/./*|*//* )
        print_error "Invalid agent skill path: $skill_path"
        return 1
        ;;
    esac
    if [ ! -f "${repo_dir}/${skill_path}" ]; then
      print_error "Agent skill path does not exist: ${repo_url}|${skill_path}"
      return 1
    fi
    skill_name=$(read_agent_skill_name "${repo_dir}/${skill_path}") || return 1
    case "$skill_name" in
      ''|*[!A-Za-z0-9._-]*)
        print_error "Invalid agent skill name: $skill_name"
        return 1
        ;;
    esac
    case "$seen_skill_names" in
      *"|${skill_name}|"*)
        print_error "Duplicate agent skill name in $repo_url: $skill_name"
        return 1
        ;;
    esac
    seen_skill_names="${seen_skill_names}${skill_name}|"
    skill_names+=("$skill_name")
  done

  for ((skill_index = 0; skill_index < ${#skill_paths[@]}; skill_index++)); do
    skill_path="${skill_paths[$skill_index]}"
    skill_name="${skill_names[$skill_index]}"
    if ! sync_agent_skill \
      "$repo_dir" "$source" "$source_type" "$repo_url" "$skill_path" "$skill_name"; then
      return 1
    fi
  done
)

# Read the repository list and coordinate all configured skill installations.
function install_agent_skills() {
  local skills_file="${CONFIG_DIR}/agents/skills.list"
  local entry
  local fields=()
  local repo_url
  local skill_paths=()

  if ! command -v yq >/dev/null 2>&1; then
    print_error "yq is required to manage agent skill installations."
    return 1
  fi
  if [ ! -f "$skills_file" ]; then
    print_error "Agent skill repository list not found: $skills_file"
    return 1
  fi

  while IFS= read -r entry || [ -n "$entry" ]; do
    entry="${entry%$'\r'}"
    case "$entry" in
      ''|'#'*) continue ;;
    esac

    fields=()
    IFS='|' read -r -a fields <<< "$entry"
    repo_url="${fields[0]}"
    skill_paths=("${fields[@]:1}")

    if ! sync_agent_skill_repo "$repo_url" "${skill_paths[@]}"; then
      return 1
    fi
  done < "$skills_file"
}


function main() {
  setup_agent_configs
  install_agent_skills
}

main "$@"
