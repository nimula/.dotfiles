# dotfiles

My dotfiles for Linux, macOS, and Windows.

## Supported OS

* Linux
* macOS
* Windows 10/11 with Windows PowerShell 5.1 or PowerShell 7

## Linux and macOS

```shell
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/nimula/.dotfiles/master/install.sh)"
```

Skip packages installation

```shell
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/nimula/.dotfiles/master/install.sh)" -- -s -v
```

## Windows

Git for Windows must be installed before running the Windows installer. The
installer configures the current PowerShell edition, so run it once from
Windows PowerShell 5.1 and once from PowerShell 7 if both editions are used.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
  "& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/nimula/.dotfiles/master/install.ps1')))"
```

The Windows installer supports these options:

```powershell
.\install.ps1 -DryRun
.\install.ps1 -Verbose
.\install.ps1 -SkipPackageInstall
.\install.ps1 -InstallDir C:\Users\me\.dotfiles
```

Unless `-SkipPackageInstall` is specified, the installer installs the Windows
OpenSSH Client capability when the `ssh-agent` service is missing. This step
requires administrator approval and access to Windows Update. The installer
does not enable or start `ssh-agent`, and it never adds private keys.

Enable the service manually when needed:

```powershell
# Run these commands as administrator.
Set-Service ssh-agent -StartupType Manual
Start-Service ssh-agent

# Adding a key does not require administrator privileges.
ssh-add.exe $env:USERPROFILE\.ssh\id_ed25519
```

The installer does not change the system execution policy. The
`-ExecutionPolicy Bypass` argument above applies only to that installer
process.

### Windows scope

The Windows setup configures:

* A shared PowerShell profile through `$PROFILE.CurrentUserAllHosts`
* Cross-platform Git aliases and defaults
* A PowerShell implementation of the `prepare-commit-msg` hook for new Git repositories
* Windows-compatible OpenSSH client settings

It does not install or configure zsh, Bash, tmux, Homebrew, Vim, Herdr, X11,
Windows `sshd`, or private SSH keys. Git hooks from `init.templateDir` are
copied only when a repository is created or reinitialized with `git init`.
