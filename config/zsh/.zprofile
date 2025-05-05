#   -----------------------------
#   1. ENVIRONMENT SET UP
#   -----------------------------

# set PATH so it includes user's private bin directories
PATH="$HOME/bin:$HOME/.local/bin:$PATH"

case $(uname) in
  "Linux")
    ;;
  "Darwin")
    # set the number of open files to be 1024
    ulimit -S -n 1024
    if [[ -x /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    ;;
  *)
    ;;
esac

#   -----------------------------
#   2. MAKE TERMINAL BETTER
#   -----------------------------

alias cd..='cd ../'               # Go back 1 directory level (for fast typers)
alias ..='cd ../'                 # Go back 1 directory level
alias ...='cd ../../'             # Go back 2 directory levels
alias .3='cd ../../../'           # Go back 3 directory levels
alias .4='cd ../../../../'        # Go back 4 directory levels
alias .5='cd ../../../../../'     # Go back 5 directory levels
alias .6='cd ../../../../../../'  # Go back 6 directory levels

#   -------------------------------
#   3. FILE AND FOLDER MANAGEMENT
#   -------------------------------

# zipf: To create a ZIP archive of a folder
zipf () { zip -r "$1".zip "$@" ; }
# zipc: To create a clean ZIP archive for a folder
zipc () { zip -r "$1".zip "$@" -x "*.DS_Store"; }
# numFiles: Count of non-hidden files in current dir
alias numFiles='echo $(ls -1 | wc -l)'

#   extract:  Extract most know archives with one command
#   ---------------------------------------------------------
extract () {
  if [ -f $1 ]; then
    case $1 in
      *.tar.bz2)  tar xjf $1    ;;
      *.tar.gz)   tar xzf $1    ;;
      *.bz2)      bunzip2 $1    ;;
      *.rar)      unrar e $1    ;;
      *.gz)       gunzip $1     ;;
      *.tar)      tar xf $1     ;;
      *.tbz2)     tar xjf $1    ;;
      *.tgz)      tar xzf $1    ;;
      *.zip)      unzip $1      ;;
      *.Z)        uncompress $1 ;;
      *.7z)       7z x $1       ;;
      *.zst)      zstd -d $1    ;;
      *)     echo "'$1' cannot be extracted via extract()" ;;
    esac
  else
    echo "'$1' is not a valid file"
  fi
}

#   ---------------------------
#   4. SEARCHING
#   ---------------------------

alias qfind="find . -name "                 # qfind:    Quickly search for file
ff () { /usr/bin/find . -name "$@" ; }      # ff:       Find file under the current directory
ffs () { /usr/bin/find . -name "$@"'*' ; }  # ffs:      Find file whose name starts with a given string
ffe () { /usr/bin/find . -name '*'"$@" ; }  # ffe:      Find file whose name ends with a given string

#   spotlight: Search for a file using MacOS Spotlight's metadata
#   -----------------------------------------------------------
spotlight () { mdfind "kMDItemDisplayName == '$@'wc"; }

#   ---------------------------
#   5. NETWORKING
#   ---------------------------

alias myip='curl https://checkip.amazonaws.com' # myip:         Public facing IP Address
alias netCons='lsof -i'                         # netCons:      Show all open TCP/IP sockets
alias lsock='sudo lsof -i -P'                   # lsock:        Display open sockets
alias lsockU='sudo lsof -nP | grep UDP'         # lsockU:       Display only open UDP sockets
alias lsockT='sudo lsof -nP | grep TCP'         # lsockT:       Display only open TCP sockets
alias openPorts='sudo lsof -i | grep LISTEN'    # openPorts:    All listening connections
alias showBlocked='sudo ipfw list'              # showBlocked:  All ipfw rules inc/ blocked IPs

case $(uname) in
  "Linux")
    alias ipInfo0='ifconfig enp6s0f0'        # ipInfo0:      Get info on connections for en0
    alias ipInfo1='ifconfig enp6s0f1'        # ipInfo1:      Get info on connections for en1
    ;;
  "Darwin")
    alias ipInfo0='ipconfig getpacket en0'   # ipInfo0:      Get info on connections for en0
    alias ipInfo1='ipconfig getpacket en1'   # ipInfo1:      Get info on connections for en1
    alias flushDNS='dscacheutil -flushcache' # flushDNS:     Flush out the DNS Cache
    ;;
  *)
    ;;
esac

#   ii:  display useful host related information
#   -------------------------------------------------------------------
ii() {
  echo -e "\nYou are logged on ${RED}$HOST"
  echo -e "\nAdditional information:$NC " ; uname -a
  echo -e "\n${RED}Users logged on:$NC " ; w -h
  echo -e "\n${RED}Current date :$NC " ; date
  echo -e "\n${RED}Machine stats :$NC " ; uptime
  echo -e "\n${RED}Current network location :$NC " ; scselect
  echo -e "\n${RED}Public facing IP Address :$NC " ; myip
  #echo -e "\n${RED}DNS Configuration:$NC " ; scutil --dns
  echo
}

#   -----------------------------
#   6. SEPARATE AUDIO FROM VIDEO WITH FFMPEG
#   -----------------------------

separate_audio() {
  for ext in "$@"; do
    for file in *."${ext}"; do
      if [ -e "${file}" ]; then
        ffmpeg -i "$file" -y -vn -acodec copy \
          "${file%.*}".$(ffprobe "$file" 2>&1 | \
          sed -nr 's/^.*Audio:\s*(\w+)\s*.*$/\1/p');
      fi
    done
  done
}
