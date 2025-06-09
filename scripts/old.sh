#!/usr/bin/env bash
# Author : nimula+github@gmail.com
#
source "./scripts/common.sh"
trap cleanup SIGINT SIGTERM ERR EXIT

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  tput cnorm # enable cursor
  # script cleanup here
  unset CURR_DIR REPO_DIR
}

# Get the platform of the current machine.
PLATFORM=$(uname);
DRY_RUN=true
VERBOSE=true
DEBUG=false
# CURR_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
NL="\n"
if [[ "${PLATFORM}" == "Darwin" ]]; then
    NL=$'\\\n'
fi

function install_zsh() {
  # Test to see if zsh is installed.
  if [[ -z "$(command -v zsh)" ]]; then
    # If zsh isn't installed, get the platform of the current machine and
    # install zsh with the appropriate package manager.
    if [[ "${PLATFORM}" == 'Linux' ]]; then
      if [[ -f /etc/redhat-release ]]; then
        sudo yum install zsh
      elif [[ -f /etc/debian_version ]]; then
        sudo apt-get install zsh
      fi
    elif [[ "${PLATFORM}" == 'Darwin' ]]; then
      brew install zsh
    fi
  fi

  if [[ "${PLATFORM}" == 'Linux' || "${PLATFORM}" == 'Darwin' ]]; then
    # Set the default shell to zsh if it isn't currently set to zsh.
    if [[ "$SHELL" != "$(command -v zsh)" ]]; then
      chsh -s "$(command -v zsh)"
    fi
  fi

  # Upgrading Bash on macOS
  if [[ "${PLATFORM}" == 'Darwin' ]]; then
      brew install bash
  fi
  # Install zim if it isn't already present
  if [[ ! -d "${HOME}/.zim/" ]]; then
    echo "Install zim"
    curl -fsSL https://raw.githubusercontent.com/zimfw/install/master/install.zsh | zsh
  fi
}

function install_nerd_font() {
  if [[ "${PLATFORM}" == 'Darwin' ]]; then
    brew tap homebrew/cask-fonts
    brew install --cask font-sauce-code-pro-nerd-font \
    font-noto-sans font-noto-sans-cjk font-noto-serif font-noto-serif-cjk
  fi
}

function install_tmux() {
  if [[ "${PLATFORM}" == 'Linux' ]]; then
    if [[ -z "$(command -v tmux)" ]]; then
      # If tmux isn't installed, install it with the appropriate package manager.
      if [[ -f /etc/redhat-release ]]; then
        sudo yum install tmux
      elif [[ -f /etc/debian_version ]]; then
        sudo apt-get install tmux
      fi
    fi
    # Clone Tmux Plugin Manager if it isn't already present.
    if [[ ! -d "${HOME}/.tmux/plugins/tpm/" ]]; then
      git clone https://github.com/tmux-plugins/tpm "${HOME}/.tmux/plugins/tpm"
    fi
  fi
}

function install_rsubl() {
	# Test to see if rsubl is installed.
  if [ -z "$(command -v rsubl)" ]; then
    DEST="/usr/local/bin"
    SUDO="sudo"

    # If '/usr/local/bin' is not available, use '.local/bin' instead.
    if [ ! -d "$DEST" ]; then
      DEST="${HOME}/.local/bin"
      SUDO=""
      mkdir -p "$DEST"
    fi

    $SUDO curl -fsSL https://raw.github.com/aurora/rmate/master/rmate \
      -o "$DEST/rsubl"
  	$SUDO chmod a+x "${DEST}/rsubl"
	fi
}

function insert_ssh_config() {
  if ! grep -q "Include ${CURR_DIR}/ssh/config" "${HOME}/.ssh/config"; then
    sed -i -- "1 i\\
Include ${CURR_DIR}/ssh/config${NL}
" "${HOME}/.ssh/config"
  fi
}

function set_skip_global_compinit() {
  if ! grep -q "skip_global_compinit=1" "${HOME}/.zshenv"; then
    sed -i -- "$ a\\
${NL}skip_global_compinit=1
" "${HOME}/.zshenv"
  fi
}

function setup-links() {
  # Symlink zsh dotfiles.
  ln -fnsv "${CURR_DIR}/zsh/.zshrc" "${HOME}"
  ln -fnsv "${CURR_DIR}/zsh/.zprofile" "${HOME}"
  ln -fnsv "${CURR_DIR}/zsh/.zimrc" "${HOME}"
  ln -fnsv "${CURR_DIR}/zsh/.p10k.zsh" "${HOME}"

  # Symlink other dotfiles.
  ln -fnsv "${CURR_DIR}/vim/.vimrc" "${HOME}"
  ln -fnsv "${CURR_DIR}/vim" "${HOME}/.vim"
  ln -fnsv "${CURR_DIR}/git/.gitignore.global" "${HOME}"
  if [[ "${PLATFORM}" == 'Linux' ]]; then
    ln -fnsv "${CURR_DIR}/tmux/.tmux.conf" "${HOME}"
  fi

  # Link static gitconfig.
  git config --global include.path "${CURR_DIR}/git/.gitconfig.static"
}

function setup-zim() {
  # Update zim module.
  zsh ~/.zim/zimfw.zsh install
  zsh ~/.zim/zimfw.zsh update
  zsh ~/.zim/zimfw.zsh upgrade
  zsh ~/.zim/zimfw.zsh compile

  set_skip_global_compinit
}

function main_old() {
  # Install zsh (if not available) and zim.
  install_zsh
  # Install sauce code pro nerd font and Noto fonts.
  install_nerd_font
  # Install tmux (if not available) and tmux plugin manager.
  install_tmux
  # Install rmate as rsubl.
  install_rsubl
  # Include preset ssh configurations.
  insert_ssh_config
}

command_name=$(basename "${BASH_SOURCE[0]}")
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
