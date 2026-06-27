#!/usr/bin/env bash
# Idempotent dotfiles installer: symlinks tracked configs into ~, and seeds +
# wires up the untracked secret store. The git repo never contains secrets.
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP="$HOME/.dotfiles-backup-$(date +%Y%m%d-%H%M%S)"

info() { printf '  %s\n' "$*"; }

# link SRC TARGET : back up an existing real TARGET, then symlink SRC -> TARGET.
link() {
    local src="$1" target="$2"
    [ -e "$src" ] || { info "skip (missing src): $src"; return; }
    mkdir -p "$(dirname "$target")"
    if [ -L "$target" ]; then
        if [ "$(readlink "$target")" = "$src" ]; then
            info "ok   $target"
            return
        fi
        rm -f "$target"
    elif [ -e "$target" ]; then
        mkdir -p "$BACKUP$(dirname "$target")"
        mv "$target" "$BACKUP$target"
        info "back $target -> $BACKUP$target"
    fi
    ln -s "$src" "$target"
    info "link $target -> $src"
}

echo "==> Config symlinks"
link "$DOTFILES/shell/.bashrc"                  "$HOME/.bashrc"
link "$DOTFILES/shell/.profile"                 "$HOME/.profile"
link "$DOTFILES/git/.gitconfig"                 "$HOME/.gitconfig"
link "$DOTFILES/git/gitignore"                  "$HOME/.config/git/ignore"
link "$DOTFILES/config/starship.toml"           "$HOME/.config/starship.toml"
link "$DOTFILES/config/nvim"                    "$HOME/.config/nvim"
link "$DOTFILES/config/fish"                    "$HOME/.config/fish"
link "$DOTFILES/config/zellij/config.kdl"       "$HOME/.config/zellij/config.kdl"
link "$DOTFILES/config/btop/btop.conf"          "$HOME/.config/btop/btop.conf"
link "$DOTFILES/claude/settings.json"           "$HOME/.claude/settings.json"
link "$DOTFILES/claude/statusline.sh"           "$HOME/.claude/statusline.sh"
link "$DOTFILES/claude/claude-statusline"       "$HOME/.claude/claude-statusline"
link "$DOTFILES/claude/themes/snazzy-light.json" "$HOME/.claude/themes/snazzy-light.json"
link "$DOTFILES/codex/config.toml"              "$HOME/.codex/config.toml"

echo "==> Secret store (untracked)"
mkdir -p "$DOTFILES/secrets"

# A. env-var secrets -> secrets.env (seed from current env / old bashrc backup)
if [ ! -f "$DOTFILES/secrets.env" ]; then
    info "seeding secrets.env"
    {
        echo "# Untracked. Seeded by install.sh on $(date)."
        if [ -n "${LLM_GATEWAY_KEY:-}" ]; then
            echo "export LLM_GATEWAY_KEY=\"$LLM_GATEWAY_KEY\""
        elif key=$(sed -n 's/.*LLM_GATEWAY_KEY="\([^"]*\)".*/\1/p' "$BACKUP$HOME/.bashrc" 2>/dev/null | head -n1) && [ -n "$key" ]; then
            echo "export LLM_GATEWAY_KEY=\"$key\""
        else
            info "WARNING: LLM_GATEWAY_KEY not found; edit secrets.env manually"
            cat "$DOTFILES/secrets.env.example" | grep -v '^#'
        fi
    } > "$DOTFILES/secrets.env"
fi
chmod 600 "$DOTFILES/secrets.env"
link "$DOTFILES/secrets.env" "$HOME/.config/secrets.env"

# B. token blobs -> secrets/ (seed from live files if present), then symlink
seed_blob() {
    local live="$1" store="$2"
    if [ ! -e "$store" ]; then
        if [ -f "$live" ] && [ ! -L "$live" ]; then
            cp "$live" "$store"; chmod 600 "$store"; info "seed $store (from $live)"
        elif [ -f "$BACKUP$live" ]; then
            cp "$BACKUP$live" "$store"; chmod 600 "$store"; info "seed $store (from backup)"
        else
            info "no source for $store yet — re-auth then re-run, or drop the file in"
            return
        fi
    fi
    link "$store" "$live"
}
seed_blob "$HOME/.config/gh/hosts.yml"          "$DOTFILES/secrets/gh-hosts.yml"
seed_blob "$HOME/.claude/.credentials.json"     "$DOTFILES/secrets/claude-credentials.json"

echo "==> Done."
[ -d "$BACKUP" ] && echo "    Backups saved under $BACKUP"
echo "    Open a new shell, or: source ~/.bashrc"
