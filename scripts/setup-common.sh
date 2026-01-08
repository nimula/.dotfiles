#!/usr/bin/env bash
# Author : nimula+github@gmail.com
#
source "$(dirname "$0")/utils.sh"
set -Eeuo pipefail

PLATFORM=$(uname);

function chsh_zsh() {
  case "$PLATFORM" in
    Linux|Darwin)
      ;;
    *)
      print_info "Not a supported platform (Linux/macOS). Skipping shell check."
      return 0
      ;;
  esac

  # Check for zsh path
  ZSH_PATH=$(command -v zsh 2>/dev/null)
  if [ -z "$ZSH_PATH" ]; then
    print_warning "zsh not found in PATH. Please install zsh first."
    return 0
  fi

  # Get current user and fallback-safe shell
  CURRENT_USER=$(whoami)

  if command -v getent >/dev/null 2>&1; then
    CURRENT_SHELL=$(getent passwd "$CURRENT_USER" | cut -d: -f7)
  else
    CURRENT_SHELL=$(grep "^$CURRENT_USER:" /etc/passwd | cut -d: -f7)
  fi

  if [[ "$CURRENT_SHELL" != "$ZSH_PATH" ]]; then
    print_info "Changing default shell to zsh for user $CURRENT_USER..."
    run chsh -s "$ZSH_PATH"
  fi
}

function install_rsubl() {
  if [ "$REMOTE_CONTAINERS" = true ]; then
    print_default "Skip rsubl installation in remote container"
    return 0
  fi

  # Test to see if rsubl is installed.
  if command -v rsubl >/dev/null 2>&1; then
    return 0
  fi

  SRC="https://raw.github.com/aurora/rmate/master/rmate"
  DEST="/usr/local/bin"
  SUDO="sudo"

  # Fallback to ~/.local/bin if /usr/local/bin is not writable or missing
  if [ ! -d "$DEST" ]; then
    DEST="$HOME/.local/bin"
    SUDO=""
    run mkdir -p "$DEST"
  fi

  print_default "Installing rmate to $DEST/rsubl"

  if [ -n "$SUDO" ]; then
    run sudo curl -fsSL "$SRC" -o "$DEST/rsubl"
    run sudo chmod a+x "$DEST/rsubl"
  else
    run curl -fsSL "$SRC" -o "$DEST/rsubl"
    run chmod a+x "$DEST/rsubl"
  fi
}

function setup_ssh_default_config() {
  include_path="${CONFIG_DIR}/ssh/_commons.conf"
  chmod 600 "$include_path"

  if [ "$REMOTE_CONTAINERS" = true ]; then
    print_default "Skip SSH default config installation in remote container"
    return 0
  fi

  ssh_config="${HOME}/.ssh/config"

  # Check if config file exists
  if [ ! -f "$ssh_config" ]; then
    print_default "Creating default SSH config file: $ssh_config"
    run install -d -m 700 "${HOME}/.ssh"
    run touch "$ssh_config"
  fi

  nodes_dir="${HOME}/.ssh/conf.d/nodes"
  os_name=$(uname | tr '[:upper:]' '[:lower:]')
  host_name=$(hostname | cut -d . -f 1 | tr '[:upper:]' '[:lower:]')
  node_conf="${nodes_dir}/${os_name}.${host_name}.conf"
  include_line="Include conf.d/nodes/${os_name}.${host_name}.conf"

  run install -d -m 700 \
    "${HOME}/.ssh/conf.d/cm" \
    "${HOME}/.ssh/conf.d/envs" \
    "$nodes_dir" \
    "${HOME}/.ssh/keys"

  run ln -fnsv "$include_path" "${nodes_dir}/_commons.conf"

  if [ ! -f "$node_conf" ]; then
    run cp -f "${CONFIG_DIR}/ssh/template.conf" "$node_conf"
    run chmod 600 "$node_conf"
  fi

  # Check if include line already exists
  if ! grep -qF "$include_line" "$ssh_config"; then
    print_default "Added include line to SSH config file"
    temp_file=$(mktemp)
    run bash -c "printf \"%s\n\n\" \"$include_line\" > \"$temp_file\" && cat \"$ssh_config\" >> \"$temp_file\""
    run cp -f "$temp_file" "$ssh_config"
    run chmod 600 "$ssh_config"
    rm $temp_file
  fi
}

function setup_config_links() {
  print_default "Linked config files to home directory."
  # Symlink zsh dotfiles.
  run ln -fnsv "$CONFIG_DIR/zsh/.zshrc" "$HOME"
  run ln -fnsv "$CONFIG_DIR/zsh/.zprofile" "$HOME"
  run ln -fnsv "$CONFIG_DIR/zsh/.zimrc" "$HOME"
  run ln -fnsv "$CONFIG_DIR/zsh/.p10k.zsh" "$HOME"

  # Symlink other dotfiles.
  run ln -fnsv "$CONFIG_DIR/vim/.vimrc" "$HOME"
  run ln -fnsv "$CONFIG_DIR/vim" "$HOME/.vim"
  run ln -fnsv "$CONFIG_DIR/git/.gitignore.global" "$HOME"

  if [[ "$PLATFORM" == 'Linux' ]]; then
    run ln -fnsv "$CONFIG_DIR/tmux/.tmux.conf" "$HOME"
  fi

  # Link static gitconfig.
  run git config --global include.path "~/${CONFIG_DIR#$HOME/}/git/.gitconfig.static"
  run git config --global init.templatedir "~/${CONFIG_DIR#$HOME/}/git/git-templates"
}

function setup_bin_links() {
  print_default "Linked bin files to home directory."
  # Ensure the local bin directory exists
  if [[ ! -d "$HOME/.local/bin" ]]; then
    print_default "Creating local bin directory: $HOME/.local/bin"
    run mkdir -p "$HOME/.local/bin"
  fi
  # Symlink bin files.
  run ln -fnsv "$BIN_DIR/git-pr" "$HOME/.local/bin/git-pr"
  run ln -fnsv "$BIN_DIR/print_utils.sh" "$HOME/.local/bin/print_utils.sh"
}

function install_zim() {
  export ZIM_HOME=${ZDOTDIR:-${HOME}}/.zim
  # Install zim if it isn't already present
  if [[ ! -d "$ZIM_HOME" ]]; then
    print_default "Install zim..."
    curl -fsSL https://raw.githubusercontent.com/zimfw/install/master/install.zsh | zsh
  fi
}

function setup_zim() {
  print_default "Setting up zim..."
  # Update zim module.
  run zsh "$ZIM_HOME/zimfw.zsh" install
  run zsh "$ZIM_HOME/zimfw.zsh" update
  run zsh "$ZIM_HOME/zimfw.zsh" upgrade
  run zsh "$ZIM_HOME/zimfw.zsh" compile

  set_skip_global_compinit
}

function set_skip_global_compinit() {
  ZSHENV="$HOME/.zshenv"

  if [ ! -f "$ZSHENV" ]; then
    print_default "Creating $ZSHENV"
    run touch "$ZSHENV"
  fi

  if ! grep -q "skip_global_compinit=1" "$ZSHENV"; then
    run bash -c "printf '\nskip_global_compinit=1\n' >> \"$ZSHENV\""
  fi
}

function main() {
  setup_ssh_default_config
  install_rsubl
  install_zim
  setup_config_links
  setup_zim
  setup_bin_links
}

main "$@"
