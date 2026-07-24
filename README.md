# dotfiles

Personal environment configs for shell, Git, Claude Code, Codex, status line,
and editor/TUI tools. The installer deploys tracked configuration with
symlinks and keeps secrets out of Git.

## Install

Run as a normal user on x86_64 Ubuntu/Debian or RHEL, Rocky Linux, or
AlmaLinux 8+ (glibc 2.28+). The account must have `sudo` access, but do not run
the installer itself as root or with `sudo`. Network access is required for
distribution packages, toolchains, release assets, plugins, and the skills
checkout:

```bash
./install.sh
```

This is the single installation entry point. It uses `sudo` only for distro
package and repository operations (`apt`, `dnf`, or RHEL repository
enablement). Apart from those system prerequisites, missing language
toolchains and tools are installed in user-owned locations such as `~/.cargo`,
`~/.local`, and `~/.nvm`; compatible commands already on `PATH` are generally
retained. Node/npm are the deliberate exception: when `~/.nvm/nvm.sh` is
absent, the installer installs NVM and an NVM-managed current Node/npm even if
compatible system commands are already on `PATH`.

On Rocky Linux and AlmaLinux it enables PowerTools for version 8 or CRB for
version 9 and newer; on RHEL it enables the matching CodeReady Builder
repository. Every RHEL-family path also installs EPEL. See the complete
mandatory package and command inventory in [`TOOLS.md`](TOOLS.md).

One run installs Rust, Go, Node/npm, uv, the required CLI/TUI tools, tmux and
its plugins, and the Claude/Codex tooling before linking configuration and
validating the result. Both Yazi commands, `yazi` and `ya`, are mandatory and
are installed and validated separately.

Claude and Codex skills/hooks require `~/compute-ai-skills`. If it is absent,
the installer clones the expected `abchoudh-amd/compute-ai-skills` repository.
It fast-forwards an existing clean `main` checkout, but preserves a dirty or
non-`main` checkout with a warning. A checkout with an unexpected origin is a
required failure.

Independent phases continue after a failure so the final summary can report
everything that needs attention. A required failure produces a nonzero exit;
fix the reported issue and run `./install.sh` again.

After a successful run, review the installed Codex hooks with `/hooks`, restart
Claude Code and Codex, and open a new shell so the installed paths and shell
initializers are active. Authentication remains a manual follow-up where the
summary requests it.

## What's tracked

| Area            | Files                                                                 |
|-----------------|----------------------------------------------------------------------|
| Shell           | `shell/.bashrc`, `shell/.profile`                                     |
| Git             | `git/.gitconfig`, `git/gitignore`                                     |
| Prompt          | `config/starship.toml`                                                |
| Claude Code     | settings, status line, theme, and `claude/mcp-servers.json`           |
| Codex           | `codex/config.toml` (key read from `$LLM_GATEWAY_KEY` at runtime)     |
| Editors / TUI   | `config/nvim`, `config/fish`, `config/zellij`, `config/btop`          |
| tmux            | `tmux/.tmux.conf`, `tmux/.gitmux.conf`                                |

## Reruns, backups, and recovery

`install.sh` is idempotent: a correct symlink or compatible installed command is
left alone, while a missing or stale managed item is repaired. A no-op rerun
does not create another backup.

Before replacing an existing path, the installer moves it into a private
mode-`0700` directory named
`~/.dotfiles-backup-YYYYMMDD-HHMMSS.XXXXXX/`. The backup tree mirrors the
original absolute path, and the final summary prints its exact location.
Claude state snapshots are copies within the same tree and are forced to mode
`0600`. Backups are retained for manual recovery; restore the corresponding
mirrored path after removing the installer-created target if you need to undo
a normal configuration replacement.

Claude MCP changes are transactional. If `~/.claude.json` existed before the
run, an ordinary reconciliation failure restores its snapshot only when the
installer can prove that doing so will not overwrite unrelated state or an
unconfirmed managed-record write. If the path was initially absent, Claude
may create normal first-run metadata while adding the first MCP entry; the
installer preserves that generated baseline and restores an absent
destination only when it can prove the operation is safe. If either proof
fails, or Claude or another process changes state concurrently, the installer
does not overwrite the unexpected state. It exits nonzero and prints the
paths of the live, snapshot, displaced, or prepared recovery files that
actually exist; the destination itself may safely be absent. Close Claude
Code, inspect or merge the reported files, and rerun the installer.

## Secrets

Secret values remain in these untracked, gitignored locations:

- `secrets.env` stores environment secrets such as `LLM_GATEWAY_KEY`. It is
  linked to `~/.config/secrets.env` and sourced by the shell configuration.
- `secrets/` stores credential blobs. When present, the installer links
  `secrets/gh-hosts.yml` to `~/.config/gh/hosts.yml` and
  `secrets/claude-credentials.json` to `~/.claude/.credentials.json`.

On a first run, the installer seeds those files from usable values already on
the machine when possible; otherwise it warns so you can authenticate or fill
them in manually. It never commits them. To initialize the environment file
yourself, copy `secrets.env.example` to `secrets.env` and add the real value.

## Claude MCP servers

The tracked, non-secret
[`claude/mcp-servers.json`](claude/mcp-servers.json) manifest declares the
`jira` and `confluence` server names. The installer reconciles those two names
at Claude's global user scope, so they are available across projects. It owns
only those names: differing managed definitions are replaced, while all other
MCP servers and every non-MCP field are preserved.

Close Claude Code before running `./install.sh` so it does not write
`~/.claude.json` while the installer is reconciling these user-scope entries.

Run the installer with `CLAUDE_CONFIG_DIR` unset:

```bash
unset CLAUDE_CONFIG_DIR
./install.sh
```

The managed user-state location is always `~/.claude.json`. The installer
fails safely instead of asking the Claude CLI to mutate state in an alternate
`CLAUDE_CONFIG_DIR`.

`~/.claude.json` is mutable state owned by Claude Code, so it is deliberately
neither tracked nor symlinked. Tracking or replacing the whole file would
capture machine-specific state and overwrite unrelated data. The installer
instead uses the Claude CLI to update only the managed names; the repository's
root `.claude.json` ignore rule also guards against accidentally committing a
copied live file.

Installation validates the definitions but does not authenticate them, test
endpoint reachability, or require MCP health. Complete OAuth manually as
needed:

```bash
claude mcp login jira
claude mcp login confluence
```

> **Warning:** Never put headers, tokens, passwords, client secrets,
> environment secret values, or other credentials in
> `claude/mcp-servers.json`; it is tracked by Git.

## Not included

- ROCm or Slurm installation and cluster configuration.
- Global Cursor skill, hook, or configuration links.
- Desktop/GUI assets.
- Authentication or secret values. Existing credentials may be preserved or
  seeded, but the installer does not supply real values or perform logins.
- Claude/Codex history, sessions, databases, caches, and other mutable state.
