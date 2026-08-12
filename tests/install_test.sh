#!/usr/bin/env bash
set -uo pipefail

container_metadata_is_valid() {
    local metadata
    metadata="${CONTAINER_EXPECTED_IMAGE:-}|${CONTAINER_EXPECTED_ID:-}|${CONTAINER_EXPECTED_VERSION:-}|${CONTAINER_EXPECTED_MAJOR:-}|${CONTAINER_EXPECTED_FAMILY:-}|${CONTAINER_EXPECTED_FALLBACK:-}"
    case "$metadata" in
        'ubuntu:24.04|ubuntu|24.04|24|debian|0'|\
        'debian:12|debian|12|12|debian|0'|\
        'rockylinux:8|rocky|floating|8|rhel|1'|\
        'rockylinux:9|rocky|floating|9|rhel|0') return 0 ;;
        *) return 1 ;;
    esac
}

container_inner_boundary_is_valid() {
    local expected_script=/tmp/dotfiles/tests/install_test.sh
    local marker=/tmp/dotfiles/.container-smoke-boundary marker_token=""
    [[ "${HOME:-}" == /tmp/dotfiles-home ]] || return 1
    [[ -f "$expected_script" && "${BASH_SOURCE[0]}" -ef "$expected_script" ]] || return 1
    if [[ ${REPOSITORY_ROOT+x} == x ]]; then
        [[ "$REPOSITORY_ROOT" == /tmp/dotfiles ]] || return 1
        [[ "${SCRIPT_PATH:-}" == "$expected_script" ]] || return 1
    fi
    (( EUID != 0 )) || return 1
    [[ -f /.dockerenv || -f /run/.containerenv ]] || return 1
    [[ -f "$marker" && ! -L "$marker" && -r "$marker" ]] || return 1
    IFS= read -r marker_token < "$marker" || return 1
    [[ "${DOTFILES_CONTAINER_TOKEN:-}" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$marker_token" == "$DOTFILES_CONTAINER_TOKEN" ]] || return 1
    container_metadata_is_valid
}

stub_write_record() {
    local name="$1" record="$2" state="$HOME/.claude.json"
    local temporary
    temporary="$(mktemp "$HOME/.claude.json.stub.XXXXXX")" || return 1
    if [[ -f "$state" ]]; then
        jq --arg name "$name" --argjson record "$record" '
            .mcpServers = (.mcpServers // {}) |
            .mcpServers[$name] = $record
        ' "$state" > "$temporary" || {
            rm -f -- "$temporary"
            return 1
        }
    else
        jq -n --arg name "$name" --argjson record "$record" '
            {
                firstStartTime: "2026-07-24T00:00:00.000Z",
                machineID: "fixture-machine-id",
                migrationVersion: 1,
                userID: "fixture-user-id",
                mcpServers: {}
            } | .mcpServers[$name] = $record
        ' > "$temporary" || {
            rm -f -- "$temporary"
            return 1
        }
    fi
    chmod 0600 "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    mv -fT -- "$temporary" "$state"
}

stub_remove_record() {
    local name="$1" state="$HOME/.claude.json"
    local temporary
    [[ -f "$state" ]] || return 1
    temporary="$(mktemp "$HOME/.claude.json.stub.XXXXXX")" || return 1
    jq --arg name "$name" 'del(.mcpServers[$name])' "$state" > "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    chmod 0600 "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    mv -fT -- "$temporary" "$state"
}

stub_add_concurrent_field() {
    local state="$HOME/.claude.json" temporary
    temporary="$(mktemp "$HOME/.claude.json.stub.XXXXXX")" || return 1
    jq '.concurrentWrite = "preserve-me"' "$state" > "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    chmod 0600 "$temporary" || {
        rm -f -- "$temporary"
        return 1
    }
    mv -fT -- "$temporary" "$state"
}

claude_stub_main() {
    local argument subcommand scope name record mode
    : "${CLAUDE_STUB_LOG:?}"
    {
        printf 'claude'
        for argument in "$@"; do
            printf ' %q' "$argument"
        done
        printf '\n'
    } >> "$CLAUDE_STUB_LOG"

    [[ $# -ge 2 && "$1" == mcp ]] || return 64
    subcommand="$2"
    shift 2
    mode="${CLAUDE_STUB_MODE:-normal}"

    case "$subcommand" in
        add-json)
            [[ $# -eq 4 && "$1" == --scope && "$2" == user ]] || return 65
            scope="$2"
            name="$3"
            record="$4"
            [[ "$scope" == user ]] || return 65
            if [[ -f "$HOME/.claude.json" ]] &&
               jq -e --arg name "$name" '
                   (.mcpServers // {}) | has($name)
               ' "$HOME/.claude.json" >/dev/null 2>&1; then
                return 68
            fi
            if [[ "$mode" == "fail-add:$name" ]]; then
                return 71
            fi
            if [[ "$mode" == "partial-add-fail:$name" ]]; then
                stub_write_record "$name" "$record" || return 72
                return 73
            fi
            if [[ "$mode" == "change-jira-and-fail:$name" && "$name" == confluence ]]; then
                stub_write_record jira \
                    '{"type":"http","url":"https://concurrent.invalid"}' || return 74
                return 75
            fi
            if [[ "$mode" == "delete-state-and-fail:$name" ]]; then
                rm -f -- "$HOME/.claude.json" || return 82
                return 83
            fi
            if [[ "$mode" == "malform-state-and-fail:$name" ]]; then
                printf '{\n' > "$HOME/.claude.json" || return 84
                return 85
            fi
            if [[ "$mode" == "directory-state-and-fail:$name" ]]; then
                rm -f -- "$HOME/.claude.json" || return 86
                mkdir "$HOME/.claude.json" || return 87
                return 88
            fi
            if [[ "$mode" == "wrong-add:$name" ]]; then
                stub_write_record "$name" \
                    '{"type":"http","url":"https://wrong.invalid"}' || return 76
                return 0
            fi
            stub_write_record "$name" "$record" || return 77
            if [[ "$mode" == "malform-after-add:$name" ]]; then
                printf '{\n' > "$HOME/.claude.json" || return 89
                return 0
            fi
            if [[ "$mode" == "delete-after-add:$name" ]]; then
                rm -f -- "$HOME/.claude.json" || return 90
                return 0
            fi
            if [[ "$mode" == "concurrent-add:$name" ]]; then
                stub_add_concurrent_field || return 78
            fi
            ;;
        remove)
            [[ $# -eq 3 && "$1" == --scope && "$2" == user ]] || return 66
            name="$3"
            if [[ "$mode" == "fail-remove:$name" ]]; then
                return 79
            fi
            if [[ "$mode" == "retain-after-remove:$name" ]]; then
                return 0
            fi
            stub_remove_record "$name" || return 80
            if [[ "$mode" == "remove-then-fail:$name" ]]; then
                return 81
            fi
            if [[ "$mode" == "delete-after-remove:$name" ]]; then
                rm -f -- "$HOME/.claude.json" || return 91
                return 0
            fi
            if [[ "$mode" == "malform-after-remove:$name" ]]; then
                printf '{\n' > "$HOME/.claude.json" || return 92
                return 0
            fi
            ;;
        *)
            return 67
            ;;
    esac
}

blocked_command_main() {
    local argument
    : "${BLOCKED_COMMAND_LOG:?}"
    {
        printf '%s' "${0##*/}"
        for argument in "$@"; do
            printf ' %q' "$argument"
        done
        printf '\n'
    } >> "$BLOCKED_COMMAND_LOG"
    return 97
}

herdr_installer_sh_stub_main() {
    local argument line
    : "${HERDR_INSTALLER_SH_LOG:?}"
    : "${HERDR_INSTALLER_SH_INPUT:?}"
    : "${HERDR_REAL_SH:?}"
    {
        printf 'sh'
        for argument in "$@"; do
            printf ' %q' "$argument"
        done
        printf '\n'
    } >> "$HERDR_INSTALLER_SH_LOG"
    : > "$HERDR_INSTALLER_SH_INPUT"
    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "$line" >> "$HERDR_INSTALLER_SH_INPUT"
    done
    "$HERDR_REAL_SH" < "$HERDR_INSTALLER_SH_INPUT"
}

installer_fixture_command_main() {
    local argument command_name="${0##*/}"
    : "${INSTALL_FIXTURE_LOG:?}"
    if [[ -n "${INSTALL_FIXTURE_CALL_LOG:-}" ]]; then
        {
            printf '%s' "$command_name"
            for argument in "$@"; do
                printf ' %q' "$argument"
            done
            printf '\n'
        } >> "$INSTALL_FIXTURE_CALL_LOG"
    fi
    case "$command_name" in
        sudo)
            {
                printf 'sudo'
                for argument in "$@"; do
                    printf ' %q' "$argument"
                done
                printf '\n'
            } >> "$INSTALL_FIXTURE_LOG"
            if [[ -n "${INSTALL_FIXTURE_FAIL_MATCH:-}" &&
                  " $* " == *"$INSTALL_FIXTURE_FAIL_MATCH"* ]]; then
                return 74
            fi
            ;;
        uname)
            [[ $# -eq 1 && "$1" == -m ]] || return 64
            printf '%s\n' "${INSTALL_FIXTURE_ARCH:-x86_64}"
            ;;
        getconf)
            [[ $# -eq 1 && "$1" == GNU_LIBC_VERSION ]] || return 65
            printf 'glibc %s\n' "${INSTALL_FIXTURE_GLIBC:-2.39}"
            ;;
        *) return 66 ;;
    esac
}

container_sudo_stub_main() {
    local argument
    : "${SUDO_COMMAND_LOG:?}"
    {
        printf 'sudo'
        for argument in "$@"; do
            printf ' %q' "$argument"
        done
        printf '\n'
    } >> "$SUDO_COMMAND_LOG"
}

container_make_stub_main() {
    local argument
    : "${CONTAINER_FALLBACK_LOG:?}"
    {
        printf 'make'
        for argument in "$@"; do
            printf ' %q' "$argument"
        done
        printf '\n'
    } >> "$CONTAINER_FALLBACK_LOG"
    if [[ " $* " == *' install '* ]]; then
        mkdir -p "$HOME/.local/bin" || return 1
        printf '%s\n' '#!/usr/bin/env bash' \
            '[[ "${1:-}" == -V || "${1:-}" == --version ]] && printf "tmux 3.3\\n"' \
            > "$HOME/.local/bin/tmux" || return 1
        chmod 0755 "$HOME/.local/bin/tmux" || return 1
    fi
}

container_find_stub_main() {
    local search_root="${1:-}" configure
    : "${CONTAINER_FALLBACK_LOG:?}"
    [[ $# -eq 10 &&
       "$2" == -mindepth && "$3" == 2 &&
       "$4" == -maxdepth && "$5" == 2 &&
       "$6" == -type && "$7" == f &&
       "$8" == -name && "$9" == configure &&
       "${10}" == -print ]] || return 98
    case "$search_root" in
        /tmp/dotfiles-install.*/extract) ;;
        *) return 99 ;;
    esac
    configure="$search_root/tmux-fixture/configure"
    [[ -f "$configure" ]] || return 97
    printf 'find %s -mindepth 2 -maxdepth 2 -type f -name configure -print\n' \
        "$search_root" >> "$CONTAINER_FALLBACK_LOG"
    printf '%s\n' "$configure"
}

mv_stub_main() {
    local source_path destination_path status argument_count
    local -a arguments=("$@")
    : "${REAL_MV:?}"
    (( $# >= 2 )) || exec "$REAL_MV" "$@"
    argument_count=${#arguments[@]}
    source_path="${arguments[argument_count - 2]}"
    destination_path="${arguments[argument_count - 1]}"

    if [[ "${MV_STUB_MODE:-normal}" == recreate-live-after-displace &&
          "$source_path" == "$HOME/.claude.json" &&
          "$destination_path" != "$HOME/.claude.json" &&
          ! -e "$HOME/.mv-race-triggered" ]]; then
        "$REAL_MV" "$@"
        status=$?
        (( status == 0 )) || return "$status"
        : > "$HOME/.mv-race-triggered"
        printf '%s\n' \
            '{"concurrentBoundary":"preserve-me","mcpServers":{"concurrent":{"type":"http","url":"https://concurrent.invalid"}}}' \
            > "$HOME/.claude.json" || return 98
        chmod 0600 "$HOME/.claude.json" || return 99
        return 0
    fi

    exec "$REAL_MV" "$@"
}

case "${0##*/}" in
    claude)
        claude_stub_main "$@"
        exit $?
        ;;
    sudo)
        if [[ "${INSTALL_FIXTURE_MODE:-}" == 1 ]]; then
            installer_fixture_command_main "$@"
        elif [[ "${DOTFILES_CONTAINER_INNER:-}" == 1 ]]; then
            container_inner_boundary_is_valid || {
                printf 'container-inner boundary validation failed\n' >&2
                exit 96
            }
            container_sudo_stub_main "$@"
        else
            blocked_command_main "$@"
        fi
        exit $?
        ;;
    uname|getconf)
        if [[ "${INSTALL_FIXTURE_MODE:-}" == 1 ]]; then
            installer_fixture_command_main "$@"
        else
            blocked_command_main "$@"
        fi
        exit $?
        ;;
    sh)
        if [[ "${HERDR_INSTALLER_SH_FIXTURE_MODE:-}" == 1 ]]; then
            herdr_installer_sh_stub_main "$@"
        else
            exit 64
        fi
        exit $?
        ;;
    apt-get|curl|dnf|git|ssh|subscription-manager|wget)
        blocked_command_main "$@"
        exit $?
        ;;
    make)
        if [[ "${DOTFILES_CONTAINER_INNER:-}" == 1 ]]; then
            container_inner_boundary_is_valid || {
                printf 'container-inner boundary validation failed\n' >&2
                exit 96
            }
            container_make_stub_main "$@"
            exit $?
        fi
        ;;
    find)
        if [[ "${DOTFILES_CONTAINER_INNER:-}" == 1 ]]; then
            container_inner_boundary_is_valid || {
                printf 'container-inner boundary validation failed\n' >&2
                exit 96
            }
            container_find_stub_main "$@"
            exit $?
        fi
        ;;
    mv)
        mv_stub_main "$@"
        exit $?
        ;;
esac

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="$REPOSITORY_ROOT/tests/install_test.sh"
SOURCE_INSTALL_HASH="$(sha256sum "$REPOSITORY_ROOT/install.sh" | awk '{print $1}')"
SOURCE_MANIFEST_HASH="$(sha256sum "$REPOSITORY_ROOT/claude/mcp-servers.json" | awk '{print $1}')"
REAL_MV_PATH="$(command -v mv)"

declare -a TEST_TEMP_ROOTS=()
declare -a CONTAINER_TEMP_ROOTS=()
declare -a CONTAINER_ENGINE_CMD=()
declare -a CONTAINER_NAMES=()
declare -a CONTAINER_TOKENS=()
CONTAINER_ENGINE_KIND=""
CONTAINER_FAILURE_OUTPUT=""
CONTAINER_ACTIVE_QUEUE_INDEX=""
CASE_ROOT=""
CASE_REPOSITORY=""
CASE_HOME=""
CASE_TMP=""
CASE_BIN=""
CASE_LOG=""
CASE_BLOCK_LOG=""
CASE_OUTPUT=""
CASE_STATUS=0
PASSED=0
FAILED=0

cleanup_test_roots() {
    local root queue_index
    for queue_index in "${!CONTAINER_NAMES[@]}"; do
        cleanup_owned_container "$queue_index" >/dev/null 2>&1 || true
    done
    for root in "${TEST_TEMP_ROOTS[@]}"; do
        case "$root" in
            /tmp/dotfiles-mcp-test.*)
                find "$root" -depth -delete 2>/dev/null || true
                ;;
        esac
    done
    for root in "${CONTAINER_TEMP_ROOTS[@]}"; do
        case "$root" in
            /tmp/dotfiles-container-test.*)
                find "$root" -depth -delete 2>/dev/null || true
                ;;
        esac
    done
}
trap cleanup_test_roots EXIT

container_engine() {
    (( ${#CONTAINER_ENGINE_CMD[@]} > 0 )) || return 127
    "${CONTAINER_ENGINE_CMD[@]}" "$@"
}

container_owner_label() {
    printf 'io.dotfiles.install-test.token'
}

container_label_value() {
    local name="$1" label
    label="$(container_owner_label)"
    container_engine inspect --type container \
        --format "{{ index .Config.Labels \"$label\" }}" "$name" 2>/dev/null
}

cleanup_owned_container() {
    local queue_index="$1" name token actual_label
    [[ "$queue_index" =~ ^[0-9]+$ ]] || return 1
    name="${CONTAINER_NAMES[queue_index]:-}"
    token="${CONTAINER_TOKENS[queue_index]:-}"
    [[ -n "$name" ]] || return 0
    [[ "$name" =~ ^[[:alnum:]][[:alnum:]_.-]*$ &&
       "$token" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual_label="$(container_label_value "$name")" || {
        CONTAINER_NAMES[queue_index]=""
        CONTAINER_TOKENS[queue_index]=""
        return 0
    }
    [[ "$actual_label" == "$token" ]] || {
        printf 'refusing to remove unowned container: %s\n' "$name" >&2
        return 1
    }
    container_engine rm -f -- "$name" >/dev/null 2>&1 || return 1
    CONTAINER_NAMES[queue_index]=""
    CONTAINER_TOKENS[queue_index]=""
}

prepare_owned_container() {
    local name="$1" token="$2" checkout="$3"
    local owner_label create_output queue_index
    shift 3
    CONTAINER_ACTIVE_QUEUE_INDEX=""
    [[ "$name" =~ ^[[:alnum:]][[:alnum:]_.-]*$ &&
       "$token" =~ ^[0-9a-f]{64}$ && -d "$checkout" ]] || return 1
    container_name_is_available "$name" || return 1

    CONTAINER_NAMES+=("$name")
    CONTAINER_TOKENS+=("$token")
    queue_index=$((${#CONTAINER_NAMES[@]} - 1))
    owner_label="$(container_owner_label)"
    create_output="$(
        container_engine create \
            --pull=never \
            --network=none \
            --name "$name" \
            --label "$owner_label=$token" \
            --cap-drop=ALL \
            --security-opt=no-new-privileges \
            "$@"
    )" || {
        cleanup_owned_container "$queue_index" || true
        return 1
    }
    if [[ ! "$create_output" =~ ^[[:alnum:]][[:alnum:]_.-]*$ ]]; then
        cleanup_owned_container "$queue_index" || true
        return 1
    fi
    container_engine cp "$checkout" "$name:/tmp/dotfiles" || {
        cleanup_owned_container "$queue_index" || true
        return 1
    }
    CONTAINER_ACTIVE_QUEUE_INDEX="$queue_index"
}

container_name_is_available() {
    local name="$1"
    [[ "$name" =~ ^[[:alnum:]][[:alnum:]_.-]*$ ]] || return 1
    if container_engine inspect --type container "$name" >/dev/null 2>&1; then
        printf 'refusing pre-existing container name: %s\n' "$name" >&2
        return 1
    fi
}

start_owned_container_attached() {
    local queue_index="$1" output="${2:-}"
    local name timeout_seconds="${CONTAINER_ATTACH_TIMEOUT_SECONDS:-300}"
    [[ "$queue_index" =~ ^[0-9]+$ &&
       "$timeout_seconds" =~ ^[1-9][0-9]*$ &&
       "$timeout_seconds" -le 3600 ]] || return 1
    name="${CONTAINER_NAMES[queue_index]:-}"
    [[ -n "$name" && ${#CONTAINER_ENGINE_CMD[@]} -gt 0 ]] || return 1
    if [[ -n "$output" ]]; then
        timeout --foreground "${timeout_seconds}s" \
            "${CONTAINER_ENGINE_CMD[@]}" start -a "$name" > "$output" 2>&1
    else
        timeout --foreground "${timeout_seconds}s" \
            "${CONTAINER_ENGINE_CMD[@]}" start -a "$name"
    fi
}

new_case() {
    local command_name command_path blocked_name
    local -a allowed_commands=(
        awk basename bash chmod cp date dirname env find grep head install jq ln mkdir mktemp
        python3 readlink rm rmdir sed sh sha256sum sort stat tar timeout wc
    )
    local -a blocked_commands=(
        apt-get curl dnf git ssh subscription-manager sudo wget
    )
    CASE_ROOT="$(mktemp -d /tmp/dotfiles-mcp-test.XXXXXX)" || return 1
    TEST_TEMP_ROOTS+=("$CASE_ROOT")
    CASE_REPOSITORY="$CASE_ROOT/repository"
    CASE_HOME="$CASE_ROOT/home"
    CASE_TMP="$CASE_ROOT/tmp"
    CASE_BIN="$CASE_ROOT/bin"
    CASE_LOG="$CASE_ROOT/claude.log"
    CASE_BLOCK_LOG="$CASE_ROOT/blocked-command.log"
    CASE_OUTPUT="$CASE_ROOT/output.log"
    mkdir -p "$CASE_REPOSITORY/claude" "$CASE_HOME" "$CASE_TMP" "$CASE_BIN" || return 1
    cp "$REPOSITORY_ROOT/install.sh" "$CASE_REPOSITORY/install.sh" || return 1
    cp "$REPOSITORY_ROOT/claude/mcp-servers.json" \
        "$CASE_REPOSITORY/claude/mcp-servers.json" || return 1
    ln -s "$SCRIPT_PATH" "$CASE_BIN/claude" || return 1
    ln -s "$SCRIPT_PATH" "$CASE_BIN/mv" || return 1
    for command_name in "${allowed_commands[@]}"; do
        command_path="$(command -v "$command_name")" || return 1
        ln -s "$command_path" "$CASE_BIN/$command_name" || return 1
    done
    for blocked_name in "${blocked_commands[@]}"; do
        ln -s "$SCRIPT_PATH" "$CASE_BIN/$blocked_name" || return 1
    done
    : > "$CASE_LOG"
    : > "$CASE_BLOCK_LOG"
}

prepare_platform_case() {
    local platform_id="$1" version_id="$2" fixture_release
    new_case || return 1
    fixture_release="$CASE_ROOT/os-release"
    printf 'ID=%s\nVERSION_ID="%s"\n' "$platform_id" "$version_id" \
        > "$fixture_release" || return 1
    sed -i "s|/etc/os-release|$fixture_release|g" \
        "$CASE_REPOSITORY/install.sh" || return 1
    ln -sfn "$SCRIPT_PATH" "$CASE_BIN/sudo" || return 1
    ln -sfn "$SCRIPT_PATH" "$CASE_BIN/uname" || return 1
    ln -sfn "$SCRIPT_PATH" "$CASE_BIN/getconf" || return 1
    : > "$CASE_ROOT/installer-command.log"
    : > "$CASE_ROOT/installer-fixture-call.log"
}

run_platform_entrypoint_rejection() {
    local architecture="$1" glibc="$2" claude_config_dir="$3"
    local -a optional_environment=()
    shift 3
    if [[ -n "$claude_config_dir" ]]; then
        optional_environment+=("CLAUDE_CONFIG_DIR=$claude_config_dir")
    fi
    env -i \
        HOME="$CASE_HOME" \
        PATH="$CASE_BIN" \
        LANG=C \
        LC_ALL=C \
        TMPDIR="$CASE_TMP" \
        CASE_REPOSITORY="$CASE_REPOSITORY" \
        INSTALL_FIXTURE_MODE=1 \
        INSTALL_FIXTURE_LOG="$CASE_ROOT/installer-command.log" \
        INSTALL_FIXTURE_CALL_LOG="$CASE_ROOT/installer-fixture-call.log" \
        INSTALL_FIXTURE_ARCH="$architecture" \
        INSTALL_FIXTURE_GLIBC="$glibc" \
        BLOCKED_COMMAND_LOG="$CASE_BLOCK_LOG" \
        CLAUDE_STUB_LOG="$CASE_LOG" \
        "${optional_environment[@]}" \
        bash "$CASE_REPOSITORY/install.sh" "$@" > "$CASE_OUTPUT" 2>&1
    CASE_STATUS=$?
    return 0
}

run_platform_packages() {
    env -i \
        HOME="$CASE_HOME" \
        PATH="$CASE_BIN" \
        LANG=C \
        LC_ALL=C \
        TMPDIR="$CASE_TMP" \
        CASE_REPOSITORY="$CASE_REPOSITORY" \
        INSTALL_FIXTURE_MODE=1 \
        INSTALL_FIXTURE_LOG="$CASE_ROOT/installer-command.log" \
        INSTALL_FIXTURE_ARCH=x86_64 \
        INSTALL_FIXTURE_GLIBC=2.39 \
        bash -c '
            source "$CASE_REPOSITORY/install.sh"
            preflight || exit $?
            if [[ "$PLATFORM_FAMILY" == debian ]]; then
                install_system_packages_debian
            else
                install_system_packages_rhel
            fi
            printf "PLATFORM=%s|%s|%s\n" \
                "$PLATFORM_ID" "$PLATFORM_FAMILY" "${RHEL_MAJOR:-}"
            printf "FAILURE_COUNT=%s\n" "${#FAILURES[@]}"
        ' > "$CASE_OUTPUT" 2>&1
    CASE_STATUS=$?
    return 0
}

run_package_failure_main() {
    local failure_match="$1"
    : > "$CASE_ROOT/installer-command.log"
    env -i \
        HOME="$CASE_HOME" \
        PATH="$CASE_BIN" \
        LANG=C \
        LC_ALL=C \
        TMPDIR="$CASE_TMP" \
        CASE_REPOSITORY="$CASE_REPOSITORY" \
        INSTALL_FIXTURE_MODE=1 \
        INSTALL_FIXTURE_LOG="$CASE_ROOT/installer-command.log" \
        INSTALL_FIXTURE_FAIL_MATCH="$failure_match" \
        INSTALL_FIXTURE_ARCH=x86_64 \
        INSTALL_FIXTURE_GLIBC=2.39 \
        CONTINUATION_LOG="$CASE_ROOT/continuation.log" \
        bash -c '
            source "$CASE_REPOSITORY/install.sh"
            install_rust() { return 0; }
            activate_cargo() { return 0; }
            install_go() { return 0; }
            install_node() { return 0; }
            activate_nvm() { return 0; }
            install_uv() { return 0; }
            install_cargo_tool() { return 0; }
            install_glow() { return 0; }
            install_codex() { return 0; }
            install_sqlit() { return 0; }
            install_claude() { return 0; }
            configure_claude_mcp_servers() { return 0; }
            install_starship() { return 0; }
            install_zoxide() { return 0; }
            install_release_binary() { return 0; }
            install_herdr() { return 0; }
            install_tmux() { return 0; }
            install_neovim() { return 0; }
            link_dotfiles() { return 0; }
            seed_secrets() { return 0; }
            install_tmux_plugins() { return 0; }
            install_compute_skills() {
                printf "skills-phase\n" >> "$CONTINUATION_LOG"
            }
            validate_required_commands() {
                printf "validation-phase\n" >> "$CONTINUATION_LOG"
            }
            print_summary() {
                printf "FAILURE_COUNT=%s\n" "${#FAILURES[@]}"
            }
            main
        ' > "$CASE_OUTPUT" 2>&1
    CASE_STATUS=$?
    return 0
}

prepare_link_case_sources() {
    local path
    local -a file_paths=(
        shell/.bashrc
        shell/.profile
        git/.gitconfig
        git/gitignore
        config/starship.toml
        config/btop/btop.conf
        config/herdr/config.toml
        claude/settings.json
        claude/statusline.sh
        claude/claude-statusline
        claude/hooks/herdr-agent-state.sh
        claude/themes/snazzy-light.json
        codex/config.toml
        tmux/.tmux.conf
        tmux/.gitmux.conf
    )
    mkdir -p "$CASE_REPOSITORY/config/nvim" \
        "$CASE_REPOSITORY/config/fish" || return 1
    printf 'nvim fixture\n' > "$CASE_REPOSITORY/config/nvim/init.lua" || return 1
    printf 'fish fixture\n' > "$CASE_REPOSITORY/config/fish/config.fish" || return 1
    for path in "${file_paths[@]}"; do
        mkdir -p "$CASE_REPOSITORY/${path%/*}" || return 1
        printf 'fixture source: %s\n' "$path" > "$CASE_REPOSITORY/$path" || return 1
    done
    chmod 0755 "$CASE_REPOSITORY/claude/hooks/herdr-agent-state.sh" || return 1
}

run_link_dotfiles() {
    env -i \
        HOME="$CASE_HOME" \
        PATH="$CASE_BIN" \
        LANG=C \
        LC_ALL=C \
        TMPDIR="$CASE_TMP" \
        CASE_REPOSITORY="$CASE_REPOSITORY" \
        MV_STUB_MODE=normal \
        REAL_MV="$REAL_MV_PATH" \
        bash -c '
            source "$CASE_REPOSITORY/install.sh"
            link_dotfiles
            printf "FAILURE_COUNT=%s\n" "${#FAILURES[@]}"
            printf "BACKUP_DIR=%s\n" "$BACKUP_DIR"
            (( ${#FAILURES[@]} == 0 ))
        ' > "$CASE_OUTPUT" 2>&1
    CASE_STATUS=$?
    return 0
}

run_go_install_fixture() {
    local metadata="$1" archive="$2"
    : > "$CASE_ROOT/download.log"
    : > "$CASE_ROOT/extract.log"
    env -i \
        HOME="$CASE_HOME" \
        PATH="$CASE_BIN" \
        LANG=C \
        LC_ALL=C \
        TMPDIR="$CASE_TMP" \
        CASE_REPOSITORY="$CASE_REPOSITORY" \
        GO_METADATA_FIXTURE="$metadata" \
        GO_ARCHIVE_FIXTURE="$archive" \
        DOWNLOAD_LOG="$CASE_ROOT/download.log" \
        EXTRACT_LOG="$CASE_ROOT/extract.log" \
        MV_STUB_MODE=normal \
        REAL_MV="$REAL_MV_PATH" \
        bash -c '
            source "$CASE_REPOSITORY/install.sh"
            download() {
                printf "%s\n" "$1" >> "$DOWNLOAD_LOG"
                case "$1" in
                    https://go.dev/dl/\?mode=json) cp "$GO_METADATA_FIXTURE" "$2" ;;
                    https://go.dev/dl/*) cp "$GO_ARCHIVE_FIXTURE" "$2" ;;
                    *) return 71 ;;
                esac
            }
            extract_archive() {
                printf "%s -> %s\n" "$1" "$2" >> "$EXTRACT_LOG"
                mkdir -p "$2/go/bin" || return 1
                printf "%s\n" "#!/usr/bin/env bash" \
                    "[[ \"\${1:-}\" == version ]] && printf \"go version go1.24.5 linux/amd64\\n\"" \
                    > "$2/go/bin/go" || return 1
                chmod 0755 "$2/go/bin/go"
            }
            install_go
        ' > "$CASE_OUTPUT" 2>&1
    CASE_STATUS=$?
    return 0
}

run_github_download_fixture() {
    local release_fixture="$1" archive_fixture="$2" checksum_fixture="${3:-}"
    : > "$CASE_ROOT/github-download.log"
    rm -f -- "$CASE_ROOT/github-result.archive"
    env -i \
        HOME="$CASE_HOME" \
        PATH="$CASE_BIN" \
        LANG=C \
        LC_ALL=C \
        TMPDIR="$CASE_TMP" \
        CASE_REPOSITORY="$CASE_REPOSITORY" \
        RELEASE_FIXTURE="$release_fixture" \
        ASSET_FIXTURE="$archive_fixture" \
        CHECKSUM_FIXTURE="$checksum_fixture" \
        DOWNLOAD_LOG="$CASE_ROOT/github-download.log" \
        RESULT_ARCHIVE="$CASE_ROOT/github-result.archive" \
        bash -c '
            source "$CASE_REPOSITORY/install.sh"
            download() {
                printf "%s\n" "$1" >> "$DOWNLOAD_LOG"
                case "$1" in
                    https://api.github.com/repos/example/tool/releases/latest)
                        cp "$RELEASE_FIXTURE" "$2"
                        ;;
                    https://downloads.invalid/tool.tar.gz)
                        cp "$ASSET_FIXTURE" "$2"
                        ;;
                    https://downloads.invalid/checksums.txt)
                        [[ -n "$CHECKSUM_FIXTURE" ]] || return 73
                        cp "$CHECKSUM_FIXTURE" "$2"
                        ;;
                    *) return 72 ;;
                esac
            }
            download_github_asset example/tool \
                "^tool-[0-9.]+-linux-amd64\\.tar\\.gz$" || exit $?
            cp "$RELEASE_ARCHIVE" "$RESULT_ARCHIVE" || exit 1
            printf "RELEASE_TAG=%s\n" "$RELEASE_TAG"
        ' > "$CASE_OUTPUT" 2>&1
    CASE_STATUS=$?
    return 0
}

run_release_binary_member_fixture() {
    local member_mode="$1"
    : > "$CASE_ROOT/release-member.log"
    env -i \
        HOME="$CASE_HOME" \
        PATH="$CASE_HOME/.local/bin:$CASE_BIN" \
        LANG=C \
        LC_ALL=C \
        TMPDIR="$CASE_TMP" \
        CASE_REPOSITORY="$CASE_REPOSITORY" \
        MEMBER_MODE="$member_mode" \
        MEMBER_LOG="$CASE_ROOT/release-member.log" \
        MV_STUB_MODE=normal \
        REAL_MV="$REAL_MV_PATH" \
        bash -c '
            source "$CASE_REPOSITORY/install.sh"
            download_github_asset() {
                RELEASE_TAG=v1.0.0
                RELEASE_ARCHIVE="$HOME/fixture.tar.gz"
                : > "$RELEASE_ARCHIVE"
            }
            extract_archive() {
                local destination="$2"
                printf "extract\n" >> "$MEMBER_LOG"
                mkdir -p "$destination/one" "$destination/two" || return 1
                case "$MEMBER_MODE" in
                    zero)
                        printf "not the requested executable\n" \
                            > "$destination/one/unrelated"
                        ;;
                    multiple)
                        printf "first\n" > "$destination/one/fixture-tool"
                        printf "second\n" > "$destination/two/fixture-tool"
                        ;;
                    one)
                        printf "%s\n" \
                            "#!/usr/bin/env bash" \
                            "[[ \"\${1:-}\" == --version ]] && printf \"fixture-tool 1.0.0\\n\"" \
                            > "$destination/one/fixture-tool"
                        ;;
                    *) return 70 ;;
                esac
            }
            install_release_binary \
                "fixture tool" fixture-tool example/tool \
                "^fixture\\.tar\\.gz$" fixture-tool || exit $?
            if [[ "$MEMBER_MODE" == one ]]; then
                install_release_binary \
                    "fixture tool" fixture-tool example/tool \
                    "^fixture\\.tar\\.gz$" fixture-tool
            fi
        ' > "$CASE_OUTPUT" 2>&1
    CASE_STATUS=$?
    return 0
}

write_herdr_command_fixture() {
    local destination="$1" label="$2" behavior="$3"
    mkdir -p "${destination%/*}" || return 1
    if [[ "$behavior" == working ]]; then
        printf '%s\n' \
            '#!/bin/sh' \
            "printf '%s %s\\n' '$label' \"\$*\" >> \"\$HERDR_VERSION_LOG\"" \
            'case "${1:-}" in' \
            '  --version|-V) printf "herdr 0.7.5\n"; exit 0 ;;' \
            '  *) exit 0 ;;' \
            'esac' \
            > "$destination" || return 1
    else
        printf '%s\n' \
            '#!/bin/sh' \
            "printf '%s %s\\n' '$label' \"\$*\" >> \"\$HERDR_VERSION_LOG\"" \
            'exit 91' \
            > "$destination" || return 1
    fi
    chmod 0755 "$destination"
}

run_herdr_install_fixture() {
    local initial_state="$1" installer_mode="$2"
    local installed_fixture="$CASE_ROOT/installer-herdr"
    local installer_bytes_fixture="$CASE_ROOT/herdr-installer-bytes.sh"
    local herdr="$CASE_HOME/.local/bin/herdr"
    local real_sh
    real_sh="$(command -v sh)" || return 1
    mkdir -p "$CASE_HOME/.local/bin" || return 1
    : > "$CASE_ROOT/herdr-curl.log"
    : > "$CASE_ROOT/herdr-installer-sh.log"
    : > "$CASE_ROOT/herdr-installer-sh-input.sh"
    : > "$CASE_ROOT/herdr-timeout.log"
    : > "$CASE_ROOT/herdr-version.log"
    : > "$installer_bytes_fixture"
    rm -f -- "$installed_fixture" "$CASE_ROOT/herdr-posix-sh.marker"
    case "$initial_state" in
        missing) rm -f -- "$herdr" ;;
        working) write_herdr_command_fixture "$herdr" initial working || return 1 ;;
        broken) write_herdr_command_fixture "$herdr" initial broken || return 1 ;;
        preserve) [[ -x "$herdr" ]] || return 1 ;;
        *) return 2 ;;
    esac
    case "$installer_mode" in
        success)
            write_herdr_command_fixture "$installed_fixture" installed working || return 1
            printf '%s\n' \
                'mkdir -p "$HOME/.local/bin"' \
                'install -m 0755 "$HERDR_INSTALL_BINARY_FIXTURE" "$HOME/.local/bin/herdr"' \
                'printf "posix-sh-consumed\n" > "$HERDR_POSIX_SH_MARKER"' \
                > "$installer_bytes_fixture" || return 1
            ;;
        broken-post-install)
            write_herdr_command_fixture "$installed_fixture" installed broken || return 1
            printf '%s\n' \
                'mkdir -p "$HOME/.local/bin"' \
                'install -m 0755 "$HERDR_INSTALL_BINARY_FIXTURE" "$HOME/.local/bin/herdr"' \
                'printf "posix-sh-consumed\n" > "$HERDR_POSIX_SH_MARKER"' \
                > "$installer_bytes_fixture" || return 1
            ;;
        curl-failure|unused) ;;
        installer-shell-failure)
            printf '%s\n' 'exit 72' > "$installer_bytes_fixture" || return 1
            ;;
        missing-post-install)
            printf '%s\n' ':' > "$installer_bytes_fixture" || return 1
            ;;
        *) return 2 ;;
    esac
    ln -sfn "$SCRIPT_PATH" "$CASE_BIN/sh" || return 1
    env -i \
        HOME="$CASE_HOME" \
        PATH="$CASE_HOME/.local/bin:$CASE_BIN" \
        LANG=C \
        LC_ALL=C \
        TMPDIR="$CASE_TMP" \
        CASE_REPOSITORY="$CASE_REPOSITORY" \
        HERDR_CURL_LOG="$CASE_ROOT/herdr-curl.log" \
        HERDR_INSTALLER_BYTES_FIXTURE="$installer_bytes_fixture" \
        HERDR_INSTALLER_SH_FIXTURE_MODE=1 \
        HERDR_INSTALLER_SH_INPUT="$CASE_ROOT/herdr-installer-sh-input.sh" \
        HERDR_INSTALLER_SH_LOG="$CASE_ROOT/herdr-installer-sh.log" \
        HERDR_TIMEOUT_LOG="$CASE_ROOT/herdr-timeout.log" \
        HERDR_VERSION_LOG="$CASE_ROOT/herdr-version.log" \
        HERDR_INSTALL_BINARY_FIXTURE="$installed_fixture" \
        HERDR_INSTALLER_MODE="$installer_mode" \
        HERDR_POSIX_SH_MARKER="$CASE_ROOT/herdr-posix-sh.marker" \
        HERDR_REAL_SH="$real_sh" \
        bash -c '
            source "$CASE_REPOSITORY/install.sh"
            timeout() {
                local argument duration
                {
                    printf "timeout"
                    for argument in "$@"; do printf " %q" "$argument"; done
                    printf "\n"
                } >> "$HERDR_TIMEOUT_LOG"
                duration="$1"
                shift
                [[ "$duration" == 10 ]] || return 96
                "$@"
            }
            curl() {
                local argument line
                {
                    printf "curl"
                    for argument in "$@"; do printf " %q" "$argument"; done
                    printf "\n"
                } >> "$HERDR_CURL_LOG"
                case "$HERDR_INSTALLER_MODE" in
                    curl-failure) return 71 ;;
                    unused) return 93 ;;
                    success|broken-post-install|installer-shell-failure|missing-post-install)
                        while IFS= read -r line || [[ -n "$line" ]]; do
                            printf "%s\n" "$line"
                        done < "$HERDR_INSTALLER_BYTES_FIXTURE"
                        ;;
                    *) return 94 ;;
                esac
            }
            install_herdr
            status=$?
            printf "STATUS=%s\n" "$status"
            exit "$status"
        ' > "$CASE_OUTPUT" 2>&1
    CASE_STATUS=$?
    return 0
}

run_herdr_hook_socket_fixture() {
    local hook="$1" agent="$2"
    local socket_path="$CASE_ROOT/herdr-$agent.sock"
    local ready_file="$CASE_ROOT/herdr-$agent.ready"
    local request_file="$CASE_ROOT/herdr-$agent-request.json"
    local server_output="$CASE_ROOT/herdr-$agent-server.log"
    local server_pid server_status=0 hook_status=0 attempt_number
    rm -f -- "$socket_path" "$ready_file" "$request_file"
    python3 - "$socket_path" "$ready_file" "$request_file" \
        > "$server_output" 2>&1 <<'PY' &
import pathlib
import socket
import sys

socket_path, ready_file, request_file = sys.argv[1:]
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(socket_path)
server.listen(1)
server.settimeout(3)
pathlib.Path(ready_file).write_text("ready\n", encoding="utf-8")
connection, _ = server.accept()
with connection:
    chunks = []
    while True:
        chunk = connection.recv(4096)
        if not chunk:
            break
        chunks.append(chunk)
        if b"\n" in chunk:
            break
    payload = b"".join(chunks).split(b"\n", 1)[0]
    pathlib.Path(request_file).write_bytes(payload + b"\n")
    connection.sendall(b'{"ok":true}\n')
server.close()
PY
    server_pid=$!
    for attempt_number in $(seq 1 100); do
        [[ -S "$socket_path" && -f "$ready_file" ]] && break
        sleep 0.01
    done
    if [[ ! -S "$socket_path" || ! -f "$ready_file" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
        return 1
    fi
    printf '%s\n' \
        "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$agent-session\",\"transcript_path\":\"$CASE_ROOT/$agent-transcript.jsonl\",\"source\":\"startup\"}" |
        env -i \
            HOME="$CASE_HOME" \
            PATH=/usr/bin:/bin \
            TMPDIR="$CASE_TMP" \
            HERDR_ENV=1 \
            HERDR_SOCKET_PATH="$socket_path" \
            HERDR_PANE_ID='%42' \
            "$hook" session > "$CASE_ROOT/herdr-$agent-hook.log" 2>&1 || hook_status=$?
    wait "$server_pid" || server_status=$?
    printf 'HOOK_STATUS=%s\nSERVER_STATUS=%s\n' \
        "$hook_status" "$server_status" > "$CASE_ROOT/herdr-$agent-status.log"
    return 0
}

run_unsafe_archive_fixture() {
    local archive_mode="$1"
    : > "$CASE_ROOT/tar.log"
    rm -f -- "$CASE_ROOT/extraction-marker"
    env -i \
        HOME="$CASE_HOME" \
        PATH="$CASE_BIN" \
        LANG=C \
        LC_ALL=C \
        TMPDIR="$CASE_TMP" \
        CASE_REPOSITORY="$CASE_REPOSITORY" \
        ARCHIVE_MODE="$archive_mode" \
        TAR_LOG="$CASE_ROOT/tar.log" \
        EXTRACTION_MARKER="$CASE_ROOT/extraction-marker" \
        bash -c '
            source "$CASE_REPOSITORY/install.sh"
            tar() {
                local option="$1"
                printf "%q" "$1" >> "$TAR_LOG"
                shift
                printf " %q" "$@" >> "$TAR_LOG"
                printf "\n" >> "$TAR_LOG"
                case "$option" in
                    -tf)
                        if [[ "$ARCHIVE_MODE" == traversal ]]; then
                            printf "../escape\n"
                        else
                            printf "safe/link\n"
                        fi
                        ;;
                    -tvf)
                        if [[ "$ARCHIVE_MODE" == symlink ]]; then
                            printf "%s\n" "lrwxrwxrwx user/group 0 2026-01-01 safe/link -> /etc/passwd"
                        else
                            printf "%s\n" "-rw------- user/group 1 2026-01-01 safe/file"
                        fi
                        ;;
                    --no-same-owner)
                        : > "$EXTRACTION_MARKER"
                        ;;
                esac
            }
            : > "$HOME/fake.tar"
            extract_archive "$HOME/fake.tar" "$HOME/extract"
        ' > "$CASE_OUTPUT" 2>&1
    CASE_STATUS=$?
    return 0
}

run_seed_secrets_fixture() {
    local key_is_set="$1" key_value="${2:-}" preset_backup="${3:-}"
    env -i \
        HOME="$CASE_HOME" \
        PATH="$CASE_BIN" \
        LANG=C \
        LC_ALL=C \
        TMPDIR="$CASE_TMP" \
        CASE_REPOSITORY="$CASE_REPOSITORY" \
        KEY_IS_SET="$key_is_set" \
        FIXTURE_KEY="$key_value" \
        PRESET_BACKUP_DIR="$preset_backup" \
        MV_STUB_MODE=normal \
        REAL_MV="$REAL_MV_PATH" \
        bash -c '
            source "$CASE_REPOSITORY/install.sh"
            if [[ "$KEY_IS_SET" == 1 ]]; then
                export LLM_GATEWAY_KEY="$FIXTURE_KEY"
            fi
            if [[ -n "$PRESET_BACKUP_DIR" ]]; then
                BACKUP_DIR="$PRESET_BACKUP_DIR"
            fi
            seed_secrets
            printf "BACKUP_DIR=%s\n" "$BACKUP_DIR"
        ' > "$CASE_OUTPUT" 2>&1
    CASE_STATUS=$?
    return 0
}

prepare_compute_checkout_fixture() {
    local checkout="$CASE_HOME/compute-ai-skills"
    mkdir -p "$checkout/.git" \
        "$checkout/.claude/skills/shared-claude-skill" \
        "$checkout/.claude/hooks/shared-claude-hook" \
        "$checkout/.codex/skills/shared-codex-skill" \
        "$checkout/.codex/hooks/shared-codex-hook" || return 1
    printf 'fixture\n' > \
        "$checkout/.claude/skills/shared-claude-skill/SKILL.md" || return 1
    printf 'fixture\n' > \
        "$checkout/.claude/hooks/shared-claude-hook/hook.sh" || return 1
    printf 'fixture\n' > \
        "$checkout/.codex/skills/shared-codex-skill/SKILL.md" || return 1
    printf 'fixture\n' > \
        "$checkout/.codex/hooks/shared-codex-hook/hook.sh" || return 1
    printf '%s\n' \
        '#!/bin/sh' \
        '# HERDR_INTEGRATION_ID=codex' \
        '# HERDR_INTEGRATION_VERSION=6' \
        'exit 0' \
        > "$checkout/.codex/hooks/herdr-agent-state.sh" || return 1
    chmod 0755 "$checkout/.codex/hooks/herdr-agent-state.sh" || return 1
    printf '%s\n' \
        '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash \\"$HOME/.codex/herdr-agent-state.sh\\" session","timeout":10}]}]}}' \
        > "$checkout/.codex/hooks.json" || return 1
}

run_compute_skills_fixture() {
    local mode="$1"
    : > "$CASE_ROOT/git.log"
    env -i \
        HOME="$CASE_HOME" \
        PATH="$CASE_BIN" \
        LANG=C \
        LC_ALL=C \
        TMPDIR="$CASE_TMP" \
        CASE_REPOSITORY="$CASE_REPOSITORY" \
        SKILLS_MODE="$mode" \
        GIT_LOG="$CASE_ROOT/git.log" \
        MV_STUB_MODE=normal \
        REAL_MV="$REAL_MV_PATH" \
        bash -c '
            source "$CASE_REPOSITORY/install.sh"
            git() {
                local argument
                {
                    printf "git"
                    for argument in "$@"; do printf " %q" "$argument"; done
                    printf "\n"
                } >> "$GIT_LOG"
                if [[ "${1:-}" == clone ]]; then
                    [[ "$SKILLS_MODE" != missing-fail ]] || return 71
                    if [[ "$SKILLS_MODE" == missing-success ]]; then
                        local target="${*: -1}"
                        mkdir -p "$target/.git" \
                            "$target/.claude/skills/cloned-claude-skill" \
                            "$target/.claude/hooks/cloned-claude-hook" \
                            "$target/.codex/skills/cloned-codex-skill" \
                            "$target/.codex/hooks/cloned-codex-hook" || return 72
                        printf "fixture\n" > \
                            "$target/.claude/skills/cloned-claude-skill/SKILL.md" || return 72
                        printf "fixture\n" > \
                            "$target/.claude/hooks/cloned-claude-hook/hook.sh" || return 72
                        printf "fixture\n" > \
                            "$target/.codex/skills/cloned-codex-skill/SKILL.md" || return 72
                        printf "fixture\n" > \
                            "$target/.codex/hooks/cloned-codex-hook/hook.sh" || return 72
                        printf "%s\n" \
                            "#!/bin/sh" \
                            "# HERDR_INTEGRATION_ID=codex" \
                            "# HERDR_INTEGRATION_VERSION=6" \
                            "exit 0" \
                            > "$target/.codex/hooks/herdr-agent-state.sh" || return 72
                        chmod 0755 "$target/.codex/hooks/herdr-agent-state.sh" || return 72
                        printf "%s\n" \
                            "{\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"bash \\\"\\$HOME/.codex/herdr-agent-state.sh\\\" session\",\"timeout\":10}]}]}}" \
                            > "$target/.codex/hooks.json" || return 72
                        return 0
                    fi
                    return 73
                fi
                [[ "${1:-}" == -C && $# -ge 3 ]] || return 74
                case "$3" in
                    remote)
                        if [[ "$SKILLS_MODE" == wrong-origin ]]; then
                            printf "https://github.com/other/project.git\n"
                        else
                            printf "https://github.com/abchoudh-amd/compute-ai-skills.git\n"
                        fi
                        ;;
                    branch)
                        if [[ "$SKILLS_MODE" == non-main ]]; then
                            printf "feature/local-work\n"
                        else
                            printf "main\n"
                        fi
                        ;;
                    status)
                        [[ "$SKILLS_MODE" != dirty ]] || printf " M local-change\n"
                        ;;
                    pull)
                        [[ "$SKILLS_MODE" != offline ]] || return 74
                        ;;
                    *) return 76 ;;
                esac
            }
            install_compute_skills
        ' > "$CASE_OUTPUT" 2>&1
    CASE_STATUS=$?
    return 0
}

run_configure() {
    local mode="${1:-normal}"
    local mv_mode="${2:-normal}"
    local -a optional_environment=()
    if (( $# >= 3 )); then
        optional_environment+=("CLAUDE_CONFIG_DIR=$3")
    fi
    env -i \
        HOME="$CASE_HOME" \
        PATH="$CASE_BIN" \
        LANG=C \
        LC_ALL=C \
        TMPDIR="$CASE_TMP" \
        CASE_REPOSITORY="$CASE_REPOSITORY" \
        CLAUDE_STUB_LOG="$CASE_LOG" \
        BLOCKED_COMMAND_LOG="$CASE_BLOCK_LOG" \
        CLAUDE_STUB_MODE="$mode" \
        MV_STUB_MODE="$mv_mode" \
        REAL_MV="$REAL_MV_PATH" \
        "${optional_environment[@]}" \
        bash -c '
            source "$CASE_REPOSITORY/install.sh"
            configure_claude_mcp_servers
            status=$?
            printf "STATUS=%s\n" "$status"
            printf "BACKUP_DIR=%s\n" "$BACKUP_DIR"
            exit "$status"
        ' > "$CASE_OUTPUT" 2>&1
    CASE_STATUS=$?
    return 0
}

run_attempted_configure() {
    env -i \
        HOME="$CASE_HOME" \
        PATH="$CASE_BIN" \
        LANG=C \
        LC_ALL=C \
        TMPDIR="$CASE_TMP" \
        CASE_REPOSITORY="$CASE_REPOSITORY" \
        CLAUDE_STUB_LOG="$CASE_LOG" \
        BLOCKED_COMMAND_LOG="$CASE_BLOCK_LOG" \
        CLAUDE_STUB_MODE=normal \
        MV_STUB_MODE=normal \
        REAL_MV="$REAL_MV_PATH" \
        bash -c '
            source "$CASE_REPOSITORY/install.sh"
            attempt "configure Claude user MCP definitions" configure_claude_mcp_servers
            printf "AFTER_ATTEMPT=1\n"
            printf "FAILURE_COUNT=%s\n" "${#FAILURES[@]}"
            final_status=0
            (( ${#FAILURES[@]} == 0 )) || final_status=1
            printf "FINAL_STATUS=%s\n" "$final_status"
            exit "$final_status"
        ' > "$CASE_OUTPUT" 2>&1
    CASE_STATUS=$?
    return 0
}

run_final_validation() {
    local missing_command="${1:-}"
    local have_log="$CASE_ROOT/validation-have.log"
    : > "$have_log"
    env -i \
        HOME="$CASE_HOME" \
        PATH="$CASE_BIN" \
        LANG=C \
        LC_ALL=C \
        TMPDIR="$CASE_TMP" \
        CASE_REPOSITORY="$CASE_REPOSITORY" \
        CLAUDE_STUB_LOG="$CASE_LOG" \
        BLOCKED_COMMAND_LOG="$CASE_BLOCK_LOG" \
        CLAUDE_STUB_MODE=normal \
        MV_STUB_MODE=normal \
        REAL_MV="$REAL_MV_PATH" \
        VALIDATION_MISSING="$missing_command" \
        VALIDATION_HAVE_LOG="$have_log" \
        bash -c '
            source "$CASE_REPOSITORY/install.sh"
            have() {
                printf "%s\n" "$1" >> "$VALIDATION_HAVE_LOG"
                [[ "$1" != "$VALIDATION_MISSING" ]]
            }
            tmux_version() { printf "3.2\n"; }
            nvim_version() { printf "0.11.2\n"; }
            binary_version_works() { return 0; }
            validate_required_commands
            printf "FAILURE_COUNT=%s\n" "${#FAILURES[@]}"
            (( ${#FAILURES[@]} == 0 ))
        ' > "$CASE_OUTPUT" 2>&1
    CASE_STATUS=$?
    return 0
}

prepare_herdr_validation_fixture() {
    local compute_source="${COMPUTE_SKILLS_SOURCE_ROOT:-$REPOSITORY_ROOT/../compute-ai-skills}"
    local compute_checkout="$CASE_HOME/compute-ai-skills"
    [[ -f "$compute_source/.codex/hooks/herdr-agent-state.sh" &&
       -f "$compute_source/.codex/hooks.json" ]] || return 1
    mkdir -p "$CASE_REPOSITORY/claude/hooks" \
        "$CASE_HOME/.claude/hooks" \
        "$CASE_HOME/.codex/hooks" \
        "$compute_checkout/.codex/hooks" || return 1
    cp "$REPOSITORY_ROOT/claude/hooks/herdr-agent-state.sh" \
        "$CASE_REPOSITORY/claude/hooks/herdr-agent-state.sh" || return 1
    cp "$REPOSITORY_ROOT/claude/settings.json" \
        "$CASE_HOME/.claude/settings.json" || return 1
    cp "$compute_source/.codex/hooks/herdr-agent-state.sh" \
        "$compute_checkout/.codex/hooks/herdr-agent-state.sh" || return 1
    cp "$compute_source/.codex/hooks.json" \
        "$compute_checkout/.codex/hooks.json" || return 1
    chmod 0755 \
        "$CASE_REPOSITORY/claude/hooks/herdr-agent-state.sh" \
        "$compute_checkout/.codex/hooks/herdr-agent-state.sh" || return 1
    ln -s "$CASE_REPOSITORY/claude/hooks/herdr-agent-state.sh" \
        "$CASE_HOME/.claude/hooks/herdr-agent-state.sh" || return 1
    ln -s "$compute_checkout/.codex/hooks/herdr-agent-state.sh" \
        "$CASE_HOME/.codex/hooks/herdr-agent-state.sh" || return 1
    ln -s "$compute_checkout/.codex/hooks/herdr-agent-state.sh" \
        "$CASE_HOME/.codex/herdr-agent-state.sh" || return 1
    ln -s "$compute_checkout/.codex/hooks.json" \
        "$CASE_HOME/.codex/hooks.json" || return 1
}

mutate_herdr_validation_fixture() {
    local scenario="$1"
    local claude_source="$CASE_REPOSITORY/claude/hooks/herdr-agent-state.sh"
    local codex_source="$CASE_HOME/compute-ai-skills/.codex/hooks/herdr-agent-state.sh"
    local claude_settings="$CASE_HOME/.claude/settings.json"
    local codex_hooks="$CASE_HOME/compute-ai-skills/.codex/hooks.json"
    local temporary="$CASE_ROOT/herdr-validation-mutation.json"
    case "$scenario" in
        claude-wrong-source)
            cp "$claude_source" "$CASE_ROOT/wrong-claude-hook.sh" || return 1
            rm -f -- "$CASE_HOME/.claude/hooks/herdr-agent-state.sh" || return 1
            ln -s "$CASE_ROOT/wrong-claude-hook.sh" \
                "$CASE_HOME/.claude/hooks/herdr-agent-state.sh"
            ;;
        codex-wrong-source)
            cp "$codex_source" "$CASE_ROOT/wrong-codex-hook.sh" || return 1
            rm -f -- "$CASE_HOME/.codex/herdr-agent-state.sh" || return 1
            ln -s "$CASE_ROOT/wrong-codex-hook.sh" \
                "$CASE_HOME/.codex/herdr-agent-state.sh"
            ;;
        claude-wrong-id)
            sed -i 's/^# HERDR_INTEGRATION_ID=claude$/# HERDR_INTEGRATION_ID=wrong/' \
                "$claude_source"
            ;;
        codex-wrong-id)
            sed -i 's/^# HERDR_INTEGRATION_ID=codex$/# HERDR_INTEGRATION_ID=wrong/' \
                "$codex_source"
            ;;
        claude-zero-version)
            sed -i 's/^# HERDR_INTEGRATION_VERSION=[0-9][0-9]*$/# HERDR_INTEGRATION_VERSION=0/' \
                "$claude_source"
            ;;
        codex-zero-version)
            sed -i 's/^# HERDR_INTEGRATION_VERSION=[0-9][0-9]*$/# HERDR_INTEGRATION_VERSION=0/' \
                "$codex_source"
            ;;
        claude-duplicate-version)
            printf '%s\n' '# HERDR_INTEGRATION_VERSION=99' >> "$claude_source"
            ;;
        codex-duplicate-version)
            printf '%s\n' '# HERDR_INTEGRATION_VERSION=99' >> "$codex_source"
            ;;
        claude-non-executable)
            chmod 0644 "$claude_source"
            ;;
        codex-non-executable)
            chmod 0644 "$codex_source"
            ;;
        claude-malformed-session)
            printf '{\n' > "$claude_settings"
            ;;
        codex-malformed-session)
            printf '{\n' > "$codex_hooks"
            ;;
        claude-duplicate-session)
            jq '.hooks.SessionStart += [.hooks.SessionStart[-1]]' \
                "$claude_settings" > "$temporary" || return 1
            mv -fT -- "$temporary" "$claude_settings"
            ;;
        codex-duplicate-session)
            jq '.hooks.SessionStart += [.hooks.SessionStart[-1]]' \
                "$codex_hooks" > "$temporary" || return 1
            mv -fT -- "$temporary" "$codex_hooks"
            ;;
        claude-shadow-session)
            jq --arg command 'bash "$HOME/.claude/hooks/herdr-agent-state.sh" session' '
                .hooks.SessionStart += [{
                    matcher: "*",
                    hooks: [{type: "command", command: $command, timeout: 11}]
                }]
            ' "$claude_settings" > "$temporary" || return 1
            mv -fT -- "$temporary" "$claude_settings"
            ;;
        codex-shadow-session)
            jq --arg command 'bash "$HOME/.codex/herdr-agent-state.sh" session' '
                .hooks.SessionStart += [{
                    hooks: [{
                        type: "command",
                        command: $command,
                        timeout: 10,
                        statusMessage: "Shadow Herdr invocation"
                    }]
                }]
            ' "$codex_hooks" > "$temporary" || return 1
            mv -fT -- "$temporary" "$codex_hooks"
            ;;
        claude-multiple-documents)
            cp "$claude_settings" "$temporary" || return 1
            printf '%s\n' '{}' > "$claude_settings" || return 1
            sed -n 'p' "$temporary" >> "$claude_settings"
            ;;
        codex-multiple-documents)
            cp "$codex_hooks" "$temporary" || return 1
            printf '%s\n' '{}' > "$codex_hooks" || return 1
            sed -n 'p' "$temporary" >> "$codex_hooks"
            ;;
        claude-duplicate-session-key)
            printf '%s\n' \
                '{"hooks":{"SessionStart":[],"SessionStart":[{"matcher":"*","hooks":[{"type":"command","command":"bash \"$HOME/.claude/hooks/herdr-agent-state.sh\" session","timeout":10}]}]}}' \
                > "$claude_settings"
            ;;
        codex-duplicate-session-key)
            printf '%s\n' \
                '{"hooks":{"SessionStart":[],"SessionStart":[{"hooks":[{"type":"command","command":"bash \"$HOME/.codex/herdr-agent-state.sh\" session","timeout":10}]}]}}' \
                > "$codex_hooks"
            ;;
        *) return 2 ;;
    esac
}

run_direct_new_state_rollback() {
    local confirmed_name="${1:-}" confirmed_record="${2:-}" mv_mode="${3:-normal}"
    env -i \
        HOME="$CASE_HOME" \
        PATH="$CASE_BIN" \
        LANG=C \
        LC_ALL=C \
        TMPDIR="$CASE_TMP" \
        CASE_REPOSITORY="$CASE_REPOSITORY" \
        CONFIRMED_NAME="$confirmed_name" \
        CONFIRMED_RECORD="$confirmed_record" \
        MV_STUB_MODE="$mv_mode" \
        REAL_MV="$REAL_MV_PATH" \
        bash -c '
            source "$CASE_REPOSITORY/install.sh"
            status=0
            if [[ -n "$CONFIRMED_NAME" ]]; then
                rollback_new_claude_state "$HOME/.claude.json" 1 "{}" "{}" \
                    "$CONFIRMED_NAME" "$CONFIRMED_RECORD" || status=$?
            else
                rollback_new_claude_state "$HOME/.claude.json" 1 "{}" "{}" || status=$?
            fi
            printf "STATUS=%s\n" "$status"
            exit "$status"
        ' > "$CASE_OUTPUT" 2>&1
    CASE_STATUS=$?
    return 0
}

run_main_inventory() {
    local inventory_log="$CASE_ROOT/install-inventory.log"
    : > "$inventory_log"
    env -i \
        HOME="$CASE_HOME" \
        PATH="$CASE_BIN" \
        LANG=C \
        LC_ALL=C \
        TMPDIR="$CASE_TMP" \
        CASE_REPOSITORY="$CASE_REPOSITORY" \
        INSTALL_INVENTORY_LOG="$inventory_log" \
        bash -c '
            source "$CASE_REPOSITORY/install.sh"
            preflight() {
                PLATFORM_ID=ubuntu
                PLATFORM_FAMILY=debian
            }
            install_system_packages_debian() { return 0; }
            install_rust() { return 0; }
            activate_cargo() { return 0; }
            install_go() { return 0; }
            install_node() { return 0; }
            activate_nvm() { return 0; }
            install_uv() { return 0; }
            install_cargo_tool() {
                printf "install_cargo_tool %s %s\n" "$1" "$2" \
                    >> "$INSTALL_INVENTORY_LOG"
            }
            install_glow() { return 0; }
            install_codex() { return 0; }
            install_sqlit() { return 0; }
            install_claude() { return 0; }
            configure_claude_mcp_servers() { return 0; }
            install_starship() { return 0; }
            install_zoxide() { return 0; }
            install_release_binary() { return 0; }
            install_herdr() {
                printf "install_herdr\n" >> "$INSTALL_INVENTORY_LOG"
            }
            install_tmux() { return 0; }
            install_neovim() { return 0; }
            link_dotfiles() { return 0; }
            seed_secrets() { return 0; }
            install_tmux_plugins() { return 0; }
            install_compute_skills() { return 0; }
            validate_required_commands() { return 0; }
            print_summary() { return 0; }
            main
        ' > "$CASE_OUTPUT" 2>&1
    CASE_STATUS=$?
    return 0
}

write_json() {
    printf '%s\n' "$2" > "$1"
}

file_sha256() {
    sha256sum "$1" | awk '{print $1}'
}

require() {
    local description="$1"
    shift
    if ! "$@"; then
        printf 'assertion failed: %s\n' "$description" >&2
        return 1
    fi
}

require_equal() {
    local description="$1" expected="$2" actual="$3"
    if [[ "$expected" != "$actual" ]]; then
        printf 'assertion failed: %s (expected %s, got %s)\n' \
            "$description" "$expected" "$actual" >&2
        return 1
    fi
}

require_herdr_installer_pipeline() {
    local marker_expected="$1"
    require_equal "official installer invokes POSIX sh with no arguments" \
        sh "$(< "$CASE_ROOT/herdr-installer-sh.log")" || return 1
    require_equal "POSIX sh consumes the exact fetched installer bytes" \
        "$(file_sha256 "$CASE_ROOT/herdr-installer-bytes.sh")" \
        "$(file_sha256 "$CASE_ROOT/herdr-installer-sh-input.sh")" || return 1
    if [[ "$marker_expected" == 1 ]]; then
        require_equal "the fetched installer is executed by POSIX sh" \
            posix-sh-consumed \
            "$(tr -d '\n' < "$CASE_ROOT/herdr-posix-sh.marker")" || return 1
    else
        require "a non-success installer does not emit the POSIX sh marker" \
            test ! -e "$CASE_ROOT/herdr-posix-sh.marker" || return 1
    fi
}

require_file_excludes() {
    local description="$1" file="$2" pattern="$3"
    if grep -Fq -- "$pattern" "$file"; then
        printf 'assertion failed: %s\n' "$description" >&2
        return 1
    fi
}

fresh_claude_non_mcp_state_is_exact() {
    jq -e '
        del(.mcpServers) == {
            "firstStartTime": "2026-07-24T00:00:00.000Z",
            "machineID": "fixture-machine-id",
            "migrationVersion": 1,
            "userID": "fixture-user-id"
        }
    ' "$1" >/dev/null
}

backup_directory() {
    find "$CASE_HOME" -mindepth 1 -maxdepth 1 -type d \
        -name '.dotfiles-backup-*' -print -quit
}

snapshot_file() {
    local backup="$1"
    find "$backup" -type f -name '.claude.json' -print -quit
}

recovery_directory() {
    find "$CASE_HOME" -mindepth 1 -maxdepth 1 -type d \
        -name '.claude.json.recovery.*' -print -quit
}

rollback_directory() {
    find "$CASE_HOME" -mindepth 1 -maxdepth 1 -type d \
        -name '.claude.json.rollback.*' -print -quit
}

require_no_external_commands() {
    require "network and privilege commands remain blocked and unused" \
        test ! -s "$CASE_BLOCK_LOG"
}

require_manual_recovery_paths() {
    local state="$1" snapshot="${2:-}"
    if ! grep -Fq -- "current Claude state preserved at $state" "$CASE_OUTPUT" &&
       ! grep -Fq -- "Claude state destination is absent at $state" "$CASE_OUTPUT"; then
        printf 'assertion failed: manual recovery reports the exact live-state path\n' >&2
        return 1
    fi
    if [[ -n "$snapshot" ]]; then
        require "manual recovery reports the exact snapshot path" \
            grep -Fq -- "original Claude state snapshot preserved at $snapshot" \
            "$CASE_OUTPUT" || return 1
    else
        require "manual recovery reports that no original snapshot exists" \
            grep -Fq -- "no original Claude state file existed before this run" \
            "$CASE_OUTPUT" || return 1
    fi
}

require_global_case_invariants() {
    local root claude_log blocked_log
    for root in "${TEST_TEMP_ROOTS[@]}"; do
        case "$root" in
            /tmp/dotfiles-mcp-test.*) ;;
            *)
                printf 'assertion failed: case root escaped the temporary fixture boundary: %s\n' \
                    "$root" >&2
                return 1
                ;;
        esac
        require "fixture HOME stays under its case root" \
            test -d "$root/home" || return 1
        claude_log="$root/claude.log"
        blocked_log="$root/blocked-command.log"
        require "every fixture retains its Claude audit log" \
            test -f "$claude_log" || return 1
        require "every fixture retains its blocked-command audit log" \
            test -f "$blocked_log" || return 1
        require "no package, privilege, source-checkout, or network command ran" \
            test ! -s "$blocked_log" || return 1
        if grep -Eq '^claude mcp (list|get|login)([[:space:]]|$)' "$claude_log"; then
            printf 'assertion failed: forbidden Claude MCP command ran in %s\n' \
                "$root" >&2
            return 1
        fi
    done
}

test_manifest_validation_precedes_mutation() {
    local invalid
    local -a invalid_manifests=(
        '{'
        '{"mcpServers":{"jira":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"}}}'
        '{"mcpServers":{"jira":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"},"confluence":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"},"extra":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"}}}'
        '{"mcpServers":{"jira":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"},"confluence":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"}},"unexpected":true}'
        '{"mcpServers":[]}'
        '{"mcpServers":{"jira":{"type":"sse","url":"https://mcp.atlassian.com/v1/mcp/authv2"},"confluence":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"}}}'
        '{"mcpServers":{"jira":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2","headers":{"Authorization":"SECRET"}},"confluence":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"}}}'
        '{"mcpServers":{"jira":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2?token=SECRET"},"confluence":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"}}}'
        '{"mcpServers":{"jira":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2#fragment"},"confluence":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"}}}'
        '{"mcpServers":{"jira":{"type":"http","url":"https://alternate.invalid"},"confluence":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"}}}'
        $'{"mcpServers":{"jira":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"},"confluence":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"}}}\n{"mcpServers":{"jira":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"},"confluence":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"}}}'
        '{"mcpServers":{"secret":{"headers":{"Authorization":"DUPLICATE_DECLARATION_SECRET"}}},"mcpServers":{"jira":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"},"confluence":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"}}}'
        '{"mcpServers":{"jira":{"type":"http","url":"https://hidden.invalid"},"jira":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"},"confluence":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"}}}'
        '{"mcpServers":{"jira":{"type":"http","url":"https://hidden.invalid","url":"https://mcp.atlassian.com/v1/mcp/authv2"},"confluence":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"}}}'
    )

    for invalid in "${invalid_manifests[@]}"; do
        new_case || return 1
        write_json "$CASE_REPOSITORY/claude/mcp-servers.json" "$invalid"
        run_configure
        require "invalid manifest fails" test "$CASE_STATUS" -ne 0 || return 1
        require "invalid manifest invokes no Claude command" test ! -s "$CASE_LOG" || return 1
        require "invalid manifest creates no state" test ! -e "$CASE_HOME/.claude.json" || return 1
        require_no_external_commands || return 1
    done
}

test_fresh_install_and_idempotent_rerun() {
    local add_count backup_count
    new_case || return 1
    run_configure
    require_equal "fresh configuration succeeds" 0 "$CASE_STATUS" || return 1
    require "fresh state is exact" jq -e \
        --slurpfile declaration "$CASE_REPOSITORY/claude/mcp-servers.json" \
        '.mcpServers == $declaration[0].mcpServers' \
        "$CASE_HOME/.claude.json" >/dev/null || return 1
    require "fresh Claude initialization metadata is preserved" \
        fresh_claude_non_mcp_state_is_exact \
        "$CASE_HOME/.claude.json" || return 1
    add_count="$(grep -c '^claude mcp add-json --scope user ' "$CASE_LOG")"
    require_equal "both definitions use explicit user scope" 2 "$add_count" || return 1
    require "no health or authentication command runs" \
        test -z "$(grep -E '^claude mcp (list|get|login)( |$)' "$CASE_LOG" || true)" || return 1
    require_no_external_commands || return 1
    backup_count="$(find "$CASE_HOME" -mindepth 1 -maxdepth 1 -type d \
        -name '.dotfiles-backup-*' | wc -l)"
    require_equal "fresh configuration creates no backup" 0 "$backup_count" || return 1

    : > "$CASE_LOG"
    run_configure
    require_equal "matching rerun succeeds" 0 "$CASE_STATUS" || return 1
    require "matching rerun performs no Claude mutation" test ! -s "$CASE_LOG" || return 1
    backup_count="$(find "$CASE_HOME" -mindepth 1 -maxdepth 1 -type d \
        -name '.dotfiles-backup-*' | wc -l)"
    require_equal "matching rerun still creates no backup" 0 "$backup_count" || return 1
}

test_alternate_claude_config_directory_is_rejected() {
    local alternate state before
    new_case || return 1
    alternate="$CASE_ROOT/alternate-claude-config"
    state="$alternate/.claude.json"
    mkdir -p "$alternate" || return 1
    write_json "$state" \
        '{"private":"ALTERNATE_CLAUDE_STATE_SECRET","mcpServers":{"alternate":{"type":"http","url":"https://alternate.invalid"}}}'
    chmod 0600 "$state" || return 1
    before="$(file_sha256 "$state")"

    run_configure normal normal "$alternate"
    require "a nonempty CLAUDE_CONFIG_DIR is rejected" \
        test "$CASE_STATUS" -ne 0 || return 1
    require "alternate Claude state bytes are untouched" \
        test "$before" == "$(file_sha256 "$state")" || return 1
    require "the canonical Claude state is not created" \
        test ! -e "$CASE_HOME/.claude.json" || return 1
    require "Claude is not invoked with an alternate config directory" \
        test ! -s "$CASE_LOG" || return 1
    require "the rejected alternate directory is diagnosed" \
        grep -Fq -- 'CLAUDE_CONFIG_DIR' "$CASE_OUTPUT" || return 1
    require_file_excludes "alternate Claude secret is absent from output" \
        "$CASE_OUTPUT" ALTERNATE_CLAUDE_STATE_SECRET || return 1
    require "alternate config rejection creates no backup" \
        test -z "$(backup_directory)" || return 1
    require_no_external_commands || return 1
}

test_existing_state_is_preserved_and_snapshotted() {
    local state original before_projection after_projection backup snapshot
    local backup_count snapshot_count
    new_case || return 1
    state="$CASE_HOME/.claude.json"
    original="$CASE_ROOT/original.json"
    write_json "$state" \
        '{"machineID":"machine","projects":{"work":{"note":"UNRELATED_SECRET_MARKER"}},"mcpServers":{"jira":{"type":"http","url":"https://old.invalid/jira"},"confluence":{"type":"http","url":"https://old.invalid/confluence"},"other":{"type":"http","url":"https://other.invalid","headers":{"Authorization":"UNRELATED_SECRET_MARKER"}}}}'
    chmod 0640 "$state"
    cp "$state" "$original"
    before_projection="$(jq -S -c 'del(.mcpServers.jira, .mcpServers.confluence)' "$original")"

    run_configure
    require_equal "existing state reconciliation succeeds" 0 "$CASE_STATUS" || return 1
    require "managed definitions converge" jq -e \
        --slurpfile declaration "$CASE_REPOSITORY/claude/mcp-servers.json" \
        '.mcpServers.jira == $declaration[0].mcpServers.jira and
         .mcpServers.confluence == $declaration[0].mcpServers.confluence' \
        "$state" >/dev/null || return 1
    after_projection="$(jq -S -c 'del(.mcpServers.jira, .mcpServers.confluence)' "$state")"
    require_equal "unrelated state is semantically preserved" \
        "$before_projection" "$after_projection" || return 1

    backup_count="$(find "$CASE_HOME" -mindepth 1 -maxdepth 1 -type d \
        -name '.dotfiles-backup-*' | wc -l)"
    require_equal "one backup tree is created" 1 "$backup_count" || return 1
    backup="$(backup_directory)"
    require_equal "backup directory is private" 700 "$(stat -c '%a' "$backup")" || return 1
    snapshot_count="$(find "$backup" -type f -name '.claude.json' | wc -l)"
    require_equal "one state snapshot is created" 1 "$snapshot_count" || return 1
    snapshot="$(snapshot_file "$backup")"
    require_equal "snapshot is private" 600 "$(stat -c '%a' "$snapshot")" || return 1
    require_equal "snapshot is the complete original" \
        "$(file_sha256 "$original")" "$(file_sha256 "$snapshot")" || return 1
    require_file_excludes "secret is absent from command log" \
        "$CASE_LOG" UNRELATED_SECRET_MARKER || return 1
    require_file_excludes "secret is absent from installer output" \
        "$CASE_OUTPUT" UNRELATED_SECRET_MARKER || return 1
    require "all mutation commands are explicitly user scoped" \
        test -z "$(grep '^claude mcp ' "$CASE_LOG" |
            grep -Ev '^claude mcp (add-json|remove) --scope user ' || true)" || return 1
    require_equal "both conflicts are explicitly removed" 2 \
        "$(grep -c '^claude mcp remove --scope user ' "$CASE_LOG")" || return 1
    require_no_external_commands || return 1

    : > "$CASE_LOG"
    run_configure
    require_equal "post-mutation rerun succeeds" 0 "$CASE_STATUS" || return 1
    require "post-mutation rerun performs no Claude mutation" \
        test ! -s "$CASE_LOG" || return 1
    require_equal "post-mutation rerun creates no second backup" 1 \
        "$(find "$CASE_HOME" -mindepth 1 -maxdepth 1 -type d \
            -name '.dotfiles-backup-*' | wc -l)" || return 1
}

test_mixed_missing_and_conflicting_state_reconciles_together() {
    local state before_projection after_projection
    new_case || return 1
    state="$CASE_HOME/.claude.json"
    write_json "$state" \
        '{"machineID":"mixed","mcpServers":{"jira":{"type":"http","url":"https://old.invalid"},"unmanaged":{"type":"http","url":"https://unmanaged.invalid"}}}'
    before_projection="$(jq -S -c \
        'del(.mcpServers.jira, .mcpServers.confluence)' "$state")"

    run_configure
    require_equal "mixed-state reconciliation succeeds" 0 "$CASE_STATUS" || return 1
    require "both managed definitions converge together" jq -e \
        --slurpfile declaration "$CASE_REPOSITORY/claude/mcp-servers.json" \
        '.mcpServers.jira == $declaration[0].mcpServers.jira and
         .mcpServers.confluence == $declaration[0].mcpServers.confluence' \
        "$state" >/dev/null || return 1
    after_projection="$(jq -S -c \
        'del(.mcpServers.jira, .mcpServers.confluence)' "$state")"
    require_equal "mixed-state unrelated data is preserved" \
        "$before_projection" "$after_projection" || return 1
    require_equal "only the conflicting name is removed" 1 \
        "$(grep -c '^claude mcp remove --scope user jira$' "$CASE_LOG")" || return 1
    require_equal "both missing and replacement records are added" 2 \
        "$(grep -c '^claude mcp add-json --scope user ' "$CASE_LOG")" || return 1
    require_equal "mixed-state transaction creates one backup" 1 \
        "$(find "$CASE_HOME" -mindepth 1 -maxdepth 1 -type d \
            -name '.dotfiles-backup-*' | wc -l)" || return 1
    require_no_external_commands || return 1
}

test_ordinary_failures_restore_original_state() {
    local mode state original backup snapshot
    local -a modes=(fail-remove:jira fail-add:jira)
    for mode in "${modes[@]}"; do
        new_case || return 1
        state="$CASE_HOME/.claude.json"
        original="$CASE_ROOT/original.json"
        write_json "$state" \
            '{"machineID":"machine","mcpServers":{"jira":{"type":"http","url":"https://old.invalid"},"other":{"type":"http","url":"https://other.invalid"}}}'
        cp "$state" "$original"
        run_configure "$mode"
        require "injected command or postcondition failure is reported" \
            test "$CASE_STATUS" -ne 0 || return 1
        require_equal "ordinary failure restores original state" \
            "$(file_sha256 "$original")" "$(file_sha256 "$state")" || return 1
        backup="$(backup_directory)"
        require "ordinary failure retains a snapshot" test -n "$backup" || return 1
        snapshot="$(snapshot_file "$backup")"
        require_equal "retained snapshot equals original" \
            "$(file_sha256 "$original")" "$(file_sha256 "$snapshot")" || return 1
    done
}

test_absent_state_clean_second_add_failure_rolls_back_first() {
    new_case || return 1
    run_configure fail-add:confluence
    require "second addition failure is reported" test "$CASE_STATUS" -ne 0 || return 1
    require "the generated non-MCP baseline remains at the canonical path" \
        fresh_claude_non_mcp_state_is_exact \
        "$CASE_HOME/.claude.json" || return 1
    require "the first confirmed addition is removed from the generated baseline" jq -e \
        '((.mcpServers // {}) | length) == 0' \
        "$CASE_HOME/.claude.json" >/dev/null || return 1
    require "fresh-state rollback does not issue a second Claude mutation" \
        test -z "$(grep '^claude mcp remove ' "$CASE_LOG" || true)" || return 1
    require "proven generated-state cleanup leaves no recovery directory" \
        test -z "$(rollback_directory)" || return 1
    require_no_external_commands || return 1
}

test_ambiguous_existing_state_is_not_overwritten_during_rollback() {
    local mode state original backup snapshot recovery
    local -a modes=(
        delete-state-and-fail:jira
        malform-state-and-fail:jira
        directory-state-and-fail:jira
    )
    for mode in "${modes[@]}"; do
        new_case || return 1
        state="$CASE_HOME/.claude.json"
        original="$CASE_ROOT/original.json"
        write_json "$state" \
            '{"machineID":"machine","mcpServers":{"jira":{"type":"http","url":"https://old.invalid"},"other":{"type":"http","url":"https://other.invalid"}}}'
        cp "$state" "$original"
        run_configure "$mode"
        require "ambiguous rollback state is reported" test "$CASE_STATUS" -ne 0 || return 1
        backup="$(backup_directory)"
        snapshot="$(snapshot_file "$backup")"
        require_equal "original snapshot remains available" \
            "$(file_sha256 "$original")" "$(file_sha256 "$snapshot")" || return 1
        case "$mode" in
            delete-state-and-fail:*)
                require_equal "a safely absent destination restores the protected snapshot" \
                    "$(file_sha256 "$original")" "$(file_sha256 "$state")" || return 1
                require "successful absent-destination restoration leaves no recovery tree" \
                    test -z "$(recovery_directory)" || return 1
                require "the original command failure is retained after restoration" \
                    grep -Fq -- "restored $state from $snapshot" "$CASE_OUTPUT" || return 1
                ;;
            malform-state-and-fail:*)
                recovery="$(recovery_directory)"
                require_equal "malformed state returns to the canonical path" '{' \
                    "$(tr -d '\n' < "$state")" || return 1
                require "canonical malformed-state recovery removes temporary material" \
                    test -z "$recovery" || return 1
                require "ambiguous rollback reports manual recovery" \
                    grep -q 'manual recovery required' "$CASE_OUTPUT" || return 1
                require_manual_recovery_paths "$state" "$snapshot" || return 1
                ;;
            directory-state-and-fail:*)
                recovery="$(recovery_directory)"
                require "nonregular state returns to the canonical path" \
                    test -d "$state" || return 1
                require "canonical nonregular-state recovery removes temporary material" \
                    test -z "$recovery" || return 1
                require "ambiguous rollback reports manual recovery" \
                    grep -q 'manual recovery required' "$CASE_OUTPUT" || return 1
                require_manual_recovery_paths "$state" "$snapshot" || return 1
                ;;
        esac
        require_no_external_commands || return 1
    done
}

test_failure_bookkeeping_continues_and_is_nonzero() {
    new_case || return 1
    write_json "$CASE_REPOSITORY/claude/mcp-servers.json" '{'
    run_attempted_configure
    require "attempt wrapper returns the installer failure status" \
        test "$CASE_STATUS" -ne 0 || return 1
    require "later work executes" grep -q '^AFTER_ATTEMPT=1$' "$CASE_OUTPUT" || return 1
    require "failure is summarized" grep -q '^FAILURE_COUNT=1$' "$CASE_OUTPUT" || return 1
    require "final result remains nonzero" grep -q '^FINAL_STATUS=1$' "$CASE_OUTPUT" || return 1
}

test_final_validation_checks_definitions_without_claude_calls() {
    local state missing_command
    local -a required_commands=(
        git curl jq fish python3 cargo go node npm uv eza fd diskus csvlens
        yazi ya glow codex sqlit claude starship zoxide fzf rg btop duf gh gitmux herdr tmux nvim
    )
    new_case || return 1
    state="$CASE_HOME/.claude.json"
    cp "$CASE_REPOSITORY/claude/mcp-servers.json" "$state"
    mkdir -p "$CASE_HOME/.tmux/plugins/tmux"
    : > "$CASE_HOME/.tmux/plugins/tmux/catppuccin.tmux"
    prepare_herdr_validation_fixture || return 1

    run_final_validation
    require_equal "final validation command completes" 0 "$CASE_STATUS" || return 1
    require "exact definitions produce no validation failure" \
        grep -q '^FAILURE_COUNT=0$' "$CASE_OUTPUT" || return 1
    require "final validation invokes no Claude command" test ! -s "$CASE_LOG" || return 1
    require_equal "final validation checks the exact required command inventory" \
        "$(container_expected_validation_have_log)" \
        "$(< "$CASE_ROOT/validation-have.log")" || return 1
    require_no_external_commands || return 1

    for missing_command in "${required_commands[@]}"; do
        run_final_validation "$missing_command"
        require "each mandatory command is independently required: $missing_command" \
            test "$CASE_STATUS" -ne 0 || return 1
        require "controlled missing command is reported" \
            grep -Fq -- "required command missing: $missing_command" \
            "$CASE_OUTPUT" || return 1
        require_equal "only the controlled command is missing" 1 \
            "$(sed -n 's/^FAILURE_COUNT=//p' "$CASE_OUTPUT")" || return 1
    done

    jq 'del(.mcpServers.confluence)' "$state" > "$CASE_ROOT/missing.json"
    mv -fT -- "$CASE_ROOT/missing.json" "$state"
    : > "$CASE_OUTPUT"
    run_final_validation
    require "missing definition is a required validation failure" \
        grep -q '^FAILURE_COUNT=1$' "$CASE_OUTPUT" || return 1
    require "failed final validation returns nonzero" \
        test "$CASE_STATUS" -ne 0 || return 1
    require "failed final validation still invokes no Claude command" \
        test ! -s "$CASE_LOG" || return 1
    require_no_external_commands || return 1
}

test_final_validation_rejects_invalid_herdr_integrations() {
    local row scenario expected_failure failure_count
    local -a rows=(
        'claude-wrong-source|Claude HERDR hook link missing or invalid'
        'codex-wrong-source|Codex HERDR runtime hook link missing or invalid'
        'claude-wrong-id|Claude HERDR hook link missing or invalid'
        'codex-wrong-id|Codex HERDR hook-tree link missing or invalid'
        'claude-zero-version|Claude HERDR hook link missing or invalid'
        'codex-zero-version|Codex HERDR hook-tree link missing or invalid'
        'claude-duplicate-version|Claude HERDR hook link missing or invalid'
        'codex-duplicate-version|Codex HERDR hook-tree link missing or invalid'
        'claude-non-executable|Claude HERDR hook link missing or invalid'
        'codex-non-executable|Codex HERDR hook-tree link missing or invalid'
        'claude-malformed-session|Claude HERDR SessionStart hook missing or invalid'
        'codex-malformed-session|Codex HERDR SessionStart hook missing or invalid'
        'claude-duplicate-session|Claude HERDR SessionStart hook missing or invalid'
        'codex-duplicate-session|Codex HERDR SessionStart hook missing or invalid'
        'claude-shadow-session|Claude HERDR SessionStart hook missing or invalid'
        'codex-shadow-session|Codex HERDR SessionStart hook missing or invalid'
        'claude-multiple-documents|Claude HERDR SessionStart hook missing or invalid'
        'codex-multiple-documents|Codex HERDR SessionStart hook missing or invalid'
        'claude-duplicate-session-key|Claude HERDR SessionStart hook missing or invalid'
        'codex-duplicate-session-key|Codex HERDR SessionStart hook missing or invalid'
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r scenario expected_failure <<< "$row"
        new_case || return 1
        cp "$CASE_REPOSITORY/claude/mcp-servers.json" \
            "$CASE_HOME/.claude.json" || return 1
        mkdir -p "$CASE_HOME/.tmux/plugins/tmux" || return 1
        : > "$CASE_HOME/.tmux/plugins/tmux/catppuccin.tmux"
        prepare_herdr_validation_fixture || return 1
        mutate_herdr_validation_fixture "$scenario" || return 1

        run_final_validation
        require "$scenario is rejected by final validation" \
            test "$CASE_STATUS" -ne 0 || return 1
        require "$scenario reports the responsible Herdr validation" \
            grep -Fq -- "$expected_failure" "$CASE_OUTPUT" || return 1
        failure_count="$(sed -n 's/^FAILURE_COUNT=//p' "$CASE_OUTPUT")"
        require "$scenario records at least one validation failure" \
            test "${failure_count:-0}" -ge 1 || return 1
        require "$scenario validation invokes no Claude command" \
            test ! -s "$CASE_LOG" || return 1
        require_no_external_commands || return 1
    done
}

test_main_inventory_requires_both_yazi_commands() {
    local expected
    expected=$'install_cargo_tool eza eza\ninstall_cargo_tool fd-find fd\ninstall_cargo_tool diskus diskus\ninstall_cargo_tool csvlens csvlens\ninstall_cargo_tool yazi-fm yazi\ninstall_cargo_tool yazi-cli ya\ninstall_herdr'
    new_case || return 1
    run_main_inventory
    require_equal "inventory-only main execution succeeds" 0 "$CASE_STATUS" || return 1
    require_equal "main invokes the exact mandatory Cargo inventory" \
        "$expected" "$(< "$CASE_ROOT/install-inventory.log")" || return 1
    require_equal "yazi-fm maps to the required yazi executable" 1 \
        "$(grep -c '^install_cargo_tool yazi-fm yazi$' \
            "$CASE_ROOT/install-inventory.log")" || return 1
    require_equal "yazi-cli maps to the required ya executable" 1 \
        "$(grep -c '^install_cargo_tool yazi-cli ya$' \
            "$CASE_ROOT/install-inventory.log")" || return 1
    require_equal "main invokes the guarded Herdr installer once" 1 \
        "$(grep -c '^install_herdr$' \
            "$CASE_ROOT/install-inventory.log")" || return 1
    require_no_external_commands || return 1
}

expected_platform_package_log() {
    local output_file="$1" platform_id="$2" major="$3"
    local saved_log="${SUDO_COMMAND_LOG:-}"
    local -a debian_packages=(
        ca-certificates git curl jq fish python3 python3-venv tar unzip zip xz-utils bzip2 findutils
        bash-completion build-essential cmake ninja-build pkg-config libssl-dev libevent-dev
        libncurses-dev gettext bison
    )
    local -a rhel_packages=(
        ca-certificates git curl jq fish python3 tar unzip zip xz bzip2 findutils bash-completion
        gcc gcc-c++ make cmake ninja-build pkgconf-pkg-config openssl-devel libevent-devel
        ncurses-devel gettext bison
    )
    : > "$output_file"
    SUDO_COMMAND_LOG="$output_file"
    case "$platform_id" in
        ubuntu|debian)
            container_sudo_stub_main apt-get update
            container_sudo_stub_main env DEBIAN_FRONTEND=noninteractive \
                apt-get install -y "${debian_packages[@]}"
            ;;
        rhel|rocky|almalinux)
            container_sudo_stub_main dnf install -y dnf-plugins-core
            case "$platform_id:$major" in
                rhel:*)
                    container_sudo_stub_main subscription-manager repos \
                        --enable "codeready-builder-for-rhel-${major}-x86_64-rpms"
                    ;;
                rocky:8|almalinux:8)
                    container_sudo_stub_main dnf config-manager --set-enabled powertools
                    ;;
                *)
                    container_sudo_stub_main dnf config-manager --set-enabled crb
                    ;;
            esac
            container_sudo_stub_main dnf install -y \
                "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${major}.noarch.rpm"
            container_sudo_stub_main dnf install -y "${rhel_packages[@]}"
            ;;
        *) return 1 ;;
    esac
    SUDO_COMMAND_LOG="$saved_log"
}

test_supported_distro_package_flows() {
    local row platform_id version_id family major expected_log
    local -a rows=(
        'ubuntu|24.04|debian|'
        'debian|12|debian|'
        'rhel|8.10|rhel|8'
        'rhel|9.4|rhel|9'
        'almalinux|8.10|rhel|8'
        'almalinux|9.5|rhel|9'
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r platform_id version_id family major <<< "$row"
        prepare_platform_case "$platform_id" "$version_id" || return 1
        run_platform_packages
        require_equal "supported platform package fixture succeeds" 0 \
            "$CASE_STATUS" || return 1
        require "fixture identifies the exact supported platform" \
            grep -Fq -- "PLATFORM=$platform_id|$family|$major" \
            "$CASE_OUTPUT" || return 1
        require "successful package fixture records no failure" \
            grep -Fq -- 'FAILURE_COUNT=0' "$CASE_OUTPUT" || return 1
        expected_log="$CASE_ROOT/expected-package.log"
        expected_platform_package_log "$expected_log" "$platform_id" "$major" || return 1
        require_equal "package and repository command order is exact" \
            "$(file_sha256 "$expected_log")" \
            "$(file_sha256 "$CASE_ROOT/installer-command.log")" || return 1
        require "findutils is an explicit system prerequisite" \
            grep -Eq ' install -y .*findutils' \
            "$CASE_ROOT/installer-command.log" || return 1
        if [[ "$platform_id:$major" == rhel:8 ]]; then
            require "RHEL 8 enables the exact CodeReady Builder repository" \
                grep -Fq -- \
                    'sudo subscription-manager repos --enable codeready-builder-for-rhel-8-x86_64-rpms' \
                    "$CASE_ROOT/installer-command.log" || return 1
            require "RHEL 8 installs the exact EPEL 8 release package" \
                grep -Fq -- \
                    'sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm' \
                    "$CASE_ROOT/installer-command.log" || return 1
        fi
        require_no_external_commands || return 1
    done
}

test_preflight_rejects_before_mutation() {
    local description architecture glibc argument platform_id version_id output_pattern
    local alternate state before
    local row
    local -a rows=(
        'unexpected argument|ubuntu|24.04|x86_64|2.39|unexpected|usage: ./install.sh'
        'unsupported distro|fedora|42|x86_64|2.39||unsupported distribution: fedora'
        'unsupported architecture|ubuntu|24.04|aarch64|2.39||unsupported architecture: aarch64'
        'old glibc|ubuntu|24.04|x86_64|2.27||unsupported glibc: 2.27'
        'old RHEL|rhel|7.9|x86_64|2.39||unsupported rhel version: 7.9'
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r description platform_id version_id architecture glibc \
            argument output_pattern <<< "$row"
        prepare_platform_case "$platform_id" "$version_id" || return 1
        if [[ -n "$argument" ]]; then
            run_platform_entrypoint_rejection "$architecture" "$glibc" "" "$argument"
        else
            run_platform_entrypoint_rejection "$architecture" "$glibc" ""
        fi
        require "$description preflight fails" test "$CASE_STATUS" -eq 2 || return 1
        require "$description is diagnosed" \
            grep -Fq -- "$output_pattern" "$CASE_OUTPUT" || return 1
        require "$description runs no privilege or package command" \
            test ! -s "$CASE_ROOT/installer-command.log" || return 1
        require "$description does not mutate the fixture HOME" \
            test -z "$(find "$CASE_HOME" -mindepth 1 -print -quit)" || return 1
        require_no_external_commands || return 1
    done

    prepare_platform_case ubuntu 24.04 || return 1
    alternate="$CASE_ROOT/alternate-claude-config"
    state="$alternate/.claude.json"
    mkdir -p "$alternate" || return 1
    write_json "$state" \
        '{"private":"ENTRYPOINT_ALTERNATE_SECRET","mcpServers":{"alternate":{"type":"http","url":"https://alternate.invalid"}}}'
    chmod 0600 "$state" || return 1
    before="$(file_sha256 "$state")"

    run_platform_entrypoint_rejection x86_64 2.39 "$alternate"
    require "CLAUDE_CONFIG_DIR entrypoint preflight exits with status 2" \
        test "$CASE_STATUS" -eq 2 || return 1
    require "CLAUDE_CONFIG_DIR entrypoint rejection names the variable" \
        grep -Fq -- 'CLAUDE_CONFIG_DIR' "$CASE_OUTPUT" || return 1
    require "CLAUDE_CONFIG_DIR entrypoint rejection runs no platform fixture" \
        test ! -s "$CASE_ROOT/installer-fixture-call.log" || return 1
    require "CLAUDE_CONFIG_DIR entrypoint rejection runs no package or privilege command" \
        test ! -s "$CASE_ROOT/installer-command.log" || return 1
    require "CLAUDE_CONFIG_DIR entrypoint rejection invokes no Claude fixture" \
        test ! -s "$CASE_LOG" || return 1
    require "CLAUDE_CONFIG_DIR entrypoint rejection does not mutate HOME" \
        test -z "$(find "$CASE_HOME" -mindepth 1 -print -quit)" || return 1
    require_equal "CLAUDE_CONFIG_DIR entrypoint rejection preserves alternate state bytes" \
        "$before" "$(file_sha256 "$state")" || return 1
    require_file_excludes "CLAUDE_CONFIG_DIR entrypoint rejection does not leak alternate state" \
        "$CASE_OUTPUT" ENTRYPOINT_ALTERNATE_SECRET || return 1
    require_no_external_commands || return 1
}

test_package_failures_continue_and_remain_nonzero() {
    local row platform_id version_id failure_match expected_operations description
    local -a failure_rows=(
        'ubuntu|24.04|apt-get update|2|Debian-family package index'
        'debian|12|apt-get install -y ca-certificates|2|Debian-family final packages'
        'rocky|8.10|dnf config-manager --set-enabled powertools|4|Rocky 8 PowerTools'
        'rocky|9.5|dnf config-manager --set-enabled crb|4|Rocky 9 CRB'
        'rhel|8.10|subscription-manager repos --enable codeready-builder-for-rhel-8-x86_64-rpms|4|RHEL CodeReady Builder'
        'almalinux|9.5|epel-release-latest-9.noarch.rpm|4|RHEL-family EPEL'
        'almalinux|8.10|dnf install -y ca-certificates|4|RHEL-family final packages'
        'rhel|9.4|dnf install -y dnf-plugins-core|4|RHEL-family DNF plugins'
    )
    for row in "${failure_rows[@]}"; do
        IFS='|' read -r platform_id version_id failure_match \
            expected_operations description <<< "$row"
        prepare_platform_case "$platform_id" "$version_id" || return 1
        : > "$CASE_ROOT/continuation.log"
        run_package_failure_main "$failure_match"
        require "$description failure remains nonzero" \
            test "$CASE_STATUS" -ne 0 || return 1
        require_equal "$description still runs later independent phases" \
            $'skills-phase\nvalidation-phase' \
            "$(< "$CASE_ROOT/continuation.log")" || return 1
        require "$description retains exactly one injected failure" \
            grep -Fq -- 'FAILURE_COUNT=1' "$CASE_OUTPUT" || return 1
        require_equal "$description does not skip later package operations" \
            "$expected_operations" \
            "$(wc -l < "$CASE_ROOT/installer-command.log")" || return 1
        require_no_external_commands || return 1
    done
}

test_link_dotfiles_backup_and_claude_state_contract() {
    local backup state state_hash correct_target regular_target directory_target
    local mismatched_target dangling_target herdr_config_target herdr_runtime_sentinel
    local herdr_runtime_hash backup_root backup_count
    new_case || return 1
    prepare_link_case_sources || return 1
    state="$CASE_HOME/.claude.json"
    write_json "$state" \
        '{"private":"CLAUDE_STATE_MUST_NOT_MOVE","mcpServers":{"other":{"type":"http","url":"https://other.invalid"}}}'
    chmod 0640 "$state" || return 1
    state_hash="$(file_sha256 "$state")"

    correct_target="$CASE_HOME/.bashrc"
    regular_target="$CASE_HOME/.profile"
    directory_target="$CASE_HOME/.gitconfig"
    mismatched_target="$CASE_HOME/.config/git/ignore"
    dangling_target="$CASE_HOME/.config/starship.toml"
    herdr_config_target="$CASE_HOME/.config/herdr/config.toml"
    herdr_runtime_sentinel="$CASE_HOME/.config/herdr/session.json"
    mkdir -p "$directory_target" "${mismatched_target%/*}" \
        "${dangling_target%/*}" "${herdr_config_target%/*}" || return 1
    printf 'regular conflict\n' > "$regular_target" || return 1
    printf 'directory conflict\n' > "$directory_target/marker" || return 1
    printf 'legacy Herdr configuration\n' > "$herdr_config_target" || return 1
    printf '{"mutable":"Herdr runtime state"}\n' > "$herdr_runtime_sentinel" || return 1
    herdr_runtime_hash="$(file_sha256 "$herdr_runtime_sentinel")"
    printf 'mismatched source\n' > "$CASE_ROOT/mismatched-source" || return 1
    ln -s "$CASE_REPOSITORY/shell/.bashrc" "$correct_target" || return 1
    ln -s "$CASE_ROOT/mismatched-source" "$mismatched_target" || return 1
    ln -s "$CASE_ROOT/does-not-exist" "$dangling_target" || return 1

    run_link_dotfiles
    require_equal "real link_dotfiles succeeds for mixed target states" 0 \
        "$CASE_STATUS" || return 1
    require "already-correct link remains exact" \
        test "$(readlink "$correct_target")" == \
            "$CASE_REPOSITORY/shell/.bashrc" || return 1
    require "regular conflict is replaced by the intended link" \
        test "$(readlink "$regular_target")" == \
            "$CASE_REPOSITORY/shell/.profile" || return 1
    require "directory conflict is replaced by the intended link" \
        test "$(readlink "$directory_target")" == \
            "$CASE_REPOSITORY/git/.gitconfig" || return 1
    require "mismatched link is replaced by the intended link" \
        test "$(readlink "$mismatched_target")" == \
            "$CASE_REPOSITORY/git/gitignore" || return 1
    require "dangling link is replaced by the intended link" \
        test "$(readlink "$dangling_target")" == \
            "$CASE_REPOSITORY/config/starship.toml" || return 1
    require "Herdr configuration conflict is replaced by the intended link" \
        test "$(readlink "$herdr_config_target")" == \
            "$CASE_REPOSITORY/config/herdr/config.toml" || return 1
    require "Herdr runtime sibling remains a regular file" \
        test -f "$herdr_runtime_sentinel" || return 1
    require "Herdr runtime sibling is never linked" \
        test ! -L "$herdr_runtime_sentinel" || return 1
    require_equal "Herdr runtime sibling content is unchanged" \
        "$herdr_runtime_hash" "$(file_sha256 "$herdr_runtime_sentinel")" || return 1
    require "Claude Herdr hook is linked from the tracked source" \
        test "$(readlink "$CASE_HOME/.claude/hooks/herdr-agent-state.sh")" == \
            "$CASE_REPOSITORY/claude/hooks/herdr-agent-state.sh" || return 1

    backup_count="$(find "$CASE_HOME" -mindepth 1 -maxdepth 1 -type d \
        -name '.dotfiles-backup-*' | wc -l)"
    require_equal "all conflicts share one unique backup tree" 1 \
        "$backup_count" || return 1
    backup="$(backup_directory)"
    require_equal "link backup tree is private" 700 \
        "$(stat -c '%a' "$backup")" || return 1
    backup_root="$backup/${CASE_HOME#/}"
    require_equal "regular conflict content is preserved" 'regular conflict' \
        "$(tr -d '\n' < "$backup_root/.profile")" || return 1
    require "directory conflict is preserved recursively" \
        test -f "$backup_root/.gitconfig/marker" || return 1
    require_equal "mismatched link target is preserved" \
        "$CASE_ROOT/mismatched-source" \
        "$(readlink "$backup_root/.config/git/ignore")" || return 1
    require_equal "dangling link target is preserved" \
        "$CASE_ROOT/does-not-exist" \
        "$(readlink "$backup_root/.config/starship.toml")" || return 1
    require_equal "Herdr configuration conflict content is preserved" \
        'legacy Herdr configuration' \
        "$(tr -d '\n' < "$backup_root/.config/herdr/config.toml")" || return 1

    require "claude.json remains a regular file" \
        test -f "$state" || return 1
    require "claude.json is never linked" test ! -L "$state" || return 1
    require_equal "claude.json content is unchanged" "$state_hash" \
        "$(file_sha256 "$state")" || return 1
    require_equal "claude.json mode is unchanged" 640 \
        "$(stat -c '%a' "$state")" || return 1
    require_file_excludes "private Claude state is absent from link output" \
        "$CASE_OUTPUT" CLAUDE_STATE_MUST_NOT_MOVE || return 1

    run_link_dotfiles
    require_equal "clean link rerun succeeds" 0 "$CASE_STATUS" || return 1
    require_equal "clean link rerun creates no new backup" 1 \
        "$(find "$CASE_HOME" -mindepth 1 -maxdepth 1 -type d \
            -name '.dotfiles-backup-*' | wc -l)" || return 1
    require "clean rerun keeps the exact Herdr configuration link" \
        test "$(readlink "$herdr_config_target")" == \
            "$CASE_REPOSITORY/config/herdr/config.toml" || return 1
    require_equal "clean rerun still leaves Herdr runtime state unchanged" \
        "$herdr_runtime_hash" "$(file_sha256 "$herdr_runtime_sentinel")" || return 1
    require_equal "clean rerun still leaves claude.json unchanged" "$state_hash" \
        "$(file_sha256 "$state")" || return 1
    require_no_external_commands || return 1
}

test_download_selection_checksums_and_archive_safety() {
    local metadata bad_metadata malformed_metadata no_stable_metadata ambiguous_go_metadata
    local metadata_case archive archive_hash release bad_release ambiguous_release archive_mode
    local manifest_release valid_manifest bad_manifest missing_manifest
    new_case || return 1
    metadata="$CASE_ROOT/go.json"
    bad_metadata="$CASE_ROOT/go-bad.json"
    archive="$CASE_ROOT/go1.24.5.linux-amd64.tar.gz"
    printf 'deterministic Go archive fixture\n' > "$archive" || return 1
    archive_hash="$(file_sha256 "$archive")"
    printf '%s\n' \
        '[' \
        '  {"version":"go1.25rc1","stable":false,"files":[]},' \
        "  {\"version\":\"go1.24.5\",\"stable\":true,\"files\":[{\"filename\":\"go1.24.5.linux-amd64.tar.gz\",\"os\":\"linux\",\"arch\":\"amd64\",\"sha256\":\"$archive_hash\"}]}," \
        '  {"version":"go1.23.9","stable":true,"files":[{"filename":"go1.23.9.linux-amd64.tar.gz","os":"linux","arch":"amd64","sha256":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"}]}' \
        ']' > "$metadata" || return 1
    sed "s/$archive_hash/0000000000000000000000000000000000000000000000000000000000000000/" \
        "$metadata" > "$bad_metadata" || return 1
    malformed_metadata="$CASE_ROOT/go-malformed.json"
    no_stable_metadata="$CASE_ROOT/go-no-stable.json"
    ambiguous_go_metadata="$CASE_ROOT/go-ambiguous.json"
    printf '{\n' > "$malformed_metadata" || return 1
    printf '%s\n' \
        '[{"version":"go1.25rc1","stable":false,"files":[{"filename":"go1.25rc1.linux-amd64.tar.gz","os":"linux","arch":"amd64","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}]}]' \
        > "$no_stable_metadata" || return 1
    printf '%s\n' \
        "[{\"version\":\"go1.24.5\",\"stable\":true,\"files\":[{\"filename\":\"go1.24.5.linux-amd64.tar.gz\",\"os\":\"linux\",\"arch\":\"amd64\",\"sha256\":\"$archive_hash\"},{\"filename\":\"go1.24.5-alt.linux-amd64.tar.gz\",\"os\":\"linux\",\"arch\":\"amd64\",\"sha256\":\"$archive_hash\"}]}]" \
        > "$ambiguous_go_metadata" || return 1

    run_go_install_fixture "$metadata" "$archive"
    require_equal "latest stable Go fixture installs successfully" 0 \
        "$CASE_STATUS" || return 1
    require_equal "Go metadata selects the first stable linux-amd64 archive" \
        $'https://go.dev/dl/?mode=json\nhttps://go.dev/dl/go1.24.5.linux-amd64.tar.gz' \
        "$(< "$CASE_ROOT/download.log")" || return 1
    require_equal "verified Go archive is extracted once" 1 \
        "$(wc -l < "$CASE_ROOT/extract.log")" || return 1
    require "validated Go tree is installed under the user prefix" \
        test -x "$CASE_HOME/.local/go/bin/go" || return 1

    find "$CASE_HOME/.local" -depth -delete 2>/dev/null || true
    run_go_install_fixture "$bad_metadata" "$archive"
    require "Go checksum mismatch is fatal" test "$CASE_STATUS" -ne 0 || return 1
    require "Go checksum is checked before extraction" \
        test ! -s "$CASE_ROOT/extract.log" || return 1
    require "bad Go archive never reaches the install prefix" \
        test ! -e "$CASE_HOME/.local/go" || return 1

    for metadata_case in \
        "$malformed_metadata" "$no_stable_metadata" "$ambiguous_go_metadata"; do
        run_go_install_fixture "$metadata_case" "$archive"
        require "invalid Go metadata fails closed: ${metadata_case##*/}" \
            test "$CASE_STATUS" -ne 0 || return 1
        require_equal "invalid Go metadata downloads metadata only" \
            'https://go.dev/dl/?mode=json' \
            "$(< "$CASE_ROOT/download.log")" || return 1
        require "invalid Go metadata is rejected before extraction" \
            test ! -s "$CASE_ROOT/extract.log" || return 1
        require "invalid Go metadata leaves the install prefix untouched" \
            test ! -e "$CASE_HOME/.local/go" || return 1
    done

    release="$CASE_ROOT/release.json"
    bad_release="$CASE_ROOT/release-bad.json"
    ambiguous_release="$CASE_ROOT/release-ambiguous.json"
    printf '%s\n' \
        "{\"tag_name\":\"v1.2.3\",\"assets\":[{\"name\":\"tool-1.2.3-linux-amd64.tar.gz\",\"browser_download_url\":\"https://downloads.invalid/tool.tar.gz\",\"digest\":\"sha256:$archive_hash\"}]}" \
        > "$release" || return 1
    sed "s/$archive_hash/ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/" \
        "$release" > "$bad_release" || return 1
    printf '%s\n' \
        '{"tag_name":"v1.2.3","assets":[' \
        ' {"name":"tool-1.2.3-linux-amd64.tar.gz","browser_download_url":"https://downloads.invalid/one.tar.gz","digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000"},' \
        ' {"name":"tool-1.2.4-linux-amd64.tar.gz","browser_download_url":"https://downloads.invalid/two.tar.gz","digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}' \
        ']}' > "$ambiguous_release" || return 1

    run_github_download_fixture "$release" "$archive"
    require_equal "unique GitHub asset with valid digest succeeds" 0 \
        "$CASE_STATUS" || return 1
    require "selected GitHub release tag is retained" \
        grep -Fq -- 'RELEASE_TAG=v1.2.3' "$CASE_OUTPUT" || return 1
    require_equal "selected GitHub asset bytes are unchanged" "$archive_hash" \
        "$(file_sha256 "$CASE_ROOT/github-result.archive")" || return 1

    run_github_download_fixture "$ambiguous_release" "$archive"
    require "ambiguous GitHub asset selection fails closed" \
        test "$CASE_STATUS" -ne 0 || return 1
    require_equal "ambiguous selection downloads metadata only" 1 \
        "$(wc -l < "$CASE_ROOT/github-download.log")" || return 1

    run_github_download_fixture "$bad_release" "$archive"
    require "GitHub digest mismatch is fatal" test "$CASE_STATUS" -ne 0 || return 1
    require "failed GitHub checksum leaves no accepted result" \
        test ! -e "$CASE_ROOT/github-result.archive" || return 1

    manifest_release="$CASE_ROOT/release-manifest.json"
    valid_manifest="$CASE_ROOT/checksums-valid.txt"
    bad_manifest="$CASE_ROOT/checksums-bad.txt"
    missing_manifest="$CASE_ROOT/checksums-missing.txt"
    printf '%s\n' \
        '{"tag_name":"v1.2.3","assets":[' \
        ' {"name":"tool-1.2.3-linux-amd64.tar.gz","browser_download_url":"https://downloads.invalid/tool.tar.gz"},' \
        ' {"name":"SHA256SUMS","browser_download_url":"https://downloads.invalid/checksums.txt"}' \
        ']}' > "$manifest_release" || return 1
    printf '%s  %s\n' "$archive_hash" \
        tool-1.2.3-linux-amd64.tar.gz > "$valid_manifest" || return 1
    printf '%064d  %s\n' 0 \
        tool-1.2.3-linux-amd64.tar.gz > "$bad_manifest" || return 1
    printf '%s  %s\n' "$archive_hash" unrelated.tar.gz \
        > "$missing_manifest" || return 1

    run_github_download_fixture "$manifest_release" "$archive" "$valid_manifest"
    require_equal "published checksum manifest validates the selected asset" 0 \
        "$CASE_STATUS" || return 1
    require_equal "manifest fallback downloads metadata, asset, and checksum once" 3 \
        "$(wc -l < "$CASE_ROOT/github-download.log")" || return 1
    require_equal "manifest-verified asset bytes are accepted unchanged" "$archive_hash" \
        "$(file_sha256 "$CASE_ROOT/github-result.archive")" || return 1

    run_github_download_fixture "$manifest_release" "$archive" "$bad_manifest"
    require "published checksum mismatch fails closed" \
        test "$CASE_STATUS" -ne 0 || return 1
    require "checksum mismatch leaves no accepted result" \
        test ! -e "$CASE_ROOT/github-result.archive" || return 1

    run_github_download_fixture "$manifest_release" "$archive" "$missing_manifest"
    require "published checksum manifest missing the selected asset fails closed" \
        test "$CASE_STATUS" -ne 0 || return 1
    require "missing checksum entry leaves no accepted result" \
        test ! -e "$CASE_ROOT/github-result.archive" || return 1

    for archive_mode in traversal symlink; do
        run_unsafe_archive_fixture "$archive_mode"
        require "$archive_mode archive member is rejected" \
            test "$CASE_STATUS" -ne 0 || return 1
        require "$archive_mode archive is rejected before extraction" \
            test ! -e "$CASE_ROOT/extraction-marker" || return 1
        require "$archive_mode archive never reaches tar extraction flags" \
            test -z "$(grep '^--no-same-owner ' "$CASE_ROOT/tar.log" || true)" || return 1
    done
    require_no_external_commands || return 1
}

test_release_binary_member_cardinality() {
    local member_mode destination before_hash
    new_case || return 1
    destination="$CASE_HOME/.local/bin/fixture-tool"
    mkdir -p "${destination%/*}" || return 1
    run_release_binary_member_fixture one
    require_equal "one executable member installs successfully" 0 \
        "$CASE_STATUS" || return 1
    require "installed release binary is executable at the user destination" \
        test -x "$destination" || return 1
    require_equal "installed release binary reports its version" \
        'fixture-tool 1.0.0' "$("$destination" --version)" || return 1
    require_equal "idempotent rerun performs no second download or extraction" 1 \
        "$(wc -l < "$CASE_ROOT/release-member.log")" || return 1
    require "successful release install creates no conflict backup" \
        test -z "$(backup_directory)" || return 1
    require_no_external_commands || return 1

    for member_mode in zero multiple; do
        new_case || return 1
        destination="$CASE_HOME/.local/bin/fixture-tool"
        mkdir -p "${destination%/*}" || return 1
        printf 'destination must remain unchanged\n' > "$destination" || return 1
        chmod 0755 "$destination" || return 1
        before_hash="$(file_sha256 "$destination")"
        run_release_binary_member_fixture "$member_mode"
        require "$member_mode required executable cardinality is rejected" \
            test "$CASE_STATUS" -ne 0 || return 1
        require_equal "$member_mode cardinality leaves destination bytes unchanged" \
            "$before_hash" "$(file_sha256 "$destination")" || return 1
        require_equal "$member_mode cardinality leaves destination mode unchanged" \
            755 "$(stat -c '%a' "$destination")" || return 1
        require "$member_mode cardinality is checked after one isolated extraction" \
            test "$(wc -l < "$CASE_ROOT/release-member.log")" -eq 1 || return 1
        require "$member_mode cardinality creates no backup or replacement" \
            test -z "$(backup_directory)" || return 1
        require_no_external_commands || return 1
    done
}

test_herdr_install_guard_and_idempotence() {
    new_case || return 1
    run_herdr_install_fixture working unused
    require_equal "working Herdr is retained" 0 "$CASE_STATUS" || return 1
    require "working Herdr skips the installer request" \
        test ! -s "$CASE_ROOT/herdr-curl.log" || return 1
    require "working Herdr never starts an installer shell" \
        test ! -s "$CASE_ROOT/herdr-installer-sh.log" || return 1
    require_equal "working Herdr uses one bounded version probe" \
        "timeout 10 $CASE_HOME/.local/bin/herdr --version" \
        "$(< "$CASE_ROOT/herdr-timeout.log")" || return 1
    require_equal "working Herdr receives the primary version flag" \
        'initial --version' "$(< "$CASE_ROOT/herdr-version.log")" || return 1
    require_no_external_commands || return 1

    new_case || return 1
    run_herdr_install_fixture missing success
    require_equal "missing Herdr installs successfully" 0 "$CASE_STATUS" || return 1
    require_equal "missing Herdr invokes the exact official curl flow once" \
        'curl -fsSL https://herdr.dev/install.sh' \
        "$(< "$CASE_ROOT/herdr-curl.log")" || return 1
    require "the official installer makes Herdr discoverable and executable" \
        test -x "$CASE_HOME/.local/bin/herdr" || return 1
    require_equal "newly installed Herdr passes its bounded post-install probe" \
        "timeout 10 $CASE_HOME/.local/bin/herdr --version" \
        "$(< "$CASE_ROOT/herdr-timeout.log")" || return 1
    require_herdr_installer_pipeline 1 || return 1

    run_herdr_install_fixture preserve unused
    require_equal "installed Herdr remains usable on a repeated run" \
        0 "$CASE_STATUS" || return 1
    require "the repeated run performs no installer request" \
        test ! -s "$CASE_ROOT/herdr-curl.log" || return 1
    require "the repeated run never starts an installer shell" \
        test ! -s "$CASE_ROOT/herdr-installer-sh.log" || return 1
    require_equal "the repeated run performs one bounded retention probe" \
        "timeout 10 $CASE_HOME/.local/bin/herdr --version" \
        "$(< "$CASE_ROOT/herdr-timeout.log")" || return 1
    require_no_external_commands || return 1

    new_case || return 1
    run_herdr_install_fixture broken success
    require_equal "broken Herdr is replaced successfully" 0 "$CASE_STATUS" || return 1
    require_equal "broken Herdr invokes the exact official curl flow once" \
        'curl -fsSL https://herdr.dev/install.sh' \
        "$(< "$CASE_ROOT/herdr-curl.log")" || return 1
    require_equal "broken Herdr exhausts both bounded probes before replacement" \
        "timeout 10 $CASE_HOME/.local/bin/herdr --version
timeout 10 $CASE_HOME/.local/bin/herdr -V
timeout 10 $CASE_HOME/.local/bin/herdr --version" \
        "$(< "$CASE_ROOT/herdr-timeout.log")" || return 1
    require "broken Herdr replacement is diagnosed" \
        grep -Fq -- 'herdr on PATH cannot complete a version probe' \
        "$CASE_OUTPUT" || return 1
    require_herdr_installer_pipeline 1 || return 1
    require_no_external_commands || return 1
}

test_herdr_install_failures_are_observable() {
    local installer_mode
    local -a installer_modes=(
        curl-failure
        installer-shell-failure
        missing-post-install
        broken-post-install
    )
    for installer_mode in "${installer_modes[@]}"; do
        new_case || return 1
        run_herdr_install_fixture missing "$installer_mode"
        require "$installer_mode makes the Herdr install step fail" \
            test "$CASE_STATUS" -ne 0 || return 1
        require_equal "$installer_mode uses the exact official curl flow once" \
            'curl -fsSL https://herdr.dev/install.sh' \
            "$(< "$CASE_ROOT/herdr-curl.log")" || return 1
        if [[ "$installer_mode" == broken-post-install ]]; then
            require_herdr_installer_pipeline 1 || return 1
        else
            require_herdr_installer_pipeline 0 || return 1
        fi
        case "$installer_mode" in
            curl-failure|installer-shell-failure|missing-post-install)
                require "$installer_mode leaves no discoverable Herdr command" \
                    test ! -e "$CASE_HOME/.local/bin/herdr" || return 1
                ;;
            broken-post-install)
                require "$installer_mode installs a command that fails both probes" \
                    grep -Fq -- 'installed -V' \
                    "$CASE_ROOT/herdr-version.log" || return 1
                ;;
        esac
        require_no_external_commands || return 1
    done
}

test_secret_roundtrip_migration_permissions_and_redaction() {
    local secret_value gh_secret claude_secret gh_hash claude_hash backup backup_root
    local preset_backup migrated_key
    secret_value="REDACTION_KEY_SENTINEL with spaces ' quote \$ dollar"
    gh_secret='GH_SECRET_REDACTION_SENTINEL'
    claude_secret='CLAUDE_SECRET_REDACTION_SENTINEL'
    new_case || return 1
    mkdir -p "$CASE_HOME/.config/gh" "$CASE_HOME/.claude" || return 1
    printf 'oauth_token: %s\n' "$gh_secret" > "$CASE_HOME/.config/gh/hosts.yml" || return 1
    printf '{"oauthToken":"%s"}\n' "$claude_secret" \
        > "$CASE_HOME/.claude/.credentials.json" || return 1
    chmod 0644 "$CASE_HOME/.config/gh/hosts.yml" \
        "$CASE_HOME/.claude/.credentials.json" || return 1
    gh_hash="$(file_sha256 "$CASE_HOME/.config/gh/hosts.yml")"
    claude_hash="$(file_sha256 "$CASE_HOME/.claude/.credentials.json")"

    run_seed_secrets_fixture 1 "$secret_value"
    require_equal "secret seeding succeeds" 0 "$CASE_STATUS" || return 1
    require_equal "secret store directory is private" 700 \
        "$(stat -c '%a' "$CASE_REPOSITORY/secrets")" || return 1
    require_equal "environment secret file is private" 600 \
        "$(stat -c '%a' "$CASE_REPOSITORY/secrets.env")" || return 1
    require_equal "GitHub credential store is private" 600 \
        "$(stat -c '%a' "$CASE_REPOSITORY/secrets/gh-hosts.yml")" || return 1
    require_equal "Claude credential store is private" 600 \
        "$(stat -c '%a' "$CASE_REPOSITORY/secrets/claude-credentials.json")" || return 1
    require "environment secret is linked into the user config" \
        test "$(readlink "$CASE_HOME/.config/secrets.env")" == \
            "$CASE_REPOSITORY/secrets.env" || return 1
    require "GitHub credentials are linked to the private store" \
        test "$(readlink "$CASE_HOME/.config/gh/hosts.yml")" == \
            "$CASE_REPOSITORY/secrets/gh-hosts.yml" || return 1
    require "Claude credentials are linked to the private store" \
        test "$(readlink "$CASE_HOME/.claude/.credentials.json")" == \
            "$CASE_REPOSITORY/secrets/claude-credentials.json" || return 1
    require_equal "GitHub credential bytes survive migration" "$gh_hash" \
        "$(file_sha256 "$CASE_REPOSITORY/secrets/gh-hosts.yml")" || return 1
    require_equal "Claude credential bytes survive migration" "$claude_hash" \
        "$(file_sha256 "$CASE_REPOSITORY/secrets/claude-credentials.json")" || return 1
    env -i PATH=/usr/bin:/bin bash -c '
        source "$1"
        [[ "$LLM_GATEWAY_KEY" == "$2" ]]
    ' fixture "$CASE_REPOSITORY/secrets.env" "$secret_value" || {
        printf 'assertion failed: shell-escaped secret does not round trip\n' >&2
        return 1
    }
    backup="$(backup_directory)"
    backup_root="$backup/${CASE_HOME#/}"
    require_equal "live GitHub source is retained in the private backup" "$gh_hash" \
        "$(file_sha256 "$backup_root/.config/gh/hosts.yml")" || return 1
    require_equal "live Claude source is retained in the private backup" "$claude_hash" \
        "$(file_sha256 "$backup_root/.claude/.credentials.json")" || return 1
    require_file_excludes "gateway secret is redacted from output" \
        "$CASE_OUTPUT" REDACTION_KEY_SENTINEL || return 1
    require_file_excludes "GitHub secret is redacted from output" \
        "$CASE_OUTPUT" GH_SECRET_REDACTION_SENTINEL || return 1
    require_file_excludes "Claude secret is redacted from output" \
        "$CASE_OUTPUT" CLAUDE_SECRET_REDACTION_SENTINEL || return 1

    run_seed_secrets_fixture 1 "$secret_value"
    require_equal "secret rerun is idempotent" 0 "$CASE_STATUS" || return 1
    require_equal "secret rerun creates no second backup" 1 \
        "$(find "$CASE_HOME" -mindepth 1 -maxdepth 1 -type d \
            -name '.dotfiles-backup-*' | wc -l)" || return 1

    new_case || return 1
    preset_backup="$CASE_HOME/.dotfiles-backup-manual"
    mkdir -p "$preset_backup/${CASE_HOME#/}" || return 1
    chmod 0700 "$preset_backup" || return 1
    migrated_key='BACKUP_MIGRATION_SENTINEL value'
    printf 'export LLM_GATEWAY_KEY="%s"\n' "$migrated_key" \
        > "$preset_backup/${CASE_HOME#/}/.bashrc" || return 1
    run_seed_secrets_fixture 0 '' "$preset_backup"
    require_equal "backup-based secret migration succeeds" 0 "$CASE_STATUS" || return 1
    env -i PATH=/usr/bin:/bin bash -c '
        source "$1"
        [[ "$LLM_GATEWAY_KEY" == "$2" ]]
    ' fixture "$CASE_REPOSITORY/secrets.env" "$migrated_key" || {
        printf 'assertion failed: backup-migrated secret does not round trip\n' >&2
        return 1
    }
    require_file_excludes "backup-migrated secret is redacted from output" \
        "$CASE_OUTPUT" BACKUP_MIGRATION_SENTINEL || return 1
    require_file_excludes "warnings never enter secrets.env" \
        "$CASE_REPOSITORY/secrets.env" WARN: || return 1

    new_case || return 1
    run_seed_secrets_fixture 0
    require_equal "truly absent gateway key seeding still succeeds" 0 \
        "$CASE_STATUS" || return 1
    require "truly absent gateway key emits the required warning" \
        grep -Fq -- \
            "WARN: LLM_GATEWAY_KEY is unset; edit $CASE_REPOSITORY/secrets.env" \
            "$CASE_OUTPUT" || return 1
    require_file_excludes "missing-key warning never enters secrets.env" \
        "$CASE_REPOSITORY/secrets.env" WARN: || return 1
    env -i PATH=/usr/bin:/bin bash -c '
        source "$1"
        [[ ${LLM_GATEWAY_KEY+x} == x && -z "$LLM_GATEWAY_KEY" ]]
    ' fixture "$CASE_REPOSITORY/secrets.env" || {
        printf 'assertion failed: absent gateway key is not represented safely\n' >&2
        return 1
    }
    require_equal "missing-key secrets.env remains private" 600 \
        "$(stat -c '%a' "$CASE_REPOSITORY/secrets.env")" || return 1
    require_equal "missing-key secret directory remains private" 700 \
        "$(stat -c '%a' "$CASE_REPOSITORY/secrets")" || return 1
    require "absent key and backup create no backup directory" \
        test -z "$(backup_directory)" || return 1
    require_no_external_commands || return 1
}

test_compute_skills_checkout_states() {
    local mode checkout sentinel_hash
    local -a preserving_modes=(clean dirty non-main offline)
    for mode in "${preserving_modes[@]}"; do
        new_case || return 1
        prepare_compute_checkout_fixture || return 1
        checkout="$CASE_HOME/compute-ai-skills"
        mkdir -p "$CASE_HOME/.codex/skills" || return 1
        printf 'personal entry\n' > "$CASE_HOME/.codex/skills/personal" || return 1
        run_compute_skills_fixture "$mode"
        require "$mode matching checkout remains usable" \
            test "$CASE_STATUS" -eq 0 || return 1
        require "$mode links Claude skills leaf-by-leaf" \
            test "$(readlink "$CASE_HOME/.claude/skills/shared-claude-skill")" == \
                "$checkout/.claude/skills/shared-claude-skill" || return 1
        require "$mode links Codex hooks leaf-by-leaf" \
            test "$(readlink "$CASE_HOME/.codex/hooks/shared-codex-hook")" == \
                "$checkout/.codex/hooks/shared-codex-hook" || return 1
        require "$mode links the Codex Herdr hook in the hooks tree" \
            test "$(readlink "$CASE_HOME/.codex/hooks/herdr-agent-state.sh")" == \
                "$checkout/.codex/hooks/herdr-agent-state.sh" || return 1
        require "$mode links the Codex Herdr runtime root alias" \
            test "$(readlink "$CASE_HOME/.codex/herdr-agent-state.sh")" == \
                "$checkout/.codex/hooks/herdr-agent-state.sh" || return 1
        require "$mode links Codex hooks.json" \
            test "$(readlink "$CASE_HOME/.codex/hooks.json")" == \
                "$checkout/.codex/hooks.json" || return 1
        require "$mode preserves unrelated personal entries" \
            grep -Fq -- 'personal entry' "$CASE_HOME/.codex/skills/personal" || return 1
        require "$mode creates no global Cursor activation" \
            test ! -e "$CASE_HOME/.cursor" || return 1
        case "$mode" in
            clean)
                require_equal "clean main checkout fast-forwards once" 1 \
                    "$(grep -c '^git -C .* pull --ff-only$' "$CASE_ROOT/git.log")" || return 1
                ;;
            dirty|non-main)
                require "$mode checkout is preserved without pull" \
                    test -z "$(grep ' pull ' "$CASE_ROOT/git.log" || true)" || return 1
                require "$mode preservation warning is reported" \
                    grep -Fq -- 'is dirty or not on main; preserving it without update' \
                    "$CASE_OUTPUT" || return 1
                ;;
            offline)
                require_equal "offline clean checkout attempts one fast-forward" 1 \
                    "$(grep -c '^git -C .* pull --ff-only$' "$CASE_ROOT/git.log")" || return 1
                require "offline pull warns and retains the checkout" \
                    grep -Fq -- 'could not fast-forward' "$CASE_OUTPUT" || return 1
                ;;
        esac
        require_no_external_commands || return 1
    done

    new_case || return 1
    prepare_compute_checkout_fixture || return 1
    checkout="$CASE_HOME/compute-ai-skills"
    printf 'wrong origin sentinel\n' > "$checkout/sentinel" || return 1
    sentinel_hash="$(file_sha256 "$checkout/sentinel")"
    run_compute_skills_fixture wrong-origin
    require "wrong-origin checkout is rejected" test "$CASE_STATUS" -ne 0 || return 1
    require_equal "wrong-origin checkout remains untouched" "$sentinel_hash" \
        "$(file_sha256 "$checkout/sentinel")" || return 1
    require "wrong-origin checkout creates no runtime links" \
        test ! -e "$CASE_HOME/.codex/skills" || return 1

    new_case || return 1
    checkout="$CASE_HOME/compute-ai-skills"
    mkdir -p "$checkout" || return 1
    printf 'non-Git sentinel\n' > "$checkout/sentinel" || return 1
    sentinel_hash="$(file_sha256 "$checkout/sentinel")"
    run_compute_skills_fixture non-git
    require "non-Git skills path is rejected" test "$CASE_STATUS" -ne 0 || return 1
    require_equal "non-Git skills path remains untouched" "$sentinel_hash" \
        "$(file_sha256 "$checkout/sentinel")" || return 1
    require "non-Git path invokes no Git command" \
        test ! -s "$CASE_ROOT/git.log" || return 1

    new_case || return 1
    checkout="$CASE_HOME/compute-ai-skills"
    run_compute_skills_fixture missing-success
    require "absent skills checkout is cloned successfully" \
        test "$CASE_STATUS" -eq 0 || return 1
    require "successful clone creates a valid Git checkout" \
        test -d "$checkout/.git" || return 1
    require_equal "successful missing checkout performs one clone" 1 \
        "$(grep -c '^git clone --branch main ' "$CASE_ROOT/git.log")" || return 1
    require_equal "new clean main checkout is fast-forwarded once" 1 \
        "$(grep -c '^git -C .* pull --ff-only$' "$CASE_ROOT/git.log")" || return 1
    require "successful clone links cloned Claude skills" \
        test "$(readlink "$CASE_HOME/.claude/skills/cloned-claude-skill")" == \
            "$checkout/.claude/skills/cloned-claude-skill" || return 1
    require "successful clone links cloned Codex hooks" \
        test "$(readlink "$CASE_HOME/.codex/hooks/cloned-codex-hook")" == \
            "$checkout/.codex/hooks/cloned-codex-hook" || return 1
    require "successful clone links the Codex Herdr hook in the hooks tree" \
        test "$(readlink "$CASE_HOME/.codex/hooks/herdr-agent-state.sh")" == \
            "$checkout/.codex/hooks/herdr-agent-state.sh" || return 1
    require "successful clone links the Codex Herdr runtime root alias" \
        test "$(readlink "$CASE_HOME/.codex/herdr-agent-state.sh")" == \
            "$checkout/.codex/hooks/herdr-agent-state.sh" || return 1
    require "successful clone links cloned hooks.json" \
        test "$(readlink "$CASE_HOME/.codex/hooks.json")" == \
            "$checkout/.codex/hooks.json" || return 1
    require "successful clone creates no Cursor activation" \
        test ! -e "$CASE_HOME/.cursor" || return 1
    require_no_external_commands || return 1

    new_case || return 1
    prepare_compute_checkout_fixture || return 1
    checkout="$CASE_HOME/compute-ai-skills"
    rm -f -- "$checkout/.codex/hooks/herdr-agent-state.sh" || return 1
    run_compute_skills_fixture dirty
    require "a stale compute checkout without the Codex Herdr hook is rejected" \
        test "$CASE_STATUS" -ne 0 || return 1
    require "the stale checkout error names the required missing hook" \
        grep -Fq -- \
            "required compute-ai-skills HERDR hook missing: $checkout/.codex/hooks/herdr-agent-state.sh" \
            "$CASE_OUTPUT" || return 1
    require "stale checkout failure occurs before runtime links are created" \
        test ! -e "$CASE_HOME/.codex/hooks" || return 1
    require_no_external_commands || return 1

    new_case || return 1
    prepare_compute_checkout_fixture || return 1
    checkout="$CASE_HOME/compute-ai-skills"
    chmod 0644 "$checkout/.codex/hooks/herdr-agent-state.sh" || return 1
    run_compute_skills_fixture dirty
    require "a compute checkout with a non-executable Codex Herdr hook is rejected" \
        test "$CASE_STATUS" -ne 0 || return 1
    require "the non-executable checkout error names the required hook" \
        grep -Fq -- \
            "required compute-ai-skills HERDR hook is not executable: $checkout/.codex/hooks/herdr-agent-state.sh" \
            "$CASE_OUTPUT" || return 1
    require "non-executable hook failure occurs before runtime links are created" \
        test ! -e "$CASE_HOME/.codex/hooks" || return 1
    require_no_external_commands || return 1

    new_case || return 1
    checkout="$CASE_HOME/compute-ai-skills"
    run_compute_skills_fixture missing-fail
    require "missing checkout plus network failure is fatal" \
        test "$CASE_STATUS" -ne 0 || return 1
    require_equal "missing checkout attempts one noninteractive clone" 1 \
        "$(grep -c '^git clone --branch main ' "$CASE_ROOT/git.log")" || return 1
    require "failed clone leaves no partial checkout" test ! -e "$checkout" || return 1
    require "failed clone creates no runtime links" \
        test ! -e "$CASE_HOME/.claude/skills" || return 1
    require_no_external_commands || return 1
}

test_herdr_integration_configuration_and_reporting() {
    local compute_source="${COMPUTE_SKILLS_SOURCE_ROOT:-$REPOSITORY_ROOT/../compute-ai-skills}"
    local claude_hook="$REPOSITORY_ROOT/claude/hooks/herdr-agent-state.sh"
    local codex_hook="$compute_source/.codex/hooks/herdr-agent-state.sh"
    local codex_hooks="$compute_source/.codex/hooks.json"
    local row agent hook no_op_status
    local -a hook_rows=(
        "claude|$claude_hook"
        "codex|$codex_hook"
    )
    [[ -f "$codex_hook" && -f "$codex_hooks" ]] || {
        printf 'assertion failed: compute-ai-skills Herdr sources are unavailable at %s\n' \
            "$compute_source" >&2
        return 1
    }
    sh -n "$claude_hook" "$codex_hook" || return 1
    require_equal "Claude Herdr hook retains the pinned v0.7.5 bytes" \
        ffd5a76b7c62f5313040fc1e98fa010ff19a7aa85dd9fe6f325b9729d5f01b46 \
        "$(file_sha256 "$claude_hook")" || return 1
    require_equal "Codex Herdr hook retains the pinned v0.7.5 bytes" \
        2ac8115359ff849cd61e450574b371f6732780a63a07ad87c00448db5c20362d \
        "$(file_sha256 "$codex_hook")" || return 1
    require_equal "Claude hook has exactly one Claude integration ID" 1 \
        "$(grep -Fxc '# HERDR_INTEGRATION_ID=claude' "$claude_hook")" || return 1
    require_equal "Claude hook has exactly one positive integration version" 1 \
        "$(grep -Ec '^# HERDR_INTEGRATION_VERSION=[1-9][0-9]*$' "$claude_hook")" || return 1
    require_equal "Codex hook has exactly one Codex integration ID" 1 \
        "$(grep -Fxc '# HERDR_INTEGRATION_ID=codex' "$codex_hook")" || return 1
    require_equal "Codex hook has exactly one positive integration version" 1 \
        "$(grep -Ec '^# HERDR_INTEGRATION_VERSION=[1-9][0-9]*$' "$codex_hook")" || return 1
    require "Claude declares exactly one matcher-wide Herdr SessionStart hook" \
        jq -e --arg command 'bash "$HOME/.claude/hooks/herdr-agent-state.sh" session' '
            ([.hooks.SessionStart[] | select(. == {
                matcher: "*",
                hooks: [{type: "command", command: $command, timeout: 10}]
            })] | length) == 1 and
            ([.hooks.SessionStart[].hooks[] | select(.command == $command)] | length) == 1
        ' "$REPOSITORY_ROOT/claude/settings.json" >/dev/null || return 1
    require "Codex declares exactly one matcher-free Herdr SessionStart hook" \
        jq -e --arg command 'bash "$HOME/.codex/herdr-agent-state.sh" session' '
            ([.hooks.SessionStart[] | select(. == {
                hooks: [{type: "command", command: $command, timeout: 10}]
            })] | length) == 1 and
            ([.hooks.SessionStart[].hooks[] | select(.command == $command)] | length) == 1
        ' "$codex_hooks" >/dev/null || return 1
    require "Claude preserves the pre-existing venv SessionStart group exactly" \
        jq -e --arg command '~/.claude/hooks/rocprofiler-compute-venv.sh' '
            ([.hooks.SessionStart[] | select(. == {
                hooks: [{type: "command", command: $command}]
            })] | length) == 1 and
            ([.hooks.SessionStart[].hooks[] | select(.command == $command)] | length) == 1
        ' "$REPOSITORY_ROOT/claude/settings.json" >/dev/null || return 1
    require "Codex preserves the pre-existing venv SessionStart group exactly" \
        jq -e \
            --arg command '$HOME/.codex/hooks/rocprofiler-compute-venv.sh' \
            --arg status_message 'Checking rocprofiler-compute venv' '
            ([.hooks.SessionStart[] | select(. == {
                hooks: [{
                    type: "command",
                    command: $command,
                    statusMessage: $status_message
                }]
            })] | length) == 1 and
            ([.hooks.SessionStart[].hooks[] | select(.command == $command)] | length) == 1
        ' "$codex_hooks" >/dev/null || return 1
    require "Codex hooks are enabled in the parsed TOML configuration" \
        python3 - "$REPOSITORY_ROOT/codex/config.toml" <<'PY' || return 1
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    configuration = tomllib.load(handle)
raise SystemExit(0 if configuration.get("features", {}).get("hooks") is True else 1)
PY
    require "Herdr configuration parses as TOML" \
        python3 - "$REPOSITORY_ROOT/config/herdr/config.toml" <<'PY' || return 1
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    tomllib.load(handle)
PY
    require "Claude retains tmux teammate mode" \
        jq -e '.env.teammateMode == "tmux"' \
        "$REPOSITORY_ROOT/claude/settings.json" >/dev/null || return 1

    new_case || return 1
    for row in "${hook_rows[@]}"; do
        IFS='|' read -r agent hook <<< "$row"
        no_op_status=0
        printf '%s\n' \
            "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$agent-outside\"}" |
            env -i \
                HOME="$CASE_HOME" \
                PATH=/usr/bin:/bin \
                TMPDIR="$CASE_TMP" \
                "$hook" session > "$CASE_ROOT/herdr-$agent-outside.log" 2>&1 || \
            no_op_status=$?
        require_equal "$agent hook is a successful no-op outside Herdr" \
            0 "$no_op_status" || return 1
        require "$agent outside-Herdr hook leaves no socket or request artifact" \
            test -z "$(find "$CASE_ROOT" -maxdepth 1 \
                \( -name "herdr-$agent.sock" -o -name "herdr-$agent-request.json" \) \
                -print -quit)" || return 1

        run_herdr_hook_socket_fixture "$hook" "$agent" || return 1
        require_equal "$agent hook and socket fixture both succeed" \
            $'HOOK_STATUS=0\nSERVER_STATUS=0' \
            "$(< "$CASE_ROOT/herdr-$agent-status.log")" || return 1
        require "$agent hook reports valid SessionStart identity to Herdr" \
            jq -e --arg agent "$agent" --arg session "$agent-session" '
                .method == "pane.report_agent_session" and
                .params.pane_id == "%42" and
                .params.source == ("herdr:" + $agent) and
                .params.agent == $agent and
                .params.agent_session_id == $session and
                .params.session_start_source == "startup" and
                (.params.seq | type) == "number"
            ' "$CASE_ROOT/herdr-$agent-request.json" >/dev/null || return 1
        if [[ "$agent" == claude ]]; then
            require "Claude reports its transcript as the agent session path" \
                jq -e --arg path "$CASE_ROOT/claude-transcript.jsonl" \
                '.params.agent_session_path == $path' \
                "$CASE_ROOT/herdr-claude-request.json" >/dev/null || return 1
        else
            require "Codex does not invent an agent session path" \
                jq -e '.params | has("agent_session_path") | not' \
                "$CASE_ROOT/herdr-codex-request.json" >/dev/null || return 1
        fi
    done
    require "hook temporary input files are cleaned up" \
        test -z "$(find "$CASE_TMP" -maxdepth 1 -name 'herdr-*-hook.*' -print -quit)" || \
        return 1
    require_no_external_commands || return 1
}

test_repository_static_and_shell_discovery_contract() {
    local path_entry
    local -a json_files=(
        claude/mcp-servers.json
        claude/settings.json
        claude/themes/snazzy-light.json
        config/nvim/lazy-lock.json
        config/nvim/lazyvim.json
    )
    local -a path_entries=(
        .local/bin
        .local/go/bin
        .cargo/bin
        .nvm/current/bin
    )
    bash -n "$REPOSITORY_ROOT/install.sh" \
        "$REPOSITORY_ROOT/shell/.bashrc" \
        "$REPOSITORY_ROOT/shell/.profile" \
        "$REPOSITORY_ROOT/claude/claude-statusline" || return 1
    if command -v shellcheck >/dev/null 2>&1; then
        shellcheck --severity=warning \
            "$REPOSITORY_ROOT/install.sh" "$SCRIPT_PATH" || return 1
    fi
    for path_entry in "${json_files[@]}"; do
        require "$path_entry is valid JSON" jq empty \
            "$REPOSITORY_ROOT/$path_entry" || return 1
    done
    require "the configured Claude statusline is executable" \
        test -x "$REPOSITORY_ROOT/claude/claude-statusline" || return 1
    require "Claude registers the slurm mount check hook" jq -e '
        [.hooks.PreToolUse[].hooks[].command]
        | index("~/.claude/hooks/slurm-mountcheck.sh") != null
    ' "$REPOSITORY_ROOT/claude/settings.json" >/dev/null || return 1
    require "the obsolete split installer is absent" \
        test ! -e "$REPOSITORY_ROOT/install-tools.sh" || return 1

    new_case || return 1
    ln -s "$REPOSITORY_ROOT/shell/.bashrc" "$CASE_HOME/.bashrc" || return 1
    ln -s "$REPOSITORY_ROOT/shell/.profile" "$CASE_HOME/.profile" || return 1
    env -i HOME="$CASE_HOME" PATH=/usr/bin:/bin TERM=dumb \
        REPOSITORY_ROOT="$REPOSITORY_ROOT" \
        bash --noprofile --norc -c '
            source "$REPOSITORY_ROOT/shell/.profile"
            printf "%s\n" "$PATH"
        ' > "$CASE_ROOT/login-path.log" 2> "$CASE_ROOT/login-stderr.log" || return 1
    env -i HOME="$CASE_HOME" PATH=/usr/bin:/bin TERM=dumb \
        REPOSITORY_ROOT="$REPOSITORY_ROOT" \
        bash --noprofile --norc -ic '
            source "$REPOSITORY_ROOT/shell/.bashrc"
            printf "%s\n" "$PATH"
        ' > "$CASE_ROOT/interactive-path.log" 2> "$CASE_ROOT/interactive-stderr.log" || return 1
    for path_entry in "${path_entries[@]}"; do
        require "login Bash discovers $path_entry" \
            grep -Fq -- "$CASE_HOME/$path_entry" "$CASE_ROOT/login-path.log" || return 1
        require "interactive Bash discovers $path_entry" \
            grep -Fq -- "$CASE_HOME/$path_entry" "$CASE_ROOT/interactive-path.log" || return 1
        require "Fish config discovers $path_entry" \
            grep -Fq -- "\"\$HOME/$path_entry\"" \
            "$REPOSITORY_ROOT/config/fish/conf.d/uv.env.fish" || return 1
    done
    require "Fish guards the uv environment file" \
        grep -Fq -- 'if test -f "$HOME/.local/bin/env.fish"' \
        "$REPOSITORY_ROOT/config/fish/conf.d/uv.env.fish" || return 1
    require "Fish guards the Cargo environment file" \
        grep -Fq -- 'if test -f "$HOME/.cargo/env.fish"' \
        "$REPOSITORY_ROOT/config/fish/conf.d/uv.env.fish" || return 1
    if command -v fish >/dev/null 2>&1; then
        fish -n "$REPOSITORY_ROOT/config/fish/conf.d/uv.env.fish" \
            "$REPOSITORY_ROOT/config/fish/config.fish" || return 1
    fi
    require_no_external_commands || return 1
}

assert_invalid_state_is_untouched() {
    local content="$1" state before
    new_case || return 1
    state="$CASE_HOME/.claude.json"
    write_json "$state" "$content"
    before="$(sha256sum "$state" | awk '{print $1}')"
    run_configure
    require "invalid live state is rejected" test "$CASE_STATUS" -ne 0 || return 1
    require_equal "invalid live state is untouched" \
        "$before" "$(sha256sum "$state" | awk '{print $1}')" || return 1
    require "invalid live state invokes no Claude command" test ! -s "$CASE_LOG" || return 1
    require "invalid live state creates no backup" test -z "$(backup_directory)" || return 1
}

test_malformed_and_nonregular_state_is_untouched() {
    local state target
    assert_invalid_state_is_untouched '{' || return 1
    assert_invalid_state_is_untouched '{"mcpServers":null}' || return 1
    assert_invalid_state_is_untouched '{"mcpServers":[]}' || return 1
    assert_invalid_state_is_untouched '{"mcpServers":"invalid"}' || return 1
    assert_invalid_state_is_untouched '[]' || return 1
    assert_invalid_state_is_untouched \
        '{"machineID":"DUPLICATE_LIVE_SECRET","machineID":"safe","mcpServers":{}}' || return 1
    assert_invalid_state_is_untouched \
        '{"mcpServers":{"hidden":{"headers":{"Authorization":"DUPLICATE_LIVE_SECRET"}}},"mcpServers":{}}' || return 1
    assert_invalid_state_is_untouched \
        '{"mcpServers":{"jira":{"type":"http","url":"https://hidden.invalid","url":"https://mcp.atlassian.com/v1/mcp/authv2"}}}' || return 1

    new_case || return 1
    state="$CASE_HOME/.claude.json"
    target="$CASE_ROOT/symlink-target.json"
    write_json "$target" '{"mcpServers":{}}'
    ln -s "$target" "$state"
    run_configure
    require "symlink state is rejected" test "$CASE_STATUS" -ne 0 || return 1
    require "symlink state remains a symlink" test -L "$state" || return 1
    require_equal "symlink target is unchanged" \
        '{"mcpServers":{}}' "$(tr -d '\n' < "$target")" || return 1

    new_case || return 1
    state="$CASE_HOME/.claude.json"
    mkdir "$state"
    run_configure
    require "directory state is rejected" test "$CASE_STATUS" -ne 0 || return 1
    require "directory state remains a directory" test -d "$state" || return 1

    new_case || return 1
    state="$CASE_HOME/.claude.json"
    mkfifo "$state"
    run_configure
    require "non-regular state is rejected" test "$CASE_STATUS" -ne 0 || return 1
    require "non-regular state remains untouched" test -p "$state" || return 1
}

test_duplicate_json_is_preserved_during_destructive_proof() {
    local state before recovery displaced content
    local desired='{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"}'
    local -a duplicate_states=(
        '{"mcpServers":{"hidden":{"headers":{"Authorization":"DUPLICATE_ROLLBACK_SECRET"}}},"mcpServers":{"jira":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"}}}'
        '{"mcpServers":{"jira":{"type":"http","url":"https://hidden.invalid","url":"https://mcp.atlassian.com/v1/mcp/authv2"}}}'
    )

    for content in "${duplicate_states[@]}"; do
        new_case || return 1
        state="$CASE_HOME/.claude.json"
        write_json "$state" "$content"
        chmod 0600 "$state" || return 1
        before="$(file_sha256 "$state")"

        run_direct_new_state_rollback jira "$desired"
        require "duplicate-bearing rollback proof fails closed" \
            test "$CASE_STATUS" -ne 0 || return 1
        require "ambiguous duplicate bytes return to the canonical path" \
            test -f "$state" || return 1
        require_equal "ambiguous duplicate bytes are preserved exactly" \
            "$before" "$(file_sha256 "$state")" || return 1
        recovery="$(rollback_directory)"
        if [[ -n "$recovery" ]]; then
            displaced="$recovery/displaced-state"
            require "ambiguous duplicate bytes are not stranded after proof" \
                test ! -e "$displaced" || return 1
        fi
        require "duplicate-bearing proof reports manual recovery" \
            grep -q 'manual recovery required' "$CASE_OUTPUT" || return 1
        require_manual_recovery_paths "$state" || return 1
        require_file_excludes "duplicate rollback secret is absent from output" \
            "$CASE_OUTPUT" DUPLICATE_ROLLBACK_SECRET || return 1
        require "duplicate proof creates no original-state backup" \
            test -z "$(backup_directory)" || return 1
        require_no_external_commands || return 1
    done
}

test_post_mutation_state_read_failures_enter_recovery() {
    local mode state original backup snapshot recovery
    local -a modes=(malform-after-add:jira delete-after-add:jira)

    for mode in "${modes[@]}"; do
        new_case || return 1
        state="$CASE_HOME/.claude.json"
        original="$CASE_ROOT/original.json"
        write_json "$state" \
            '{"machineID":"post-mutation","mcpServers":{"jira":{"type":"http","url":"https://old.invalid"},"unmanaged":{"type":"http","url":"https://unmanaged.invalid"}}}'
        cp "$state" "$original" || return 1

        run_configure "$mode"
        require "post-mutation state read failure is reported" \
            test "$CASE_STATUS" -ne 0 || return 1
        require_equal "one conflicting record is removed before the injected race" 1 \
            "$(grep -c '^claude mcp remove --scope user jira$' "$CASE_LOG")" || return 1
        require_equal "one replacement is added before the injected race" 1 \
            "$(grep -c '^claude mcp add-json --scope user jira ' "$CASE_LOG")" || return 1
        require "an invalid post-mutation read never becomes a missing confluence record" \
            test -z "$(grep ' confluence\( \|$\)' "$CASE_LOG" || true)" || return 1
        backup="$(backup_directory)"
        snapshot="$(snapshot_file "$backup")"
        require_equal "the protected pre-mutation snapshot remains exact" \
            "$(file_sha256 "$original")" "$(file_sha256 "$snapshot")" || return 1
        case "$mode" in
            malform-after-add:*)
                require_equal "malformed post-mutation bytes remain canonical" '{' \
                    "$(tr -d '\n' < "$state")" || return 1
                require "malformed post-mutation state enters manual recovery" \
                    grep -q 'manual recovery required' "$CASE_OUTPUT" || return 1
                recovery="$(recovery_directory)"
                require "canonical post-mutation recovery removes temporary material" \
                    test -z "$recovery" || return 1
                require_manual_recovery_paths "$state" "$snapshot" || return 1
                ;;
            delete-after-add:*)
                require_equal "raced-away state restores the protected snapshot" \
                    "$(file_sha256 "$original")" "$(file_sha256 "$state")" || return 1
                require "safe raced-away restoration leaves no recovery tree" \
                    test -z "$(recovery_directory)" || return 1
                ;;
        esac
        require_no_external_commands || return 1
    done
}

test_post_remove_readback_boundaries_stop_before_add() {
    local mode state original backup snapshot
    local -a modes=(
        delete-after-remove:jira
        malform-after-remove:jira
        retain-after-remove:jira
    )

    for mode in "${modes[@]}"; do
        new_case || return 1
        state="$CASE_HOME/.claude.json"
        original="$CASE_ROOT/original.json"
        write_json "$state" \
            '{"machineID":"post-remove","mcpServers":{"jira":{"type":"http","url":"https://old.invalid"},"unmanaged":{"type":"http","url":"https://unmanaged.invalid"}}}'
        cp "$state" "$original" || return 1

        run_configure "$mode"
        require "$mode post-remove readback failure is reported" \
            test "$CASE_STATUS" -ne 0 || return 1
        require_equal "$mode invokes one successful removal" 1 \
            "$(grep -c '^claude mcp remove --scope user jira$' "$CASE_LOG")" || return 1
        require_equal "$mode stops before every replacement add" 0 \
            "$(grep -c '^claude mcp add-json ' "$CASE_LOG")" || return 1
        require_equal "$mode performs no later Claude operation" 1 \
            "$(wc -l < "$CASE_LOG")" || return 1
        require "$mode diagnoses the failed removal confirmation" \
            grep -Fq -- 'the previous jira MCP record was not confirmed removed' \
            "$CASE_OUTPUT" || return 1
        backup="$(backup_directory)"
        snapshot="$(snapshot_file "$backup")"
        require_equal "$mode preserves the exact protected snapshot" \
            "$(file_sha256 "$original")" "$(file_sha256 "$snapshot")" || return 1

        case "$mode" in
            delete-after-remove:*)
                require_equal "deleted post-remove state safely restores the snapshot" \
                    "$(file_sha256 "$original")" "$(file_sha256 "$state")" || return 1
                require "deleted post-remove state reports the safe restoration" \
                    grep -Fq -- "restored $state from $snapshot" "$CASE_OUTPUT" || return 1
                require "deleted post-remove restoration leaves no recovery tree" \
                    test -z "$(recovery_directory)" || return 1
                ;;
            malform-after-remove:*)
                require "malformed post-remove state remains a regular canonical file" \
                    test -f "$state" || return 1
                require_equal "malformed post-remove bytes remain canonical" '{' \
                    "$(tr -d '\n' < "$state")" || return 1
                require "malformed post-remove state enters manual recovery" \
                    grep -Fq -- 'manual recovery required' "$CASE_OUTPUT" || return 1
                require "malformed post-remove recovery leaves no temporary tree" \
                    test -z "$(recovery_directory)" || return 1
                require_manual_recovery_paths "$state" "$snapshot" || return 1
                ;;
            retain-after-remove:*)
                require_equal "retained original state safely restores the snapshot" \
                    "$(file_sha256 "$original")" "$(file_sha256 "$state")" || return 1
                require "retained original state reports the safe restoration" \
                    grep -Fq -- "restored $state from $snapshot" "$CASE_OUTPUT" || return 1
                require_file_excludes "retained original state needs no manual recovery" \
                    "$CASE_OUTPUT" 'manual recovery required' || return 1
                require "retained original restoration leaves no recovery tree" \
                    test -z "$(recovery_directory)" || return 1
                ;;
        esac
        require_no_external_commands || return 1
    done
}

test_fresh_first_add_unreadable_state_enters_recovery() {
    local state
    new_case || return 1
    state="$CASE_HOME/.claude.json"
    require "fresh unreadable-state case starts without Claude state" \
        test ! -e "$state" || return 1

    run_configure malform-after-add:jira
    require "unreadable state after the first add is reported" \
        test "$CASE_STATUS" -ne 0 || return 1
    require_equal "the fresh transaction attempts exactly one Jira add" 1 \
        "$(grep -c '^claude mcp add-json --scope user jira ' "$CASE_LOG")" || return 1
    require_equal "the fresh transaction stops before every later Claude operation" 1 \
        "$(wc -l < "$CASE_LOG")" || return 1
    require "the unreadable first-add state cannot be confirmed" \
        grep -Fq -- 'the added jira MCP record could not be confirmed' \
        "$CASE_OUTPUT" || return 1
    require "the unreadable first-add state remains a regular canonical file" \
        test -f "$state" || return 1
    require_equal "the unreadable first-add bytes remain canonical" '{' \
        "$(tr -d '\n' < "$state")" || return 1
    require "the unreadable first-add state enters manual recovery" \
        grep -Fq -- 'manual recovery required' "$CASE_OUTPUT" || return 1
    require_manual_recovery_paths "$state" || return 1
    require "an initially absent state creates no protected snapshot" \
        test -z "$(backup_directory)" || return 1
    require "unreadable first-add recovery creates no rollback tree" \
        test -z "$(rollback_directory)" || return 1
    require_no_external_commands || return 1
}

test_existing_state_unconfirmed_managed_changes_are_preserved() {
    local scenario mode state original backup snapshot recovery
    local -a scenarios=(partial concurrent wrong removal)

    for scenario in "${scenarios[@]}"; do
        new_case || return 1
        state="$CASE_HOME/.claude.json"
        original="$CASE_ROOT/original.json"
        case "$scenario" in
            partial|wrong|removal)
                case "$scenario" in
                    partial) mode=partial-add-fail:jira ;;
                    wrong) mode=wrong-add:jira ;;
                    removal) mode=remove-then-fail:jira ;;
                esac
                write_json "$state" \
                    "{\"machineID\":\"managed-$scenario\",\"mcpServers\":{\"jira\":{\"type\":\"http\",\"url\":\"https://old.invalid\"},\"unmanaged\":{\"type\":\"http\",\"url\":\"https://unmanaged.invalid\"}}}"
                ;;
            concurrent)
                mode=change-jira-and-fail:confluence
                write_json "$state" \
                    '{"machineID":"managed-concurrent","mcpServers":{"jira":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"},"unmanaged":{"type":"http","url":"https://unmanaged.invalid"}}}'
                ;;
        esac
        cp "$state" "$original" || return 1

        run_configure "$mode"
        require "$scenario managed-record mutation remains a failed transaction" \
            test "$CASE_STATUS" -ne 0 || return 1
        require "$scenario unconfirmed managed state remains at the canonical path" \
            test -f "$state" || return 1
        require "$scenario unconfirmed managed state is not overwritten by the snapshot" \
            test "$(file_sha256 "$state")" != "$(file_sha256 "$original")" || return 1
        case "$scenario" in
            partial)
                require "partial failed add preserves the record written before failure" jq -e \
                    '.mcpServers.jira.url == "https://mcp.atlassian.com/v1/mcp/authv2"' \
                    "$state" >/dev/null || return 1
                ;;
            concurrent)
                require "concurrent managed change is preserved before restoration" jq -e \
                    '.mcpServers.jira.url == "https://concurrent.invalid"' \
                    "$state" >/dev/null || return 1
                ;;
            wrong)
                require "wrong successful add remains unconfirmed and preserved" jq -e \
                    '.mcpServers.jira.url == "https://wrong.invalid"' \
                    "$state" >/dev/null || return 1
                ;;
            removal)
                require "failed remove that deleted its record remains unconfirmed and preserved" jq -e \
                    '(.mcpServers | has("jira") | not)' \
                    "$state" >/dev/null || return 1
                ;;
        esac
        backup="$(backup_directory)"
        snapshot="$(snapshot_file "$backup")"
        require_equal "$scenario protected snapshot remains exact" \
            "$(file_sha256 "$original")" "$(file_sha256 "$snapshot")" || return 1
        recovery="$(recovery_directory)"
        require "$scenario canonical preservation removes temporary recovery material" \
            test -z "$recovery" || return 1
        require "$scenario unconfirmed managed change reports manual recovery" \
            grep -q 'manual recovery required' "$CASE_OUTPUT" || return 1
        require_manual_recovery_paths "$state" "$snapshot" || return 1
        require_no_external_commands || return 1
    done
}

test_concurrent_unrelated_change_preserves_both_versions() {
    local state original backup snapshot recovery
    new_case || return 1
    state="$CASE_HOME/.claude.json"
    original="$CASE_ROOT/original.json"
    write_json "$state" \
        '{"machineID":"machine","private":"CONCURRENT_SECRET_MARKER","mcpServers":{"jira":{"type":"http","url":"https://old.invalid"},"other":{"type":"http","url":"https://other.invalid"}}}'
    cp "$state" "$original"
    run_configure concurrent-add:jira
    require "concurrent write makes reconciliation fail" test "$CASE_STATUS" -ne 0 || return 1
    recovery="$(recovery_directory)"
    require "concurrent state returns to the canonical path" jq -e \
        '.concurrentWrite == "preserve-me"' "$state" >/dev/null || return 1
    require "concurrent state is not overwritten by the snapshot" \
        test "$(sha256sum "$state" | awk '{print $1}')" != \
             "$(sha256sum "$original" | awk '{print $1}')" || return 1
    require "canonical concurrent-state recovery removes temporary material" \
        test -z "$recovery" || return 1
    backup="$(backup_directory)"
    snapshot="$(snapshot_file "$backup")"
    require_equal "original snapshot is retained" \
        "$(file_sha256 "$original")" "$(file_sha256 "$snapshot")" || return 1
    require "manual recovery is reported" \
        grep -q 'manual recovery required' "$CASE_OUTPUT" || return 1
    require_manual_recovery_paths "$state" "$snapshot" || return 1
    require_file_excludes "concurrent secret is absent from command log" \
        "$CASE_LOG" CONCURRENT_SECRET_MARKER || return 1
    require_file_excludes "concurrent secret is absent from output" \
        "$CASE_OUTPUT" CONCURRENT_SECRET_MARKER || return 1
}

test_restore_boundary_recreation_never_overwrites_concurrent_state() {
    local state original backup snapshot recovery_path
    local -a recovery_paths=()
    new_case || return 1
    state="$CASE_HOME/.claude.json"
    original="$CASE_ROOT/original.json"
    write_json "$state" \
        '{"machineID":"before-race","mcpServers":{"jira":{"type":"http","url":"https://old.invalid"},"unmanaged":{"type":"http","url":"https://unmanaged.invalid"}}}'
    cp "$state" "$original"

    run_configure fail-add:jira recreate-live-after-displace
    require "restoration-boundary race is reported" test "$CASE_STATUS" -ne 0 || return 1
    require "the race hook reached the live-state displacement boundary" \
        test -f "$CASE_HOME/.mv-race-triggered" || return 1
    require "the concurrently recreated live file is never overwritten" jq -e \
        '.concurrentBoundary == "preserve-me" and
         .mcpServers.concurrent.url == "https://concurrent.invalid"' \
        "$state" >/dev/null || return 1

    backup="$(backup_directory)"
    snapshot="$(snapshot_file "$backup")"
    require_equal "the protected original snapshot survives the boundary race" \
        "$(file_sha256 "$original")" "$(file_sha256 "$snapshot")" || return 1
    mapfile -t recovery_paths < <(
        find "$CASE_HOME" -mindepth 1 \
            \( -path "$CASE_HOME/.dotfiles-backup-*" -o \
               -path "$CASE_HOME/.dotfiles-backup-*/*" \) -prune -o \
            \( -name '.claude.json.recovery.*' -o \
               -path "$CASE_HOME/.claude.json.recovery.*/*" \) -print | sort
    )
    require "the full displaced restoration set is retained" \
        test "${#recovery_paths[@]}" -ge 3 || return 1
    require_manual_recovery_paths "$state" "$snapshot" || return 1
    for recovery_path in "${recovery_paths[@]}"; do
        require "every retained recovery artifact path is reported" \
            grep -Fq -- "$recovery_path" "$CASE_OUTPUT" || return 1
    done
}

test_absent_state_partial_and_changed_records_are_preserved() {
    local state recovery displaced
    new_case || return 1
    state="$CASE_HOME/.claude.json"
    run_configure partial-add-fail:jira
    require "partial failed add is reported" test "$CASE_STATUS" -ne 0 || return 1
    recovery="$(rollback_directory)"
    displaced="$recovery/displaced-state"
    require "partial failed add returns to the canonical path" jq -e \
        '.mcpServers.jira.url == "https://mcp.atlassian.com/v1/mcp/authv2"' \
        "$state" >/dev/null || return 1
    if [[ -n "$recovery" ]]; then
        require "partial failed add is not stranded as displaced material" \
            test ! -e "$displaced" || return 1
    fi
    require "partial write reports manual recovery" \
        grep -q 'manual recovery required' "$CASE_OUTPUT" || return 1
    require_manual_recovery_paths "$state" || return 1
    require "absent initial state creates no snapshot tree" \
        test -z "$(backup_directory)" || return 1

    new_case || return 1
    state="$CASE_HOME/.claude.json"
    run_configure change-jira-and-fail:confluence
    require "changed confirmed record makes rollback fail safely" \
        test "$CASE_STATUS" -ne 0 || return 1
    recovery="$(rollback_directory)"
    displaced="$recovery/displaced-state"
    require "changed managed record returns to the canonical path" jq -e \
        '.mcpServers.jira.url == "https://concurrent.invalid"' \
        "$state" >/dev/null || return 1
    if [[ -n "$recovery" ]]; then
        require "changed generated state is not stranded as displaced material" \
            test ! -e "$displaced" || return 1
    fi
    require "changed record reports manual recovery" \
        grep -q 'manual recovery required' "$CASE_OUTPUT" || return 1
    require_manual_recovery_paths "$state" || return 1
}

test_fresh_state_rollback_displacement_contract() {
    local state recovery displaced shape
    local desired='{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"}'
    local -a clean_shapes=(
        '{}'
        '{"mcpServers":{}}'
        '{"mcpServers":{"jira":{"type":"http","url":"https://mcp.atlassian.com/v1/mcp/authv2"}}}'
    )

    for shape in "${clean_shapes[@]}"; do
        new_case || return 1
        state="$CASE_HOME/.claude.json"
        write_json "$state" "$shape"
        if [[ "$shape" == *'"jira"'* ]]; then
            run_direct_new_state_rollback jira "$desired"
        else
            run_direct_new_state_rollback
        fi
        require_equal "exact generated shape is accepted for cleanup" 0 \
            "$CASE_STATUS" || return 1
        require "exact generated shape is removed only after displacement" \
            test ! -e "$state" || return 1
        require "clean generated rollback removes its private staging directory" \
            test -z "$(rollback_directory)" || return 1
    done

    new_case || return 1
    state="$CASE_HOME/.claude.json"
    write_json "$state" \
        '{"mcpServers":{"jira":{"type":"http","url":"https://unconfirmed.invalid"}}}'
    run_direct_new_state_rollback jira "$desired"
    require "changed generated state requires manual recovery" \
        test "$CASE_STATUS" -ne 0 || return 1
    recovery="$(rollback_directory)"
    displaced="$recovery/displaced-state"
    require "changed generated state returns to the canonical path" jq -e \
        '.mcpServers.jira.url == "https://unconfirmed.invalid"' \
        "$state" >/dev/null || return 1
    if [[ -n "$recovery" ]]; then
        require "changed state is not stranded as displaced material" \
            test ! -e "$displaced" || return 1
    fi
    require_manual_recovery_paths "$state" || return 1

    new_case || return 1
    state="$CASE_HOME/.claude.json"
    mkdir "$state" || return 1
    run_direct_new_state_rollback
    require "nonregular generated state requires manual recovery" \
        test "$CASE_STATUS" -ne 0 || return 1
    recovery="$(rollback_directory)"
    displaced="$recovery/displaced-state"
    require "nonregular generated state returns to the canonical path" \
        test -d "$state" || return 1
    if [[ -n "$recovery" ]]; then
        require "nonregular state is not stranded as displaced material" \
            test ! -e "$displaced" || return 1
    fi
    require_manual_recovery_paths "$state" || return 1

    new_case || return 1
    state="$CASE_HOME/.claude.json"
    run_configure fail-add:confluence recreate-live-after-displace
    require "fresh-state displacement race preserves the installer failure" \
        test "$CASE_STATUS" -ne 0 || return 1
    require "fresh-state race hook reached the displacement boundary" \
        test -f "$CASE_HOME/.mv-race-triggered" || return 1
    require "fresh-state rollback never removes a recreated destination" jq -e \
        '.concurrentBoundary == "preserve-me" and
         .mcpServers.concurrent.url == "https://concurrent.invalid"' \
        "$state" >/dev/null || return 1
    recovery="$(rollback_directory)"
    displaced="$recovery/displaced-state"
    require "fresh-state race retains private rollback material" \
        test -d "$recovery" || return 1
    require "fresh-state race retains the displaced generated state" \
        test -f "$displaced" || return 1
    require "fresh-state race reports manual recovery without clobbering" \
        grep -q 'manual recovery required' "$CASE_OUTPUT" || return 1
    require_manual_recovery_paths "$state" || return 1
}

test_source_inputs_are_unchanged() {
    require_equal "source installer remains unchanged" \
        "$SOURCE_INSTALL_HASH" \
        "$(sha256sum "$REPOSITORY_ROOT/install.sh" | awk '{print $1}')" || return 1
    require_equal "source manifest remains unchanged" \
        "$SOURCE_MANIFEST_HASH" \
        "$(sha256sum "$REPOSITORY_ROOT/claude/mcp-servers.json" | awk '{print $1}')" || return 1
}

container_matrix() {
    printf '%s\n' \
        'ubuntu:24.04|ubuntu|24.04|24|debian|0' \
        'debian:12|debian|12|12|debian|0' \
        'rockylinux:8|rocky|floating|8|rhel|1' \
        'rockylinux:9|rocky|floating|9|rhel|0'
}

test_container_matrix_contract_is_exact() {
    local expected actual row image expected_id expected_version expected_major
    local expected_family fallback
    expected=$'ubuntu:24.04|ubuntu|24.04|24|debian|0\ndebian:12|debian|12|12|debian|0\nrockylinux:8|rocky|floating|8|rhel|1\nrockylinux:9|rocky|floating|9|rhel|0'
    actual="$(container_matrix)"
    require_equal "container matrix and Rocky 8 fallback flag are exact" \
        "$expected" "$actual" || return 1
    while IFS='|' read -r image expected_id expected_version expected_major \
        expected_family fallback; do
        CONTAINER_EXPECTED_IMAGE="$image" \
        CONTAINER_EXPECTED_ID="$expected_id" \
        CONTAINER_EXPECTED_VERSION="$expected_version" \
        CONTAINER_EXPECTED_MAJOR="$expected_major" \
        CONTAINER_EXPECTED_FAMILY="$expected_family" \
        CONTAINER_EXPECTED_FALLBACK="$fallback" \
            container_metadata_is_valid || return 1
    done <<< "$actual"
    if CONTAINER_EXPECTED_IMAGE=ubuntu:24.04 \
       CONTAINER_EXPECTED_ID=ubuntu \
       CONTAINER_EXPECTED_VERSION=24.04 \
       CONTAINER_EXPECTED_MAJOR=24 \
       CONTAINER_EXPECTED_FAMILY=rhel \
       CONTAINER_EXPECTED_FALLBACK=0 \
           container_metadata_is_valid; then
        printf 'assertion failed: forged container metadata is rejected\n' >&2
        return 1
    fi
    if CONTAINER_EXPECTED_IMAGE=ubuntu:24.04 \
       CONTAINER_EXPECTED_ID=ubuntu \
       CONTAINER_EXPECTED_VERSION=24.10 \
       CONTAINER_EXPECTED_MAJOR=24 \
       CONTAINER_EXPECTED_FAMILY=debian \
       CONTAINER_EXPECTED_FALLBACK=0 \
           container_metadata_is_valid; then
        printf 'assertion failed: forged container version metadata is rejected\n' >&2
        return 1
    fi
}

container_inner_expected_sudo_log() {
    local expected_file="$1" saved_log="$SUDO_COMMAND_LOG"
    local -a debian_packages=(
        ca-certificates git curl jq fish python3 python3-venv tar unzip zip xz-utils bzip2 findutils
        bash-completion build-essential cmake ninja-build pkg-config libssl-dev libevent-dev
        libncurses-dev gettext bison
    )
    local -a rhel_packages=(
        ca-certificates git curl jq fish python3 tar unzip zip xz bzip2 findutils bash-completion
        gcc gcc-c++ make cmake ninja-build pkgconf-pkg-config openssl-devel libevent-devel
        ncurses-devel gettext bison
    )
    : > "$expected_file"
    SUDO_COMMAND_LOG="$expected_file"
    if [[ "$CONTAINER_EXPECTED_FAMILY" == debian ]]; then
        container_sudo_stub_main apt-get update
        container_sudo_stub_main env DEBIAN_FRONTEND=noninteractive \
            apt-get install -y "${debian_packages[@]}"
    else
        container_sudo_stub_main dnf install -y dnf-plugins-core
        if [[ "$CONTAINER_EXPECTED_MAJOR" == 8 ]]; then
            container_sudo_stub_main dnf config-manager --set-enabled powertools
        else
            container_sudo_stub_main dnf config-manager --set-enabled crb
        fi
        container_sudo_stub_main dnf install -y \
            "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${CONTAINER_EXPECTED_MAJOR}.noarch.rpm"
        container_sudo_stub_main dnf install -y "${rhel_packages[@]}"
    fi
    SUDO_COMMAND_LOG="$saved_log"
}

container_record_install_call() {
    local argument
    : "${CONTAINER_INSTALL_CALL_LOG:?}"
    printf '%s' "$1" >> "$CONTAINER_INSTALL_CALL_LOG"
    shift
    for argument in "$@"; do
        printf ' %q' "$argument" >> "$CONTAINER_INSTALL_CALL_LOG"
    done
    printf '\n' >> "$CONTAINER_INSTALL_CALL_LOG"
}

container_expected_validation_have_log() {
    local command_name
    local -a required_commands=(
        git curl jq fish python3 cargo go node npm uv eza fd diskus csvlens
        yazi ya glow codex sqlit claude starship zoxide fzf rg btop duf gh gitmux herdr tmux nvim
    )
    for command_name in "${required_commands[@]}"; do
        printf '%s\n' "$command_name"
    done
    printf '%s\n' tmux nvim fzf rg btop duf gh gitmux herdr
}

container_inner_main() {
    local run_number=1 sudo_line_count=0 expected_sudo current_sudo fallback_hash main_status=0
    local fallback_enabled expected_main_failure
    [[ $# -eq 0 ]] || return 2
    container_inner_boundary_is_valid || {
        printf 'container-inner boundary validation failed\n' >&2
        return 1
    }
    fallback_enabled="$CONTAINER_EXPECTED_FALLBACK"
    expected_main_failure="${CONTAINER_EXPECTED_MAIN_FAILURE:-0}"
    [[ "$expected_main_failure" == 0 || "$expected_main_failure" == 1 ]] || {
        printf 'invalid container worker failure mode\n' >&2
        return 1
    }
    mkdir -p "$HOME" "$HOME/container-bin" || return 1
    export PATH="$HOME/container-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    export SUDO_COMMAND_LOG="$HOME/sudo-command.log"
    export BLOCKED_COMMAND_LOG="$HOME/forbidden-command.log"
    export CONTAINER_FALLBACK_LOG="$HOME/rocky8-fallback.log"
    export CONTAINER_INSTALL_CALL_LOG="$HOME/current-install-calls.log"
    : >> "$SUDO_COMMAND_LOG"
    : >> "$BLOCKED_COMMAND_LOG"
    : >> "$CONTAINER_FALLBACK_LOG"
    : > "$CONTAINER_INSTALL_CALL_LOG"

    if [[ -f "$HOME/container-run-count" ]]; then
        read -r run_number < "$HOME/container-run-count" || return 1
        run_number=$((run_number + 1))
    fi
    (( run_number <= 2 )) || {
        printf 'container smoke was started more than twice\n' >&2
        return 1
    }

    local command_name
    for command_name in sudo apt-get curl dnf find git ssh subscription-manager wget make; do
        ln -sfn "$SCRIPT_PATH" "$HOME/container-bin/$command_name" || return 1
    done

    sudo_line_count="$(wc -l < "$SUDO_COMMAND_LOG")" || return 1
    expected_sudo="$HOME/expected-sudo.log"
    current_sudo="$HOME/current-sudo.log"

    source "$REPOSITORY_ROOT/install.sh"
    declare -F main >/dev/null || return 1
    eval "$(declare -f install_tmux | sed '1s/install_tmux/container_original_install_tmux/')"
    eval "$(declare -f install_neovim | sed '1s/install_neovim/container_original_install_neovim/')"
    eval "$(declare -f validate_required_commands | sed '1s/validate_required_commands/container_original_validate_required_commands/')"

    install_rust() { container_record_install_call install_rust "$@"; present cargo; }
    activate_cargo() { return 0; }
    install_go() { container_record_install_call install_go "$@"; present go; }
    install_node() { container_record_install_call install_node "$@"; present node; }
    activate_nvm() { return 0; }
    install_uv() { container_record_install_call install_uv "$@"; present uv; }
    install_cargo_tool() {
        container_record_install_call install_cargo_tool "$@"
        present "$2"
    }
    install_glow() { container_record_install_call install_glow "$@"; present glow; }
    install_codex() { container_record_install_call install_codex "$@"; present codex; }
    install_sqlit() { container_record_install_call install_sqlit "$@"; present sqlit; }
    install_claude() { container_record_install_call install_claude "$@"; present claude; }
    configure_claude_mcp_servers() {
        container_record_install_call configure_claude_mcp_servers "$@"
        present "Claude user MCP definitions"
    }
    install_starship() { container_record_install_call install_starship "$@"; present starship; }
    install_zoxide() { container_record_install_call install_zoxide "$@"; present zoxide; }
    install_release_binary() {
        container_record_install_call install_release_binary "$@"
        present "$2"
    }
    install_herdr() {
        container_record_install_call install_herdr "$@"
        present herdr
    }
    seed_secrets() {
        container_record_install_call seed_secrets "$@"
        present "container secret fixture"
    }
    install_tmux_plugins() {
        container_record_install_call install_tmux_plugins "$@"
        present "TPM and Catppuccin"
    }
    install_compute_skills() {
        container_record_install_call install_compute_skills "$@"
        present compute-ai-skills
    }
    validate_required_commands() {
        info "container smoke validation"
        [[ "$expected_main_failure" == 0 ]] || \
            fail "intentional container worker failure"
    }

    download_github_asset() {
        export RELEASE_TAG=v0.11.2
        export RELEASE_ARCHIVE="$HOME/fake-${1//\//-}.tar.gz"
    }
    extract_archive() {
        local archive="$1" destination="$2" configure
        case "$archive" in
            *tmux-tmux*)
                configure="$destination/tmux-fixture/configure"
                mkdir -p "${configure%/*}" || return 1
                printf '%s\n' \
                    '#!/usr/bin/env bash' \
                    'printf "tmux-configure" >> "$CONTAINER_FALLBACK_LOG"' \
                    'printf " %q" "$@" >> "$CONTAINER_FALLBACK_LOG"' \
                    'printf "\\n" >> "$CONTAINER_FALLBACK_LOG"' \
                    > "$configure" || return 1
                chmod 0755 "$configure"
                ;;
            *neovim-neovim*)
                mkdir -p "$destination/nvim-linux-x86_64/bin" || return 1
                printf '%s\n' '#!/usr/bin/env bash' 'exit 1' \
                    > "$destination/nvim-linux-x86_64/bin/nvim" || return 1
                chmod 0755 "$destination/nvim-linux-x86_64/bin/nvim"
                ;;
            *) return 1 ;;
        esac
    }
    install_neovim_from_source() {
        local tag="$1" target="$2"
        printf 'neovim-source tag=%s CMAKE_INSTALL_PREFIX=%s\n' \
            "$tag" "$target" >> "$CONTAINER_FALLBACK_LOG"
        mkdir -p "$target/bin" || return 1
        printf '%s\n' '#!/usr/bin/env bash' \
            '[[ "${1:-}" == --version ]] && printf "NVIM v0.11.2\\n"' \
            > "$target/bin/nvim" || return 1
        chmod 0755 "$target/bin/nvim"
    }
    install_tmux() {
        container_record_install_call install_tmux "$@"
        if [[ "$fallback_enabled" == 1 ]]; then
            container_original_install_tmux
        else
            present tmux
        fi
    }
    install_neovim() {
        container_record_install_call install_neovim "$@"
        if [[ "$fallback_enabled" == 1 ]]; then
            container_original_install_neovim
        else
            present nvim
        fi
    }

    main || main_status=$?
    (( main_status == 0 )) || return "$main_status"
    if [[ "$expected_main_failure" == 1 ]]; then
        printf 'container worker continued after failed main\n' >&2
        return 98
    fi
    require_equal "container uses the expected platform ID" \
        "$CONTAINER_EXPECTED_ID" "$PLATFORM_ID" || return 1
    require_equal "container uses the expected platform family" \
        "$CONTAINER_EXPECTED_FAMILY" "$PLATFORM_FAMILY" || return 1
    if [[ "$CONTAINER_EXPECTED_VERSION" == floating ]]; then
        require_equal "container uses the expected RHEL major" \
            "$CONTAINER_EXPECTED_MAJOR" "$RHEL_MAJOR" || return 1
    else
        require_equal "container uses the declared exact VERSION_ID" \
            "$CONTAINER_EXPECTED_VERSION" "$PLATFORM_VERSION" || return 1
    fi

    require_equal "yazi is installed from its required Cargo crate" 1 \
        "$(grep -c '^install_cargo_tool yazi-fm yazi$' "$CONTAINER_INSTALL_CALL_LOG")" || return 1
    require_equal "ya is installed from its required Cargo crate" 1 \
        "$(grep -c '^install_cargo_tool yazi-cli ya$' "$CONTAINER_INSTALL_CALL_LOG")" || return 1
    require_equal "the container main inventory invokes Herdr installation once" 1 \
        "$(grep -c '^install_herdr$' "$CONTAINER_INSTALL_CALL_LOG")" || return 1

    mkdir -p "$HOME/.tmux/plugins/tmux" "$HOME/.codex" || return 1
    : > "$HOME/.tmux/plugins/tmux/catppuccin.tmux" || return 1
    ln -sfn "$HOME/container-hooks.json" "$HOME/.codex/hooks.json" || return 1
    cp "$REPOSITORY_ROOT/claude/mcp-servers.json" "$HOME/.claude.json" || return 1
    VALIDATION_HAVE_LOG="$HOME/current-validation-have.log"
    export VALIDATION_HAVE_LOG
    have() {
        printf '%s\n' "$1" >> "$VALIDATION_HAVE_LOG"
        [[ "$1" != "${VALIDATION_MISSING:-}" ]]
    }
    tmux_version() { printf '3.2\n'; }
    nvim_version() { printf '0.11.2\n'; }
    binary_version_works() { return 0; }
    claude_mcp_state_is_exact() { return 0; }
    herdr_hook_is_valid() { return 0; }
    claude_herdr_session_start_is_exact() { return 0; }
    codex_herdr_session_start_is_exact() { return 0; }

    : > "$VALIDATION_HAVE_LOG"
    FAILURES=()
    unset VALIDATION_MISSING
    container_original_validate_required_commands
    require_equal "real required-command validation accepts the complete inventory" 0 \
        "${#FAILURES[@]}" || return 1
    require_equal "real validation checks the exact mandatory command inventory" \
        "$(container_expected_validation_have_log)" \
        "$(< "$VALIDATION_HAVE_LOG")" || return 1
    for VALIDATION_MISSING in yazi ya herdr; do
        : > "$VALIDATION_HAVE_LOG"
        FAILURES=()
        container_original_validate_required_commands >/dev/null 2>&1
        require_equal "each controlled executable is independently mandatory" 1 \
            "${#FAILURES[@]}" || return 1
        require_equal "the controlled missing command is reported exactly" \
            "required command missing: $VALIDATION_MISSING" "${FAILURES[0]}" || return 1
    done
    unset VALIDATION_MISSING

    container_inner_expected_sudo_log "$expected_sudo" || return 1
    tail -n "+$((sudo_line_count + 1))" "$SUDO_COMMAND_LOG" > "$current_sudo" || return 1
    require_equal "container records the exact distro package flow" \
        "$(file_sha256 "$expected_sudo")" "$(file_sha256 "$current_sudo")" || return 1
    require "container never executes a direct package, network, or checkout command" \
        test ! -s "$BLOCKED_COMMAND_LOG" || return 1

    if [[ "$fallback_enabled" == 1 ]]; then
        require_equal "only Rocky 8 enables the fallback exercise" rocky \
            "$CONTAINER_EXPECTED_ID" || return 1
        require_equal "only Rocky 8 has major version 8" 8 \
            "$CONTAINER_EXPECTED_MAJOR" || return 1
        require_equal "Rocky 8 uses the production tmux configure lookup shape" 1 \
            "$(grep -Ec '^find /tmp/dotfiles-install\.[^/]+/extract -mindepth 2 -maxdepth 2 -type f -name configure -print$' \
                "$CONTAINER_FALLBACK_LOG")" || return 1
        require "Rocky 8 exercises the tmux configure fallback" \
            grep -Fq -- "tmux-configure --prefix=$HOME/.local" \
            "$CONTAINER_FALLBACK_LOG" || return 1
        require "Rocky 8 exercises tmux make install" \
            grep -Fq -- 'make install' "$CONTAINER_FALLBACK_LOG" || return 1
        require "Rocky 8 rejects the staged Neovim binary and uses source fallback" \
            grep -Fq -- \
                "neovim-source tag=v0.11.2 CMAKE_INSTALL_PREFIX=$HOME/.local/opt/nvim-v0.11.2" \
                "$CONTAINER_FALLBACK_LOG" || return 1
        fallback_hash="$(sha256sum "$CONTAINER_FALLBACK_LOG" | awk '{print $1}')" || return 1
        if (( run_number == 1 )); then
            printf '%s\n' "$fallback_hash" > "$HOME/rocky8-fallback.sha256"
        else
            require_equal "the second Rocky 8 run reuses installed fallbacks" \
                "$(< "$HOME/rocky8-fallback.sha256")" "$fallback_hash" || return 1
        fi
    else
        require "non-Rocky-8 images do not exercise fallback fixtures" \
            test ! -s "$CONTAINER_FALLBACK_LOG" || return 1
    fi

    printf '%s\n' "$run_number" > "$HOME/container-run-count"
    printf 'container smoke %s run %d passed\n' "$CONTAINER_EXPECTED_ID" "$run_number"
}

stage_container_path() {
    local destination="$1" path="$2" source_path target_path
    case "$path" in
        .claude.json|secrets.env|secrets|secrets/*|.git|.git/*)
            printf 'refusing forbidden container checkout path: %s\n' "$path" >&2
            return 1
            ;;
        ''|/*|..|../*|*/..|*/../*)
            printf 'refusing unsafe container checkout path: %s\n' "$path" >&2
            return 1
            ;;
    esac
    source_path="$REPOSITORY_ROOT/$path"
    [[ -f "$source_path" || -L "$source_path" ]] || return 0
    target_path="$destination/$path"
    mkdir -p "${target_path%/*}" || return 1
    cp -a -- "$source_path" "$target_path"
}

stage_container_checkout() {
    local destination="$1" path
    local -a untracked_feature_allowlist=(
        tests/install_test.sh
        claude/hooks/herdr-agent-state.sh
        config/herdr/config.toml
    )
    mkdir -p "$destination" || return 1
    while IFS= read -r -d '' path; do
        stage_container_path "$destination" "$path" || return 1
    done < <(git -C "$REPOSITORY_ROOT" ls-files -z --cached)
    for path in "${untracked_feature_allowlist[@]}"; do
        stage_container_path "$destination" "$path" || return 1
    done
    find "$destination" -type d -exec chmod 0755 {} + || return 1
    [[ -x "$destination/install.sh" && -x "$destination/tests/install_test.sh" ]] || return 1
    [[ ! -e "$destination/.git" && ! -e "$destination/.claude.json" &&
       ! -e "$destination/secrets.env" && ! -e "$destination/secrets" ]]
}

select_container_engine() {
    local docker_path podman_path context endpoint
    CONTAINER_ENGINE_CMD=()
    CONTAINER_ENGINE_KIND=""

    docker_path="$(command -v docker 2>/dev/null || true)"
    if [[ -n "$docker_path" ]]; then
        if [[ -n "${DOCKER_HOST:-}" ]]; then
            endpoint="$DOCKER_HOST"
        else
            context="${DOCKER_CONTEXT:-}"
            if [[ -z "$context" ]]; then
                context="$($docker_path context show 2>/dev/null)" || context=""
            fi
            if [[ -n "$context" ]]; then
                endpoint="$($docker_path context inspect \
                    --format '{{ .Endpoints.docker.Host }}' "$context" 2>/dev/null)" || endpoint=""
            else
                endpoint=""
            fi
        fi
        case "$endpoint" in
            unix:///*) ;;
            '') ;;
            *)
                printf 'refusing remote Docker endpoint: %s\n' "$endpoint" >&2
                return 1
                ;;
        esac
        if [[ -n "$endpoint" ]]; then
            CONTAINER_ENGINE_CMD=(
                env -u DOCKER_CONTEXT -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH
                "DOCKER_HOST=$endpoint" "$docker_path"
            )
            if container_engine info >/dev/null 2>&1; then
                CONTAINER_ENGINE_KIND=docker
                return 0
            fi
            CONTAINER_ENGINE_CMD=()
        fi
    fi

    if [[ -n "${CONTAINER_HOST:-}" || -n "${CONTAINER_CONNECTION:-}" ||
          -n "${PODMAN_CONNECTIONS_CONF:-}" ]]; then
        printf 'refusing configured remote Podman connection\n' >&2
        return 1
    fi
    podman_path="$(command -v podman 2>/dev/null || true)"
    if [[ -n "$podman_path" ]]; then
        CONTAINER_ENGINE_CMD=("$podman_path" --remote=false)
        if container_engine info >/dev/null 2>&1; then
            CONTAINER_ENGINE_KIND=podman
            return 0
        fi
        CONTAINER_ENGINE_CMD=()
    fi
    printf 'container smoke requires a working docker or podman engine\n' >&2
    return 1
}

container_exit_code() {
    local name="$1" value
    value="$(container_engine inspect --type container \
        --format '{{ .State.ExitCode }}' "$name" 2>/dev/null)" || return 1
    [[ "$value" =~ ^[0-9]+$ && "$value" -le 255 ]] || return 1
    printf '%s\n' "$value"
}

dispatch_container_worker_failure() {
    local container_root checkout boundary_token container_name
    local queue_index start_status=0 worker_status
    select_container_engine || return 1
    if ! container_engine image inspect ubuntu:24.04 >/dev/null 2>&1; then
        printf 'required container image is unavailable locally: ubuntu:24.04\n' >&2
        return 1
    fi
    container_root="$(mktemp -d /tmp/dotfiles-container-test.XXXXXX)" || return 1
    CONTAINER_TEMP_ROOTS+=("$container_root")
    checkout="$container_root/worker-failure/checkout"
    boundary_token="$(
        printf '%s\n' "$container_root|worker-failure|ubuntu:24.04" |
            sha256sum | awk '{print $1}'
    )" || return 1
    [[ "$boundary_token" =~ ^[0-9a-f]{64}$ ]] || return 1
    container_name="dotfiles-install-test-worker-${boundary_token:0:16}"
    container_name_is_available "$container_name" || return 1
    stage_container_checkout "$checkout" || return 1
    printf '%s\n' "$boundary_token" > "$checkout/.container-smoke-boundary" || return 1
    chmod 0444 "$checkout/.container-smoke-boundary" || return 1
    prepare_owned_container "$container_name" "$boundary_token" "$checkout" \
            --user 65532:65532 \
            --env HOME=/tmp/dotfiles-home \
            --env DOTFILES_CONTAINER_INNER=1 \
            --env "DOTFILES_CONTAINER_TOKEN=$boundary_token" \
            --env CONTAINER_EXPECTED_IMAGE=ubuntu:24.04 \
            --env CONTAINER_EXPECTED_ID=ubuntu \
            --env CONTAINER_EXPECTED_VERSION=24.04 \
            --env CONTAINER_EXPECTED_MAJOR=24 \
            --env CONTAINER_EXPECTED_FAMILY=debian \
            --env CONTAINER_EXPECTED_FALLBACK=0 \
            --env CONTAINER_EXPECTED_MAIN_FAILURE=1 \
            ubuntu:24.04 /tmp/dotfiles/tests/install_test.sh || return 1
    queue_index="$CONTAINER_ACTIVE_QUEUE_INDEX"
    CONTAINER_FAILURE_OUTPUT="$container_root/worker-failure/output.log"
    start_owned_container_attached "$queue_index" "$CONTAINER_FAILURE_OUTPUT" || start_status=$?
    worker_status="$(container_exit_code "$container_name")" || {
        cleanup_owned_container "$queue_index" || true
        return 1
    }
    cleanup_owned_container "$queue_index" || return 1
    if (( worker_status != 0 )); then
        return "$worker_status"
    fi
    (( start_status == 0 )) || return "$start_status"
}

verify_container_worker_failure() {
    local status=0
    dispatch_container_worker_failure || status=$?
    if (( status != 1 )) && [[ -f "$CONTAINER_FAILURE_OUTPUT" ]]; then
        sed -n '1,160p' "$CONTAINER_FAILURE_OUTPUT" >&2
    fi
    require_equal "failed container worker status reaches the host dispatcher" \
        1 "$status" || return 1
    require "failed container worker reports the injected main failure" \
        grep -Fq -- 'FAIL: intentional container worker failure' \
        "$CONTAINER_FAILURE_OUTPUT" || return 1
    require "failed container worker stops before post-main assertions" \
        test -z "$(grep -F 'container worker continued after failed main' \
            "$CONTAINER_FAILURE_OUTPUT" || true)" || return 1
    require "failed container worker never reports a smoke pass" \
        test -z "$(grep -F 'container smoke ubuntu run' \
            "$CONTAINER_FAILURE_OUTPUT" || true)" || return 1
    printf 'container worker failure propagation passed\n'
}

run_root_preflight_container() {
    local image="$1" container_root="$2" checkout boundary_token container_name
    local queue_index output
    checkout="$container_root/root-preflight/checkout"
    boundary_token="$(
        printf '%s\n' "$container_root|root-preflight|$image" | sha256sum | awk '{print $1}'
    )" || return 1
    [[ "$boundary_token" =~ ^[0-9a-f]{64}$ ]] || return 1
    container_name="dotfiles-install-test-root-${boundary_token:0:16}"
    container_name_is_available "$container_name" || return 1
    stage_container_checkout "$checkout" || return 1
    prepare_owned_container "$container_name" "$boundary_token" "$checkout" \
            --user 0:0 \
            --env HOME=/tmp/root-preflight-home \
            "$image" bash -c '
                /tmp/dotfiles/install.sh
                status=$?
                if [[ "$status" -ne 2 || -e "$HOME/.local" ]]; then
                    printf "root preflight contract failed: status=%s\n" "$status" >&2
                    exit 91
                fi
                printf "root preflight rejected before HOME mutation\n"
            ' || return 1
    queue_index="$CONTAINER_ACTIVE_QUEUE_INDEX"
    output="$container_root/root-preflight/output.log"
    if ! start_owned_container_attached "$queue_index" "$output"; then
        cleanup_owned_container "$queue_index" || true
        return 1
    fi
    require "root container rejects the installer before HOME mutation" \
        grep -Fq -- 'root preflight rejected before HOME mutation' "$output" || {
            cleanup_owned_container "$queue_index" || true
            return 1
        }
    require "root container reports the non-root requirement" \
        grep -Fq -- 'run this installer as a normal user, not root or sudo' "$output" || {
            cleanup_owned_container "$queue_index" || true
            return 1
        }
    cleanup_owned_container "$queue_index"
}

run_container_matrix() {
    local verify_root_preflight="${1:-0}"
    local container_root row image expected_id expected_version expected_major
    local expected_family fallback
    local checkout run_index safe_name boundary_token container_queue_index container_name
    local -a rows=()
    select_container_engine || return 1
    mapfile -t rows < <(container_matrix)
    for row in "${rows[@]}"; do
        IFS='|' read -r image expected_id expected_version expected_major \
            expected_family fallback <<< "$row"
        if ! container_engine image inspect "$image" >/dev/null 2>&1; then
            printf 'required container image is unavailable locally: %s\n' "$image" >&2
            printf 'preload all four matrix images; this harness never pulls implicitly\n' >&2
            return 1
        fi
    done

    container_root="$(mktemp -d /tmp/dotfiles-container-test.XXXXXX)" || return 1
    CONTAINER_TEMP_ROOTS+=("$container_root")
    if [[ "$verify_root_preflight" == 1 ]]; then
        run_root_preflight_container ubuntu:24.04 "$container_root" || return 1
    fi
    for row in "${rows[@]}"; do
        IFS='|' read -r image expected_id expected_version expected_major \
            expected_family fallback <<< "$row"
        safe_name="${image//[:\/]/-}"
        checkout="$container_root/$safe_name/checkout"
        boundary_token="$(
            printf '%s\n' "$container_root|$row" | sha256sum | awk '{print $1}'
        )" || return 1
        [[ "$boundary_token" =~ ^[0-9a-f]{64}$ ]] || return 1
        container_name="dotfiles-install-test-${safe_name}-${boundary_token:0:16}"
        [[ "$container_name" =~ ^[[:alnum:]][[:alnum:]_.-]*$ ]] || return 1
        container_name_is_available "$container_name" || return 1
        stage_container_checkout "$checkout" || return 1
        printf '%s\n' "$boundary_token" > "$checkout/.container-smoke-boundary" || return 1
        chmod 0444 "$checkout/.container-smoke-boundary" || return 1
        printf 'container smoke: %s\n' "$image"
        prepare_owned_container "$container_name" "$boundary_token" "$checkout" \
                --user 65532:65532 \
                --env HOME=/tmp/dotfiles-home \
                --env DOTFILES_CONTAINER_INNER=1 \
                --env "DOTFILES_CONTAINER_TOKEN=$boundary_token" \
                --env "CONTAINER_EXPECTED_IMAGE=$image" \
                --env "CONTAINER_EXPECTED_ID=$expected_id" \
                --env "CONTAINER_EXPECTED_VERSION=$expected_version" \
                --env "CONTAINER_EXPECTED_MAJOR=$expected_major" \
                --env "CONTAINER_EXPECTED_FAMILY=$expected_family" \
                --env "CONTAINER_EXPECTED_FALLBACK=$fallback" \
                "$image" /tmp/dotfiles/tests/install_test.sh || return 1
        container_queue_index="$CONTAINER_ACTIVE_QUEUE_INDEX"
        for run_index in 1 2; do
            printf '  installer run %d/2\n' "$run_index"
            start_owned_container_attached "$container_queue_index" || {
                cleanup_owned_container "$container_queue_index" || true
                return 1
            }
        done
        cleanup_owned_container "$container_queue_index" || return 1
    done
}

test_forged_container_inner_is_rejected_before_mutation() {
    local root forged_home output before after status=0
    root="$(mktemp -d /tmp/dotfiles-container-test.XXXXXX)" || return 1
    CONTAINER_TEMP_ROOTS+=("$root")
    forged_home="$root/forged-home"
    output="$root/forged-inner.log"
    mkdir -p "$forged_home" || return 1
    printf 'preserve-me\n' > "$forged_home/sentinel" || return 1
    before="$(find "$forged_home" -mindepth 1 -printf '%P:%y:%s\n' | sort)"

    env -i \
        HOME="$forged_home" \
        PATH=/usr/bin:/bin \
        LANG=C \
        LC_ALL=C \
        DOTFILES_CONTAINER_INNER=1 \
        DOTFILES_CONTAINER_TOKEN=0000000000000000000000000000000000000000000000000000000000000000 \
        CONTAINER_EXPECTED_IMAGE=ubuntu:24.04 \
        CONTAINER_EXPECTED_ID=ubuntu \
        CONTAINER_EXPECTED_VERSION=24.04 \
        CONTAINER_EXPECTED_MAJOR=24 \
        CONTAINER_EXPECTED_FAMILY=debian \
        CONTAINER_EXPECTED_FALLBACK=0 \
        bash "$SCRIPT_PATH" > "$output" 2>&1 || status=$?

    require "forged container-inner mode is rejected" test "$status" -ne 0 || return 1
    require "container-inner rejection identifies its boundary failure" \
        grep -Fq 'container-inner boundary validation failed' "$output" || return 1
    after="$(find "$forged_home" -mindepth 1 -printf '%P:%y:%s\n' | sort)"
    require_equal "forged container-inner mode does not mutate an arbitrary HOME" \
        "$before" "$after" || return 1
    require "forged container-inner mode never creates its command directory" \
        test ! -e "$forged_home/container-bin" || return 1
}

test_staging_rejects_forbidden_paths_before_source_read() {
    local root forbidden_path repository destination source_path poison_marker output status
    local git_log restrictive_destination
    local index=0
    local -a forbidden_paths=(
        .claude.json
        secrets.env
        secrets/nested/token
        .git/config
    )
    root="$(mktemp -d /tmp/dotfiles-container-test.XXXXXX)" || return 1
    CONTAINER_TEMP_ROOTS+=("$root")
    for forbidden_path in "${forbidden_paths[@]}"; do
        index=$((index + 1))
        repository="$root/repository-$index"
        destination="$root/destination-$index"
        poison_marker="$root/poison-read-$index"
        output="$root/stage-$index.log"
        source_path="$repository/$forbidden_path"
        mkdir -p "${source_path%/*}" || return 1
        printf 'must-not-be-read\n' > "$source_path" || return 1
        printf 'safe\n' > "$repository/safe.txt" || return 1
        status=0
        (
            REPOSITORY_ROOT="$repository"
            git() { printf '%s\0%s\0' "$forbidden_path" safe.txt; }
            cp() {
                printf 'poison source was copied\n' > "$poison_marker"
                return 99
            }
            stage_container_checkout "$destination"
        ) > "$output" 2>&1 || status=$?
        require "forbidden Git path is rejected" test "$status" -ne 0 || return 1
        require "forbidden Git path is named without reading its source" \
            grep -Fq -- "refusing forbidden container checkout path: $forbidden_path" \
            "$output" || return 1
        require "forbidden source is rejected before copy can read it" \
            test ! -e "$poison_marker" || return 1
        require "staging stops before later safe paths are copied" \
            test -z "$(find "$destination" -mindepth 1 -print -quit)" || return 1
    done

    repository="$root/allowlisted-repository"
    destination="$root/allowlisted-destination"
    git_log="$root/staging-git.log"
    mkdir -p "$repository/tests" "$repository/secrets" || return 1
    printf '#!/usr/bin/env bash\n' > "$repository/install.sh" || return 1
    printf '#!/usr/bin/env bash\n' > "$repository/tests/install_test.sh" || return 1
    chmod 0755 "$repository/install.sh" "$repository/tests/install_test.sh" || return 1
    printf 'tracked\n' > "$repository/tracked.txt" || return 1
    printf 'unrelated\n' > "$repository/unrelated-untracked.txt" || return 1
    printf 'secret\n' > "$repository/.claude.json" || return 1
    printf 'secret\n' > "$repository/secrets.env" || return 1
    printf 'secret\n' > "$repository/secrets/token" || return 1
    : > "$git_log"
    (
        REPOSITORY_ROOT="$repository"
        git() {
            printf '%q ' "$@" >> "$git_log"
            printf '\n' >> "$git_log"
            [[ "$*" == *'ls-files -z --cached'* ]] || return 98
            printf '%s\0%s\0' install.sh tracked.txt
        }
        stage_container_checkout "$destination"
    ) || return 1
    require "tracked checkout files are staged" \
        test -f "$destination/tracked.txt" || return 1
    require "the explicit untracked feature input is staged" \
        test -x "$destination/tests/install_test.sh" || return 1
    require "unrelated untracked files are excluded" \
        test ! -e "$destination/unrelated-untracked.txt" || return 1
    require "untracked Claude state is excluded" \
        test ! -e "$destination/.claude.json" || return 1
    require "untracked secret files are excluded" \
        test ! -e "$destination/secrets.env" && \
        test ! -e "$destination/secrets" || return 1
    require "staging never enumerates every untracked file" \
        test -z "$(grep -- '--others' "$git_log" || true)" || return 1

    restrictive_destination="$root/restrictive-umask-destination"
    (
        umask 0077
        REPOSITORY_ROOT="$repository"
        git() {
            [[ "$*" == *'ls-files -z --cached'* ]] || return 98
            printf '%s\0%s\0' install.sh tracked.txt
        }
        stage_container_checkout "$restrictive_destination"
    ) || return 1
    require_equal "restrictive-umask staging normalizes the checkout root" 755 \
        "$(stat -c '%a' "$restrictive_destination")" || return 1
    require "restrictive-umask staging makes every directory container-traversable" \
        test -z "$(find "$restrictive_destination" -type d ! -perm 0755 \
            -print -quit)" || return 1
    require "restrictive-umask staging preserves executable entrypoints" \
        test -x "$restrictive_destination/install.sh" && \
        test -x "$restrictive_destination/tests/install_test.sh" || return 1
}

test_container_dispatch_without_host_mutation() {
    local root fake_engine log timeout_log bad_log collision_log failed_log wrong_label_log worker_log
    local state_dir original_select original_stage queue_index
    local status=0 timeout_status=0 bad_status=0 collision_status=0 failed_status=0
    local wrong_label_status=0 worker_status=0 line name worker_name timeout_name
    local -a created_names=()
    root="$(mktemp -d /tmp/dotfiles-container-test.XXXXXX)" || return 1
    CONTAINER_TEMP_ROOTS+=("$root")
    fake_engine="$root/fake-engine"
    log="$root/engine.log"
    timeout_log="$root/timeout-engine.log"
    bad_log="$root/bad-engine.log"
    collision_log="$root/collision-engine.log"
    failed_log="$root/failed-create-engine.log"
    wrong_label_log="$root/wrong-label-engine.log"
    worker_log="$root/worker-failure-engine.log"
    state_dir="$root/engine-state"
    mkdir -p "$state_dir" || return 1
    : > "$log"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -u' \
        'command_name="${1:-}"' \
        'printf "%q" "$command_name" >> "$FAKE_ENGINE_LOG"' \
        '(( $# == 0 )) || shift' \
        'printf " %q" "$@" >> "$FAKE_ENGINE_LOG"' \
        'printf "\\n" >> "$FAKE_ENGINE_LOG"' \
        'case "$command_name" in' \
        '  image) exit 0 ;;' \
        '  inspect)' \
        '    format=0; format_value=""; name=""' \
        '    while (( $# > 0 )); do' \
        '      case "$1" in' \
        '        --format) format=1; format_value="$2"; shift 2 ;;' \
        '        --type) shift 2 ;;' \
        '        *) name="$1"; shift ;;' \
        '      esac' \
        '    done' \
        '    [[ -n "$name" ]] || exit 2' \
        '    if (( ! format )) && [[ "${FAKE_ENGINE_COLLISION:-0}" == 1 ]]; then exit 0; fi' \
        '    [[ -f "$FAKE_ENGINE_STATE/$name" ]] || exit 1' \
        '    if (( format )); then' \
        '      case "$format_value" in' \
        '        *State.ExitCode*) sed -n "2p" "$FAKE_ENGINE_STATE/$name" ;;' \
        '        *) sed -n "1p" "$FAKE_ENGINE_STATE/$name" ;;' \
        '      esac' \
        '    fi' \
        '    ;;' \
        '  create)' \
        '    name=""; label=""' \
        '    while (( $# > 0 )); do' \
        '      case "$1" in' \
        '        --name) name="$2"; shift 2 ;;' \
        '        --label) label="${2#*=}"; shift 2 ;;' \
        '        --env|--user|--security-opt) shift 2 ;;' \
        '        --pull=*|--network=*|--cap-drop=*) shift ;;' \
        '        *) shift ;;' \
        '      esac' \
        '    done' \
        '    [[ -n "$name" && "$label" =~ ^[0-9a-f]{64}$ ]] || exit 3' \
        '    [[ "${FAKE_ENGINE_WRONG_LABEL:-0}" == 1 ]] && label=not-owned' \
        '    printf "%s\\n0\\n" "$label" > "$FAKE_ENGINE_STATE/$name"' \
        '    printf "%s\\n" "${FAKE_ENGINE_CREATE_OUTPUT:-fake-id}"' \
        '    exit "${FAKE_ENGINE_CREATE_STATUS:-0}"' \
        '    ;;' \
        '  start)' \
        '    name="${*: -1}"' \
        '    [[ -f "$FAKE_ENGINE_STATE/$name" ]] || exit 4' \
        '    [[ "${FAKE_ENGINE_START_DELAY:-0}" == 0 ]] || sleep "$FAKE_ENGINE_START_DELAY"' \
        '    label="$(sed -n "1p" "$FAKE_ENGINE_STATE/$name")"' \
        '    printf "%s\\n%s\\n" "$label" "${FAKE_ENGINE_WORKER_STATUS:-0}" > "$FAKE_ENGINE_STATE/$name"' \
        '    exit "${FAKE_ENGINE_START_STATUS:-0}"' \
        '    ;;' \
        '  rm)' \
        '    name="${*: -1}"' \
        '    rm -f -- "$FAKE_ENGINE_STATE/$name"' \
        '    ;;' \
        'esac' \
        > "$fake_engine" || return 1
    chmod 0755 "$fake_engine" || return 1
    export FAKE_ENGINE_LOG="$log" FAKE_ENGINE_STATE="$state_dir"

    original_select="$(declare -f select_container_engine)"
    original_stage="$(declare -f stage_container_checkout)"
    select_container_engine() {
        CONTAINER_ENGINE_CMD=("$fake_engine")
        CONTAINER_ENGINE_KIND=fake
    }
    stage_container_checkout() {
        local destination="$1"
        printf 'stage %s\n' "$destination" >> "$FAKE_ENGINE_LOG"
        mkdir -p "$destination/tests" || return 1
        printf '#!/usr/bin/env bash\n' > "$destination/install.sh" || return 1
        printf '#!/usr/bin/env bash\n' > "$destination/tests/install_test.sh" || return 1
        chmod 0755 "$destination/install.sh" "$destination/tests/install_test.sh"
    }
    run_container_matrix >/dev/null 2>&1 || status=$?
    if (( status == 0 )); then
        : > "$timeout_log"
        FAKE_ENGINE_LOG="$timeout_log"
        FAKE_ENGINE_START_DELAY=5
        CONTAINER_ATTACH_TIMEOUT_SECONDS=1
        export FAKE_ENGINE_LOG FAKE_ENGINE_START_DELAY CONTAINER_ATTACH_TIMEOUT_SECONDS
        run_container_matrix >/dev/null 2>&1 || timeout_status=$?
        unset FAKE_ENGINE_START_DELAY CONTAINER_ATTACH_TIMEOUT_SECONDS
    fi
    if (( status == 0 && timeout_status != 0 )); then
        : > "$bad_log"
        FAKE_ENGINE_LOG="$bad_log"
        FAKE_ENGINE_CREATE_OUTPUT='malformed output'
        export FAKE_ENGINE_LOG FAKE_ENGINE_CREATE_OUTPUT
        run_container_matrix >/dev/null 2>&1 || bad_status=$?
        unset FAKE_ENGINE_CREATE_OUTPUT
    fi
    if (( status == 0 && bad_status != 0 )); then
        : > "$collision_log"
        FAKE_ENGINE_LOG="$collision_log"
        FAKE_ENGINE_COLLISION=1
        export FAKE_ENGINE_LOG FAKE_ENGINE_COLLISION
        run_container_matrix >/dev/null 2>&1 || collision_status=$?
        unset FAKE_ENGINE_COLLISION
    fi
    if (( status == 0 && collision_status != 0 )); then
        : > "$failed_log"
        FAKE_ENGINE_LOG="$failed_log"
        FAKE_ENGINE_CREATE_STATUS=75
        export FAKE_ENGINE_LOG FAKE_ENGINE_CREATE_STATUS
        run_container_matrix >/dev/null 2>&1 || failed_status=$?
        unset FAKE_ENGINE_CREATE_STATUS
    fi
    if (( status == 0 && failed_status != 0 )); then
        : > "$wrong_label_log"
        FAKE_ENGINE_LOG="$wrong_label_log"
        FAKE_ENGINE_CREATE_STATUS=76
        FAKE_ENGINE_WRONG_LABEL=1
        export FAKE_ENGINE_LOG FAKE_ENGINE_CREATE_STATUS FAKE_ENGINE_WRONG_LABEL
        run_container_matrix >/dev/null 2>&1 || wrong_label_status=$?
        unset FAKE_ENGINE_CREATE_STATUS FAKE_ENGINE_WRONG_LABEL
    fi
    if (( status == 0 && wrong_label_status != 0 )); then
        : > "$worker_log"
        FAKE_ENGINE_LOG="$worker_log"
        FAKE_ENGINE_WORKER_STATUS=1
        export FAKE_ENGINE_LOG FAKE_ENGINE_WORKER_STATUS
        dispatch_container_worker_failure >/dev/null 2>&1 || worker_status=$?
        unset FAKE_ENGINE_WORKER_STATUS
    fi
    eval "$original_select"
    eval "$original_stage"
    (( status == 0 )) || return "$status"
    require "attached worker timeout is reported" \
        test "$timeout_status" -ne 0 || return 1
    require "malformed create output is rejected" \
        test "$bad_status" -ne 0 || return 1
    require "pre-existing name collision is rejected" \
        test "$collision_status" -ne 0 || return 1
    require "interrupted create is reported" \
        test "$failed_status" -ne 0 || return 1
    require "wrong-label cleanup is refused" \
        test "$wrong_label_status" -ne 0 || return 1
    require_equal "failed worker status propagates through the host dispatcher" \
        1 "$worker_status" || return 1

    require_equal "container dispatch inspects four local images" 4 \
        "$(grep -c '^image inspect ' "$log")" || return 1
    require_equal "container dispatch creates four isolated containers" 4 \
        "$(grep -c '^create ' "$log")" || return 1
    require_equal "container dispatch copies four checkouts" 4 \
        "$(grep -c '^cp ' "$log")" || return 1
    require_equal "container dispatch starts each container twice" 8 \
        "$(grep -c '^start -a ' "$log")" || return 1
    require_equal "container dispatch removes the four owned names" 4 \
        "$(grep -c '^rm -f -- dotfiles-install-test-' "$log")" || return 1
    require_equal "Rocky 8 alone enables fallback coverage" 1 \
        "$(grep -c 'CONTAINER_EXPECTED_FALLBACK=1' "$log")" || return 1
    require_equal "every container receives declared version metadata" 4 \
        "$(grep -c 'CONTAINER_EXPECTED_VERSION=' "$log")" || return 1
    require_equal "Ubuntu receives its exact declared version" 1 \
        "$(grep -c 'CONTAINER_EXPECTED_VERSION=24.04' "$log")" || return 1
    require_equal "Debian receives its exact declared version" 1 \
        "$(grep -c 'CONTAINER_EXPECTED_VERSION=12' "$log")" || return 1
    require_equal "floating Rocky tags receive major-only version metadata" 2 \
        "$(grep -c 'CONTAINER_EXPECTED_VERSION=floating' "$log")" || return 1
    require_equal "failed-worker dispatch receives exact Ubuntu version metadata" 1 \
        "$(grep -c 'CONTAINER_EXPECTED_VERSION=24.04' "$worker_log")" || return 1
    mapfile -t created_names < <(
        sed -n 's/^create .* --name \([^ ]*\) .*/\1/p' "$log"
    )
    require_equal "four unique safe container names are preassigned" 4 \
        "$(printf '%s\n' "${created_names[@]}" | sort -u | wc -l)" || return 1
    for name in "${created_names[@]}"; do
        require_equal "each owned name is copied exactly once" 1 \
            "$(grep -c " $name:/tmp/dotfiles$" "$log")" || return 1
        require_equal "each owned name is started exactly twice" 2 \
            "$(grep -c "^start -a $name$" "$log")" || return 1
        require_equal "each owned name is removed exactly once with option termination" 1 \
            "$(grep -c "^rm -f -- $name$" "$log")" || return 1
    done
    while IFS= read -r line; do
        [[ "$line" == *'--pull=never'* &&
           "$line" == *'--network=none'* &&
           "$line" == *'--name dotfiles-install-test-'* &&
           "$line" == *'--label io.dotfiles.install-test.token='* &&
           "$line" == *'--user 65532:65532'* &&
           "$line" == *'--cap-drop=ALL'* &&
           "$line" == *'--security-opt=no-new-privileges'* ]] || {
            printf 'assertion failed: unsafe container create command: %s\n' "$line" >&2
            return 1
        }
    done < <(grep '^create ' "$log")
    require "container dispatch never pulls, builds, or uses docker run" \
        test -z "$(grep -E '^(pull|build|run)( |$)' "$log" || true)" || return 1
    require "container dispatch never bind-mounts the checkout" \
        test -z "$(grep -E '(^| )(-v|--volume|--mount)( |$)' "$log" || true)" || return 1
    require_equal "timed-out dispatch creates one isolated container" 1 \
        "$(grep -c '^create ' "$timeout_log")" || return 1
    require_equal "timed-out dispatch starts only its first worker" 1 \
        "$(grep -c '^start -a ' "$timeout_log")" || return 1
    require_equal "timed-out owned worker is force-cleaned exactly once" 1 \
        "$(grep -c '^rm -f -- dotfiles-install-test-' "$timeout_log")" || return 1
    timeout_name="$(sed -n \
        's/^create .* --name \([^ ]*\) .*/\1/p' "$timeout_log")"
    require "timed-out owned worker state is gone after cleanup" \
        test ! -e "$state_dir/$timeout_name" || return 1
    require_equal "malformed-output dispatch stops after the first create" 1 \
        "$(grep -c '^create ' "$bad_log")" || return 1
    require "malformed create output is never passed to copy or start" \
        test -z "$(grep -E '^(cp|start)( |$)' "$bad_log" || true)" || return 1
    require_equal "owned malformed-output container is cleaned exactly once" 1 \
        "$(grep -c '^rm -f -- dotfiles-install-test-' "$bad_log")" || return 1
    require "pre-existing collision stops before staging, create, copy, or removal" \
        test -z "$(grep -E '^(stage|create|cp|rm)( |$)' "$collision_log" || true)" || return 1
    require_equal "failed create still cleans the owned name exactly once" 1 \
        "$(grep -c '^rm -f -- dotfiles-install-test-' "$failed_log")" || return 1
    require "failed create never reaches copy or start" \
        test -z "$(grep -E '^(cp|start)( |$)' "$failed_log" || true)" || return 1
    require "wrong ownership label prevents container removal" \
        test -z "$(grep '^rm ' "$wrong_label_log" || true)" || return 1
    require_equal "wrong ownership label is inspected once before refusal" 1 \
        "$(grep -c '^inspect --type container --format ' "$wrong_label_log")" || return 1
    require_equal "failed worker creates exactly one isolated container" 1 \
        "$(grep -c '^create ' "$worker_log")" || return 1
    require_equal "failed worker copies exactly one staged checkout" 1 \
        "$(grep -c '^cp ' "$worker_log")" || return 1
    require_equal "failed worker is started exactly once" 1 \
        "$(grep -c '^start -a ' "$worker_log")" || return 1
    require_equal "host inspects the failed worker exit code exactly once" 1 \
        "$(grep -c 'State.ExitCode' "$worker_log")" || return 1
    require_equal "failed worker ownership is checked once before cleanup" 1 \
        "$(grep -c 'Config.Labels' "$worker_log")" || return 1
    require_equal "failed owned worker is removed exactly once" 1 \
        "$(grep -c '^rm -f -- dotfiles-install-test-worker-' "$worker_log")" || return 1
    require_equal "failed worker never dispatches a second create, copy, or start" 3 \
        "$(grep -Ec '^(create|cp|start) ' "$worker_log")" || return 1
    worker_name="$(sed -n \
        's/^create .* --name \([^ ]*\) .*/\1/p' "$worker_log")"
    require "failed owned worker state is gone after cleanup" \
        test ! -e "$state_dir/$worker_name" || return 1
    for queue_index in "${!CONTAINER_NAMES[@]}"; do
        if [[ -n "${CONTAINER_NAMES[queue_index]}" ]]; then
            CONTAINER_NAMES[queue_index]=""
            CONTAINER_TOKENS[queue_index]=""
        fi
    done
}

test_container_engine_is_local_and_pinned() {
    local root bin docker_stub podman_stub log marker output status
    root="$(mktemp -d /tmp/dotfiles-container-test.XXXXXX)" || return 1
    CONTAINER_TEMP_ROOTS+=("$root")
    bin="$root/bin"
    docker_stub="$bin/docker"
    podman_stub="$bin/podman"
    log="$root/engine-select.log"
    marker="$root/staging-marker"
    output="$root/select-output.log"
    mkdir -p "$bin" || return 1
    : > "$log"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "docker" >> "$ENGINE_SELECT_LOG"' \
        'printf " %q" "$@" >> "$ENGINE_SELECT_LOG"' \
        'printf " host=%q context=%q\\n" "${DOCKER_HOST:-}" "${DOCKER_CONTEXT:-}" >> "$ENGINE_SELECT_LOG"' \
        'case "${1:-}" in' \
        '  context)' \
        '    case "${2:-}" in' \
        '      show)' \
        '        [[ "${FAKE_DOCKER_MODE:-local}" != no-context ]] || exit 1' \
        '        printf "fixture-context\\n"' \
        '        ;;' \
        '      inspect) printf "%s\\n" "${FAKE_DOCKER_ENDPOINT:-unix:///fixture/docker.sock}" ;;' \
        '    esac' \
        '    ;;' \
        '  info|version)' \
        '    [[ "${FAKE_DOCKER_MODE:-local}" == local ]]' \
        '    ;;' \
        'esac' \
        > "$docker_stub" || return 1
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "podman" >> "$ENGINE_SELECT_LOG"' \
        'printf " %q" "$@" >> "$ENGINE_SELECT_LOG"' \
        'printf "\\n" >> "$ENGINE_SELECT_LOG"' \
        '[[ "${1:-}" == --remote=false ]] || exit 91' \
        'shift' \
        'case "${1:-}" in info|version) exit 0 ;; *) exit 1 ;; esac' \
        > "$podman_stub" || return 1
    chmod 0755 "$docker_stub" "$podman_stub" || return 1

    status=0
    : > "$log"
    (
        export PATH="$bin:/usr/bin:/bin" ENGINE_SELECT_LOG="$log"
        export DOCKER_HOST=tcp://remote.invalid:2376
        unset DOCKER_CONTEXT CONTAINER_HOST CONTAINER_CONNECTION PODMAN_CONNECTIONS_CONF
        stage_container_checkout() { : > "$marker"; }
        run_container_matrix
    ) > "$output" 2>&1 || status=$?
    require "remote DOCKER_HOST is rejected" test "$status" -ne 0 || return 1
    require "remote DOCKER_HOST is named" \
        grep -Fq -- 'refusing remote Docker endpoint: tcp://remote.invalid:2376' \
        "$output" || return 1
    require "remote DOCKER_HOST causes zero staging" test ! -e "$marker" || return 1
    require "remote DOCKER_HOST causes zero engine mutation" \
        test -z "$(grep -E '( image | create | cp )' "$log" || true)" || return 1

    status=0
    : > "$log"
    rm -f -- "$marker"
    (
        export PATH="$bin:/usr/bin:/bin" ENGINE_SELECT_LOG="$log"
        export DOCKER_CONTEXT=remote-fixture
        export FAKE_DOCKER_ENDPOINT=ssh://remote.invalid/run/docker.sock
        unset DOCKER_HOST CONTAINER_HOST CONTAINER_CONNECTION PODMAN_CONNECTIONS_CONF
        stage_container_checkout() { : > "$marker"; }
        run_container_matrix
    ) > "$output" 2>&1 || status=$?
    require "remote Docker context is rejected" test "$status" -ne 0 || return 1
    require "remote Docker context endpoint is named" \
        grep -Fq -- 'refusing remote Docker endpoint: ssh://remote.invalid/run/docker.sock' \
        "$output" || return 1
    require "remote Docker context causes zero staging" test ! -e "$marker" || return 1
    require "remote Docker context stops before image, copy, or create" \
        test -z "$(grep -E '( image | create | cp )' "$log" || true)" || return 1

    status=0
    : > "$log"
    rm -f -- "$marker"
    (
        export PATH="$bin:/usr/bin:/bin" ENGINE_SELECT_LOG="$log"
        export FAKE_DOCKER_MODE=no-context
        export CONTAINER_HOST=tcp://remote-podman.invalid:1234
        unset DOCKER_HOST DOCKER_CONTEXT CONTAINER_CONNECTION PODMAN_CONNECTIONS_CONF
        stage_container_checkout() { : > "$marker"; }
        run_container_matrix
    ) > "$output" 2>&1 || status=$?
    require "Podman connection environment is rejected" test "$status" -ne 0 || return 1
    require "Podman connection rejection is diagnosed" \
        grep -Fq -- 'refusing configured remote Podman connection' \
        "$output" || return 1
    require "Podman connection environment causes zero staging" \
        test ! -e "$marker" || return 1
    require "Podman connection environment stops before Podman info or mutation" \
        test -z "$(grep '^podman ' "$log" || true)" || return 1

    status=0
    : > "$log"
    (
        export PATH="$bin:/usr/bin:/bin" ENGINE_SELECT_LOG="$log"
        export FAKE_DOCKER_MODE=local
        export FAKE_DOCKER_ENDPOINT=unix:///fixture/docker.sock
        unset DOCKER_HOST DOCKER_CONTEXT CONTAINER_HOST CONTAINER_CONNECTION PODMAN_CONNECTIONS_CONF
        select_container_engine || exit $?
        printf 'KIND=%s\n' "$CONTAINER_ENGINE_KIND"
        container_engine version
    ) > "$output" 2>&1 || status=$?
    require_equal "local Docker selection succeeds" 0 "$status" || return 1
    require "local Docker selection is identified" \
        grep -Fq -- 'KIND=docker' "$output" || return 1
    require_equal "every operational Docker call is pinned to the resolved Unix socket" 2 \
        "$(grep -c 'host=unix:///fixture/docker.sock context=' "$log")" || return 1

    status=0
    : > "$log"
    (
        export PATH="$bin:/usr/bin:/bin" ENGINE_SELECT_LOG="$log"
        export FAKE_DOCKER_MODE=no-context
        unset DOCKER_HOST DOCKER_CONTEXT CONTAINER_HOST CONTAINER_CONNECTION PODMAN_CONNECTIONS_CONF
        select_container_engine || exit $?
        printf 'KIND=%s\n' "$CONTAINER_ENGINE_KIND"
        container_engine version
    ) > "$output" 2>&1 || status=$?
    require_equal "local Podman selection succeeds" 0 "$status" || return 1
    require "local Podman selection is identified" \
        grep -Fq -- 'KIND=podman' "$output" || return 1
    require_equal "every operational Podman call pins local mode" 2 \
        "$(grep -Ec '^podman --remote=false (info|version)$' "$log")" || return 1
}

run_test() {
    local name="$1" function_name="$2" body_status=0 invariant_status=0
    "$function_name" || body_status=$?
    require_global_case_invariants || invariant_status=$?
    if (( body_status == 0 && invariant_status == 0 )); then
        PASSED=$((PASSED + 1))
        printf 'ok %d - %s\n' "$PASSED" "$name"
    else
        FAILED=$((FAILED + 1))
        printf 'not ok - %s\n' "$name" >&2
    fi
}

run_hermetic_suite() {
    run_test "manifest validation precedes mutation" test_manifest_validation_precedes_mutation
    run_test "fresh configuration and idempotent rerun" test_fresh_install_and_idempotent_rerun
    run_test "alternate Claude config directories are rejected" test_alternate_claude_config_directory_is_rejected
    run_test "existing state preservation and private snapshot" test_existing_state_is_preserved_and_snapshotted
    run_test "mixed missing and conflicting state reconciles together" test_mixed_missing_and_conflicting_state_reconciles_together
    run_test "ordinary failures restore the original" test_ordinary_failures_restore_original_state
    run_test "post-mutation read failures enter recovery" test_post_mutation_state_read_failures_enter_recovery
    run_test "post-remove readback failures stop before replacement" test_post_remove_readback_boundaries_stop_before_add
    run_test "fresh first-add unreadable state enters recovery" test_fresh_first_add_unreadable_state_enters_recovery
    run_test "unconfirmed managed changes survive existing-state rollback" test_existing_state_unconfirmed_managed_changes_are_preserved
    run_test "clean second-add failure rolls back the first addition" test_absent_state_clean_second_add_failure_rolls_back_first
    run_test "ambiguous existing state is preserved during rollback" test_ambiguous_existing_state_is_not_overwritten_during_rollback
    run_test "failure bookkeeping continues with nonzero final status" test_failure_bookkeeping_continues_and_is_nonzero
    run_test "final validation checks definitions without Claude calls" test_final_validation_checks_definitions_without_claude_calls
    run_test "final validation rejects invalid Herdr integrations" test_final_validation_rejects_invalid_herdr_integrations
    run_test "main inventory requires yazi and ya" test_main_inventory_requires_both_yazi_commands
    run_test "supported distro package flows are exact" test_supported_distro_package_flows
    run_test "preflight rejects unsupported hosts before mutation" test_preflight_rejects_before_mutation
    run_test "package failures continue and remain nonzero" test_package_failures_continue_and_remain_nonzero
    run_test "dotfile links preserve conflicts and never link claude.json" test_link_dotfiles_backup_and_claude_state_contract
    run_test "download selection and archives fail closed" test_download_selection_checksums_and_archive_safety
    run_test "release binaries require exactly one expected executable" test_release_binary_member_cardinality
    run_test "Herdr installation is guarded and idempotent" test_herdr_install_guard_and_idempotence
    run_test "Herdr installer failures are observable" test_herdr_install_failures_are_observable
    run_test "secrets migrate privately without log leakage" test_secret_roundtrip_migration_permissions_and_redaction
    run_test "compute skills checkout states are preserved safely" test_compute_skills_checkout_states
    run_test "Herdr integrations are exact and report session identity" test_herdr_integration_configuration_and_reporting
    run_test "repository syntax and shell discovery are valid" test_repository_static_and_shell_discovery_contract
    run_test "malformed and nonregular state is untouched" test_malformed_and_nonregular_state_is_untouched
    run_test "duplicate JSON survives destructive rollback proof" test_duplicate_json_is_preserved_during_destructive_proof
    run_test "concurrent unrelated change preserves both versions" test_concurrent_unrelated_change_preserves_both_versions
    run_test "restoration-boundary recreation never overwrites concurrent state" test_restore_boundary_recreation_never_overwrites_concurrent_state
    run_test "absent-state ambiguous writes are preserved" test_absent_state_partial_and_changed_records_are_preserved
    run_test "fresh-state rollback uses safe atomic displacement" test_fresh_state_rollback_displacement_contract
    run_test "allowlisted source inputs remain unchanged" test_source_inputs_are_unchanged
    run_test "container matrix contract is exact" test_container_matrix_contract_is_exact
    run_test "forged container-inner mode is rejected before mutation" test_forged_container_inner_is_rejected_before_mutation
    run_test "container staging rejects secrets before source reads" test_staging_rejects_forbidden_paths_before_source_read
    run_test "container dispatch and worker failures are isolated" test_container_dispatch_without_host_mutation
    run_test "container engines are local and explicitly pinned" test_container_engine_is_local_and_pinned

    printf '%d tests passed; %d tests failed\n' "$PASSED" "$FAILED"
    (( FAILED == 0 ))
}

test_runner_main() {
    if [[ "${DOTFILES_CONTAINER_INNER:-}" == 1 ]]; then
        container_inner_main "$@"
        return
    fi
    case "$#:${1:-}" in
        0:) run_hermetic_suite ;;
        1:--containers)
            verify_container_worker_failure || return 1
            run_container_matrix 1
            ;;
        *)
            printf 'usage: %s [--containers]\n' "${0##*/}" >&2
            return 2
            ;;
    esac
}

test_runner_main "$@"
