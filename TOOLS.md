# Tools

Inventory of the CLI tools and tmux plugins these dotfiles depend on. Run
[`install-tools.sh`](install-tools.sh) to install everything below; it skips any
tool already on `PATH`. No versions are pinned — latest is installed.

## Prerequisites (assumed present)

These managers are used to install the tools and are not installed by the script:

- **Rust / cargo** — https://rustup.rs
- **Go** — https://go.dev/dl/
- **Node / npm** — https://github.com/nvm-sh/nvm
- **uv** — https://github.com/astral-sh/uv

## Cargo (`cargo install`)

| Tool | Purpose | Source |
|------|---------|--------|
| eza | modern `ls` | https://github.com/eza-community/eza |
| fd-find (`fd`) | modern `find` | https://github.com/sharkdp/fd |
| diskus | fast `du` for dir size | https://github.com/sharkdp/diskus |
| zellij | terminal multiplexer | https://github.com/zellij-org/zellij |
| csvlens | CSV viewer | https://github.com/YS-L/csvlens |
| yazi-build (`yazi`, `ya`) | terminal file manager | https://github.com/sxyazi/yazi |

## Go (`go install`)

| Tool | Purpose | Source |
|------|---------|--------|
| glow | markdown renderer | https://github.com/charmbracelet/glow |

## npm (`-g`)

| Tool | Purpose | Source |
|------|---------|--------|
| @openai/codex | OpenAI Codex CLI | https://github.com/openai/codex |

## uv tools (`uv tool install`)

| Tool | Purpose | Source |
|------|---------|--------|
| sqlit-tui (`sqlit`) | SQLite TUI | https://pypi.org/project/sqlit-tui |

## AI CLIs (native installer)

| Tool | Purpose | Source |
|------|---------|--------|
| claude | Claude Code CLI (native installer → `~/.local/bin/claude`) | https://claude.ai/install.sh |

## fzf (git clone + bundled installer)

| Tool | Purpose | Source |
|------|---------|--------|
| fzf | fuzzy finder (installed to `~/.fzf`) | https://github.com/junegunn/fzf |

## Standalone binaries (release tarball → `~/.local/bin`)

Installed via each project's official installer or GitHub release tarball:

| Tool | Purpose | Source |
|------|---------|--------|
| starship | shell prompt | https://github.com/starship/starship |
| zoxide | smarter `cd` | https://github.com/ajeetdsouza/zoxide |
| ripgrep (`rg`) | fast `grep` | https://github.com/BurntSushi/ripgrep |
| btop | resource monitor | https://github.com/aristocratos/btop |
| duf | disk-usage viewer | https://github.com/muesli/duf |
| nvim | Neovim editor | https://github.com/neovim/neovim |
| gh | GitHub CLI | https://github.com/cli/cli |

## tmux plugins (TPM)

Managed by the Tmux Plugin Manager — the script clones TPM, then you press
`prefix + I` (prefix is `Ctrl-s`) inside tmux to install the rest from the
`@plugin` lines in `tmux/.tmux.conf`.

| Plugin | Purpose | Source |
|--------|---------|--------|
| tmux-plugins/tpm | plugin manager | https://github.com/tmux-plugins/tpm |
| catppuccin/tmux | catppuccin theme (latte) | https://github.com/catppuccin/tmux |
