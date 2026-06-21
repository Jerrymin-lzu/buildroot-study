# syntax=docker/dockerfile:1
FROM ubuntu:24.04

ARG UID=1000
ARG GID=1000
ARG APT_MIRROR=mirrors.aliyun.com
ARG BUILDROOT_VERSION=2023.11.1
ARG NODE_VERSION=20

ENV DEBIAN_FRONTEND=noninteractive
ENV BUILDROOT_VERSION=${BUILDROOT_VERSION}
ENV BUILDROOT_DIR=/home/luckfox/workspace/buildroot-${BUILDROOT_VERSION}
ENV STUDY_DIR=/home/luckfox/workspace/buildroot-study
ENV MY_WORK_DIR=/home/luckfox/workspace/buildroot-study/my-work
ENV RUSTUP_DIST_SERVER=https://mirrors.ustc.edu.cn/rust-static
ENV RUSTUP_UPDATE_ROOT=https://mirrors.ustc.edu.cn/rust-static/rustup
ENV NVM_DIR=/home/luckfox/.nvm
ENV NVM_SYMLINK_CURRENT=true

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Match the verified host family: Ubuntu 24.04 on x86_64/WSL2, with Buildroot
# dependencies plus the tools used by the eBPF, tracing and V4L2 tutorials.
RUN sed -i "s/archive.ubuntu.com/${APT_MIRROR}/g; s/security.ubuntu.com/${APT_MIRROR}/g" \
        /etc/apt/sources.list.d/ubuntu.sources && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        autoconf automake bc binfmt-support bison bsdmainutils build-essential \
        bzip2 ca-certificates chrpath clang cmake cpio curl device-tree-compiler \
        diffstat dkms dwarves expect expect-dev expat fakeroot file flex gawk \
        gcc-aarch64-linux-gnu g++-aarch64-linux-gnu git gnupg gzip iproute2 \
        libclang-dev libelf-dev libgmp-dev liblz4-tool libmpc-dev libncurses-dev \
        libssl-dev live-build llvm lsb-release make nano openssh-client patch \
        patchelf pkg-config python-is-python3 python3 python3-pip qemu-system-arm \
        qemu-system-misc qemu-user-static rsync scons ssh sudo tar texinfo unzip \
        vim wget xz-utils zip zstd && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN userdel -r ubuntu 2>/dev/null || true && \
    groupadd -g "${GID}" luckfox && \
    useradd -m -u "${UID}" -g "${GID}" -s /bin/bash luckfox && \
    echo "luckfox:luckfox" | chpasswd && \
    usermod -aG sudo luckfox && \
    echo 'luckfox ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/90-luckfox && \
    chmod 0440 /etc/sudoers.d/90-luckfox

USER luckfox
WORKDIR /home/luckfox/workspace
ENV PATH=/home/luckfox/.cargo/bin:/home/luckfox/.nvm/current/bin:${PATH}

# Rust/eBPF toolchain used by my-work/myapp and docs/5_aya_ebpf.md.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
    mkdir -p /home/luckfox/.cargo && \
    cat >/home/luckfox/.cargo/config.toml <<'EOF'
[source.crates-io]
replace-with = "ustc"

[source.ustc]
registry = "sparse+https://mirrors.ustc.edu.cn/crates.io-index/"
EOF

RUN rustup toolchain install stable nightly --component rust-src && \
    rustup default stable && \
    rustup target add aarch64-unknown-linux-gnu && \
    cargo install --locked --git https://github.com/rust-lang/rust-bindgen --tag v0.65.1 bindgen-cli && \
    cargo install --locked bpf-linker cargo-generate

# Node is useful for optional editing/assistant workflows. No Codex auth or API
# key is baked into the image.
RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash && \
    source "${NVM_DIR}/nvm.sh" && \
    nvm install "${NODE_VERSION}" && \
    nvm alias default "${NODE_VERSION}" && \
    nvm use default && \
    ln -sfn "${NVM_DIR}/versions/node/$(nvm version default)" "${NVM_DIR}/current" && \
    node --version && \
    npm --version

RUN wget "https://buildroot.org/downloads/buildroot-${BUILDROOT_VERSION}.tar.gz" && \
    tar -xzf "buildroot-${BUILDROOT_VERSION}.tar.gz" && \
    rm "buildroot-${BUILDROOT_VERSION}.tar.gz"

WORKDIR ${BUILDROOT_DIR}

RUN cat >board/qemu/aarch64-virt/observe-kernel.config <<'EOF'
# Observability options for eBPF, ftrace, perf, kprobe/uprobe and trace-cmd.
CONFIG_BPF=y
CONFIG_BPF_SYSCALL=y
CONFIG_BPF_JIT=y
CONFIG_BPF_JIT_ALWAYS_ON=y
CONFIG_HAVE_EBPF_JIT=y
CONFIG_BPF_EVENTS=y
CONFIG_BPF_STREAM_PARSER=y
CONFIG_CGROUP_BPF=y
CONFIG_BPF_LSM=y
CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_INFO_DWARF4=y
CONFIG_DEBUG_INFO_BTF=y
CONFIG_DEBUG_INFO_BTF_MODULES=y
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y
CONFIG_TRACEPOINTS=y
CONFIG_TRACING=y
CONFIG_FTRACE=y
CONFIG_FUNCTION_TRACER=y
CONFIG_FUNCTION_GRAPH_TRACER=y
CONFIG_DYNAMIC_FTRACE=y
CONFIG_DYNAMIC_FTRACE_WITH_ARGS=y
CONFIG_IRQSOFF_TRACER=y
CONFIG_SCHED_TRACER=y
CONFIG_STACK_TRACER=y
CONFIG_BLK_DEV_IO_TRACE=y
CONFIG_EVENT_TRACING=y
CONFIG_CONTEXT_SWITCH_TRACER=y
CONFIG_RING_BUFFER=y
CONFIG_KPROBES=y
CONFIG_KPROBE_EVENTS=y
CONFIG_UPROBES=y
CONFIG_UPROBE_EVENTS=y
CONFIG_BPF_KPROBE_OVERRIDE=y
CONFIG_PERF_EVENTS=y
CONFIG_PERF_USE_VMALLOC=y
CONFIG_HW_PERF_EVENTS=y
CONFIG_PROFILING=y
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y
CONFIG_PROC_EVENTS=y
CONFIG_TASKSTATS=y
CONFIG_SCHEDSTATS=y
CONFIG_CGROUPS=y
CONFIG_NET=y
CONFIG_INET=y
CONFIG_NETFILTER=y
CONFIG_NET_CLS_BPF=y
CONFIG_NET_ACT_BPF=y
CONFIG_NET_SCH_INGRESS=y
CONFIG_NET_INGRESS=y
CONFIG_CRYPTO_SHA1=y
CONFIG_CRYPTO_USER_API_HASH=y
CONFIG_DEBUG_FS=y
CONFIG_BPF_FS=y
CONFIG_MODULES=y
CONFIG_MODULE_UNLOAD=y
EOF

RUN cat >board/qemu/aarch64-virt/v4l2-kernel.config <<'EOF'
# V4L2/media stack and virtual camera drivers for QEMU experiments.
CONFIG_MEDIA_SUPPORT=y
CONFIG_MEDIA_SUPPORT_FILTER=y
CONFIG_MEDIA_CAMERA_SUPPORT=y
CONFIG_MEDIA_PLATFORM_SUPPORT=y
CONFIG_MEDIA_TEST_SUPPORT=y
CONFIG_VIDEO_DEV=y
CONFIG_MEDIA_CONTROLLER=y
CONFIG_MEDIA_CONTROLLER_REQUEST_API=y
CONFIG_VIDEO_V4L2_SUBDEV_API=y
CONFIG_VIDEO_ADV_DEBUG=y
CONFIG_V4L2_FWNODE=m
CONFIG_V4L2_ASYNC=m

# Virtual V4L2 devices used by the tutorials.
CONFIG_V4L_TEST_DRIVERS=y
CONFIG_VIDEO_VIVID=m
# CONFIG_VIDEO_VIVID_CEC is not set
CONFIG_VIDEO_VIVID_MAX_DEVS=64
CONFIG_VIDEO_VIMC=m

# Buffer backends selected by vivid/vimc, kept explicit for readability.
CONFIG_VIDEOBUF2_CORE=m
CONFIG_VIDEOBUF2_V4L2=m
CONFIG_VIDEOBUF2_MEMOPS=m
CONFIG_VIDEOBUF2_VMALLOC=m
CONFIG_VIDEOBUF2_DMA_CONTIG=m
CONFIG_VIDEO_V4L2_TPG=m

# Debug/trace support used to observe the V4L2 software stack.
CONFIG_DEBUG_KERNEL=y
CONFIG_DEBUG_FS=y
CONFIG_DYNAMIC_DEBUG=y
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y
CONFIG_STACKTRACE=y
CONFIG_FRAME_POINTER=y
CONFIG_TRACING=y
CONFIG_FTRACE=y
CONFIG_FUNCTION_TRACER=y
CONFIG_FUNCTION_GRAPH_TRACER=y
CONFIG_DYNAMIC_FTRACE=y
CONFIG_KPROBES=y
CONFIG_KPROBE_EVENTS=y
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y
EOF

RUN cat >board/qemu/aarch64-virt/post-build.sh <<'EOF'
#!/bin/sh
set -eu

TARGET_DIR="${TARGET_DIR:?TARGET_DIR is not set}"
FSTAB="${TARGET_DIR}/etc/fstab"
MY_WORK_DIR="${MY_WORK_DIR:-/home/luckfox/workspace/buildroot-study/my-work}"

mkdir -p "${TARGET_DIR}/sys/kernel/tracing" "${TARGET_DIR}/sys/kernel/debug"

if ! grep -qE '^[^#][[:space:]]+/sys/kernel/tracing[[:space:]]+tracefs[[:space:]]' "${FSTAB}"; then
	cat >>"${FSTAB}" <<'EOT'
tracefs		/sys/kernel/tracing	tracefs	defaults	0	0
EOT
fi

if ! grep -qE '^[^#][[:space:]]+/sys/kernel/debug[[:space:]]+debugfs[[:space:]]' "${FSTAB}"; then
	cat >>"${FSTAB}" <<'EOT'
debugfs		/sys/kernel/debug	debugfs	defaults	0	0
EOT
fi

if [ -d "${MY_WORK_DIR}/prac" ]; then
	rm -rf "${TARGET_DIR}/home/prac"
	mkdir -p "${TARGET_DIR}/home"
	cp -a "${MY_WORK_DIR}/prac" "${TARGET_DIR}/home/prac"
fi
EOF

RUN chmod +x board/qemu/aarch64-virt/post-build.sh && \
    make qemu_aarch64_virt_defconfig && \
    cat >>.config <<'EOF'

# Architecture
BR2_aarch64=y
BR2_cortex_a53=y

# Toolchain
BR2_TOOLCHAIN_BUILDROOT_GLIBC=y
BR2_TOOLCHAIN_BUILDROOT_CXX=y

# System
BR2_SYSTEM_DHCP="eth0"

# Filesystem
BR2_TARGET_ROOTFS_EXT2=y
BR2_TARGET_ROOTFS_EXT2_4=y
BR2_TARGET_ROOTFS_EXT2_SIZE="512M"
# BR2_TARGET_ROOTFS_TAR is not set

# Image
BR2_ROOTFS_POST_BUILD_SCRIPT="board/qemu/aarch64-virt/post-build.sh"
BR2_ROOTFS_POST_IMAGE_SCRIPT="board/qemu/post-image.sh"
BR2_ROOTFS_POST_SCRIPT_ARGS="$(BR2_DEFCONFIG)"

# Linux headers same as kernel
BR2_PACKAGE_HOST_LINUX_HEADERS_CUSTOM_6_1=y

# Kernel
BR2_LINUX_KERNEL=y
BR2_LINUX_KERNEL_CUSTOM_VERSION=y
BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="6.1.44"
BR2_LINUX_KERNEL_USE_CUSTOM_CONFIG=y
BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE="board/qemu/aarch64-virt/linux.config"
BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES="board/qemu/aarch64-virt/observe-kernel.config board/qemu/aarch64-virt/v4l2-kernel.config"
BR2_LINUX_KERNEL_NEEDS_HOST_OPENSSL=y
BR2_LINUX_KERNEL_NEEDS_HOST_PAHOLE=y
BR2_LINUX_KERNEL_NEEDS_HOST_LIBELF=y

# Runtime observability and network tools
BR2_PACKAGE_AUDIT=y
BR2_PACKAGE_BABELTRACE2=y
BR2_PACKAGE_BINUTILS=y
BR2_PACKAGE_BPFTOOL=y
BR2_PACKAGE_DROPWATCH=y
BR2_PACKAGE_ELFUTILS=y
BR2_PACKAGE_ELFUTILS_PROGS=y
BR2_PACKAGE_ETHTOOL=y
BR2_PACKAGE_IPROUTE2=y
BR2_PACKAGE_LIBBPF=y
BR2_PACKAGE_LINUX_TOOLS_PERF=y
BR2_PACKAGE_LINUX_TOOLS_PERF_NEEDS_HOST_PYTHON3=y
BR2_PACKAGE_LINUX_TOOLS_PERF_TUI=y
BR2_PACKAGE_LINUX_TOOLS_PERF_SCRIPTS=y
BR2_PACKAGE_LTRACE=y
BR2_PACKAGE_LTTNG_LIBUST=y
BR2_PACKAGE_LTTNG_MODULES=y
BR2_PACKAGE_LTTNG_TOOLS=y
BR2_PACKAGE_PYTHON3=y
BR2_PACKAGE_STRACE=y
BR2_PACKAGE_SYSSTAT=y
BR2_PACKAGE_TCPDUMP=y
BR2_PACKAGE_TRACE_CMD=y
BR2_PACKAGE_UFTRACE=y

# V4L2/media tutorials
BR2_PACKAGE_FFMPEG=y
BR2_PACKAGE_FFMPEG_FFMPEG=y
BR2_PACKAGE_FFMPEG_ENCODERS="all"
BR2_PACKAGE_FFMPEG_DECODERS="all"
BR2_PACKAGE_FFMPEG_MUXERS="all"
BR2_PACKAGE_FFMPEG_DEMUXERS="all"
BR2_PACKAGE_FFMPEG_PARSERS="all"
BR2_PACKAGE_FFMPEG_BSFS="all"
BR2_PACKAGE_FFMPEG_PROTOCOLS="all"
BR2_PACKAGE_FFMPEG_FILTERS="all"
BR2_PACKAGE_FFMPEG_INDEVS=y
BR2_PACKAGE_FFMPEG_OUTDEVS=y
BR2_PACKAGE_LIBV4L=y
BR2_PACKAGE_LIBV4L_UTILS=y
BR2_PACKAGE_V4L2GRAB=y
BR2_PACKAGE_V4L2LOOPBACK=y
BR2_PACKAGE_V4L2LOOPBACK_UTILS=y
BR2_PACKAGE_YAVTA=y

# QEMU helper generated inside output/host, useful when host packages differ.
BR2_PACKAGE_HOST_QEMU=y
BR2_PACKAGE_HOST_QEMU_SYSTEM_MODE=y
EOF

RUN make olddefconfig

COPY --chown=luckfox:luckfox my-work/ ${MY_WORK_DIR}/

RUN chmod +x ${MY_WORK_DIR}/scripts/*.sh ${MY_WORK_DIR}/prac/*.sh 2>/dev/null || true && \
    mkdir -p ${MY_WORK_DIR}/myapp/.cargo && \
    cat >${MY_WORK_DIR}/myapp/.cargo/config.toml <<EOF
[target."cfg(all())"]
runner = "sudo -E"

[target.aarch64-unknown-linux-gnu]
linker = "${BUILDROOT_DIR}/output/host/bin/aarch64-buildroot-linux-gnu-gcc"
EOF

# Buildroot normally creates this from board/qemu/post-image.sh after a full
# image build. Create it during environment setup as well, so tutorials can
# reference a stable path before the first successful image generation.
RUN mkdir -p ${BUILDROOT_DIR}/output/images && \
    cat >${BUILDROOT_DIR}/output/images/start-qemu.sh <<EOF
#!/bin/sh

BINARIES_DIR="\${0%/*}/"
# shellcheck disable=SC2164
cd "\${BINARIES_DIR}"

if [ ! -e rootfs.ext4 ] && [ -e rootfs.ext2 ]; then
    ln -sf rootfs.ext2 rootfs.ext4
fi

mode_serial=false
mode_sys_qemu=false
while [ "\${1:-}" ]; do
    case "\$1" in
    --serial-only|serial-only) mode_serial=true; shift;;
    --use-system-qemu) mode_sys_qemu=true; shift;;
    --) shift; break;;
    *) echo "unknown option: \$1" >&2; exit 1;;
    esac
done

if \${mode_serial}; then
    EXTRA_ARGS="-nographic"
else
    EXTRA_ARGS=""
fi

if ! \${mode_sys_qemu}; then
    export PATH="${BUILDROOT_DIR}/output/host/bin:\${PATH}"
fi

exec qemu-system-aarch64 \\
    -M virt \\
    -cpu cortex-a53 \\
    -nographic \\
    -smp 1 \\
    -kernel Image \\
    -append "rootwait root=/dev/vda console=ttyAMA0" \\
    -netdev user,id=eth0 \\
    -device virtio-net-device,netdev=eth0 \\
    -drive file=rootfs.ext4,if=none,format=raw,id=hd0 \\
    -device virtio-blk-device,drive=hd0 \\
    \${EXTRA_ARGS} "\$@"
EOF
RUN chmod +x ${BUILDROOT_DIR}/output/images/start-qemu.sh

WORKDIR ${MY_WORK_DIR}

CMD ["/bin/bash"]
