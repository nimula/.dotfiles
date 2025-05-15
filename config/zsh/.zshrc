# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Start configuration added by Zim install {{{
#
# User configuration sourced by interactive shells
#

# -----------------
# Zsh configuration
# -----------------

#
# History
#

# Remove older command from the history if a duplicate is to be added.
setopt HIST_IGNORE_ALL_DUPS

#
# Input/output
#

# Set editor default keymap to emacs (`-e`) or vi (`-v`)
bindkey -e

# Prompt for spelling correction of commands.
#setopt CORRECT

# Customize spelling correction prompt.
#SPROMPT='zsh: correct %F{red}%R%f to %F{green}%r%f [nyae]? '

# Remove path separator from WORDCHARS.
WORDCHARS=${WORDCHARS//[\/]}

# -----------------
# Zim configuration
# -----------------

# Use degit instead of git as the default tool to install and update modules.
#zstyle ':zim:zmodule' use 'degit'

# --------------------
# Module configuration
# --------------------

#
# git
#

# Set a custom prefix for the generated aliases. The default prefix is 'G'.
#zstyle ':zim:git' aliases-prefix 'g'

#
# input
#

# Append `../` to your input for each `.` you type after an initial `..`
#zstyle ':zim:input' double-dot-expand yes

#
# termtitle
#

# Set a custom terminal title format using prompt expansion escape sequences.
# See http://zsh.sourceforge.net/Doc/Release/Prompt-Expansion.html#Simple-Prompt-Escapes
# If none is provided, the default '%n@%m: %~' is used.
#zstyle ':zim:termtitle' format '%1~'


#
# zsh-autosuggestions
#

# Disable automatic widget re-binding on each precmd. This can be set when
# zsh-users/zsh-autosuggestions is the last module in your ~/.zimrc.
ZSH_AUTOSUGGEST_MANUAL_REBIND=1

# Customize the style that the suggestions are shown with.
# See https://github.com/zsh-users/zsh-autosuggestions/blob/master/README.md#suggestion-highlight-style
#ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=242'

#
# zsh-syntax-highlighting
#

# Set what highlighters will be used.
# See https://github.com/zsh-users/zsh-syntax-highlighting/blob/master/docs/highlighters.md
ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets)

# Customize the main highlighter styles.
# See https://github.com/zsh-users/zsh-syntax-highlighting/blob/master/docs/highlighters/main.md#how-to-tweak-it
#typeset -A ZSH_HIGHLIGHT_STYLES
#ZSH_HIGHLIGHT_STYLES[comment]='fg=242'

# ------------------
# Initialize modules
# ------------------

ZIM_HOME=${ZDOTDIR:-${HOME}}/.zim
# Download zimfw plugin manager if missing.
if [[ ! -e ${ZIM_HOME}/zimfw.zsh ]]; then
  if (( ${+commands[curl]} )); then
    curl -fsSL --create-dirs -o ${ZIM_HOME}/zimfw.zsh \
        https://github.com/zimfw/zimfw/releases/latest/download/zimfw.zsh
  else
    mkdir -p ${ZIM_HOME} && wget -nv -O ${ZIM_HOME}/zimfw.zsh \
        https://github.com/zimfw/zimfw/releases/latest/download/zimfw.zsh
  fi
fi
# Install missing modules, and update ${ZIM_HOME}/init.zsh if missing or outdated.
if [[ ! ${ZIM_HOME}/init.zsh -nt ${ZIM_CONFIG_FILE:-${ZDOTDIR:-${HOME}}/.zimrc} ]]; then
  source ${ZIM_HOME}/zimfw.zsh init
fi
# Initialize modules.
source ${ZIM_HOME}/init.zsh

# ------------------------------
# Post-init module configuration
# ------------------------------

#
# zsh-history-substring-search
#

zmodload -F zsh/terminfo +p:terminfo
# Bind ^[[A/^[[B manually so up/down works both before and after zle-line-init
for key ('^[[A' '^P' ${terminfo[kcuu1]}) bindkey ${key} history-substring-search-up
for key ('^[[B' '^N' ${terminfo[kcud1]}) bindkey ${key} history-substring-search-down
for key ('k') bindkey -M vicmd ${key} history-substring-search-up
for key ('j') bindkey -M vicmd ${key} history-substring-search-down
unset key
# }}} End configuration added by Zim install

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# ------------------
# User configuration
# ------------------
export HISTFILE=~/.zsh_history
export HISTFILESIZE=50000
export HISTSIZE=50000
export SAVEHIST=10000
export HISTORY_IGNORE="([bf]g *|cd|l[alsm.]#( *)#|less *|pwd|ps|exit|git st#( *)#|git d[bw]|man|run-help|)"

setopt INC_APPEND_HISTORY
setopt EXTENDED_HISTORY
setopt HIST_REDUCE_BLANKS
setopt HIST_IGNORE_SPACE
setopt CORRECT_ALL
setopt AUTO_REMOVE_SLASH

# Specify characters among special characters to be treated as "word" boundaries
WORDCHARS="$WORDCHARS*?.-_[]~&;!#$%^(){}<>"

# Make terminal command navigation sane again
bindkey "^[[1;5C" forward-word                # [Ctrl-right] - forward one word
bindkey "^[[1;5D" backward-word               # [Ctrl-left] - backward one word
bindkey '^[^[[C' forward-word                 # [Ctrl-right] - forward one word
bindkey '^[^[[D' backward-word                # [Ctrl-left] - backward one word
bindkey '^[[1;3D' beginning-of-line           # [Alt-left] - beginning of line
bindkey '^[[1;3C' end-of-line                 # [Alt-right] - end of line
bindkey '^[[5D' beginning-of-line             # [Alt-left] - beginning of line
bindkey '^[[5C' end-of-line                   # [Alt-right] - end of line
bindkey '^?' backward-delete-char             # [Backspace] - delete backward
if [[ "${terminfo[kdch1]}" != "" ]]; then
  bindkey "${terminfo[kdch1]}" delete-char    # [Delete] - delete forward
else
  bindkey "^[[3~" delete-char                 # [Delete] - delete forward
  bindkey "^[3;5~" delete-char
  bindkey "\e[3~" delete-char
fi
bindkey "^A" vi-beginning-of-line
bindkey -M viins "^F" vi-forward-word         # [Ctrl-f] - move to next word
bindkey -M viins "^E" vi-add-eol              # [Ctrl-e] - move to end of line
bindkey "^J" history-beginning-search-forward
bindkey "^K" history-beginning-search-backward

# You may need to manually set your language environment
# export LANG=en_US.UTF-8
export LANG=zh_TW.UTF-8
export LC_TIME=C

# Preferred editor for local and remote sessions
# if [[ -n $SSH_CONNECTION ]]; then
#   export EDITOR='vim'
# else
#   export EDITOR='mvim'
# fi

# Compilation flags
# export ARCHFLAGS="-arch x86_64"

# ssh
# export SSH_KEY_PATH="~/.ssh/rsa_id"

alias l.='ls -d .*'
alias l='ls -CF'
alias la='ls -Al'
alias ll='ls -lF'

if ls --color > /dev/null 2>&1; then # GNU `ls`
  alias ls='ls --color=always'
  alias lm='ls -alF | less -R'
else
  alias ls='ls -G'
  alias lm='CLICOLOR_FORCE=1 ls -AGlF | more -R'
fi

# update_ssh_auth_sock: Update SSH_AUTH_SOCK in tmux
#   ------------------------------------------
if [ -n "${TMUX}" ]; then
  # Update the SSH_AUTH_SOCK of the existing shell
  function update_ssh_auth_sock() {
    NEWVAL=$(tmux show-env -s | grep '^SSH_')
    if [ -n "${NEWVAL}" ]; then
      eval ${NEWVAL}
    fi
  }

  # Convert to a widget
  zle -N update_ssh_auth_sock

  # Shortcut key assignment
  bindkey "^[s" update_ssh_auth_sock
  alias update_repo='update_ssh_auth_sock; repo sync -d -c -q --jobs=24 --no-tags'
fi

#  man: Colored man pages
#   ------------------------------------------
function man() {
  env LESS_TERMCAP_mb=$'\E[01;31m' \
  LESS_TERMCAP_md=$'\E[01;38;5;74m' \
  LESS_TERMCAP_me=$'\E[0m' \
  LESS_TERMCAP_se=$'\E[0m' \
  LESS_TERMCAP_so=$'\E[38;5;246m' \
  LESS_TERMCAP_ue=$'\E[0m' \
  LESS_TERMCAP_us=$'\E[04;38;5;146m' \
  man "$@"
}

#   mans:   Search manpage given in argument '1' for term given in argument
#           '2' (case insensitive)
#           displays paginated result with colored search terms and two
#           lines surrounding each hit.
#           Example: mans mplayer codec
#   --------------------------------------------------------------------
function mans () {
  man $1 | grep -iC2 --color=always $2 | more -R
}

#   lr:  Full Recursive Directory Listing
#   ------------------------------------------
function lr() {
  /bin/ls -R |
  grep ':$' |
  sed -e 's/:$//' \
  -e 's/[^-][^\/]*\//–/g' \
  -e 's/^/ /' \
  -e 's/-/|/' |
  more -R
}
