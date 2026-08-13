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

declare -a COMPUTE_RUNTIME_TREES=(
    "$COMPUTE_SKILLS/.claude/skills|$HOME/.claude/skills"
    "$COMPUTE_SKILLS/.claude/agents|$HOME/.claude/agents"
    "$COMPUTE_SKILLS/.claude/agent-resources|$HOME/.claude/agent-resources"
    "$COMPUTE_SKILLS/.claude/hooks|$HOME/.claude/hooks"
    "$COMPUTE_SKILLS/.claude/references|$HOME/.claude/references"
    "$COMPUTE_SKILLS/.codex/skills|$HOME/.codex/skills"
    "$COMPUTE_SKILLS/.codex/agents|$HOME/.codex/agents"
    "$COMPUTE_SKILLS/.codex/agent-resources|$HOME/.codex/agent-resources"
    "$COMPUTE_SKILLS/.codex/hooks|$HOME/.codex/hooks"
    "$COMPUTE_SKILLS/.cursor/skills|$HOME/.cursor/skills"
    "$COMPUTE_SKILLS/.cursor/agents|$HOME/.cursor/agents"
    "$COMPUTE_SKILLS/.cursor/agent-resources|$HOME/.cursor/agent-resources"
    "$COMPUTE_SKILLS/.cursor/hooks|$HOME/.cursor/hooks"
    "$COMPUTE_SKILLS/.cursor/rules|$HOME/.cursor/rules"
)

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
    if [[ -z "$BACKUP_DIR" ]]; then
        BACKUP_DIR="$(mktemp -d "$HOME/.dotfiles-backup-$(date +%Y%m%d-%H%M%S).XXXXXX")" || return 1
    fi
    chmod 0700 "$BACKUP_DIR"
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

install_herdr() {
    if have herdr; then
        if binary_version_works "$(command -v herdr)"; then
            present herdr
            return 0
        fi
        warn "herdr on PATH cannot complete a version probe; reinstalling with the official installer"
    fi
    curl -fsSL https://herdr.dev/install.sh | sh || return 1
    have herdr || return 1
    binary_version_works "$(command -v herdr)"
}

preflight() {
    local architecture glibc_line
    [[ $# -eq 0 ]] || { info "usage: ./install.sh" >&2; return 2; }
    (( EUID != 0 )) || { info "run this installer as a normal user, not root or sudo" >&2; return 2; }
    [[ -n "${HOME:-}" && "$HOME" != / ]] || { info "HOME is not a safe user directory" >&2; return 2; }
    [[ -z "${CLAUDE_CONFIG_DIR:-}" ]] || {
        info "CLAUDE_CONFIG_DIR must be unset so the installer can protect $HOME/.claude.json" >&2
        return 2
    }
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
        ca-certificates git curl jq fish python3 python3-venv tar unzip zip xz-utils bzip2 findutils
        bash-completion build-essential cmake ninja-build pkg-config libssl-dev libevent-dev
        libncurses-dev gettext bison
    )
    attempt "apt package index" sudo apt-get update
    attempt "apt system prerequisites" sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
}

install_system_packages_rhel() {
    local epel_url="https://dl.fedoraproject.org/pub/epel/epel-release-latest-${RHEL_MAJOR}.noarch.rpm"
    local -a packages=(
        ca-certificates git curl jq fish python3 tar unzip zip xz bzip2 findutils bash-completion
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

json_document_has_unique_object_keys() {
    local document="$1"
    [[ -f "$document" && -r "$document" ]] || return 1
    python3 - "$document" >/dev/null 2>&1 <<'PY'
import json
import sys


class DuplicateObjectKey(Exception):
    pass


def reject_duplicate_object_keys(pairs):
    parsed_object = {}
    for key, value in pairs:
        if key in parsed_object:
            raise DuplicateObjectKey
        parsed_object[key] = value
    return parsed_object


try:
    with open(sys.argv[1], "r", encoding="utf-8") as document:
        json.load(document, object_pairs_hook=reject_duplicate_object_keys)
except Exception:
    raise SystemExit(1)
PY
}

claude_mcp_declaration_is_valid() {
    local declaration="$1"
    json_document_has_unique_object_keys "$declaration" || return 1
    jq -se '
        length == 1 and
        (.[0] |
            type == "object" and
            keys == ["mcpServers"] and
            (.mcpServers | type == "object") and
            (.mcpServers | keys) == ["confluence", "jira"] and
            .mcpServers.jira == {
                "type": "http",
                "url": "https://mcp.atlassian.com/v1/mcp/authv2"
            } and
            .mcpServers.confluence == {
                "type": "http",
                "url": "https://mcp.atlassian.com/v1/mcp/authv2"
            })
    ' "$declaration" >/dev/null 2>&1
}

claude_state_is_valid() {
    local state="$1"
    [[ -f "$state" && ! -L "$state" ]] || return 1
    json_document_has_unique_object_keys "$state" || return 1
    jq -se '
        length == 1 and
        (.[0] |
            type == "object" and
            ((has("mcpServers") | not) or (.mcpServers | type == "object")))
    ' "$state" >/dev/null 2>&1
}

canonical_declared_claude_record() {
    local declaration="$1" name="$2"
    claude_mcp_declaration_is_valid "$declaration" || return 1
    jq -S -c --arg name "$name" '.mcpServers[$name]' "$declaration" 2>/dev/null
}

lookup_claude_record() {
    local state="$1" name="$2" output_name="$3"
    local lookup_result presence record_value
    printf -v "$output_name" '%s' "" || return 2
    claude_state_is_valid "$state" || return 2
    lookup_result="$(jq -S -c --arg name "$name" '
        (.mcpServers // {}) as $servers |
        if ($servers | has($name)) then
            [true, $servers[$name]]
        else
            [false]
        end
    ' "$state" 2>/dev/null)" || return 2
    presence="$(jq -r '.[0] | if . == true then "present" elif . == false then "absent" else "invalid" end' <<< "$lookup_result" 2>/dev/null)" || return 2
    case "$presence" in
        present)
            record_value="$(jq -S -c '.[1]' <<< "$lookup_result" 2>/dev/null)" || return 2
            printf -v "$output_name" '%s' "$record_value" || return 2
            return 0
            ;;
        absent) return 1 ;;
        *) return 2 ;;
    esac
}

canonical_claude_non_mcp_fields() {
    claude_state_is_valid "$1" || return 1
    jq -S -c 'del(.mcpServers)' "$1" 2>/dev/null
}

canonical_unmanaged_claude_records() {
    claude_state_is_valid "$1" || return 1
    jq -S -c '
        (.mcpServers // {}) |
        with_entries(select(.key != "jira" and .key != "confluence"))
    ' "$1" 2>/dev/null
}

canonical_claude_state() {
    claude_state_is_valid "$1" || return 1
    jq -S -c '.' "$1" 2>/dev/null
}

claude_mcp_state_is_exact() {
    local state="$1" declaration="$2" name desired_record current_record
    local -a names=(jira confluence)
    claude_mcp_declaration_is_valid "$declaration" || return 1
    claude_state_is_valid "$state" || return 1
    for name in "${names[@]}"; do
        desired_record="$(canonical_declared_claude_record "$declaration" "$name")" || return 1
        lookup_claude_record "$state" "$name" current_record || return 1
        [[ "$current_record" == "$desired_record" ]] || return 1
    done
}

create_claude_state_snapshot() {
    local state="$1" snapshot="$2"
    claude_state_is_valid "$state" || return 1
    [[ ! -e "$snapshot" && ! -L "$snapshot" ]] || return 1
    mkdir -p "$(dirname "$snapshot")" || return 1
    (umask 077; cp -- "$state" "$snapshot") || return 1
    if ! chmod 0600 "$snapshot" || ! claude_state_is_valid "$snapshot"; then
        rm -f -- "$snapshot"
        return 1
    fi
    info "back $state -> $snapshot"
}

claude_unrelated_state_matches() {
    local state="$1" expected_non_mcp="$2" expected_unmanaged="$3"
    local current_non_mcp current_unmanaged
    current_non_mcp="$(canonical_claude_non_mcp_fields "$state")" || return 1
    current_unmanaged="$(canonical_unmanaged_claude_records "$state")" || return 1
    [[ "$current_non_mcp" == "$expected_non_mcp" &&
       "$current_unmanaged" == "$expected_unmanaged" ]]
}

claude_existing_state_matches_transaction() {
    local state="$1" expected_non_mcp="$2" expected_unmanaged="$3" expected_managed="$4"
    local canonical_state current_non_mcp current_unmanaged current_managed
    canonical_state="$(canonical_claude_state "$state")" || return 1
    current_non_mcp="$(jq -S -c 'del(.mcpServers)' <<< "$canonical_state" 2>/dev/null)" || return 1
    current_unmanaged="$(jq -S -c '(.mcpServers // {}) | with_entries(select(.key != "jira" and .key != "confluence"))' <<< "$canonical_state" 2>/dev/null)" || return 1
    current_managed="$(jq -S -c '(.mcpServers // {}) | with_entries(select(.key == "jira" or .key == "confluence"))' <<< "$canonical_state" 2>/dev/null)" || return 1
    [[ "$current_non_mcp" == "$expected_non_mcp" &&
       "$current_unmanaged" == "$expected_unmanaged" &&
       "$current_managed" == "$expected_managed" ]]
}

report_claude_manual_recovery() {
    local reason="$1" state="$2" snapshot="${3:-}"
    local displaced_state="${4:-}" restore_file="${5:-}" recovery_directory="${6:-}"
    info "manual recovery required: $reason" >&2
    if [[ -e "$state" || -L "$state" ]]; then
        info "current Claude state preserved at $state" >&2
    else
        info "Claude state destination is absent at $state" >&2
    fi
    if [[ -n "$snapshot" ]]; then
        info "original Claude state snapshot preserved at $snapshot" >&2
    else
        info "no original Claude state file existed before this run" >&2
    fi
    if [[ -n "$displaced_state" && ( -e "$displaced_state" || -L "$displaced_state" ) ]]; then
        info "displaced Claude state preserved at $displaced_state" >&2
    fi
    if [[ -n "$restore_file" && ( -e "$restore_file" || -L "$restore_file" ) ]]; then
        info "prepared Claude state preserved at $restore_file" >&2
    fi
    if [[ -n "$recovery_directory" && -d "$recovery_directory" ]]; then
        info "private Claude recovery directory preserved at $recovery_directory" >&2
    fi
    info "review the preserved files privately, restore the intended regular JSON file at $state, and then rerun the installer" >&2
}

restore_displaced_claude_state_without_clobbering() {
    local state="$1" displaced_state="$2"
    [[ -e "$displaced_state" || -L "$displaced_state" ]] || return 1
    mv -T -n -- "$displaced_state" "$state" 2>/dev/null || return 1
    [[ ! -e "$displaced_state" && ! -L "$displaced_state" ]] || return 1
    [[ -e "$state" || -L "$state" ]]
}

recover_displaced_claude_state() {
    local reason="$1" state="$2" snapshot="$3"
    local displaced_state="$4" prepared_state="$5" recovery_directory="$6"
    local cleanup_failed=0
    if restore_displaced_claude_state_without_clobbering "$state" "$displaced_state"; then
        if [[ -n "$prepared_state" && ( -e "$prepared_state" || -L "$prepared_state" ) ]]; then
            rm -f -- "$prepared_state" || cleanup_failed=1
        fi
        rmdir -- "$recovery_directory" 2>/dev/null || cleanup_failed=1
        if (( cleanup_failed )); then
            report_claude_manual_recovery "$reason; the displaced current state was restored but recovery material remains" "$state" "$snapshot" "$displaced_state" "$prepared_state" "$recovery_directory"
        else
            report_claude_manual_recovery "$reason; the displaced current state was restored without overwriting another path" "$state" "$snapshot"
        fi
    else
        report_claude_manual_recovery "$reason; safe restoration of the displaced current state was not possible" "$state" "$snapshot" "$displaced_state" "$prepared_state" "$recovery_directory"
    fi
    return 1
}

atomic_restore_claude_state() {
    local state="$1" snapshot="$2" original_mode="$3"
    local expected_non_mcp="$4" expected_unmanaged="$5" expected_managed="$6"
    local state_directory recovery_directory displaced_state restore_file
    local displaced_live_state=0
    state_directory="$(dirname "$state")"
    recovery_directory="$(mktemp -d "$state_directory/.claude.json.recovery.XXXXXX")" || {
        report_claude_manual_recovery "a private Claude state recovery location could not be created" "$state" "$snapshot"
        return 1
    }
    if ! chmod 0700 "$recovery_directory"; then
        report_claude_manual_recovery "the Claude state recovery location could not be made private" "$state" "$snapshot" "" "" "$recovery_directory"
        return 1
    fi
    displaced_state="$recovery_directory/displaced-state"
    restore_file="$recovery_directory/original-state"
    if ! (umask 077; cp -- "$snapshot" "$restore_file") ||
       ! chmod "$original_mode" "$restore_file" ||
       ! claude_state_is_valid "$restore_file"; then
        rm -f -- "$restore_file"
        rmdir -- "$recovery_directory" 2>/dev/null || true
        report_claude_manual_recovery "the original Claude state could not be prepared for restoration" "$state" "$snapshot" "" "$restore_file" "$recovery_directory"
        return 1
    fi

    if [[ -e "$state" || -L "$state" ]]; then
        if mv -T -- "$state" "$displaced_state"; then
            displaced_live_state=1
        elif [[ -e "$state" || -L "$state" ]]; then
            report_claude_manual_recovery "the live Claude state could not be displaced safely for restoration" "$state" "$snapshot" "" "$restore_file" "$recovery_directory"
            return 1
        fi
    fi

    if (( displaced_live_state )) &&
       ! claude_existing_state_matches_transaction "$displaced_state" "$expected_non_mcp" "$expected_unmanaged" "$expected_managed"; then
        recover_displaced_claude_state "the last fully confirmed Claude transaction state could not be proven during MCP reconciliation" "$state" "$snapshot" "$displaced_state" "$restore_file" "$recovery_directory"
        return 1
    fi

    if ! ln -T -- "$restore_file" "$state"; then
        if (( displaced_live_state )); then
            recover_displaced_claude_state "the original Claude state could not be installed without replacing another state" "$state" "$snapshot" "$displaced_state" "$restore_file" "$recovery_directory"
        else
            report_claude_manual_recovery "the original Claude state could not be installed without replacing another state" "$state" "$snapshot" "" "$restore_file" "$recovery_directory"
        fi
        return 1
    fi

    if ! rm -f -- "$restore_file" ||
       { (( displaced_live_state )) && ! rm -f -- "$displaced_state"; } ||
       ! rmdir -- "$recovery_directory"; then
        report_claude_manual_recovery "the original Claude state was restored but recovery material could not be removed" "$state" "$snapshot" "$displaced_state" "$restore_file" "$recovery_directory"
        return 1
    fi
    return 0
}

restore_existing_claude_transaction() {
    local state="$1" snapshot="$2" original_mode="$3"
    local expected_non_mcp="$4" expected_unmanaged="$5" expected_managed="$6"
    atomic_restore_claude_state "$state" "$snapshot" "$original_mode" "$expected_non_mcp" "$expected_unmanaged" "$expected_managed" || return 1
    info "restored $state from $snapshot"
}

run_claude_mcp_remove() {
    env -u CLAUDE_CONFIG_DIR claude mcp remove --scope user "$1" >/dev/null 2>&1
}

run_claude_mcp_add() {
    env -u CLAUDE_CONFIG_DIR claude mcp add-json --scope user "$1" "$2" >/dev/null 2>&1
}

displaced_generated_claude_state_is_exact() {
    local state="$1" expected_non_mcp="$2" expected_unmanaged="$3"
    shift 3
    local name desired_record current_record record_status index
    local -a confirmed_additions=("$@")
    local -a managed_names=(jira confluence)
    local -A confirmed_records=()

    claude_unrelated_state_matches "$state" "$expected_non_mcp" "$expected_unmanaged" || return 1
    (( ${#confirmed_additions[@]} % 2 == 0 )) || return 1
    for (( index=0; index < ${#confirmed_additions[@]}; index+=2 )); do
        name="${confirmed_additions[index]}"
        desired_record="${confirmed_additions[index + 1]}"
        case "$name" in jira|confluence) ;; *) return 1 ;; esac
        [[ -z "${confirmed_records[$name]+present}" ]] || return 1
        confirmed_records["$name"]="$desired_record"
    done

    for name in "${managed_names[@]}"; do
        lookup_claude_record "$state" "$name" current_record
        record_status=$?
        if [[ -n "${confirmed_records[$name]+present}" ]]; then
            (( record_status == 0 )) || return 1
            [[ "$current_record" == "${confirmed_records[$name]}" ]] || return 1
        else
            (( record_status == 1 )) || return 1
        fi
    done
}

create_generated_claude_baseline_file() {
    local source_state="$1" baseline_file="$2" mode="$3"
    local expected_non_mcp="$4" expected_unmanaged="$5"
    local baseline_record record_status name
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [[ ! -e "$baseline_file" && ! -L "$baseline_file" ]] || return 1
    claude_state_is_valid "$source_state" || return 1
    if ! (umask 077; jq -S '
        del(.mcpServers.jira, .mcpServers.confluence) |
        if has("mcpServers") and (.mcpServers | length) == 0 then
            del(.mcpServers)
        else
            .
        end
    ' "$source_state" > "$baseline_file" 2>/dev/null) ||
       ! chmod "$mode" "$baseline_file" ||
       ! claude_unrelated_state_matches "$baseline_file" "$expected_non_mcp" "$expected_unmanaged"; then
        rm -f -- "$baseline_file"
        return 1
    fi
    for name in jira confluence; do
        lookup_claude_record "$baseline_file" "$name" baseline_record
        record_status=$?
        (( record_status == 1 )) && [[ -z "$baseline_record" ]] || {
            rm -f -- "$baseline_file"
            return 1
        }
    done
}

rollback_new_claude_state() {
    local state="$1" baseline_captured="$2" expected_non_mcp="$3" expected_unmanaged="$4"
    shift 4
    local -a confirmed_additions=("$@")
    local state_directory recovery_directory displaced_state baseline_file generated_mode

    if [[ ! -e "$state" && ! -L "$state" ]]; then
        return 0
    fi
    if (( ! baseline_captured )); then
        report_claude_manual_recovery "generated Claude state was preserved because its non-MCP baseline was not confirmed" "$state"
        return 1
    fi

    state_directory="$(dirname "$state")"
    recovery_directory="$(mktemp -d "$state_directory/.claude.json.rollback.XXXXXX")" || {
        report_claude_manual_recovery "a private generated Claude state recovery location could not be created" "$state"
        return 1
    }
    if ! chmod 0700 "$recovery_directory"; then
        report_claude_manual_recovery "the generated Claude state recovery location could not be made private" "$state" "" "" "" "$recovery_directory"
        return 1
    fi
    displaced_state="$recovery_directory/displaced-state"
    baseline_file="$recovery_directory/generated-baseline"
    if ! mv -T -- "$state" "$displaced_state"; then
        rmdir -- "$recovery_directory" 2>/dev/null || true
        report_claude_manual_recovery "the generated Claude state could not be displaced safely for rollback" "$state" "" "" "" "$recovery_directory"
        return 1
    fi

    if ! displaced_generated_claude_state_is_exact "$displaced_state" "$expected_non_mcp" "$expected_unmanaged" "${confirmed_additions[@]}"; then
        recover_displaced_claude_state "the displaced generated Claude state contained unexpected or unconfirmed content" "$state" "" "$displaced_state" "" "$recovery_directory"
        return 1
    fi

    if [[ "$expected_non_mcp" == '{}' && "$expected_unmanaged" == '{}' ]]; then
        if [[ -e "$state" || -L "$state" ]]; then
            report_claude_manual_recovery "another Claude state appeared while the proven-empty generated state was being rolled back" "$state" "" "$displaced_state" "" "$recovery_directory"
            return 1
        fi
        if ! rm -f -- "$displaced_state" || ! rmdir -- "$recovery_directory"; then
            report_claude_manual_recovery "the proven-empty generated Claude state could not be removed cleanly" "$state" "" "$displaced_state" "" "$recovery_directory"
            return 1
        fi
        info "removed the proven-empty generated Claude state"
        return 0
    fi

    generated_mode="$(stat -c '%a' "$displaced_state" 2>/dev/null)" || {
        recover_displaced_claude_state "the generated Claude state mode could not be read for rollback" "$state" "" "$displaced_state" "" "$recovery_directory"
        return 1
    }
    if ! create_generated_claude_baseline_file "$displaced_state" "$baseline_file" "$generated_mode" "$expected_non_mcp" "$expected_unmanaged"; then
        recover_displaced_claude_state "the generated non-MCP Claude baseline could not be prepared for rollback" "$state" "" "$displaced_state" "$baseline_file" "$recovery_directory"
        return 1
    fi
    if ! ln -T -- "$baseline_file" "$state"; then
        recover_displaced_claude_state "the generated non-MCP Claude baseline could not be installed without replacing another state" "$state" "" "$displaced_state" "$baseline_file" "$recovery_directory"
        return 1
    fi
    if ! rm -f -- "$baseline_file" "$displaced_state" || ! rmdir -- "$recovery_directory"; then
        report_claude_manual_recovery "the generated Claude baseline was restored but recovery material could not be removed" "$state" "" "$displaced_state" "$baseline_file" "$recovery_directory"
        return 1
    fi
    info "rolled back confirmed Claude MCP additions while preserving generated Claude metadata"
}

configure_claude_mcp_servers() {
    local declaration="$DOTFILES/claude/mcp-servers.json"
    local state="$HOME/.claude.json"
    local snapshot="" original_mode="" original_state=0 fresh_baseline_captured=0
    local expected_non_mcp='{}' expected_unmanaged='{}' expected_managed='{}'
    local snapshot_state current_state generated_state name desired_record current_record
    local next_expected_managed record_status transaction_failed=0 transaction_failure=""
    local -a names=(jira confluence)
    local -a confirmed_additions=()

    have jq && have python3 && have claude || return 1
    if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
        info "CLAUDE_CONFIG_DIR must be unset so the installer can protect $state" >&2
        return 1
    fi
    claude_mcp_declaration_is_valid "$declaration" || return 1

    if [[ -e "$state" || -L "$state" ]]; then
        original_state=1
        claude_state_is_valid "$state" || return 1
        if claude_mcp_state_is_exact "$state" "$declaration"; then
            present "Claude user MCP definitions"
            return 0
        fi

        original_mode="$(stat -c '%a' "$state" 2>/dev/null)" || return 1
        [[ "$original_mode" =~ ^[0-7]{3,4}$ ]] || return 1
        ensure_backup_dir || return 1
        snapshot="$BACKUP_DIR/${state#/}"
        create_claude_state_snapshot "$state" "$snapshot" || return 1
        snapshot_state="$(canonical_claude_state "$snapshot")" || return 1
        expected_non_mcp="$(jq -S -c 'del(.mcpServers)' <<< "$snapshot_state" 2>/dev/null)" || return 1
        expected_unmanaged="$(jq -S -c '(.mcpServers // {}) | with_entries(select(.key != "jira" and .key != "confluence"))' <<< "$snapshot_state" 2>/dev/null)" || return 1
        expected_managed="$(jq -S -c '(.mcpServers // {}) | with_entries(select(.key == "jira" or .key == "confluence"))' <<< "$snapshot_state" 2>/dev/null)" || return 1
        current_state="$(canonical_claude_state "$state")" || {
            report_claude_manual_recovery "Claude state changed after its snapshot was created" "$state" "$snapshot"
            return 1
        }
        if [[ "$current_state" != "$snapshot_state" ]]; then
            report_claude_manual_recovery "Claude state changed after its snapshot was created" "$state" "$snapshot"
            return 1
        fi
    fi

    if (( ! original_state )) && [[ -e "$state" || -L "$state" ]]; then
        report_claude_manual_recovery "Claude state appeared before MCP reconciliation began" "$state"
        return 1
    fi

    for name in "${names[@]}"; do
        if (( original_state )); then
            if ! claude_existing_state_matches_transaction "$state" "$expected_non_mcp" "$expected_unmanaged" "$expected_managed"; then
                transaction_failed=1
                transaction_failure="Claude state changed outside the last fully confirmed transaction state"
                break
            fi
        elif (( fresh_baseline_captured )); then
            if ! displaced_generated_claude_state_is_exact "$state" "$expected_non_mcp" "$expected_unmanaged" "${confirmed_additions[@]}"; then
                transaction_failed=1
                transaction_failure="generated Claude state changed outside confirmed MCP additions"
                break
            fi
        elif [[ -e "$state" || -L "$state" ]]; then
            transaction_failed=1
            transaction_failure="Claude state appeared before the first managed addition"
            break
        fi

        desired_record="$(canonical_declared_claude_record "$declaration" "$name")" || {
            transaction_failed=1
            transaction_failure="the desired $name MCP record could not be read"
            break
        }

        if (( ! original_state && ! fresh_baseline_captured && ${#confirmed_additions[@]} == 0 )); then
            if [[ -e "$state" || -L "$state" ]]; then
                transaction_failed=1
                transaction_failure="Claude state appeared before the first managed record was read"
                break
            fi
            record_status=1
            current_record=""
        elif [[ ! -e "$state" && ! -L "$state" ]]; then
            record_status=2
        else
            lookup_claude_record "$state" "$name" current_record
            record_status=$?
        fi
        if (( record_status == 2 )); then
            transaction_failed=1
            transaction_failure="the current $name MCP record could not be read"
            break
        fi
        if (( record_status == 0 )) && [[ "$current_record" == "$desired_record" ]]; then
            continue
        fi

        if (( record_status == 0 )); then
            if ! run_claude_mcp_remove "$name"; then
                transaction_failed=1
                transaction_failure="Claude failed while removing the previous $name MCP record"
                break
            fi
            if [[ ! -e "$state" && ! -L "$state" ]]; then
                record_status=2
            else
                lookup_claude_record "$state" "$name" current_record
                record_status=$?
            fi
            if (( record_status != 1 )); then
                transaction_failed=1
                transaction_failure="the previous $name MCP record was not confirmed removed"
                break
            fi
            if (( original_state )); then
                next_expected_managed="$(jq -S -c --arg name "$name" 'del(.[$name])' <<< "$expected_managed" 2>/dev/null)" || {
                    transaction_failed=1
                    transaction_failure="the expected managed Claude state could not be advanced after removing $name"
                    break
                }
                if ! claude_existing_state_matches_transaction "$state" "$expected_non_mcp" "$expected_unmanaged" "$next_expected_managed"; then
                    transaction_failed=1
                    transaction_failure="the complete Claude state after removing $name was not fully confirmed"
                    break
                fi
                expected_managed="$next_expected_managed"
            elif ! claude_unrelated_state_matches "$state" "$expected_non_mcp" "$expected_unmanaged"; then
                transaction_failed=1
                transaction_failure="unrelated Claude state changed while removing $name"
                break
            fi
        fi

        if (( ! original_state && ! fresh_baseline_captured && ${#confirmed_additions[@]} == 0 )) &&
           [[ -e "$state" || -L "$state" ]]; then
            transaction_failed=1
            transaction_failure="Claude state appeared immediately before the first managed addition"
            break
        fi
        if ! run_claude_mcp_add "$name" "$desired_record"; then
            transaction_failed=1
            transaction_failure="Claude failed while adding the $name MCP record"
            break
        fi
        if [[ ! -e "$state" && ! -L "$state" ]]; then
            record_status=2
        else
            lookup_claude_record "$state" "$name" current_record
            record_status=$?
        fi
        if (( record_status != 0 )) || [[ "$current_record" != "$desired_record" ]]; then
            transaction_failed=1
            transaction_failure="the added $name MCP record could not be confirmed"
            break
        fi
        if (( original_state )); then
            next_expected_managed="$(jq -S -c --arg name "$name" --argjson record "$desired_record" '. + {($name): $record}' <<< "$expected_managed" 2>/dev/null)" || {
                transaction_failed=1
                transaction_failure="the expected managed Claude state could not be advanced after adding $name"
                break
            }
            if ! claude_existing_state_matches_transaction "$state" "$expected_non_mcp" "$expected_unmanaged" "$next_expected_managed"; then
                transaction_failed=1
                transaction_failure="the complete Claude state after adding $name was not fully confirmed"
                break
            fi
            expected_managed="$next_expected_managed"
        fi
        confirmed_additions+=("$name" "$desired_record")

        if (( ! original_state && ! fresh_baseline_captured )); then
            generated_state="$(canonical_claude_state "$state")" || {
                transaction_failed=1
                transaction_failure="Claude's generated state could not be captured"
                break
            }
            expected_non_mcp="$(jq -S -c 'del(.mcpServers)' <<< "$generated_state" 2>/dev/null)" || {
                transaction_failed=1
                transaction_failure="Claude's generated non-MCP state could not be captured"
                break
            }
            expected_unmanaged="$(jq -S -c '(.mcpServers // {}) | with_entries(select(.key != "jira" and .key != "confluence"))' <<< "$generated_state" 2>/dev/null)" || {
                transaction_failed=1
                transaction_failure="Claude's generated unmanaged MCP state could not be captured"
                break
            }
            fresh_baseline_captured=1
        fi

        if (( original_state )); then
            if ! claude_existing_state_matches_transaction "$state" "$expected_non_mcp" "$expected_unmanaged" "$expected_managed"; then
                transaction_failed=1
                transaction_failure="Claude state changed after the confirmed $name addition"
                break
            fi
        elif ! displaced_generated_claude_state_is_exact "$state" "$expected_non_mcp" "$expected_unmanaged" "${confirmed_additions[@]}"; then
            transaction_failed=1
            transaction_failure="generated Claude state contained unexpected content after adding $name"
            break
        fi
    done

    if (( ! transaction_failed )); then
        if (( original_state )); then
            if ! claude_existing_state_matches_transaction "$state" "$expected_non_mcp" "$expected_unmanaged" "$expected_managed" ||
               ! claude_mcp_state_is_exact "$state" "$declaration"; then
                transaction_failed=1
                transaction_failure="final Claude MCP verification failed"
            fi
        elif (( ! fresh_baseline_captured )) ||
             ! displaced_generated_claude_state_is_exact "$state" "$expected_non_mcp" "$expected_unmanaged" "${confirmed_additions[@]}" ||
             ! claude_mcp_state_is_exact "$state" "$declaration"; then
            transaction_failed=1
            transaction_failure="final generated Claude MCP verification failed"
        fi
    fi

    if (( transaction_failed )); then
        info "Claude MCP reconciliation failed: $transaction_failure" >&2
        if (( original_state )); then
            restore_existing_claude_transaction "$state" "$snapshot" "$original_mode" "$expected_non_mcp" "$expected_unmanaged" "$expected_managed" || true
        else
            rollback_new_claude_state "$state" "$fresh_baseline_captured" "$expected_non_mcp" "$expected_unmanaged" "${confirmed_additions[@]}" || true
        fi
        return 1
    fi
    return 0
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
        "$DOTFILES/config/btop/btop.conf|$HOME/.config/btop/btop.conf"
        "$DOTFILES/config/herdr/config.toml|$HOME/.config/herdr/config.toml"
        "$DOTFILES/claude/settings.json|$HOME/.claude/settings.json"
        "$DOTFILES/claude/statusline.sh|$HOME/.claude/statusline.sh"
        "$DOTFILES/claude/claude-statusline|$HOME/.claude/claude-statusline"
        "$DOTFILES/claude/hooks/herdr-agent-state.sh|$HOME/.claude/hooks/herdr-agent-state.sh"
        "$DOTFILES/claude/themes/snazzy-light.json|$HOME/.claude/themes/snazzy-light.json"
        "$DOTFILES/codex/config.toml|$HOME/.codex/config.toml"
        "$DOTFILES/cursor/hooks.json|$HOME/.cursor/hooks.json"
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

runtime_source_dir_is_usable() {
    local source_dir="$1"
    [[ -d "$source_dir" && -r "$source_dir" && -x "$source_dir" ]]
}

link_runtime_tree() {
    local source_dir="$1" target_dir="$2" source_path
    runtime_source_dir_is_usable "$source_dir" || return 1
    runtime_target_dir_is_safe "$target_dir" "$source_dir" || return 1
    mkdir -p "$target_dir" || return 1
    [[ -d "$target_dir" && ! -L "$target_dir" ]] || return 1
    for source_path in \
        "$source_dir"/* "$source_dir"/.[!.]* "$source_dir"/..?*; do
        [[ -e "$source_path" || -L "$source_path" ]] || continue
        link_path "$source_path" "$target_dir/$(basename "$source_path")" || {
            return 1
        }
    done
    return 0
}

obsolete_runtime_link_is_owned() {
    local source_dir="$1" target_path="$2" expected_source actual_source
    runtime_source_dir_is_usable "$source_dir" || return 1
    [[ -L "$target_path" ]] || return 1
    expected_source="$source_dir/$(basename "$target_path")"
    actual_source="$(readlink "$target_path")" || return 1
    [[ "$actual_source" == "$expected_source" ]] || return 1
    [[ ! -e "$expected_source" && ! -L "$expected_source" ]]
}

runtime_target_dir_is_safe() {
    local target_dir="$1" source_dir="${2:-}"
    [[ ! -L "$target_dir" ]] || return 1
    [[ ! -e "$target_dir" || -d "$target_dir" ]] || return 1
    if [[ -n "$source_dir" && -e "$target_dir" && "$source_dir" -ef "$target_dir" ]]; then
        return 1
    fi
    return 0
}

backup_obsolete_runtime_links() {
    local source_dir="$1" target_dir="$2" target_path
    runtime_source_dir_is_usable "$source_dir" || return 1
    runtime_target_dir_is_safe "$target_dir" "$source_dir" || return 1
    [[ -d "$target_dir" ]] || return 0
    for target_path in \
        "$target_dir"/* "$target_dir"/.[!.]* "$target_dir"/..?*; do
        [[ -e "$target_path" || -L "$target_path" ]] || continue
        if obsolete_runtime_link_is_owned "$source_dir" "$target_path"; then
            backup_existing "$target_path" || return 1
        fi
    done
    return 0
}

runtime_tree_is_reconciled() {
    local source_dir="$1" target_dir="$2" source_path target_path
    runtime_source_dir_is_usable "$source_dir" || return 1
    [[ -d "$target_dir" && ! -L "$target_dir" ]] || return 1
    [[ ! "$source_dir" -ef "$target_dir" ]] || return 1
    for source_path in \
        "$source_dir"/* "$source_dir"/.[!.]* "$source_dir"/..?*; do
        [[ -e "$source_path" || -L "$source_path" ]] || continue
        target_path="$target_dir/$(basename "$source_path")"
        [[ -L "$target_path" ]] || return 1
        [[ "$(readlink "$target_path")" == "$source_path" ]] || return 1
    done
    for target_path in \
        "$target_dir"/* "$target_dir"/.[!.]* "$target_dir"/..?*; do
        [[ -e "$target_path" || -L "$target_path" ]] || continue
        obsolete_runtime_link_is_owned "$source_dir" "$target_path" && return 1
    done
    return 0
}

compute_runtime_sources_are_valid() {
    local entry source_dir required_file
    for entry in "${COMPUTE_RUNTIME_TREES[@]}"; do
        source_dir="${entry%%|*}"
        if ! runtime_source_dir_is_usable "$source_dir"; then
            info "required compute-ai-skills runtime tree missing or inaccessible: $source_dir" >&2
            return 1
        fi
    done
    [[ -f "$COMPUTE_SKILLS/.codex/hooks.json" ]] || {
        info "required compute-ai-skills Codex hooks missing: $COMPUTE_SKILLS/.codex/hooks.json" >&2
        return 1
    }
    for required_file in \
        "$COMPUTE_SKILLS/.claude/hooks/agent-boundary.py" \
        "$COMPUTE_SKILLS/.codex/hooks/agent-boundary.py" \
        "$COMPUTE_SKILLS/.cursor/hooks/agent-boundary.py" \
        "$COMPUTE_SKILLS/agent_policy/core.py"; do
        if [[ ! -f "$required_file" ]]; then
            info "required compute-ai-skills boundary source missing: $required_file" >&2
            return 1
        fi
        if [[ ! -r "$required_file" ]]; then
            info "required compute-ai-skills boundary source is not readable: $required_file" >&2
            return 1
        fi
    done
    if [[ ! -x "$COMPUTE_SKILLS/.cursor/hooks/agent-boundary.py" ]]; then
        info "required compute-ai-skills Cursor boundary hook is not executable: $COMPUTE_SKILLS/.cursor/hooks/agent-boundary.py" >&2
        return 1
    fi
}

compute_runtime_targets_are_safe() {
    local entry source_dir target_dir
    for entry in "${COMPUTE_RUNTIME_TREES[@]}"; do
        source_dir="${entry%%|*}"
        target_dir="${entry#*|}"
        if ! runtime_target_dir_is_safe "$target_dir" "$source_dir"; then
            info "runtime target must be a real directory, not a symlink or file: $target_dir" >&2
            return 1
        fi
    done
}

install_compute_skills() {
    local origin branch status entry source_dir target_dir
    local herdr_hook_source="$COMPUTE_SKILLS/.codex/hooks/herdr-agent-state.sh"
    if [[ ! -e "$COMPUTE_SKILLS" && ! -L "$COMPUTE_SKILLS" ]]; then
        mkdir "$COMPUTE_SKILLS" || return 1
        if ! GIT_TERMINAL_PROMPT=0 git clone --branch main \
            https://github.com/abchoudh-amd/compute-ai-skills.git "$COMPUTE_SKILLS"; then
            if [[ -e "$COMPUTE_SKILLS" || -L "$COMPUTE_SKILLS" ]]; then
                backup_existing "$COMPUTE_SKILLS" || return 1
            fi
            return 1
        fi
    fi
    [[ -d "$COMPUTE_SKILLS/.git" ]] || return 1
    origin="$(git -C "$COMPUTE_SKILLS" remote get-url origin 2>/dev/null)" || return 1
    skills_origin_is_expected "$origin" || return 1
    branch="$(git -C "$COMPUTE_SKILLS" branch --show-current 2>/dev/null)" || return 1
    status="$(git -C "$COMPUTE_SKILLS" status --porcelain 2>/dev/null)" || return 1
    if [[ "$branch" == main && -z "$status" ]]; then
        GIT_TERMINAL_PROMPT=0 git -C "$COMPUTE_SKILLS" pull --ff-only origin main || \
            warn "could not fast-forward $COMPUTE_SKILLS; using the existing checkout"
    else
        warn "$COMPUTE_SKILLS is dirty or not on main; preserving it without update"
    fi
    if [[ ! -f "$herdr_hook_source" ]]; then
        info "required compute-ai-skills HERDR hook missing: $herdr_hook_source" >&2
        return 1
    fi
    if [[ ! -x "$herdr_hook_source" ]]; then
        info "required compute-ai-skills HERDR hook is not executable: $herdr_hook_source" >&2
        return 1
    fi
    compute_runtime_sources_are_valid || return 1
    compute_runtime_targets_are_safe || return 1
    for entry in "${COMPUTE_RUNTIME_TREES[@]}"; do
        source_dir="${entry%%|*}"
        target_dir="${entry#*|}"
        backup_obsolete_runtime_links "$source_dir" "$target_dir" || return 1
    done
    for entry in "${COMPUTE_RUNTIME_TREES[@]}"; do
        source_dir="${entry%%|*}"
        target_dir="${entry#*|}"
        link_runtime_tree "$source_dir" "$target_dir" || return 1
    done
    link_path "$herdr_hook_source" "$HOME/.codex/herdr-agent-state.sh" || return 1
    link_path "$COMPUTE_SKILLS/.codex/hooks.json" "$HOME/.codex/hooks.json" || return 1
}

herdr_hook_is_valid() {
    local hook="$1" expected_source="$2" expected_integration_id="$3"
    local integration_id_marker_count expected_id_marker_count
    local version_marker_count all_version_marker_count
    [[ -L "$hook" && -x "$hook" ]] || return 1
    [[ "$(readlink "$hook")" == "$expected_source" ]] || return 1
    integration_id_marker_count="$(grep -Ec '^# HERDR_INTEGRATION_ID=' "$hook" || true)"
    expected_id_marker_count="$(grep -Fxc "# HERDR_INTEGRATION_ID=$expected_integration_id" "$hook" || true)"
    version_marker_count="$(grep -Ec '^# HERDR_INTEGRATION_VERSION=[1-9][0-9]*$' "$hook" || true)"
    all_version_marker_count="$(grep -Ec '^# HERDR_INTEGRATION_VERSION=' "$hook" || true)"
    [[ "$integration_id_marker_count" == 1 && "$expected_id_marker_count" == 1 &&
       "$version_marker_count" == 1 && "$all_version_marker_count" == 1 ]]
}

claude_herdr_session_start_is_exact() {
    local settings="$1"
    json_document_has_unique_object_keys "$settings" || return 1
    jq -e --arg expected_command 'bash "$HOME/.claude/hooks/herdr-agent-state.sh" session' '
        if (.hooks.SessionStart | type) != "array" then
            false
        else
            ([
                .hooks.SessionStart[]
                | select(. == {
                    matcher: "*",
                    hooks: [{
                        type: "command",
                        command: $expected_command,
                        timeout: 10
                    }]
                })
            ] | length) == 1
            and ([
                .hooks.SessionStart
                | ..
                | objects
                | select(.command? == $expected_command)
            ] | length) == 1
        end
    ' "$settings" >/dev/null
}

codex_herdr_session_start_is_exact() {
    local hooks="$1"
    json_document_has_unique_object_keys "$hooks" || return 1
    jq -e --arg expected_command 'bash "$HOME/.codex/herdr-agent-state.sh" session' '
        if (.hooks.SessionStart | type) != "array" then
            false
        else
            ([
                .hooks.SessionStart[]
                | select(. == {
                    hooks: [{
                        type: "command",
                        command: $expected_command,
                        timeout: 10
                    }]
                })
            ] | length) == 1
            and ([
                .hooks.SessionStart
                | ..
                | objects
                | select(.command? == $expected_command)
            ] | length) == 1
        end
    ' "$hooks" >/dev/null
}

claude_boundary_hooks_are_exact() {
    local settings="$1"
    json_document_has_unique_object_keys "$settings" || return 1
    jq -e --arg expected_command 'python3 "$HOME/.claude/hooks/agent-boundary.py"' '
        def boundary_group:
            {
                hooks: [{
                    command: $expected_command,
                    type: "command"
                }]
            };
        . as $root
        | ["PreToolUse", "SubagentStart", "SubagentStop"] as $events
        | all($events[];
            . as $event
            | ($root.hooks[$event] | type) == "array"
            and ([$root.hooks[$event][] | select(. == boundary_group)] | length) == 1
            and ([$root.hooks[$event] | .. | objects
                  | select(.command? == $expected_command)] | length) == 1
        )
        and ([$root.hooks | .. | objects
              | select(.command? == $expected_command)] | length) == 3
        and ([$root.hooks | .. | objects | .command? // empty
              | select(contains(".claude/hooks/agent-boundary.py"))] | length) == 3
    ' "$settings" >/dev/null
}

cursor_boundary_hooks_are_exact() {
    local hooks="$1"
    json_document_has_unique_object_keys "$hooks" || return 1
    jq -e --arg expected_command '$HOME/.cursor/hooks/agent-boundary.py' '
        . == {
            hooks: {
                subagentStart: [{
                    command: $expected_command,
                    failClosed: true
                }],
                preToolUse: [{
                    command: $expected_command,
                    failClosed: true
                }],
                beforeShellExecution: [{
                    command: $expected_command,
                    failClosed: true
                }],
                beforeMCPExecution: [{
                    command: $expected_command,
                    failClosed: true
                }],
                beforeReadFile: [{
                    command: $expected_command,
                    failClosed: true
                }],
                subagentStop: [{
                    command: $expected_command,
                    failClosed: true
                }]
            }
        }
    ' "$hooks" >/dev/null
}

validate_required_commands() {
    local command_name entry source_dir target_dir
    local -a commands=(
        git curl jq fish python3 cargo go node npm uv eza fd diskus csvlens
        yazi ya glow codex sqlit claude starship zoxide fzf rg btop duf gh gitmux herdr tmux nvim
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
    for command_name in fzf rg btop duf gh gitmux herdr; do
        if have "$command_name" && ! binary_version_works "$(command -v "$command_name")"; then
            fail "required command cannot execute a version probe: $command_name"
        fi
    done
    [[ -f "$HOME/.tmux/plugins/tmux/catppuccin.tmux" ]] || fail "Catppuccin tmux plugin missing"
    if ! compute_runtime_sources_are_valid; then
        fail "compute-ai-skills runtime sources missing or invalid"
    fi
    for entry in "${COMPUTE_RUNTIME_TREES[@]}"; do
        source_dir="${entry%%|*}"
        target_dir="${entry#*|}"
        if ! runtime_tree_is_reconciled "$source_dir" "$target_dir"; then
            fail "compute-ai-skills runtime tree missing or invalid: $target_dir"
        fi
    done
    if [[ ! -L "$HOME/.codex/hooks.json" ]] ||
       [[ "$(readlink "$HOME/.codex/hooks.json" 2>/dev/null)" != \
          "$COMPUTE_SKILLS/.codex/hooks.json" ]]; then
        fail "Codex hooks.json link missing or invalid"
    fi
    if ! herdr_hook_is_valid \
        "$HOME/.claude/hooks/herdr-agent-state.sh" \
        "$DOTFILES/claude/hooks/herdr-agent-state.sh" claude; then
        fail "Claude HERDR hook link missing or invalid"
    fi
    if ! herdr_hook_is_valid \
        "$HOME/.codex/hooks/herdr-agent-state.sh" \
        "$COMPUTE_SKILLS/.codex/hooks/herdr-agent-state.sh" codex; then
        fail "Codex HERDR hook-tree link missing or invalid"
    fi
    if ! herdr_hook_is_valid \
        "$HOME/.codex/herdr-agent-state.sh" \
        "$COMPUTE_SKILLS/.codex/hooks/herdr-agent-state.sh" codex; then
        fail "Codex HERDR runtime hook link missing or invalid"
    fi
    if ! claude_herdr_session_start_is_exact "$HOME/.claude/settings.json"; then
        fail "Claude HERDR SessionStart hook missing or invalid"
    fi
    if ! codex_herdr_session_start_is_exact "$HOME/.codex/hooks.json"; then
        fail "Codex HERDR SessionStart hook missing or invalid"
    fi
    if [[ ! -L "$HOME/.claude/settings.json" ]] ||
       [[ "$(readlink "$HOME/.claude/settings.json" 2>/dev/null)" != \
          "$DOTFILES/claude/settings.json" ]]; then
        fail "Claude settings link missing or invalid"
    fi
    if ! claude_boundary_hooks_are_exact "$HOME/.claude/settings.json"; then
        fail "Claude boundary hooks missing or invalid"
    fi
    if [[ ! -L "$HOME/.cursor/hooks.json" ]] ||
       [[ "$(readlink "$HOME/.cursor/hooks.json" 2>/dev/null)" != \
          "$DOTFILES/cursor/hooks.json" ]]; then
        fail "Cursor hooks.json link missing or invalid"
    fi
    if ! cursor_boundary_hooks_are_exact "$HOME/.cursor/hooks.json"; then
        fail "Cursor boundary hooks missing or invalid"
    fi
    if ! claude_mcp_state_is_exact \
        "$HOME/.claude.json" "$DOTFILES/claude/mcp-servers.json"; then
        fail "Claude user MCP definitions missing or invalid"
    fi
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
    info "post-install: run 'claude mcp login jira' as needed"
    info "post-install: run 'claude mcp login confluence' as needed"
    info "post-install: review Codex hooks with /hooks, then restart Claude, Codex, and Cursor"
    info "post-install: fully quit and reopen Cursor after runtime or hook changes"
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
    attempt "install csvlens" install_cargo_tool csvlens csvlens
    attempt "install yazi" install_cargo_tool yazi-fm yazi
    attempt "install ya" install_cargo_tool yazi-cli ya

    section "Language-managed tools"
    attempt "install glow" install_glow
    attempt "install Codex" install_codex
    attempt "install sqlit" install_sqlit
    attempt "install Claude" install_claude

    section "Claude MCP servers"
    attempt "configure Claude user MCP definitions" configure_claude_mcp_servers

    section "User-local tools"
    attempt "install Starship" install_starship
    attempt "install zoxide" install_zoxide
    attempt "install fzf" install_release_binary fzf fzf junegunn/fzf '^fzf-[^/]+-linux_amd64\.tar\.gz$' fzf
    attempt "install ripgrep" install_release_binary ripgrep rg BurntSushi/ripgrep '^ripgrep-[^-]+-x86_64-unknown-linux-musl\.tar\.gz$' rg
    attempt "install btop" install_release_binary btop btop aristocratos/btop '^btop-x86_64-unknown-linux-musl\.tar\.gz$' btop
    attempt "install duf" install_release_binary duf duf muesli/duf '^duf_[^_]+_linux_x86_64\.tar\.gz$' duf
    attempt "install GitHub CLI" install_release_binary gh gh cli/cli '^gh_[^_]+_linux_amd64\.tar\.gz$' gh
    attempt "install gitmux" install_release_binary gitmux gitmux arl/gitmux '^gitmux_v[^_]+_linux_amd64\.tar\.gz$' gitmux
    attempt "install herdr" install_herdr
    attempt "install tmux 3.2+" install_tmux
    attempt "install Neovim 0.11.2+" install_neovim

    section "Configuration and secrets"
    link_dotfiles
    attempt "seed and link secrets" seed_secrets

    section "tmux plugins"
    attempt "install TPM and Catppuccin" install_tmux_plugins

    section "Claude, Codex, and Cursor runtime content"
    attempt "install compute-ai-skills" install_compute_skills

    section "Final validation"
    validate_required_commands
    print_summary
    (( ${#FAILURES[@]} == 0 ))
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
