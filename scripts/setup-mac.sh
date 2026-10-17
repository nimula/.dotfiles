#!/usr/bin/env bash
# Author : nimula+github@gmail.com
#
[ "$(uname)" != "Darwin" ] && exit
source "$(dirname "$0")/utils.sh"
set -Eeuo pipefail

print_default "Setting up macOS..."
# Finder
run defaults write com.apple.finder AppleShowAllFiles -bool true

# Menubar
run defaults -currentHost write com.apple.controlcenter.plist BatteryShowPercentage -bool true

# Disable .DS_Store on network disks
run defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true

run killall Dock
run killall Finder
run killall SystemUIServer

# Install Codex.
run bash -c "curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh"

# Install Herdr.
run bash -c "curl -fsSL https://herdr.dev/install.sh | sh"
