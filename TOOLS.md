# Tool manifest

[`install.sh`](install.sh) is the only supported installer. Run it as a normal
user with no arguments:

```bash
./install.sh
```

The installer uses `sudo` only for system packages and puts user-managed
software under `~/.local`, `~/.cargo`, `~/.nvm`, and the other paths called out
below. Existing commands on `PATH` are normally retained. Upstream versions
are resolved when the installer runs; they are not repository-pinned. Cargo
installs always use `--locked`, and tmux and Neovim have enforced minimum
versions.

## Supported systems and prerequisites

The supported platform is x86_64 Linux with glibc 2.28 or newer and a readable
`/etc/os-release`:

- Debian and Ubuntu are supported subject to the glibc requirement.
- RHEL, Rocky Linux, and AlmaLinux major version 8 or newer are supported.

The installer requires Bash, a safe non-root `HOME`, network access to the
listed upstream sources, and working `sudo`. On RHEL itself,
`subscription-manager` must be able to enable CodeReady Builder. The installer
enables PowerTools on Rocky/AlmaLinux 8, CRB on newer Rocky/AlmaLinux releases,
and installs EPEL on all RHEL-family systems.

System prerequisites are installed through the distribution package manager
(plus the upstream EPEL release RPM on RHEL-family systems):

| Family | Packages |
| --- | --- |
| Debian/Ubuntu (`apt`) | `ca-certificates git curl jq fish python3 python3-venv tar unzip zip xz-utils bzip2 findutils bash-completion build-essential cmake ninja-build pkg-config libssl-dev libevent-dev libncurses-dev gettext bison` |
| RHEL/Rocky/AlmaLinux (`dnf`) | `dnf-plugins-core`, EPEL, then `ca-certificates git curl jq fish python3 tar unzip zip xz bzip2 findutils bash-completion gcc gcc-c++ make cmake ninja-build pkgconf-pkg-config openssl-devel libevent-devel ncurses-devel gettext bison` |

Of those packages, final validation directly requires the commands `git`,
`curl`, `jq`, `fish`, and `python3`. `findutils` supplies `find`, which the
installer uses to validate extracted release and source-build layouts. The
remaining packages support source builds and the configured shell environment.

## Language toolchains

The installer bootstraps each missing toolchain before installing tools that
depend on it.

| Required command | Installation and source | User-local location |
| --- | --- | --- |
| `cargo` | Minimal stable Rust via the official [rustup installer](https://sh.rustup.rs) | `~/.cargo` |
| `go` | Latest stable Linux amd64 archive and published SHA-256 from [go.dev](https://go.dev/dl/) | `~/.local/go` |
| `node`, `npm` | Latest tagged [NVM](https://github.com/nvm-sh/nvm) release, followed by current Node with the latest npm and a default NVM alias | `$NVM_DIR` (default `~/.nvm`); the installer enables NVM's `current` symlink |
| `uv` | Official [uv installer](https://astral.sh/uv/install.sh) with path modification disabled | `~/.local/bin` |

## Required command inventory

Every command in the following tables is mandatory: `install.sh` checks all of
them during final validation.

### Cargo tools

Each missing command is installed with
`cargo install --locked --root "$HOME/.local" <crate>` from the Cargo registry.

| Crate | Required command | Purpose | Source |
| --- | --- | --- | --- |
| `eza` | `eza` | Modern `ls` | [crates.io](https://crates.io/crates/eza) |
| `fd-find` | `fd` | Modern `find` | [crates.io](https://crates.io/crates/fd-find) |
| `diskus` | `diskus` | Fast directory-size utility | [crates.io](https://crates.io/crates/diskus) |
| `csvlens` | `csvlens` | CSV viewer | [crates.io](https://crates.io/crates/csvlens) |
| `yazi-fm` | `yazi` | Terminal file manager | [crates.io](https://crates.io/crates/yazi-fm) |
| `yazi-cli` | `ya` | Yazi command-line companion | [crates.io](https://crates.io/crates/yazi-cli) |

`yazi-fm` -> `yazi` and `yazi-cli` -> `ya` are two separate, mandatory,
locked Cargo installs. Both commands must be present and are installed
independently.

### Language-managed and native CLI tools

| Required command | Installation | Source |
| --- | --- | --- |
| `glow` | `GOBIN=~/.local/bin go install github.com/charmbracelet/glow@latest` | [charmbracelet/glow](https://github.com/charmbracelet/glow) |
| `codex` | `npm install --global --prefix ~/.local @openai/codex` | [@openai/codex](https://www.npmjs.com/package/@openai/codex) |
| `sqlit` | `uv tool install sqlit-tui` | [sqlit-tui](https://pypi.org/project/sqlit-tui/) |
| `claude` | Native installer, requesting `latest` | [claude.ai/install.sh](https://claude.ai/install.sh) |

### User-local tools

| Required command | Installation source | Destination |
| --- | --- | --- |
| `starship` | Official [Starship installer](https://starship.rs/install.sh) | `~/.local/bin` |
| `zoxide` | Official [zoxide installer](https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh), invoked with `--bin-dir` | `~/.local/bin/zoxide` |
| `fzf` | Latest [junegunn/fzf](https://github.com/junegunn/fzf) Linux amd64 release | `~/.local/bin/fzf` |
| `bat` | Latest [sharkdp/bat](https://github.com/sharkdp/bat) x86_64 musl release | `~/.local/bin/bat` |
| `rg` | Latest [BurntSushi/ripgrep](https://github.com/BurntSushi/ripgrep) x86_64 musl release | `~/.local/bin/rg` |
| `btop` | Latest [aristocratos/btop](https://github.com/aristocratos/btop) x86_64 musl release | `~/.local/bin/btop` |
| `duf` | Latest [muesli/duf](https://github.com/muesli/duf) Linux x86_64 release | `~/.local/bin/duf` |
| `gh` | Latest [cli/cli](https://github.com/cli/cli) Linux amd64 release | `~/.local/bin/gh` |
| `gitmux` | Latest [arl/gitmux](https://github.com/arl/gitmux) Linux amd64 release | `~/.local/bin/gitmux` |
| `herdr` | Official [Herdr installer](https://herdr.dev/install.sh), invoked as `curl -fsSL https://herdr.dev/install.sh \| sh` | Upstream installer-selected location on `PATH` |

GitHub release downloads are selected from the latest release metadata. The
installer verifies a release-provided SHA-256 digest or checksum manifest when
one is available, rejects unsafe archive members, and verifies that the
installed executable can answer a version probe. Final validation repeats the
version probe for `fzf`, `bat`, `rg`, `btop`, `duf`, `gh`, and `gitmux`.

`fzf` and `zoxide` carry minimum versions in addition to the presence check,
because distributions ship binaries too old to work with this configuration:
`fzf >= 0.48.0` (the first release with the `--bash` integration flag) and
`zoxide >= 0.9.0` (the first line whose shell init is alias-safe and installs a
`PROMPT_COMMAND` hook). A command on `PATH` below its minimum is replaced by a
user-local build in `~/.local/bin`, which wins over the distribution copy
without removing the system package.

Herdr has its own guarded path: an existing command that completes a version
probe is retained without running its installer. A missing or broken command
causes the exact `curl -fsSL https://herdr.dev/install.sh | sh` pipeline above
to run, after which the command must be discoverable and complete a version
probe. Final validation repeats that probe.

### tmux and Neovim version fallbacks

- `tmux` 3.2 or newer is required. If `tmux` is absent or too old, the
  installer downloads the latest [tmux/tmux](https://github.com/tmux/tmux)
  source release, builds it, and installs it under `~/.local`.
- Neovim 0.11.2 or newer is required. If `nvim` is absent or too old, the
  installer first uses the latest
  [neovim/neovim](https://github.com/neovim/neovim) Linux x86_64 release. If
  that release binary cannot run, it builds the same release tag from source.
  The result lives under `~/.local/opt/nvim-<tag>`, with
  `~/.local/bin/nvim` pointing to it.

## tmux plugins

The installer clones [tmux-plugins/tpm](https://github.com/tmux-plugins/tpm)
to `~/.tmux/plugins/tpm` when needed and runs TPM's plugin installer. No manual
`prefix + I` step is required. The tmux configuration declares
[catppuccin/tmux](https://github.com/catppuccin/tmux) with the Latte flavor;
final validation requires
`~/.tmux/plugins/tmux/catppuccin.tmux`. The configured tmux prefix is
`Ctrl-s`.

## Herdr agent integrations

The installer manages only Herdr's `config.toml`, linking the tracked
`config/herdr/config.toml` source to `$HOME/.config/herdr/config.toml`. Herdr
logs, sockets, locks, release notes, and session state remain machine-local
rather than tracked or symlinked. Creating or repairing this link does not
reload a running Herdr server.

The integration assets are vendored from Herdr v0.7.5 rather than generated at
install time:

- Dotfiles owns `claude/hooks/herdr-agent-state.sh` (integration ID `claude`,
  version `7`) and links it to `~/.claude/hooks/herdr-agent-state.sh`.
  `claude/settings.json` contains exactly one matcher-`*`, timeout-10
  `SessionStart` invocation of
  `bash "$HOME/.claude/hooks/herdr-agent-state.sh" session`.
- `~/compute-ai-skills` owns `.codex/hooks/herdr-agent-state.sh` (integration ID
  `codex`, version `6`) and the Codex `hooks.json`. Its installer links the hook
  into `~/.codex/hooks/`, the path used by its matcher-free, timeout-10
  `SessionStart` entry, and prunes the obsolete top-level
  `~/.codex/herdr-agent-state.sh`. The tracked Codex config enables
  `[features] hooks = true`.

The hooks report native session identity to Herdr's local Unix socket only when
Herdr has supplied its pane environment (`HERDR_ENV`, `HERDR_SOCKET_PATH`, and
`HERDR_PANE_ID`); otherwise they exit successfully without reporting. They do
not publish activity-state transitions, so Herdr's agent status remains derived
from pane output. The existing tmux setup continues unchanged.

Restart Claude Code and Codex after installation. In Codex, inspect `/hooks`
and complete any trust prompt it presents; installation enables hook support
but does not update trusted-hook hashes.

> **Warning:** Do not run `herdr integration install` for these integrations.
> Their live paths are symlinks to tracked files, and the generated installer
> can rewrite those tracked targets. Update the pinned assets deliberately.

## Claude MCP configuration

[`claude/mcp-servers.json`](claude/mcp-servers.json) is the tracked,
non-secret MCP manifest. Its exact supported schema is:

```json
{
  "mcpServers": {
    "jira": {
      "type": "http",
      "url": "https://mcp.atlassian.com/v1/mcp/authv2"
    },
    "confluence": {
      "type": "http",
      "url": "https://mcp.atlassian.com/v1/mcp/authv2"
    }
  }
}
```

Only the managed names `jira` and `confluence` are allowed in this manifest,
and each record must contain exactly the shown `type` and `url`. The installer
uses the installed Claude CLI to reconcile these definitions globally at user
scope with `claude mcp remove --scope user` and
`claude mcp add-json --scope user`. It preserves every unrelated MCP server
and every non-MCP field in Claude's local state. The manifest and live state
must also be duplicate-key-free JSON. Run the installer with
`CLAUDE_CONFIG_DIR` unset so the one protected state path remains
`~/.claude.json`.

Before mutating an existing `~/.claude.json`, the installer creates one
private snapshot in its timestamped backup tree (backup directory mode `0700`,
snapshot mode `0600`). A matching state needs no snapshot. A failed
non-concurrent transaction is rolled back only after the installer proves the
complete last confirmed projection of non-MCP fields, unmanaged servers, and
the two managed records. If that proof fails, an unconfirmed managed write or
other unexpected live state is returned to the canonical path without
clobbering, and the snapshot is preserved for manual recovery.

OAuth and service reachability are deliberately outside installation. Log in
manually when needed:

```bash
claude mcp login jira
claude mcp login confluence
```

Do not track or symlink `~/.claude.json`, and do not put credentials, OAuth
tokens, authorization headers, environment secrets, or client secrets in the
manifest. No MCP credentials, secret-bearing headers, or authentication tokens
belong in tracked files.

## Global compute-ai-skills runtime activation

The installer activates
[abchoudh-amd/compute-ai-skills](https://github.com/abchoudh-amd/compute-ai-skills)
globally for Claude and Codex from `~/compute-ai-skills`. If that path
is absent, it clones the repository's `main` branch noninteractively. An
existing path must be a Git checkout with one of the accepted HTTPS or SSH
origins for that repository; an unexpected origin or non-checkout is a required
failure. A clean checkout on `main` is updated only with
`git pull --ff-only origin main`, pinning the update to the already verified
remote and branch. If that fast-forward cannot be completed, the existing
checkout remains in use and the installer warns. A dirty checkout or one on
another branch is preserved without any update. Partial material left by a
failed first clone is moved recoverably into the private timestamped backup
tree.

The checkout owns the installers for its own runtime content. Once it is
present, validated, and fast-forwarded, `install.sh` delegates to them:

```bash
python3 -B ~/compute-ai-skills/scripts/install-codex.py  --install
python3 -B ~/compute-ai-skills/scripts/install-claude.py --install
```

Both are standard-library-only and share one collision-safe symlink engine in
the checkout's `runtime_install/`, so their safety rules and exit codes match:

| Exit | Meaning |
| --- | --- |
| `0` | every link aligned |
| `1` | safely repairable missing or obsolete links |
| `2` | invalid repository inventory, or any collision |

Exit `2` is a required failure here. The engine refuses rather than clobbers:
a regular file, a broken symlink, or a symlink to the wrong target at a
destination stops the run before anything is written. It also validates each
runtime's inventory — agent definitions, their resource bundles, skills, and
hooks — and re-verifies every link after installing. Destination parents must
be physical directories inside the runtime home.

The installers own `~/.codex/hooks.json` and the Codex HERDR hook, and prune
the obsolete top-level `~/.codex/herdr-agent-state.sh` that earlier versions of
this script created. `.claude/references/` is deliberately not linked: skills
resolve `../../references/<file>.md` from their physical directory back into
the checkout. Each boundary adapter likewise resolves its physical checkout
path to import the shared `agent_policy` core, which is validated in place
rather than linked.

Claude is installed links-only. Its user-scoped hooks live in the
dotfiles-owned `claude/settings.json`, which `~/.claude/settings.json` symlinks
to, and the Claude installer resolves that symlink chain and writes through to
the physical file. To keep this repository authoritative, `install.sh` runs
`install-claude.py --check` first and inspects its output: a `repairable:
settings` finding means upstream declares a hook the tracked file lacks, which
is reported as a warning and skips the Claude install rather than editing a
tracked file. That settings file contains one command group invoking
`python3 "$HOME/.claude/hooks/agent-boundary.py"` for each of `PreToolUse`,
`SubagentStart`, and `SubagentStop`; an absent, empty, or `*` matcher on those
groups all mean every tool and are accepted interchangeably.

Cursor is not installed or configured. The checkout ships no Cursor installer
and documents that runtime as manual-only.

After installation, terminate and restart Claude Code and Codex so they reload
the global runtime and hooks. In Codex, also inspect `/hooks` and complete any
trust prompt; hook support is enabled, but installation does not update
trusted-hook hashes.

## Final validation contract

The exact required command set is:

```text
git curl jq fish python3 cargo go node npm uv eza fd diskus csvlens
yazi ya glow codex sqlit claude starship zoxide fzf bat rg btop duf gh gitmux
herdr tmux nvim
```

In addition to command presence, validation enforces tmux >= 3.2, Neovim >=
0.11.2, fzf >= 0.48.0, zoxide >= 0.9.0, executable release-binary and Herdr
version probes, the Catppuccin plugin, an aligned `--check` from both
compute-ai-skills installers, the Claude/Codex Herdr hook links and
SessionStart entries, the Codex hooks link, the three Claude boundary hook
groups, and exact `jira`/`confluence` user MCP definitions. Any missing
requirement makes `./install.sh` exit nonzero after printing its full summary.
