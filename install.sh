#!/usr/bin/env bash
set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_PREFIX="$HOME/.local"
LOCAL_BIN="$LOCAL_PREFIX/bin"
LOCAL_OPT="$LOCAL_PREFIX/opt"
LOCAL_GO="$LOCAL_PREFIX/go"
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
COMPUTE_SKILLS="$HOME/compute-ai-skills"
BACKUP_DIR=""
NEW_TEMP_DIR=""

declare -a TEMP_DIRS=()
declare -a INSTALLED=()
declare -a PRESENT=()
declare -a WARNINGS=()
declare -a FAILURES=()
STEP_REPORTED_PRESENT=0
RELEASE_JSON=""

info() { printf '  %s\n' "$*"; }
section() { printf '\n==> %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

append_unique() {
    local array_name="$1" value="$2" existing
    local -n values="$array_name"
    for existing in "${values[@]}"; do
        [[ "$existing" == "$value" ]] && return 0
    done
    values+=("$value")
}

present() {
    append_unique PRESENT "$1"
    STEP_REPORTED_PRESENT=1
    info "ok   $1"
}
warn() { append_unique WARNINGS "$1"; info "WARN: $1" >&2; }
fail() { append_unique FAILURES "$1"; info "FAIL: $1" >&2; }

attempt() {
    local label="$1"
    shift
    STEP_REPORTED_PRESENT=0
    info "$label"
    if "$@"; then
        (( STEP_REPORTED_PRESENT == 1 )) || append_unique INSTALLED "$label"
        return 0
    fi
    fail "$label"
    return 0
}

version_ge() {
    [[ -n "${1:-}" && -n "${2:-}" ]] || return 1
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

make_temp_dir() {
    NEW_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-install.XXXXXX")" || return 1
    TEMP_DIRS+=("$NEW_TEMP_DIR")
}

cleanup() {
    local directory temp_root="${TMPDIR:-/tmp}"
    for directory in "${TEMP_DIRS[@]}"; do
        case "$directory" in
            "$temp_root"/dotfiles-install.*) rm -rf -- "$directory" ;;
        esac
    done
}
trap cleanup EXIT

ensure_backup_dir() {
    [[ -n "$BACKUP_DIR" ]] && return 0
    BACKUP_DIR="$(mktemp -d "$HOME/.dotfiles-backup-$(date +%Y%m%d-%H%M%S).XXXXXX")" || return 1
}

backup_existing() {
    local target="$1" relative destination
    [[ -e "$target" || -L "$target" ]] || return 0
    ensure_backup_dir || return 1
    relative="${target#/}"
    destination="$BACKUP_DIR/$relative"
    mkdir -p "$(dirname "$destination")" || return 1
    mv -- "$target" "$destination" || return 1
    info "back $target -> $destination"
}

link_path() {
    local source_path="$1" target="$2"
    [[ -e "$source_path" || -L "$source_path" ]] || return 1
    mkdir -p "$(dirname "$target")" || return 1
    if [[ -L "$target" && "$(readlink "$target")" == "$source_path" ]]; then
        present "$target"
        return 0
    fi
    backup_existing "$target" || return 1
    ln -s "$source_path" "$target" || return 1
    info "link $target -> $source_path"
}

download() {
    local url="$1" destination="$2"
    curl --fail --location --silent --show-error --retry 3 "$url" -o "$destination"
}

archive_is_safe() {
    local archive="$1" member listing verbose_listing line_type
    listing="$(tar -tf "$archive")" || return 1
    while IFS= read -r member; do
        [[ "$member" != /* ]] || return 1
        [[ ! "$member" =~ (^|/)\.\.($|/) ]] || return 1
    done <<< "$listing"

    verbose_listing="$(tar -tvf "$archive")" || return 1
    while IFS= read -r member; do
        line_type="${member:0:1}"
        case "$line_type" in
            -|d) ;;
            *) return 1 ;;
        esac
    done <<< "$verbose_listing"
}

extract_archive() {
    local archive="$1" destination="$2"
    mkdir -p "$destination" || return 1
    archive_is_safe "$archive" || return 1
    tar --no-same-owner --no-same-permissions -xf "$archive" -C "$destination"
}

verify_sha256() {
    local file="$1" expected="$2" actual
    actual="$(sha256sum "$file" | awk '{print $1}')" || return 1
    [[ "$actual" == "$expected" ]]
}

github_release_asset() {
    local repository="$1" asset_regex="$2" metadata="$3"
    local json match_count
    make_temp_dir || return 1
    json="$NEW_TEMP_DIR/release.json"
    download "https://api.github.com/repos/$repository/releases/latest" "$json" || return 1
    RELEASE_JSON="$json"
    match_count="$(jq --arg pattern "$asset_regex" '[.assets[] | select(.name | test($pattern))] | length' "$json")" || return 1
    [[ "$match_count" == 1 ]] || return 1
    jq -r --arg pattern "$asset_regex" '
        .tag_name as $tag
        | .assets[]
        | select(.name | test($pattern))
        | [$tag, .name, .browser_download_url, (.digest // "")]
        | @tsv
    ' "$json" > "$metadata"
}

verify_github_asset_checksum() {
    local archive="$1" asset_name="$2" digest="$3"
    local checksum_record checksum_name checksum_url checksum_file checksum_line expected
    local -a checksum_records=()
    if [[ "$digest" == sha256:* ]]; then
        verify_sha256 "$archive" "${digest#sha256:}"
        return
    fi

    mapfile -t checksum_records < <(jq -r '
        .assets[]
        | select(.name | test("(sha256|sha256sums|checksums?)"; "i"))
        | [.name, .browser_download_url] | @tsv
    ' "$RELEASE_JSON")
    if [[ ${#checksum_records[@]} -eq 0 ]]; then
        warn "$asset_name release does not publish a SHA-256 digest or checksum manifest"
        return 0
    fi

    for checksum_record in "${checksum_records[@]}"; do
        IFS=$'\t' read -r checksum_name checksum_url <<< "$checksum_record"
        make_temp_dir || return 1
        checksum_file="$NEW_TEMP_DIR/checksums.txt"
        download "$checksum_url" "$checksum_file" || continue
        checksum_line="$(grep -F "$asset_name" "$checksum_file" | head -n1 || true)"
        expected="$(grep -Eo '[0-9a-fA-F]{64}' <<< "$checksum_line" | head -n1 || true)"
        if [[ -z "$expected" && ( "$checksum_name" == "$asset_name.sha256" || "$checksum_name" == "$asset_name.sha256sum" ) ]]; then
            expected="$(grep -Eo '[0-9a-fA-F]{64}' "$checksum_file" | head -n1 || true)"
        fi
        if [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]]; then
            verify_sha256 "$archive" "${expected,,}"
            return
        fi
    done
    return 1
}

binary_version_works() {
    local binary="$1"
    timeout 10 "$binary" --version >/dev/null 2>&1 || \
        timeout 10 "$binary" -V >/dev/null 2>&1
}

download_github_asset() {
    local repository="$1" asset_regex="$2"
    local metadata tag asset_name asset_url digest archive
    make_temp_dir || return 1
    metadata="$NEW_TEMP_DIR/asset.tsv"
    github_release_asset "$repository" "$asset_regex" "$metadata" || return 1
    IFS=$'\t' read -r tag asset_name asset_url digest < "$metadata"
    [[ -n "$tag" && -n "$asset_name" && -n "$asset_url" ]] || return 1
    make_temp_dir || return 1
    archive="$NEW_TEMP_DIR/$asset_name"
    download "$asset_url" "$archive" || return 1
    verify_github_asset_checksum "$archive" "$asset_name" "$digest" || return 1
    RELEASE_TAG="$tag"
    RELEASE_ARCHIVE="$archive"
}

install_release_binary() {
    local label="$1" command_name="$2" repository="$3" asset_regex="$4" binary_name="$5"
    local extract_dir destination
    local -a matches=()
    if have "$command_name"; then
        if binary_version_works "$(command -v "$command_name")"; then
            present "$command_name"
            return 0
        fi
        warn "$command_name on PATH cannot complete a version probe; installing a user-local replacement"
    fi
    download_github_asset "$repository" "$asset_regex" || return 1
    make_temp_dir || return 1
    extract_dir="$NEW_TEMP_DIR/extract"
    extract_archive "$RELEASE_ARCHIVE" "$extract_dir" || return 1
    mapfile -t matches < <(find "$extract_dir" -type f -name "$binary_name" -print)
    [[ ${#matches[@]} -eq 1 ]] || return 1
    chmod 0755 "${matches[0]}" || return 1
    binary_version_works "${matches[0]}" || return 1
    destination="$LOCAL_BIN/$command_name"
    backup_existing "$destination" || return 1
    install -m 0755 "${matches[0]}" "$destination" || return 1
    have "$command_name" || return 1
    binary_version_works "$destination" || return 1
    info "installed $label -> $destination"
}

preflight() {
    local architecture glibc_line
    [[ $# -eq 0 ]] || { info "usage: ./install.sh" >&2; return 2; }
    (( EUID != 0 )) || { info "run this installer as a normal user, not root or sudo" >&2; return 2; }
    [[ -n "${HOME:-}" && "$HOME" != / ]] || { info "HOME is not a safe user directory" >&2; return 2; }
    architecture="$(uname -m)"
    [[ "$architecture" == x86_64 ]] || { info "unsupported architecture: $architecture (x86_64 required)" >&2; return 2; }
    [[ -r /etc/os-release ]] || { info "missing /etc/os-release" >&2; return 2; }
    # shellcheck disable=SC1091
    source /etc/os-release
    PLATFORM_ID="${ID,,}"
    PLATFORM_VERSION="${VERSION_ID:-}"
    case "$PLATFORM_ID" in
        debian|ubuntu) PLATFORM_FAMILY=debian ;;
        rhel|rocky|almalinux)
            PLATFORM_FAMILY=rhel
            RHEL_MAJOR="${PLATFORM_VERSION%%.*}"
            [[ "$RHEL_MAJOR" =~ ^[0-9]+$ && "$RHEL_MAJOR" -ge 8 ]] || {
                info "unsupported $PLATFORM_ID version: ${PLATFORM_VERSION:-unknown} (8+ required)" >&2
                return 2
            }
            ;;
        *) info "unsupported distribution: $PLATFORM_ID" >&2; return 2 ;;
    esac
    glibc_line="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
    GLIBC_VERSION="${glibc_line##* }"
    version_ge "$GLIBC_VERSION" 2.28 || {
        info "unsupported glibc: ${GLIBC_VERSION:-unknown} (2.28+ required)" >&2
        return 2
    }
    have sudo || { info "sudo is required for system packages" >&2; return 2; }
}

install_system_packages_debian() {
    local -a packages=(
        ca-certificates git curl jq fish python3 python3-venv tar unzip zip xz-utils bzip2
        bash-completion build-essential cmake ninja-build pkg-config libssl-dev libevent-dev
        libncurses-dev gettext bison
    )
    attempt "apt package index" sudo apt-get update
    attempt "apt system prerequisites" sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
}

install_system_packages_rhel() {
    local epel_url="https://dl.fedoraproject.org/pub/epel/epel-release-latest-${RHEL_MAJOR}.noarch.rpm"
    local -a packages=(
        ca-certificates git curl jq fish python3 tar unzip zip xz bzip2 bash-completion
        gcc gcc-c++ make cmake ninja-build pkgconf-pkg-config openssl-devel libevent-devel
        ncurses-devel gettext bison
    )
    attempt "dnf plugins" sudo dnf install -y dnf-plugins-core
    case "$PLATFORM_ID" in
        rocky|almalinux)
            if (( RHEL_MAJOR == 8 )); then
                attempt "enable PowerTools" sudo dnf config-manager --set-enabled powertools
            else
                attempt "enable CRB" sudo dnf config-manager --set-enabled crb
            fi
            ;;
        rhel)
            attempt "enable CodeReady Builder" sudo subscription-manager repos \
                --enable "codeready-builder-for-rhel-${RHEL_MAJOR}-x86_64-rpms"
            ;;
    esac
    attempt "install EPEL" sudo dnf install -y "$epel_url"
    attempt "dnf system prerequisites" sudo dnf install -y "${packages[@]}"
}

install_rust() {
    local script
    if have cargo; then
        present cargo
        return 0
    fi
    make_temp_dir || return 1
    script="$NEW_TEMP_DIR/rustup-init.sh"
    download https://sh.rustup.rs "$script" || return 1
    sh "$script" -y --profile minimal --default-toolchain stable --no-modify-path || return 1
    [[ -r "$HOME/.cargo/env" ]] || return 1
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
    have cargo
}

activate_cargo() {
    if [[ -r "$HOME/.cargo/env" ]]; then
        # shellcheck disable=SC1091
        source "$HOME/.cargo/env"
    fi
}

install_go() {
    local json row filename expected_sha archive extract_dir
    if have go; then
        present go
        return 0
    fi
    have jq && have sha256sum || return 1
    make_temp_dir || return 1
    json="$NEW_TEMP_DIR/go.json"
    download 'https://go.dev/dl/?mode=json' "$json" || return 1
    row="$(jq -r '
        map(select(.stable == true))[0].files[]
        | select(.os == "linux" and .arch == "amd64" and (.filename | endswith(".tar.gz")))
        | [.filename, .sha256] | @tsv
    ' "$json")" || return 1
    [[ "$(printf '%s\n' "$row" | sed '/^$/d' | wc -l)" -eq 1 ]] || return 1
    IFS=$'\t' read -r filename expected_sha <<< "$row"
    [[ -n "$filename" && "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
    archive="$NEW_TEMP_DIR/$filename"
    download "https://go.dev/dl/$filename" "$archive" || return 1
    verify_sha256 "$archive" "$expected_sha" || return 1
    make_temp_dir || return 1
    extract_dir="$NEW_TEMP_DIR/extract"
    extract_archive "$archive" "$extract_dir" || return 1
    [[ -x "$extract_dir/go/bin/go" ]] || return 1
    "$extract_dir/go/bin/go" version >/dev/null || return 1
    backup_existing "$LOCAL_GO" || return 1
    mkdir -p "$LOCAL_PREFIX" || return 1
    mv "$extract_dir/go" "$LOCAL_GO" || return 1
    export PATH="$LOCAL_GO/bin:$PATH"
    have go
}

activate_nvm() {
    [[ -s "$NVM_DIR/nvm.sh" ]] || return 1
    export NVM_DIR NVM_SYMLINK_CURRENT=true
    set +u
    # shellcheck disable=SC1090
    source "$NVM_DIR/nvm.sh"
    set -u
}

install_node() {
    local metadata tag
    if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
        if [[ -e "$NVM_DIR" || -L "$NVM_DIR" ]]; then
            return 1
        fi
        have git && have jq || return 1
        make_temp_dir || return 1
        metadata="$NEW_TEMP_DIR/nvm.json"
        download https://api.github.com/repos/nvm-sh/nvm/releases/latest "$metadata" || return 1
        tag="$(jq -r '.tag_name // empty' "$metadata")" || return 1
        [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
        git clone --depth 1 --branch "$tag" https://github.com/nvm-sh/nvm.git "$NVM_DIR" || return 1
    fi
    activate_nvm || return 1
    if [[ ! -x "$NVM_DIR/current/bin/node" ]]; then
        nvm install node --latest-npm || return 1
        nvm alias default node || return 1
        nvm use default >/dev/null || return 1
    else
        present node
    fi
    export PATH="$NVM_DIR/current/bin:$PATH"
    have node && have npm
}

install_uv() {
    local script
    if have uv; then
        present uv
        return 0
    fi
    make_temp_dir || return 1
    script="$NEW_TEMP_DIR/uv-installer.sh"
    download https://astral.sh/uv/install.sh "$script" || return 1
    UV_INSTALL_DIR="$LOCAL_BIN" UV_NO_MODIFY_PATH=1 sh "$script" || return 1
    have uv
}

install_cargo_tool() {
    local crate="$1" command_name="$2"
    if have "$command_name"; then
        present "$command_name"
        return 0
    fi
    have cargo || return 1
    cargo install --locked --root "$LOCAL_PREFIX" "$crate" || return 1
    have "$command_name"
}

install_glow() {
    if have glow; then present glow; return 0; fi
    have go || return 1
    GOBIN="$LOCAL_BIN" go install github.com/charmbracelet/glow@latest || return 1
    have glow
}

install_codex() {
    if have codex; then present codex; return 0; fi
    have npm || return 1
    npm install --global --prefix "$LOCAL_PREFIX" @openai/codex || return 1
    have codex
}

install_sqlit() {
    if have sqlit; then present sqlit; return 0; fi
    have uv || return 1
    uv tool install sqlit-tui || return 1
    have sqlit
}

install_claude() {
    local script
    if have claude; then present claude; return 0; fi
    make_temp_dir || return 1
    script="$NEW_TEMP_DIR/claude-installer.sh"
    download https://claude.ai/install.sh "$script" || return 1
    bash "$script" latest || return 1
    have claude
}

install_starship() {
    local script
    if have starship; then present starship; return 0; fi
    make_temp_dir || return 1
    script="$NEW_TEMP_DIR/starship-installer.sh"
    download https://starship.rs/install.sh "$script" || return 1
    sh "$script" -y -b "$LOCAL_BIN" || return 1
    have starship
}

install_zoxide() {
    local script
    if have zoxide; then present zoxide; return 0; fi
    make_temp_dir || return 1
    script="$NEW_TEMP_DIR/zoxide-installer.sh"
    download https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh "$script" || return 1
    sh "$script" || return 1
    have zoxide
}

tmux_version() { tmux -V 2>/dev/null | awk '{print $2}'; }
nvim_version() { nvim --version 2>/dev/null | sed -n '1s/^NVIM v\{0,1\}//p'; }

install_tmux() {
    local extract_dir source_dir jobs
    local -a configure_files=()
    if have tmux && version_ge "$(tmux_version)" 3.2; then
        present tmux
        return 0
    fi
    download_github_asset tmux/tmux '^tmux-[0-9][0-9.]*[a-z]*\.tar\.gz$' || return 1
    make_temp_dir || return 1
    extract_dir="$NEW_TEMP_DIR/extract"
    extract_archive "$RELEASE_ARCHIVE" "$extract_dir" || return 1
    mapfile -t configure_files < <(find "$extract_dir" -mindepth 2 -maxdepth 2 -type f -name configure -print)
    [[ ${#configure_files[@]} -eq 1 ]] || return 1
    source_dir="$(dirname "${configure_files[0]}")"
    jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)"
    (cd "$source_dir" && ./configure --prefix="$LOCAL_PREFIX" && make -j "$jobs" && make install) || return 1
    have tmux && version_ge "$(tmux_version)" 3.2
}

install_neovim_from_source() {
    local tag="$1" target="$2" archive extract_dir source_dir jobs
    make_temp_dir || return 1
    archive="$NEW_TEMP_DIR/neovim-source.tar.gz"
    download "https://github.com/neovim/neovim/archive/refs/tags/$tag.tar.gz" "$archive" || return 1
    make_temp_dir || return 1
    extract_dir="$NEW_TEMP_DIR/extract"
    extract_archive "$archive" "$extract_dir" || return 1
    source_dir="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d -name 'neovim-*' -print -quit)"
    [[ -n "$source_dir" ]] || return 1
    jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)"
    backup_existing "$target" || return 1
    (cd "$source_dir" && make -j "$jobs" CMAKE_BUILD_TYPE=Release CMAKE_INSTALL_PREFIX="$target" install) || return 1
}

install_neovim() {
    local extract_dir root target destination
    if have nvim && version_ge "$(nvim_version)" 0.11.2; then
        present nvim
        return 0
    fi
    download_github_asset neovim/neovim '^nvim-linux-x86_64\.tar\.gz$' || return 1
    target="$LOCAL_OPT/nvim-$RELEASE_TAG"
    make_temp_dir || return 1
    extract_dir="$NEW_TEMP_DIR/extract"
    extract_archive "$RELEASE_ARCHIVE" "$extract_dir" || return 1
    root="$extract_dir/nvim-linux-x86_64"
    if [[ -x "$root/bin/nvim" ]] && "$root/bin/nvim" --version >/dev/null 2>&1; then
        backup_existing "$target" || return 1
        mkdir -p "$LOCAL_OPT" || return 1
        mv "$root" "$target" || return 1
    else
        install_neovim_from_source "$RELEASE_TAG" "$target" || return 1
    fi
    destination="$LOCAL_BIN/nvim"
    backup_existing "$destination" || return 1
    ln -s "$target/bin/nvim" "$destination" || return 1
    have nvim && version_ge "$(nvim_version)" 0.11.2
}

link_dotfiles() {
    local entry
    local -a links=(
        "$DOTFILES/shell/.bashrc|$HOME/.bashrc"
        "$DOTFILES/shell/.profile|$HOME/.profile"
        "$DOTFILES/git/.gitconfig|$HOME/.gitconfig"
        "$DOTFILES/git/gitignore|$HOME/.config/git/ignore"
        "$DOTFILES/config/starship.toml|$HOME/.config/starship.toml"
        "$DOTFILES/config/nvim|$HOME/.config/nvim"
        "$DOTFILES/config/fish|$HOME/.config/fish"
        "$DOTFILES/config/zellij/config.kdl|$HOME/.config/zellij/config.kdl"
        "$DOTFILES/config/btop/btop.conf|$HOME/.config/btop/btop.conf"
        "$DOTFILES/claude/settings.json|$HOME/.claude/settings.json"
        "$DOTFILES/claude/statusline.sh|$HOME/.claude/statusline.sh"
        "$DOTFILES/claude/claude-statusline|$HOME/.claude/claude-statusline"
        "$DOTFILES/claude/themes/snazzy-light.json|$HOME/.claude/themes/snazzy-light.json"
        "$DOTFILES/codex/config.toml|$HOME/.codex/config.toml"
        "$DOTFILES/tmux/.tmux.conf|$HOME/.tmux.conf"
        "$DOTFILES/tmux/.gitmux.conf|$HOME/.gitmux.conf"
    )
    for entry in "${links[@]}"; do
        attempt "link ${entry#*|}" link_path "${entry%%|*}" "${entry#*|}"
    done
}

seed_secrets() {
    local secrets_file="$DOTFILES/secrets.env" key="" old_bashrc=""
    local store_dir="$DOTFILES/secrets"
    mkdir -p "$store_dir" || return 1
    chmod 0700 "$store_dir" || return 1
    if [[ ! -f "$secrets_file" ]]; then
        if [[ -n "${LLM_GATEWAY_KEY:-}" ]]; then
            key="$LLM_GATEWAY_KEY"
        elif [[ -n "$BACKUP_DIR" ]]; then
            old_bashrc="$BACKUP_DIR/${HOME#/}/.bashrc"
            if [[ -f "$old_bashrc" ]]; then
                key="$(sed -n 's/.*LLM_GATEWAY_KEY="\([^"]*\)".*/\1/p' "$old_bashrc" | head -n1)"
            fi
        fi
        umask 077
        {
            printf '# Untracked secret environment.\n'
            printf 'export LLM_GATEWAY_KEY=%q\n' "$key"
        } > "$secrets_file" || return 1
        [[ -n "$key" ]] || warn "LLM_GATEWAY_KEY is unset; edit $secrets_file"
    fi
    chmod 0600 "$secrets_file" || return 1
    link_path "$secrets_file" "$HOME/.config/secrets.env" || return 1
    seed_secret_blob "$HOME/.config/gh/hosts.yml" "$store_dir/gh-hosts.yml" || return 1
    seed_secret_blob "$HOME/.claude/.credentials.json" "$store_dir/claude-credentials.json" || return 1
}

seed_secret_blob() {
    local live="$1" store="$2" backup_copy=""
    if [[ ! -f "$store" ]]; then
        if [[ -f "$live" && ! -L "$live" ]]; then
            cp "$live" "$store" || return 1
        elif [[ -n "$BACKUP_DIR" ]]; then
            backup_copy="$BACKUP_DIR/${live#/}"
            if [[ -f "$backup_copy" ]]; then
                cp "$backup_copy" "$store" || return 1
            fi
        fi
    fi
    if [[ -f "$store" ]]; then
        chmod 0600 "$store" || return 1
        link_path "$store" "$live" || return 1
    else
        warn "no saved credential source for $live; authenticate after installation"
    fi
}

install_tmux_plugins() {
    local tpm="$HOME/.tmux/plugins/tpm"
    if [[ ! -d "$tpm/.git" ]]; then
        if [[ -e "$tpm" || -L "$tpm" ]]; then
            return 1
        fi
        git clone https://github.com/tmux-plugins/tpm "$tpm" || return 1
    else
        present tpm
    fi
    TMUX_PLUGIN_MANAGER_PATH="$HOME/.tmux/plugins/" "$tpm/bin/install_plugins" || return 1
    [[ -f "$HOME/.tmux/plugins/tmux/catppuccin.tmux" ]]
}

skills_origin_is_expected() {
    local origin="$1"
    case "$origin" in
        https://github.com/abchoudh-amd/compute-ai-skills|https://github.com/abchoudh-amd/compute-ai-skills.git|\
        git@github.com:abchoudh-amd/compute-ai-skills.git|ssh://git@github.com/abchoudh-amd/compute-ai-skills.git) return 0 ;;
        *) return 1 ;;
    esac
}

link_runtime_tree() {
    local source_dir="$1" target_dir="$2" source_path
    [[ -d "$source_dir" ]] || return 1
    mkdir -p "$target_dir" || return 1
    shopt -s nullglob
    for source_path in "$source_dir"/*; do
        link_path "$source_path" "$target_dir/$(basename "$source_path")" || {
            shopt -u nullglob
            return 1
        }
    done
    shopt -u nullglob
}

install_compute_skills() {
    local origin branch status
    if [[ ! -e "$COMPUTE_SKILLS" ]]; then
        GIT_TERMINAL_PROMPT=0 git clone --branch main \
            https://github.com/abchoudh-amd/compute-ai-skills.git "$COMPUTE_SKILLS" || return 1
    fi
    [[ -d "$COMPUTE_SKILLS/.git" ]] || return 1
    origin="$(git -C "$COMPUTE_SKILLS" remote get-url origin 2>/dev/null)" || return 1
    skills_origin_is_expected "$origin" || return 1
    branch="$(git -C "$COMPUTE_SKILLS" branch --show-current 2>/dev/null)"
    status="$(git -C "$COMPUTE_SKILLS" status --porcelain 2>/dev/null)"
    if [[ "$branch" == main && -z "$status" ]]; then
        GIT_TERMINAL_PROMPT=0 git -C "$COMPUTE_SKILLS" pull --ff-only || \
            warn "could not fast-forward $COMPUTE_SKILLS; using the existing checkout"
    else
        warn "$COMPUTE_SKILLS is dirty or not on main; preserving it without update"
    fi
    link_runtime_tree "$COMPUTE_SKILLS/.claude/skills" "$HOME/.claude/skills" || return 1
    link_runtime_tree "$COMPUTE_SKILLS/.claude/hooks" "$HOME/.claude/hooks" || return 1
    link_runtime_tree "$COMPUTE_SKILLS/.codex/skills" "$HOME/.codex/skills" || return 1
    link_runtime_tree "$COMPUTE_SKILLS/.codex/hooks" "$HOME/.codex/hooks" || return 1
    link_path "$COMPUTE_SKILLS/.codex/hooks.json" "$HOME/.codex/hooks.json" || return 1
}

validate_required_commands() {
    local command_name
    local -a commands=(
        git curl jq fish python3 cargo go node npm uv eza fd diskus zellij csvlens
        yazi ya glow codex sqlit claude starship zoxide fzf rg btop duf gh gitmux tmux nvim
    )
    for command_name in "${commands[@]}"; do
        have "$command_name" || fail "required command missing: $command_name"
    done
    if have tmux && ! version_ge "$(tmux_version)" 3.2; then
        fail "tmux 3.2+ required"
    fi
    if have nvim && ! version_ge "$(nvim_version)" 0.11.2; then
        fail "Neovim 0.11.2+ required"
    fi
    for command_name in fzf rg btop duf gh gitmux; do
        if have "$command_name" && ! binary_version_works "$(command -v "$command_name")"; then
            fail "required command cannot execute a version probe: $command_name"
        fi
    done
    [[ -f "$HOME/.tmux/plugins/tmux/catppuccin.tmux" ]] || fail "Catppuccin tmux plugin missing"
    [[ -L "$HOME/.codex/hooks.json" ]] || fail "Codex hooks.json link missing"
}

print_summary() {
    local item
    section "Summary"
    printf '  installed/updated: %d\n' "${#INSTALLED[@]}"
    for item in "${INSTALLED[@]}"; do printf '    + %s\n' "$item"; done
    printf '  already present:  %d\n' "${#PRESENT[@]}"
    printf '  warnings:         %d\n' "${#WARNINGS[@]}"
    for item in "${WARNINGS[@]}"; do printf '    ! %s\n' "$item"; done
    printf '  failures:         %d\n' "${#FAILURES[@]}"
    for item in "${FAILURES[@]}"; do printf '    x %s\n' "$item"; done
    [[ -n "$BACKUP_DIR" ]] && printf '  backups: %s\n' "$BACKUP_DIR"
    info "post-install: authenticate gh/Claude/Codex/Jira as needed"
    info "post-install: review Codex hooks with /hooks, then restart Claude and Codex"
    info "open a new shell after installation"
}

main() {
    preflight "$@" || exit $?
    mkdir -p "$LOCAL_BIN" "$LOCAL_OPT" || { info "cannot create $LOCAL_PREFIX" >&2; exit 1; }
    export PATH="$LOCAL_BIN:$LOCAL_GO/bin:$HOME/.cargo/bin:$NVM_DIR/current/bin:$PATH"

    section "System prerequisites ($PLATFORM_ID)"
    if [[ "$PLATFORM_FAMILY" == debian ]]; then
        install_system_packages_debian
    else
        install_system_packages_rhel
    fi

    section "Language toolchains"
    attempt "install Rust stable" install_rust
    activate_cargo
    attempt "install latest stable Go" install_go
    attempt "install NVM and current Node/npm" install_node
    activate_nvm || true
    export PATH="$LOCAL_BIN:$LOCAL_GO/bin:$HOME/.cargo/bin:$NVM_DIR/current/bin:$PATH"
    attempt "install uv" install_uv

    section "Cargo tools"
    attempt "install eza" install_cargo_tool eza eza
    attempt "install fd" install_cargo_tool fd-find fd
    attempt "install diskus" install_cargo_tool diskus diskus
    attempt "install zellij" install_cargo_tool zellij zellij
    attempt "install csvlens" install_cargo_tool csvlens csvlens
    attempt "install yazi" install_cargo_tool yazi-fm yazi
    attempt "install ya" install_cargo_tool yazi-cli ya

    section "Language-managed tools"
    attempt "install glow" install_glow
    attempt "install Codex" install_codex
    attempt "install sqlit" install_sqlit
    attempt "install Claude" install_claude

    section "User-local tools"
    attempt "install Starship" install_starship
    attempt "install zoxide" install_zoxide
    attempt "install fzf" install_release_binary fzf fzf junegunn/fzf '^fzf-[^/]+-linux_amd64\.tar\.gz$' fzf
    attempt "install ripgrep" install_release_binary ripgrep rg BurntSushi/ripgrep '^ripgrep-[^-]+-x86_64-unknown-linux-musl\.tar\.gz$' rg
    attempt "install btop" install_release_binary btop btop aristocratos/btop '^btop-x86_64-unknown-linux-musl\.tar\.gz$' btop
    attempt "install duf" install_release_binary duf duf muesli/duf '^duf_[^_]+_linux_x86_64\.tar\.gz$' duf
    attempt "install GitHub CLI" install_release_binary gh gh cli/cli '^gh_[^_]+_linux_amd64\.tar\.gz$' gh
    attempt "install gitmux" install_release_binary gitmux gitmux arl/gitmux '^gitmux_v[^_]+_linux_amd64\.tar\.gz$' gitmux
    attempt "install tmux 3.2+" install_tmux
    attempt "install Neovim 0.11.2+" install_neovim

    section "Configuration and secrets"
    link_dotfiles
    attempt "seed and link secrets" seed_secrets

    section "tmux plugins"
    attempt "install TPM and Catppuccin" install_tmux_plugins

    section "Claude and Codex skills"
    attempt "install compute-ai-skills" install_compute_skills

    section "Final validation"
    validate_required_commands
    print_summary
    (( ${#FAILURES[@]} == 0 ))
}

main "$@"
