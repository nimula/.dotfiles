#!/usr/bin/env bash

POWERLEVEL9K_MODE='nerdfont-complete'
# POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(dir dir_writable)
# POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(status vcs)
POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(context dir dir_writable vcs vi_mode)
POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(status background_jobs history ram load time)
DEFAULT_USER=$USER

# Fall back mode for powerlevel9k when SSH-ing to server with dot-file-repo and
# powerlevel9k installed, but dot-file-repo and fonts not available on client.
if [ -z $SSH_CLIENT ]; then
    # this env variable will be available only if this .zshrc is used on client
    export LC_CLIENT_HAS_DOT_FILE_REPO=1
fi
if [ -z $LC_CLIENT_HAS_DOT_FILE_REPO ]; then
  CURR_DIR="$( cd "$( dirname "$0" )" >/dev/null || exit 1; pwd )"
   source "$CURR_DIR/powerlevel9k_settings_no_font_fallback.sh"
fi
