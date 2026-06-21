#!/bin/bash
#=============================================================================
# apply_kernel_fragments.sh
#
# Selectively update Buildroot's BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES entry.
#
# Examples:
#   ./scripts/apply_kernel_fragments.sh --list
#   ./scripts/apply_kernel_fragments.sh --show
#   ./scripts/apply_kernel_fragments.sh --set observe-kernel,v4l2-kernel
#   ./scripts/apply_kernel_fragments.sh --all --reconfigure
#   ./scripts/apply_kernel_fragments.sh --clear
#
# Notes:
#   - This script edits the Buildroot .config file only.
#   - Use --reconfigure after changing fragments when the Linux package was
#     already configured or built.
#   - Use --build to run a full Buildroot make after applying the selection.
#=============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONTAINER_WORKSPACE_DIR="$(cd "${WORK_DIR}/../.." && pwd)"
HOST_WORKSPACE_DIR="$(cd "${WORK_DIR}/../../.." && pwd)"

if [ -d "${CONTAINER_WORKSPACE_DIR}/buildroot-2023.11.1" ]; then
    DEFAULT_BUILDROOT_DIR="${CONTAINER_WORKSPACE_DIR}/buildroot-2023.11.1"
elif [ -d "${HOST_WORKSPACE_DIR}/buildroot-2023.11.1" ]; then
    DEFAULT_BUILDROOT_DIR="${HOST_WORKSPACE_DIR}/buildroot-2023.11.1"
else
    DEFAULT_BUILDROOT_DIR="${CONTAINER_WORKSPACE_DIR}/buildroot-2023.11.1"
fi

BUILDROOT_DIR="${BUILDROOT_DIR:-${DEFAULT_BUILDROOT_DIR}}"
FRAGMENT_DIR="board/qemu/aarch64-virt"
MODE=""
NAMES=""
DO_SYNC=true
DO_RECONFIGURE=false
DO_BUILD=false
DRY_RUN=false

usage() {
    cat <<'EOF'
Usage:
  apply_kernel_fragments.sh [options]

Selection options:
  --list                    List known fragment files.
  --show                    Show current BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES.
  --set NAME[,NAME...]      Replace the active fragment list.
  --add NAME[,NAME...]      Add fragment(s) to the active list.
  --remove NAME[,NAME...]   Remove fragment(s) from the active list.
  --all                     Replace active list with all known fragments.
  --clear                   Clear the active fragment list.

Buildroot options:
  --buildroot DIR           Buildroot tree, default: ../../buildroot-2023.11.1.
  --fragment-dir DIR        Fragment directory relative to Buildroot.
  --no-sync                 Do not run Buildroot olddefconfig after editing.
  --reconfigure             Run: make linux-reconfigure
  --build                   Run: make
  --dry-run                 Print the new value without editing .config.
  -h, --help                Show this help.

Fragment names can be full paths, file basenames, or shortened basenames:
  observe-kernel.config
  observe-kernel
  observe
  v4l2-kernel.config
  v4l2-kernel
  v4l2
EOF
}

fail() {
    echo "error: $*" >&2
    exit 1
}

log() {
    echo "[fragments] $*"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --buildroot)
            [ "$#" -ge 2 ] || fail "--buildroot needs a directory"
            BUILDROOT_DIR="$2"
            shift 2
            ;;
        --fragment-dir)
            [ "$#" -ge 2 ] || fail "--fragment-dir needs a directory"
            FRAGMENT_DIR="$2"
            shift 2
            ;;
        --list|--show|--all|--clear)
            [ -z "${MODE}" ] || fail "only one selection option can be used"
            MODE="${1#--}"
            shift
            ;;
        --set|--add|--remove)
            [ -z "${MODE}" ] || fail "only one selection option can be used"
            [ "$#" -ge 2 ] || fail "$1 needs a comma-separated name list"
            MODE="${1#--}"
            NAMES="$2"
            shift 2
            ;;
        --no-sync)
            DO_SYNC=false
            shift
            ;;
        --reconfigure)
            DO_RECONFIGURE=true
            shift
            ;;
        --build)
            DO_BUILD=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

[ -n "${MODE}" ] || MODE="show"
[ -d "${BUILDROOT_DIR}" ] || fail "Buildroot directory does not exist: ${BUILDROOT_DIR}"
[ -f "${BUILDROOT_DIR}/Makefile" ] || fail "not a Buildroot tree: ${BUILDROOT_DIR}"
[ -f "${BUILDROOT_DIR}/.config" ] || fail "Buildroot .config does not exist: ${BUILDROOT_DIR}/.config"

cd "${BUILDROOT_DIR}"

CONFIG_FILE=".config"
VAR="BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES"

current_value() {
    sed -n "s/^${VAR}=\"\\(.*\\)\"/\\1/p" "${CONFIG_FILE}" | tail -1
}

custom_kernel_config() {
    sed -n 's/^BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE="\([^"]*\)"/\1/p' "${CONFIG_FILE}" | tail -1
}

known_fragments() {
    local custom
    custom="$(custom_kernel_config)"

    find "${FRAGMENT_DIR}" -maxdepth 1 -type f -name '*.config' | sort | while read -r f; do
        [ "${f}" = "${custom}" ] && continue
        [ "$(basename "${f}")" = "linux.config" ] && continue
        echo "${f}"
    done
}

print_list() {
    log "Buildroot: ${BUILDROOT_DIR}"
    log "Fragment dir: ${FRAGMENT_DIR}"
    known_fragments | while read -r f; do
        echo "  ${f}"
    done
}

print_current() {
    local value
    value="$(current_value)"
    log "Current ${VAR}:"
    if [ -n "${value}" ]; then
        printf '%s\n' "${value}" | tr ' ' '\n' | sed 's/^/  /'
    else
        echo "  <empty>"
    fi
}

dedupe_words() {
    awk '
        NF {
            for (i = 1; i <= NF; i++) {
                if (!seen[$i]++) {
                    out = out ? out " " $i : $i
                }
            }
        }
        END { print out }
    '
}

resolve_one() {
    local name="$1"
    local candidate
    local matches
    local count

    name="${name#./}"

    if [ -f "${name}" ]; then
        echo "${name}"
        return
    fi

    if [ -f "${FRAGMENT_DIR}/${name}" ]; then
        echo "${FRAGMENT_DIR}/${name}"
        return
    fi

    if [ -f "${FRAGMENT_DIR}/${name}.config" ]; then
        echo "${FRAGMENT_DIR}/${name}.config"
        return
    fi

    if [ -f "${FRAGMENT_DIR}/${name}-kernel.config" ]; then
        echo "${FRAGMENT_DIR}/${name}-kernel.config"
        return
    fi

    matches="$(known_fragments | while read -r candidate; do
        case "$(basename "${candidate}")" in
            "${name}"|\
            "${name}.config"|\
            "${name}-kernel.config")
                echo "${candidate}"
                ;;
        esac
    done)"

    count="$(printf '%s\n' "${matches}" | sed '/^$/d' | wc -l)"
    if [ "${count}" -eq 1 ]; then
        printf '%s\n' "${matches}" | sed '/^$/d'
        return
    fi
    if [ "${count}" -gt 1 ]; then
        fail "ambiguous fragment name '${name}': ${matches}"
    fi

    fail "unknown fragment '${name}'. Use --list to see available fragments."
}

resolve_names() {
    local raw="$1"
    local item

    printf '%s\n' "${raw}" | tr ',' '\n' | while read -r item; do
        item="$(printf '%s' "${item}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -z "${item}" ] && continue
        resolve_one "${item}"
    done | tr '\n' ' ' | dedupe_words
}

write_value() {
    local value="$1"
    local tmp

    if ${DRY_RUN}; then
        log "dry-run new ${VAR}: ${value:-<empty>}"
        return
    fi

    tmp="$(mktemp)"
    if grep -q "^${VAR}=" "${CONFIG_FILE}"; then
        awk -v var="${VAR}" -v value="${value}" '
            BEGIN { written = 0 }
            $0 ~ "^" var "=" {
                print var "=\"" value "\""
                written = 1
                next
            }
            { print }
            END {
                if (!written) {
                    print var "=\"" value "\""
                }
            }
        ' "${CONFIG_FILE}" > "${tmp}"
    else
        cp "${CONFIG_FILE}" "${tmp}"
        printf '%s="%s"\n' "${VAR}" "${value}" >> "${tmp}"
    fi
    mv "${tmp}" "${CONFIG_FILE}"
    log "updated ${CONFIG_FILE}: ${VAR}=\"${value}\""
}

case "${MODE}" in
    list)
        print_list
        exit 0
        ;;
    show)
        print_current
        exit 0
        ;;
    all)
        NEW_VALUE="$(known_fragments | tr '\n' ' ' | dedupe_words)"
        ;;
    clear)
        NEW_VALUE=""
        ;;
    set)
        NEW_VALUE="$(resolve_names "${NAMES}")"
        ;;
    add)
        NEW_VALUE="$(printf '%s %s\n' "$(current_value)" "$(resolve_names "${NAMES}")" | dedupe_words)"
        ;;
    remove)
        REMOVE_VALUE="$(resolve_names "${NAMES}")"
        NEW_VALUE="$(printf '%s\n' "$(current_value)" | tr ' ' '\n' | while read -r item; do
            [ -z "${item}" ] && continue
            keep=true
            for remove_item in ${REMOVE_VALUE}; do
                if [ "${item}" = "${remove_item}" ]; then
                    keep=false
                    break
                fi
            done
            if ${keep}; then
                echo "${item}"
            fi
        done | tr '\n' ' ' | dedupe_words)"
        ;;
    *)
        fail "unsupported mode: ${MODE}"
        ;;
esac

write_value "${NEW_VALUE}"

if ${DRY_RUN}; then
    exit 0
fi

if ${DO_SYNC}; then
    log "running Buildroot olddefconfig"
    make olddefconfig
fi

if ${DO_RECONFIGURE}; then
    log "running linux-reconfigure"
    make linux-reconfigure
fi

if ${DO_BUILD}; then
    log "running full Buildroot make"
    make
fi
