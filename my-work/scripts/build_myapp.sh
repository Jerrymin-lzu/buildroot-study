#!/bin/bash
#=============================================================================
# build_myapp.sh — 一键交叉编译并部署 myapp eBPF/XDP 程序
#
# 用法:
#   ./build_myapp.sh                # 编译并部署（默认）
#   ./build_myapp.sh build-only     # 仅编译，不部署
#   ./build_myapp.sh deploy-only    # 仅部署（假设已编译）
#   ./build_myapp.sh verify         # 仅验证已有编译产物
#   ./build_myapp.sh clean          # 清理编译产物
#   ./build_myapp.sh deps-check     # 仅检查依赖是否满足
#
# 环境变量（可覆盖默认值）:
#   BUILDROOT_DIR   — Buildroot 目录（默认: ~/workspace/buildroot-2023.11.1）
#   MYAPP_DIR       — myapp 项目目录（默认: 自动检测）
#   PRAC_DIR        — prac 部署目录（默认: 自动检测）
#   TARGET          — 交叉编译目标（默认: aarch64-unknown-linux-gnu）
#=============================================================================

set -e

#=============================================================================
# 颜色定义
#=============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

#=============================================================================
# 日志函数
#=============================================================================
log_info()    { echo -e "${BLUE}[INFO]${NC}    $(date '+%H:%M:%S')  $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%H:%M:%S')  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $(date '+%H:%M:%S')  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $(date '+%H:%M:%S')  $*"; }
log_step()    { echo ""; echo -e "${CYAN}${BOLD}▶ $*${NC}"; echo -e "${CYAN}────────────────────────────────────────────────────${NC}"; }

#=============================================================================
# 路径解析
#=============================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 默认路径（可通过环境变量覆盖）
MYAPP_DIR="${MYAPP_DIR:-${WORK_DIR}/myapp}"
BUILDROOT_DIR="${BUILDROOT_DIR:-${HOME}/workspace/buildroot-2023.11.1}"
PRAC_DIR="${PRAC_DIR:-${WORK_DIR}/prac}"
TARGET="${TARGET:-aarch64-unknown-linux-gnu}"
TARGET_DIR="target/${TARGET}/release"
EBPF_TARGET="bpfel-unknown-none"
EBPF_TARGET_DIR="target/${EBPF_TARGET}/release"

# Buildroot 工具链
TOOLCHAIN_BIN="${BUILDROOT_DIR}/output/host/bin"
CROSS_GCC="${TOOLCHAIN_BIN}/aarch64-buildroot-linux-gnu-gcc"
CROSS_READELF="${TOOLCHAIN_BIN}/aarch64-buildroot-linux-gnu-readelf"

# 部署脚本
COPY_SCRIPT="${SCRIPT_DIR}/copy_prac_to_rootfs.sh"

#=============================================================================
# 辅助函数
#=============================================================================
check_cmd() {
    if ! command -v "$1" &>/dev/null; then
        log_error "未找到命令: $1"
        return 1
    fi
    return 0
}

check_file() {
    if [ ! -f "$1" ]; then
        log_error "文件不存在: $1"
        return 1
    fi
    return 0
}

check_dir() {
    if [ ! -d "$1" ]; then
        log_error "目录不存在: $1"
        return 1
    fi
    return 0
}

#=============================================================================
# 依赖检查
#=============================================================================
check_dependencies() {
    log_step "检查依赖"

    local all_ok=true

    # --- Rust 工具链 ---
    log_info "检查 Rust 工具链..."
    if check_cmd rustup; then
        log_success "rustup: $(rustup --version 2>/dev/null || true)"

        if rustup toolchain list 2>/dev/null | grep -q "stable"; then
            log_success "stable 工具链已安装"
        else
            log_warn "stable 工具链未安装，运行: rustup install stable"
            all_ok=false
        fi

        if rustup toolchain list 2>/dev/null | grep -q "nightly"; then
            if rustup component list --toolchain nightly 2>/dev/null | grep -q "rust-src.*(installed)"; then
                log_success "nightly 工具链 + rust-src 已安装"
            else
                log_warn "nightly 缺少 rust-src 组件，运行: rustup component add rust-src --toolchain nightly"
                all_ok=false
            fi
        else
            log_warn "nightly 工具链未安装，运行: rustup toolchain install nightly --component rust-src"
            all_ok=false
        fi

        if rustup target list --installed 2>/dev/null | grep -q "${TARGET}"; then
            log_success "目标 ${TARGET} 已安装"
        else
            log_warn "目标 ${TARGET} 未安装，运行: rustup target add ${TARGET}"
            all_ok=false
        fi
    else
        log_error "rustup 未安装，请先安装 Rust: https://rustup.rs"
        all_ok=false
    fi

    # --- bpf-linker ---
    if check_cmd bpf-linker; then
        log_success "bpf-linker: $(bpf-linker --version 2>/dev/null || echo '已安装')"
    else
        log_warn "bpf-linker 未安装，运行: cargo install bpf-linker"
        all_ok=false
    fi

    # --- 交叉编译器 ---
    log_info "检查 Buildroot 交叉编译器..."
    if [ -x "${CROSS_GCC}" ]; then
        log_success "交叉编译器: $(${CROSS_GCC} --version 2>&1 | head -1)"
    else
        log_error "交叉编译器不存在: ${CROSS_GCC}"
        log_error "请确认 Buildroot 已完成编译: cd ${BUILDROOT_DIR} && make"
        all_ok=false
    fi

    # --- 项目目录 ---
    log_info "检查项目目录..."
    check_dir "${MYAPP_DIR}" || all_ok=false
    if [ -f "${MYAPP_DIR}/Cargo.toml" ]; then
        log_success "myapp 项目目录: ${MYAPP_DIR}"
    else
        log_error "myapp/Cargo.toml 不存在: ${MYAPP_DIR}"
        all_ok=false
    fi

    check_dir "${PRAC_DIR}" || {
        log_warn "prac 目录不存在，将自动创建"
        mkdir -p "${PRAC_DIR}"
        log_success "已创建 prac 目录: ${PRAC_DIR}"
    }

    # --- 部署脚本 ---
    if [ ! -f "${COPY_SCRIPT}" ]; then
        log_error "部署脚本不存在: ${COPY_SCRIPT}"
        all_ok=false
    elif [ ! -x "${COPY_SCRIPT}" ]; then
        log_error "部署脚本无执行权限: ${COPY_SCRIPT}"
        log_error "运行: chmod +x ${COPY_SCRIPT}"
        all_ok=false
    else
        log_success "部署脚本: ${COPY_SCRIPT}"
    fi

    # --- .cargo/config.toml 交叉编译配置 ---
    local cargo_config="${MYAPP_DIR}/.cargo/config.toml"
    if [ -f "${cargo_config}" ]; then
        if grep -q "aarch64-unknown-linux-gnu" "${cargo_config}" 2>/dev/null; then
            log_success ".cargo/config.toml 已包含 aarch64 目标配置"
        else
            log_warn ".cargo/config.toml 缺少 aarch64 目标配置，请参照文档添加 [target.aarch64-unknown-linux-gnu] 段"
            all_ok=false
        fi
    else
        log_warn ".cargo/config.toml 不存在: ${cargo_config}"
        all_ok=false
    fi

    if [ "${all_ok}" = false ]; then
        log_error "部分依赖不满足，请参照 docs/5_aya_ebpf.md 完成环境配置"
        return 1
    fi

    log_success "所有依赖检查通过"
    return 0
}

#=============================================================================
# 打印配置信息
#=============================================================================
print_config() {
    log_step "编译配置"
    echo "  工作目录:     ${WORK_DIR}"
    echo "  项目目录:     ${MYAPP_DIR}"
    echo "  部署目录:     ${PRAC_DIR}"
    echo "  Buildroot:    ${BUILDROOT_DIR}"
    echo "  目标架构:     ${TARGET}"
    echo "  eBPF 目标:    ${EBPF_TARGET}"
    echo "  交叉编译器:   ${CROSS_GCC}"
    echo "  产物路径:     ${MYAPP_DIR}/${TARGET_DIR}/myapp"
    echo "  部署脚本:     ${COPY_SCRIPT}"
}

#=============================================================================
# 编译
#=============================================================================
do_build() {
    local start_time=$(date +%s)

    # --- 设置 PATH ---
    export PATH="${PATH}:${TOOLCHAIN_BIN}"
    log_info "已添加工具链到 PATH: ${TOOLCHAIN_BIN}"

    cd "${MYAPP_DIR}"

    # --- 步骤 1: 编译 eBPF 程序 ---
    log_step "[1/4] 编译 eBPF 程序 (本机构建)"

    cargo +nightly build \
        --package myapp-ebpf \
        --target "${EBPF_TARGET}" \
        --release \
        -Z build-std=core 2>&1 | sed 's/^/  | /'

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_error "eBPF 程序编译失败"
        exit 1
    fi

    local ebpf_artifact="${EBPF_TARGET_DIR}/myapp"
    if [ ! -f "${ebpf_artifact}" ]; then
        log_error "eBPF 编译产物不存在: ${ebpf_artifact}"
        exit 1
    fi

    log_success "eBPF 程序编译完成"
    log_info "产物: ${ebpf_artifact}"
    log_info "eBPF 类型: $(file "${ebpf_artifact}" | cut -d: -f2-)"

    # --- 步骤 2: 交叉编译用户态程序 ---
    log_step "[2/4] 交叉编译用户态程序 (${TARGET})"

    cargo +nightly build \
        --package myapp \
        --target "${TARGET}" \
        --release \
        -Z build-std=core,std,alloc,proc_macro,test 2>&1 | sed 's/^/  | /'

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_error "用户态程序交叉编译失败"
        exit 1
    fi

    log_success "用户态程序编译完成"

    # --- 步骤 3: 验证编译产物 ---
    log_step "[3/4] 验证编译产物"

    local artifact="${TARGET_DIR}/myapp"

    if [ ! -f "${artifact}" ]; then
        log_error "编译产物不存在: ${artifact}"
        exit 1
    fi

    log_info "文件大小: $(du -h "${artifact}" | cut -f1)"
    log_info "文件类型: $(file "${artifact}" | cut -d: -f2-)"

    # 程序化校验架构（不能只靠人眼看 file 输出）
    if ! file "${artifact}" | grep -q "ARM aarch64"; then
        log_error "编译产物架构不正确！预期 ARM aarch64，实际:"
        file "${artifact}"
        log_error "请检查 .cargo/config.toml 中 [target.aarch64-unknown-linux-gnu] 的 linker 配置"
        exit 1
    fi
    log_success "架构验证通过: ARM aarch64"

    # 使用交叉 readelf 做更深层验证
    if [ -x "${CROSS_READELF}" ]; then
        echo ""
        log_info "动态链接器:"
        "${CROSS_READELF}" -l "${artifact}" 2>/dev/null | grep -i interpreter | sed 's/^/  | /' || log_warn "未找到 INTERP 段（可能是静态链接）"

        log_info "依赖的动态库:"
        "${CROSS_READELF}" -d "${artifact}" 2>/dev/null | grep NEEDED | sed 's/^/  | /' || log_info "  (无动态库依赖)"
    else
        log_warn "交叉 readelf 不可用，跳过深层验证"
    fi

    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    log_success "编译验证完成 (耗时: ${elapsed}s)"
}

#=============================================================================
# 部署
#=============================================================================
do_deploy() {
    log_step "[4/4] 部署到根文件系统"

    local artifact="${MYAPP_DIR}/${TARGET_DIR}/myapp"

    if [ ! -f "${artifact}" ]; then
        log_error "编译产物不存在: ${artifact}"
        log_error "请先执行编译: $0"
        exit 1
    fi

    # 静默校验架构（避免部署了错误架构的二进制到 VM）
    if ! file "${artifact}" | grep -q "ARM aarch64"; then
        log_error "编译产物架构不正确！预期 ARM aarch64，实际: $(file "${artifact}" | cut -d: -f2-)"
        log_error "请检查 .cargo/config.toml 中 [target.aarch64-unknown-linux-gnu] 的 linker 配置后重新编译"
        exit 1
    fi

    # 拷贝到 prac 目录
    if [ ! -d "${PRAC_DIR}" ]; then
        log_warn "prac 目录不存在，自动创建: ${PRAC_DIR}"
        mkdir -p "${PRAC_DIR}"
    fi
    log_info "拷贝 myapp → ${PRAC_DIR}/"
    cp -v "${artifact}" "${PRAC_DIR}/"
    log_success "已拷贝到 prac 目录"

    # 打包到 Buildroot 根文件系统
    if [ ! -d "${BUILDROOT_DIR}/output/target" ]; then
        log_error "Buildroot target 目录不存在: ${BUILDROOT_DIR}/output/target"
        log_error "请确认 Buildroot 已完成首次编译"
        exit 1
    fi

    "${COPY_SCRIPT}" "${BUILDROOT_DIR}/output/target"

    log_success "部署完成！"
    echo ""
    echo "  ┌─────────────────────────────────────────────────────┐"
    echo "  │  下一步:                                             │"
    echo "  │                                                     │"
    echo "  │  1. 重新生成根文件系统镜像:                            │"
    echo "  │     cd ${BUILDROOT_DIR} && make                      │"
    echo "  │                                                     │"
    echo "  │  2. 启动 QEMU 虚拟机                                  │"
    echo "  │                                                     │"
    echo "  │  3. 在虚拟机中运行:                                    │"
    echo "  │     cd /home/prac && ./myapp --iface eth0            │"
    echo "  └─────────────────────────────────────────────────────┘"
}

#=============================================================================
# 清理
#=============================================================================
do_clean() {
    log_step "清理编译产物"
    if [ ! -d "${MYAPP_DIR}" ]; then
        log_warn "项目目录不存在: ${MYAPP_DIR}，无需清理"
        return 0
    fi
    cd "${MYAPP_DIR}"
    cargo clean 2>/dev/null || true
    rm -rf target 2>/dev/null || true
    log_success "清理完成"
}

#=============================================================================
# 验证已有产物
#=============================================================================
do_verify() {
    log_step "验证编译产物"

    local artifact="${MYAPP_DIR}/${TARGET_DIR}/myapp"

    if [ ! -f "${artifact}" ]; then
        log_error "编译产物不存在: ${artifact}"
        log_error "请先执行编译: $0"
        exit 1
    fi

    log_info "文件: ${artifact}"
    log_info "大小: $(du -h "${artifact}" | cut -f1)"
    log_info "类型: $(file "${artifact}" | cut -d: -f2-)"

    # 程序化校验架构
    if ! file "${artifact}" | grep -q "ARM aarch64"; then
        log_error "编译产物架构不正确！预期 ARM aarch64，实际:"
        file "${artifact}"
        log_error "请检查 .cargo/config.toml 中 [target.aarch64-unknown-linux-gnu] 的 linker 配置"
        exit 1
    fi
    log_success "架构验证通过: ARM aarch64"

    if [ -x "${CROSS_READELF}" ]; then
        echo ""
        log_info "=== ELF 头部 ==="
        "${CROSS_READELF}" -h "${artifact}" 2>/dev/null | grep -E "Class|Machine|Entry" | sed 's/^/  | /'

        echo ""
        log_info "=== 动态链接器 ==="
        "${CROSS_READELF}" -l "${artifact}" 2>/dev/null | grep -i interpreter | sed 's/^/  | /' || echo "  | (静态链接)"

        echo ""
        log_info "=== 动态库依赖 ==="
        "${CROSS_READELF}" -d "${artifact}" 2>/dev/null | grep NEEDED | sed 's/^/  | /' || echo "  | (无动态库依赖)"
    fi

    log_success "验证完成"
}

#=============================================================================
# 主入口
#=============================================================================
print_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║${NC}  ${BOLD}myapp eBPF/XDP — 一键交叉编译部署脚本${NC}              ${CYAN}${BOLD}║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

case "${1}" in
    clean)
        do_clean
        exit 0
        ;;
    deps-check)
        check_dependencies
        exit $?
        ;;
    verify)
        do_verify
        exit 0
        ;;
    build-only)
        print_banner
        print_config
        check_dependencies
        do_build
        log_success "编译完成（跳过部署）"
        exit 0
        ;;
    deploy-only)
        if [ ! -f "${MYAPP_DIR}/${TARGET_DIR}/myapp" ]; then
            log_error "编译产物不存在: ${MYAPP_DIR}/${TARGET_DIR}/myapp"
            log_error "请先执行编译: $0"
            exit 1
        fi
        print_banner
        print_config
        do_deploy
        exit 0
        ;;
    help|--help|-h)
        echo "用法: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  (默认)        编译并部署"
        echo "  build-only    仅编译，不部署"
        echo "  deploy-only   仅部署（假设已编译）"
        echo "  verify        仅验证已有编译产物"
        echo "  clean         清理编译产物"
        echo "  deps-check    仅检查依赖"
        echo "  help          显示此帮助"
        echo ""
        echo "环境变量:"
        echo "  BUILDROOT_DIR  Buildroot 目录（默认: ~/workspace/buildroot-2023.11.1）"
        echo "  MYAPP_DIR      myapp 项目目录"
        echo "  PRAC_DIR       prac 部署目录"
        echo "  TARGET         交叉编译目标（默认: aarch64-unknown-linux-gnu）"
        exit 0
        ;;
    "")
        print_banner
        print_config
        check_dependencies
        do_build
        do_deploy
        log_success "全部完成！"
        ;;
    *)
        log_error "未知命令: $1"
        echo "运行 '$0 help' 查看帮助"
        exit 1
        ;;
esac
