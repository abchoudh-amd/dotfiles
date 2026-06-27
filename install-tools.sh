#!/usr/bin/env bash
# Install the CLI tools + tmux plugins these dotfiles depend on.
# Idempotent: every tool is guarded by have() and skipped if already on PATH.
# No versions pinned — latest is installed. See TOOLS.md for the manifest.
set -uo pipefail

BIN="$HOME/.local/bin"
mkdir -p "$BIN"

info() { printf '  %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
need() { have "$1" || { info "SKIP: '$1' not found — install it first (see TOOLS.md Prerequisites)"; return 1; }; }

# fetch_extract URL  : download a tarball/zip and extract into a temp dir, echo the dir
fetch_extract() {
    local url="$1" tmp
    tmp="$(mktemp -d)"
    if [[ "$url" == *.zip ]]; then
        curl -fsSL "$url" -o "$tmp/a.zip" && unzip -q "$tmp/a.zip" -d "$tmp"
    else
        curl -fsSL "$url" | tar -xz -C "$tmp"
    fi
    echo "$tmp"
}

echo "==> cargo crates"
if need cargo; then
    for c in eza fd-find diskus zellij csvlens yazi-build; do
        # crate->binary name differs for fd-find/yazi-build
        bin="$c"; [ "$c" = fd-find ] && bin=fd; [ "$c" = yazi-build ] && bin=yazi
        have "$bin" && { info "ok   $bin"; continue; }
        info "cargo install $c"; cargo install "$c"
    done
fi

echo "==> go"
if need go; then
    if have glow; then info "ok   glow"; else info "go install glow"; go install github.com/charmbracelet/glow@latest; fi
fi

echo "==> npm -g"
if need npm; then
    if have codex; then info "ok   codex"; else info "npm i -g @openai/codex"; npm install -g @openai/codex; fi
fi

echo "==> uv tools"
if need uv; then
    if have sqlit; then info "ok   sqlit"; else info "uv tool install sqlit-tui"; uv tool install sqlit-tui; fi
fi

echo "==> claude code (native installer)"
if have claude; then info "ok   claude"; else
    info "install claude"; curl -fsSL https://claude.ai/install.sh | bash
fi

echo "==> fzf"
if have fzf; then
    info "ok   fzf"
elif need git; then
    info "clone fzf -> ~/.fzf"
    git clone --depth 1 https://github.com/junegunn/fzf ~/.fzf && ~/.fzf/install --bin
fi

echo "==> standalone binaries (-> $BIN)"
# starship + zoxide ship official install scripts that drop into ~/.local/bin
if have starship; then info "ok   starship"; else
    info "install starship"; curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b "$BIN"
fi
if have zoxide; then info "ok   zoxide"; else
    info "install zoxide"; curl -fsSL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
fi
# gh: official install script honors a target dir via GH? — use release tarball
if have rg; then info "ok   rg"; else
    info "install ripgrep"
    d=$(fetch_extract "https://github.com/BurntSushi/ripgrep/releases/latest/download/ripgrep-15.1.0-x86_64-unknown-linux-musl.tar.gz") \
        && find "$d" -name rg -type f -exec install -m755 {} "$BIN/rg" \; ; rm -rf "$d"
fi
if have btop; then info "ok   btop"; else
    info "install btop"
    d=$(fetch_extract "https://github.com/aristocratos/btop/releases/latest/download/btop-x86_64-linux-musl.tbz" ) 2>/dev/null || true
    [ -n "${d:-}" ] && find "$d" -name btop -type f -exec install -m755 {} "$BIN/btop" \; 2>/dev/null; rm -rf "${d:-/nonexistent}"
    have btop || info "  (btop: fetch failed — see https://github.com/aristocratos/btop/releases)"
fi
if have duf; then info "ok   duf"; else
    info "  duf: download a release from https://github.com/muesli/duf/releases into $BIN"
fi
if have nvim; then info "ok   nvim"; else
    info "install neovim"
    d=$(fetch_extract "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz") \
        && cp -r "$d"/nvim-linux-x86_64/bin/nvim "$BIN/nvim" && cp -r "$d"/nvim-linux-x86_64/lib "$d"/nvim-linux-x86_64/share "$HOME/.local/" ; rm -rf "$d"
fi
if have gh; then info "ok   gh"; else
    info "  gh: install via https://github.com/cli/cli/blob/trunk/docs/install_linux.md or distro package"
fi

echo "==> tmux plugins (TPM)"
if [ -d "$HOME/.tmux/plugins/tpm" ]; then
    info "ok   tpm cloned"
elif need git; then
    info "clone tpm"; git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"
fi
info "open tmux and press 'prefix + I' (prefix = Ctrl-s) to install catppuccin"

echo "==> Done. Tools missing above can be installed manually — see TOOLS.md."
