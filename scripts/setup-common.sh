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
  if [ "$REMOTE_CONTAINERS" = true ]; then
    print_default "Skip SSH default config installation in remote container"
	  return 0
  fi

  ssh_config="${HOME}/.ssh/config"

  # Check if config file exists
  if [ ! -f "$ssh_config" ]; then
    print_default "Creating default SSH config file: $ssh_config"
    run mkdir -p "${HOME}/.ssh"
    run touch "$ssh_config"
  fi

  # Check if include line already exists
  if ! grep -q "Include ${CONFIG_DIR}/ssh/config" "$ssh_config"; then
    print_default "Added include line to SSH config file"
    temp_file=$(mktemp)
    run bash -c "printf \"Include %s/ssh/config\n\n\" \"$CONFIG_DIR\" > \"$temp_file\" && cat \"$ssh_config\" >> \"$temp_file\""
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
  run git config --global include.path "$CONFIG_DIR/git/.gitconfig.static"
}

function setup_zim() {
  export ZIM_HOME=${ZDOTDIR:-${HOME}}/.zim
  # Install zim if it isn't already present
  if [[ ! -d "$ZIM_HOME" ]]; then
    print_default "Install zim..."
    curl -fsSL https://raw.githubusercontent.com/zimfw/install/master/install.zsh | zsh
  fi

  print_default "Setting up zim..."
  # Update zim module.
  run zsh ~/.zim/zimfw.zsh install
  run zsh ~/.zim/zimfw.zsh update
  run zsh ~/.zim/zimfw.zsh upgrade
  run zsh ~/.zim/zimfw.zsh compile

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
  setup_zim
  setup_ssh_default_config
  setup_config_links
  install_rsubl
}

main "$@"
