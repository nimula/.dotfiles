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

## Git worktrees (Linux and macOS)

`git-wt` requires Zsh and Git with relative worktree path support. The installer
links it into `~/.local/bin`. To enable automatic directory changes, add this
to your Bash or Zsh configuration (after completion initialization in Zsh):

```shell
source <(git-wt shellenv)
```

Both `git wt` and `git-wt` then change directory after a successful `init`,
`switch` (including `sw`, `checkout`, and `co`), or `create`. Other Git commands
are forwarded unchanged. Tab completion is provided for `git-wt` commands,
branches, create bases, and removal targets/options; Git's own completion is
left unchanged.

```shell
# Clone into a new container with a bare .git and an initial worktree.
git wt init https://github.com/example/project.git project

git wt create feature/login
git wt sw main
git wt list
git wt rm feature/login
git wt rm 'review-*'
git wt prune
```

Worktrees live under `project/<branch>`; a branch such as `feature/login`
uses `project/feature/login`. `switch` reuses an existing worktree or creates
one for a local branch or an `origin` branch. It does not fetch automatically.
`create <branch> [base]` creates a new branch, defaulting to `origin/HEAD`, then
local `main` or `master`.

To migrate an existing repository, run `git wt init` without arguments from
its root. Migration preserves the working files and index, including staged,
unstaged, untracked, and ignored files. Existing linked worktrees, initialized
submodules, sparse checkout, split indexes, and in-progress Git operations are
not supported. Migration rejects an existing shared index or an enabled
`core.splitIndex` setting before moving repository data.
On a migration failure, follow the reported recovery steps before retrying;
partially moved data is retained rather than automatically discarded.

Removal accepts a branch, a detached HEAD SHA, or a quoted glob. Patterns and
SHAs shared by multiple detached worktrees require confirmation. `-s` disables
prompts but does not grant approval; `-f` skips confirmation and permits dirty
worktree removal, and `-f -f` also permits locked worktrees. Branches are kept.
The bare container, the main worktree of a regular repository, and the current
worktree are protected.

Automatic directory changes require the shell functions above. Calls through
`command git wt ...` or `git -C ... wt ...` run as external processes and do not
change the calling shell's directory. Worktree paths containing newlines are
not supported.

## Codex agents

Linux/macOS agent setup uses Bash 3.2+, awk, standard Unix utilities (including
od), and an existing standalone **mikefarah/yq v4** with TOML support.
The agent scripts do not download, install or upgrade tools. No Python, Ruby,
Node, jq, Taplo or running Codex installation is required. Windows installation
behavior is unchanged.

Install only the Codex configuration from the repository root:

```shell
bash scripts/setup-codex.sh --dry-run
bash scripts/setup-codex.sh

# Use an existing yq outside PATH.
DOTFILES_YQ=/path/to/yq bash scripts/setup-codex.sh
```

The destination is `$CODEX_HOME` when set, otherwise `~/.codex`.
Use `--codex-home PATH` or `--source-dir PATH` for a different destination or
source. Dry-run builds the same temporary candidates without writing the
destination. Normal Unix setup then runs the existing skills installer; that
installer requires yq on PATH and network access to the repositories in
`config/agents/skills.list`. Codex configuration setup itself needs no network.

The installer:

* Writes UTF-8 without a BOM, converting existing UTF-8 BOM or BOM-marked
  UTF-16LE/BE Markdown and configuration before merging. Invalid encoding is
  reported before writing. Existing LF/CRLF newline styles are retained.
* Keeps consecutive `@PATH` lines at the beginning of `AGENTS.md` as literal text,
  then writes a managed block containing, in order, the full contents of
  `AGENT-POLICIES.md`, `ENGINEERING-GUIDELINES.md` and
  `codex/ORCHESTRATE.md`. Each document is followed by one blank line.
  The `<!-- dotfiles:agents:start -->` and
  `<!-- dotfiles:agents:end -->` markers each have one blank line before
  and after them.
* Appends the remaining original text, filtering out the old markers and
  enclosed instructions only when there is exactly one complete, correctly
  ordered block. Missing, duplicate, reversed or malformed markers do not
  stop installation: the original text and markers remain, and a warning asks
  the user to review and remove duplicate old instructions manually.
* Locally updates the six main settings and the two managed agents settings
  from `config/agents/codex/config.toml`. Ordinary declarations retain their
  existing comments and unrelated text. A root `agents = {...}` declaration
  is converted to a separate `[agents]` table after the root settings,
  preserving all agents values and moving only that declaration's trailing
  comment to the new table header. This normalization happens before inserting
  or updating the required settings. yq reads and writes TOML directly;
  converted agents text stays in memory, with no JSON or separate agents
  intermediate file. The remainder of the configuration is preserved as text.
  Managed declarations
  use bare keys and an explicit table, or the root inline agents form.
* Discovers `*.toml` role files directly under `config/agents/codex/agents/`
  and copies their complete contents unchanged to the destination's `agents/`
  directory. Destination role files absent from the source remain untouched.
* Finishes all temporary candidates before writing, then overwrites changed
  target files in place. Existing inodes, permissions and filesystem birth
  times are retained; new files use mode 600. Unchanged files are not written.
  There are no role hashes, ownership state, backups, install locks or rollback
  transactions. An interrupted write can leave partial content. Symbolic links
  are followed when reading or writing; the links themselves are retained.

The main session uses GPT-6.1 Sol / high. Explorer uses GPT-6 Luna / high,
researcher GPT-6 Luna / medium, worker GPT-6.1 Sol / medium, and architect
GPT-6 Astra / high. Existing shared policies retain the six-failure starting
budget and one evidence-based extension of up to two runs.

Start a new Codex session after installation to load the configuration.
