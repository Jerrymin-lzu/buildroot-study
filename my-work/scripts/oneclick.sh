#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONTAINER_WORKSPACE_DIR="$(cd "${WORK_DIR}/../.." && pwd)"
HOST_WORKSPACE_DIR="$(cd "${WORK_DIR}/../../.." && pwd)"

if [ -z "${BUILDROOT_DIR:-}" ]; then
    if [ -d "${CONTAINER_WORKSPACE_DIR}/buildroot-2023.11.1" ]; then
        BUILDROOT_DIR="${CONTAINER_WORKSPACE_DIR}/buildroot-2023.11.1"
    elif [ -d "${HOST_WORKSPACE_DIR}/buildroot-2023.11.1" ]; then
        BUILDROOT_DIR="${HOST_WORKSPACE_DIR}/buildroot-2023.11.1"
    else
        BUILDROOT_DIR="${CONTAINER_WORKSPACE_DIR}/buildroot-2023.11.1"
    fi
fi

"${SCRIPT_DIR}/copy_prac_to_rootfs.sh" "${BUILDROOT_DIR}/output/target"
