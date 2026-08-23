# dotfiles

Personal environment configs for shell, Git, Claude Code, Codex, global agent
runtime integration, status line, and editor/TUI tools. The installer deploys
tracked configuration with symlinks and keeps secrets out of Git.

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

One run installs Rust, Go, Node/npm, uv, the required CLI/TUI tools (including
Herdr), tmux and its plugins, and the Claude/Codex tooling before activating
the global Claude and Codex runtime content, linking configuration, and
validating the result. Both Yazi commands, `yazi` and `ya`, are mandatory and
are installed and validated separately. Cursor is neither installed nor
configured.

The shared Claude and Codex runtime content requires
`~/compute-ai-skills`. If it is absent, the installer clones the expected
`abchoudh-amd/compute-ai-skills` repository. An existing checkout must have an
accepted origin. A clean `main` checkout is updated only with
`pull --ff-only origin main`; an update failure keeps the existing checkout
with a warning, while a dirty or non-`main` checkout is preserved without an
update. A non-repository path or checkout with an unexpected origin is a
required failure. If a failed initial clone leaves partial material, the
installer moves it into the same private backup tree used for link conflicts.

Herdr is also required. A `herdr` command on `PATH` that completes a version
probe is retained. If it is missing or broken, the installer runs the official
installer exactly as follows and then requires the resulting command to be on
`PATH` and pass the same probe:

```bash
curl -fsSL https://herdr.dev/install.sh | sh
```

Independent phases continue after a failure so the final summary can report
everything that needs attention. A required failure produces a nonzero exit;
fix the reported issue and run `./install.sh` again.

After a successful run, terminate and restart Claude Code and Codex so both
reload their global runtime content and hook configuration. In Codex, review
the installed hooks with `/hooks` and complete
any trust prompt it presents. Then open a new shell so the installed paths and
shell initializers are active. The installer enables Codex hooks but does not
update trusted-hook hashes. Authentication remains a manual follow-up where
the summary requests it.

## What's tracked

| Area            | Files                                                                 |
|-----------------|----------------------------------------------------------------------|
| Shell           | `shell/.bashrc`, `shell/.profile`                                     |
| Git             | `git/.gitconfig`, `git/gitignore`                                     |
| Prompt          | `config/starship.toml`                                                |
| Herdr           | `config/herdr/config.toml` -> `~/.config/herdr/config.toml`           |
| Claude Code     | settings, status line, theme, and `claude/mcp-servers.json`           |
| Codex           | `codex/config.toml` (key read from `$LLM_GATEWAY_KEY` at runtime)     |
| Editors / TUI   | `config/nvim`, `config/fish`, `config/btop`                           |
| tmux            | `tmux/.tmux.conf`, `tmux/.gitmux.conf`                                |

## Global Claude and Codex runtime content

`~/compute-ai-skills` owns the installers for its own runtime content, so this
repository delegates to them rather than reimplementing their link engine.
After the checkout is cloned, validated, and fast-forwarded, `install.sh` runs:

```bash
python3 -B ~/compute-ai-skills/scripts/install-codex.py  --install
python3 -B ~/compute-ai-skills/scripts/install-claude.py --install
```

Both share one standard-library engine in the checkout's `runtime_install/`,
so their safety rules and exit codes are identical: `0` when every link is
aligned, `1` for safely repairable missing or obsolete links, and `2` for an
invalid inventory or any collision. The engine never clobbers an existing
path — a regular file, a broken link, or a link to the wrong target makes it
refuse and exit `2` before changing anything. Each installer also validates its
own inventory, so a renamed or missing skill, agent, or hook fails before any
link is written. `~/.codex/hooks.json` and the Codex HERDR hook are part of
that inventory.

Claude is installed **links-only**. Its user-scoped hooks live in the tracked
[`claude/settings.json`](claude/settings.json), which `~/.claude/settings.json`
symlinks to, and the upstream installer would otherwise resolve that symlink
and write through it into this repository. So `install.sh` runs the Claude
installer in `--check` mode first: if it reports that a hook entry is missing
from the settings file, the run warns and skips the Claude install, leaving the
tracked file for a human to reconcile. Dotfiles stays authoritative over its
own settings.

The tracked `claude/settings.json` adds exactly one boundary-hook group for
each of `PreToolUse`, `SubagentStart`, and `SubagentStop`. Each group runs
`python3 "$HOME/.claude/hooks/agent-boundary.py"`, whose script is supplied by
the linked compute checkout. An absent, empty, or `*` matcher on those groups
all mean every tool and are accepted interchangeably.

`.claude/references/` is deliberately **not** linked. A Claude skill reaches
the shared contracts through `../../references/<file>.md`, and because
`~/.claude/skills/<skill>` is a symlink into the checkout, the kernel resolves
that path from the physical directory back into the checkout's own
`.claude/references/`. The boundary adapters likewise resolve their physical
checkout path before importing the shared `agent_policy` core, so that
directory is validated in place rather than linked into any runtime.

Cursor is not installed. The checkout documents it as manual-only and ships no
Cursor installer; symlink its runtime trees and merge its hook manifest by hand
if you want it.

Final validation re-runs both installers in `--check` mode and requires each to
report an aligned installation. It also checks the exact Codex `hooks.json`
link, the dotfiles-owned Claude settings link, the Claude and Codex HERDR hook
links and their `SessionStart` entries, and all three Claude boundary hook
groups. The two boundary adapters, the shared policy source, and both installer
scripts must exist and be readable. Any mismatch makes the installer exit
nonzero.

## Herdr agent integration

The installer manages only Herdr's `config.toml`: it links the tracked
`config/herdr/config.toml` source to `$HOME/.config/herdr/config.toml`. Herdr
logs, sockets, locks, release notes, and session state remain machine-local;
they are not tracked or symlinked. The installer does not reload a running
Herdr server after creating or repairing the link.

This repository owns the tracked Claude hook
[`claude/hooks/herdr-agent-state.sh`](claude/hooks/herdr-agent-state.sh), which
the installer links to `~/.claude/hooks/herdr-agent-state.sh`. It is vendored
from Herdr v0.7.5 with integration ID `claude` and integration version `7`.
Claude's tracked settings invoke it on `SessionStart`; restart Claude Code
after installation so the new hook configuration is loaded.

The tracked Codex configuration enables hook support, while
`~/compute-ai-skills` owns the corresponding v0.7.5 Codex hook (integration ID
`codex`, version `6`) and `hooks.json`. Its installer links that hook at
`~/.codex/hooks/herdr-agent-state.sh`, which is the path its `SessionStart`
entry invokes. Inside a Herdr-managed pane, these hooks report the native
Claude or Codex session identity to Herdr's local socket. They exit quietly
outside that environment and do not report activity transitions, so Herdr
continues to derive agent status from pane output. The Herdr integration does
not replace or change the tracked tmux configuration.

> **Warning:** Do not run `herdr integration install` against these managed
> integrations. The live hook paths are symlinks, so that command can rewrite
> the tracked hook targets. Update the vendored assets deliberately instead.

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
- Desktop/GUI assets.
- Authentication or secret values. Existing credentials may be preserved or
  seeded, but the installer does not supply real values or perform logins.
- Claude/Codex/Cursor history, sessions, databases, caches, and other mutable
  state.
