#!/bin/bash
#=============================================================================
# copy_prac_to_rootfs.sh
#
# 将 buildroot-study/my-work/prac 目录打包到 Buildroot 根文件系统的 /home/ 目录下。
#
# 使用方式：
#   1. 作为 Buildroot post-build script（推荐）：
#      在 buildroot 的 menuconfig 中设置：
#        System configuration → Custom scripts to run after creating filesystem images
#      指向本脚本的路径。
#      Buildroot 会自动传入 TARGET_DIR 作为第一个参数。
#
#   2. 手动运行（Buildroot 已完成编译后）：
#      ./copy_prac_to_rootfs.sh <TARGET_DIR>
#      例如：
#      ./copy_prac_to_rootfs.sh ../../buildroot-2023.11.1/output/target
#
# 环境变量（Buildroot 自动设置）：
#   TARGET_DIR  - 目标文件系统暂存目录（脚本 $1）
#   BINARIES_DIR - 最终镜像输出目录
#   BUILD_DIR   - 构建目录
#   CONFIG_DIR   - .config 所在目录
#=============================================================================

set -e  # 出错即停

# --- 确定目录路径 ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRAC_SRC="${SCRIPT_DIR}/../prac"

# TARGET_DIR 来自 Buildroot 传入的第一个参数
TARGET_DIR="${1}"

if [ -z "${TARGET_DIR}" ]; then
    echo "错误: 缺少 TARGET_DIR 参数"
    echo "用法: $0 <TARGET_DIR>"
    echo "例如: $0 ../../buildroot-2023.11.1/output/target"
    exit 1
fi

if [ ! -d "${TARGET_DIR}" ]; then
    echo "错误: TARGET_DIR 不存在: ${TARGET_DIR}"
    echo "请确认 Buildroot 已完成编译，或传入正确的路径。"
    exit 1
fi

if [ ! -d "${PRAC_SRC}" ]; then
    echo "错误: prac 源目录不存在: ${PRAC_SRC}"
    echo "请确认 buildroot-study/my-work/prac 目录已创建并包含你要打包的文件。"
    exit 1
fi

# --- 目标路径 ---
PRAC_DST="${TARGET_DIR}/home/prac"

echo "============================================"
echo "  拷贝 prac 到根文件系统"
echo "============================================"
echo "  源路径:  ${PRAC_SRC}"
echo "  目标路径: ${PRAC_DST}"
echo "--------------------------------------------"

# 确保目标 /home 目录存在
mkdir -p "${TARGET_DIR}/home"

# 先删除旧目录（如果存在），再拷贝新内容
if [ -d "${PRAC_DST}" ]; then
    echo "  删除旧的 prac 目录..."
    rm -rf "${PRAC_DST}"
fi

# 拷贝整个 prac 目录
cp -a "${PRAC_SRC}" "${PRAC_DST}"

# --- 列出拷贝结果 ---
echo "--------------------------------------------"
echo "  拷贝完成！/home/prac 中的文件："
find "${PRAC_DST}" -type f | sort | while read -r f; do
    echo "    ${f#${PRAC_DST}/}"
done
echo "============================================"

exit 0
