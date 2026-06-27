# dotfiles

Personal environment configs — shell, git, Claude Code, Codex, status line, and
editor/TUI tools. Deployed into `~` via symlinks. **Secrets are never committed.**

## Install

```bash
cd ~/dotfiles
./install.sh
```

`install.sh` is idempotent. It backs up any existing real files to
`~/.dotfiles-backup-<timestamp>/`, symlinks the tracked configs into place, and
seeds + wires up the untracked secret store (see below). Re-running re-points
symlinks and leaves correct ones untouched.

## What's tracked

| Area            | Files                                                                 |
|-----------------|----------------------------------------------------------------------|
| Shell           | `shell/.bashrc`, `shell/.profile`                                     |
| Git             | `git/.gitconfig`, `git/gitignore` → `~/.config/git/ignore`            |
| Prompt          | `config/starship.toml`                                                |
| Claude Code     | `claude/settings.json`, `statusline.sh`, `claude-statusline`, theme   |
| Codex           | `codex/config.toml` (key read from `$LLM_GATEWAY_KEY` at runtime)     |
| Editors / TUI   | `config/nvim`, `config/fish`, `config/zellij`, `config/btop`          |

## Secrets

The git repo contains **no secrets**. Real values live in two untracked,
gitignored locations that `install.sh` seeds from your current machine:

- **`secrets.env`** — env-var secrets (e.g. `LLM_GATEWAY_KEY`). Symlinked to
  `~/.config/secrets.env` and sourced by `~/.bashrc`. `codex/config.toml` reads
  the key from this env var at runtime.
- **`secrets/`** — token blob files, symlinked into place so token rotation
  updates them live without dirtying the repo:
  - `secrets/gh-hosts.yml`        → `~/.config/gh/hosts.yml`
  - `secrets/claude-credentials.json` → `~/.claude/.credentials.json`

To set up secrets manually instead of seeding:
`cp secrets.env.example secrets.env`, fill in the key, and drop the token files
into `secrets/`.

## Not included

- **Claude skills/hooks** (`~/.claude/skills`, `~/.claude/hooks`) are symlinks
  into the separate `~/compute-ai-skills` repo — clone that separately.
- Claude/Codex state (history, sessions, sqlite, caches) and gh config beyond
  the auth token are intentionally excluded.
