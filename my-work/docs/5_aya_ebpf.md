# 5. 交叉编译 Aya eBPF 程序

本文说明如何将 Aya eBPF (XDP) 工程交叉编译为 aarch64 二进制，部署到 Buildroot 生成的 QEMU 虚拟机中运行。

---

## 背景

myapp 是一个基于 Aya 框架的 eBPF/XDP 项目，通过 `cargo generate https://github.com/aya-rs/aya-template` 生成。项目包含三个 crate：

```
myapp/
├── Cargo.toml          # workspace 配置
├── .cargo/
│   └── config.toml     # cargo 配置
├── myapp/              # 用户态程序（需交叉编译为 aarch64）
│   ├── Cargo.toml
│   ├── build.rs        # 负责编译 myapp-ebpf
│   └── src/main.rs
├── myapp-ebpf/         # eBPF 程序（编译为 BPF 字节码，架构无关）
│   ├── Cargo.toml
│   ├── build.rs
│   └── src/main.rs
└── myapp-common/       # 共享代码
    ├── Cargo.toml
    └── src/lib.rs
```

### 两层编译架构

```
┌──────────────────────────────────────────────────────────────────┐
│  x86 主机 (WSL2)                                                 │
│                                                                  │
│  ┌─────────────────────┐     ┌──────────────────────────────┐    │
│  │ myapp-ebpf           │     │ myapp (用户态)                │    │
│  │                      │     │                              │    │
│  │ bpf-linker (nightly) │     │ aarch64-buildroot-linux-gnu- │    │
│  │         │            │     │ gcc (交叉编译器)              │    │
│  │         ▼            │     │         │                    │    │
│  │   myapp.bpf.o        │     │         ▼                    │    │
│  │   (BPF 字节码)        │     │   myapp (ELF aarch64)       │    │
│  │   架构无关            │     │   需交叉编译                  │    │
│  └──────────┬───────────┘     └──────────────┬───────────────┘    │
│             │                                │                    │
│             └──────────┬─────────────────────┘                    │
│                        │ include_bytes!()                         │
│                        ▼                                          │
│              最终二进制 (aarch64)                                  │
│              eBPF 字节码嵌入其中                                   │
└──────────────────────────────────────────────────────────────────┘
                                 │
                                 │ 部署到 rootfs
                                 ▼
┌──────────────────────────────────────────────────────────────────┐
│  QEMU 虚拟机 (ARM aarch64)                                       │
│                                                                  │
│  ./myapp --iface eth0                                            │
│    │                                                             │
│    ├── 加载内嵌的 eBPF 字节码 → 内核 BPF verifier → JIT 为 ARM64 │
│    └── 挂载 XDP 程序到 eth0                                      │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

**关键认知**：

- **eBPF 程序**（`myapp-ebpf`）编译为 BPF 字节码，**与目标架构无关**，在本机用 bpf-linker 编译即可
- **用户态程序**（`myapp`）**必须交叉编译为目标架构**（aarch64），因为它直接在虚拟机中运行
- eBPF 字节码在 `build.rs` 中通过 `aya_build::build_ebpf` 编译后，由 `include_bytes_aligned!()` 宏嵌入到用户态二进制中

---

## 步骤 1：安装依赖

### 1.1 Rust 工具链

```bash
# 安装 stable 和 nightly 工具链
rustup install stable
rustup toolchain install nightly --component rust-src

# 安装 aarch64 交叉编译目标
rustup target add aarch64-unknown-linux-gnu
```

### 1.2 bpf-linker

```bash
# 根据 bpf-linker README 安装最新版本
# https://github.com/aya-rs/bpf-linker#installation
cargo install bpf-linker
```

### 1.3 cargo-generate（生成项目模板时使用）

```bash
cargo install cargo-generate
```

### 1.4 bpftool

```bash
# Ubuntu/Debian
sudo apt install linux-tools-$(uname -r) linux-tools-common

# 或从源码构建
# https://github.com/libbpf/bpftool
```

### 1.5 验证 Buildroot 交叉编译工具链可用

```bash
ls ~/workspace/buildroot-2023.11.1/output/host/bin/aarch64-buildroot-linux-gnu-gcc
# 预期输出: .../aarch64-buildroot-linux-gnu-gcc (可执行文件存在)

aarch64-buildroot-linux-gnu-gcc --version
# 预期输出: aarch64-buildroot-linux-gnu-gcc.br_real (Buildroot 2023.11.1) 12.3.0
```

> 如果 `output/host/bin/` 目录为空，说明 Buildroot 尚未完成编译，先执行 `cd ~/workspace/buildroot-2023.11.1 && make`。

---

## 步骤 2：配置 Cargo 交叉编译

编辑 `myapp/.cargo/config.toml`，在原有配置基础上添加 aarch64 目标：

```toml
# 原有：本机运行时使用 sudo
[target."cfg(all())"]
runner = "sudo -E"

# 新增：aarch64 交叉编译配置
[target.aarch64-unknown-linux-gnu]
linker = "/home/luckfox/workspace/buildroot-2023.11.1/output/host/bin/aarch64-buildroot-linux-gnu-gcc"
```

> **说明**：`linker` 指定 cargo 在链接阶段使用的交叉链接器。rustc 生成的 `.o` 文件本身就是目标架构的，只需交叉链接器完成最终链接。

---

## 步骤 3：设置环境变量

每次打开新终端时执行：

```bash
# 将交叉编译器加入 PATH
export PATH=$PATH:/home/luckfox/workspace/buildroot-2023.11.1/output/host/bin
```

> 可将此行追加到 `~/.bashrc` 中。

---

## 步骤 4：构建

### 4.1 完整构建流程

```bash
cd ~/workspace/buildroot-study/my-work/myapp

# 1) 构架 eBPF 程序（本机编译，生成 BPF 字节码）
cargo build --package myapp-ebpf --release

# 2) 交叉编译用户态程序（aarch64）
#    需要 nightly + -Z build-std（为目标架构重新编译标准库）
cargo +nightly build \
    --package myapp \
    --target aarch64-unknown-linux-gnu \
    --release \
    -Z build-std=core,std,alloc,proc_macro,test
```

### 4.2 各参数说明

| 参数 | 含义 |
|------|------|
| `cargo build` | 默认 stable 工具链，用于编译 eBPF 程序 |
| `cargo +nightly build` | 必须使用 nightly，因为需要 unstable 特性 `-Z build-std` |
| `--package myapp` | 只编译用户态程序（myapp-ebpf 已单独编译） |
| `--target aarch64-unknown-linux-gnu` | 目标架构为 ARM64 |
| `-Z build-std=core,std,...` | 为目标架构重新编译 Rust 标准库（x86 的 std 不适用于 ARM） |
| `--release` | 优化编译（eBPF 程序也建议 release 模式） |

### 4.3 为什么需要 `-Z build-std`

Rust 标准库（std）包含平台相关代码（系统调用、线程、内存管理等）。主机安装的 std 是 x86 版本的，无法在 ARM 上运行。`-Z build-std` 会为目标架构从源码重新编译 std。

### 4.4 构建脚本自动编译 eBPF

用户态 crate 的 `build.rs` 会自动编译 `myapp-ebpf`：

```rust
// myapp/build.rs 的关键逻辑
let ebpf_package = aya_build::Package {
    name: "myapp-ebpf",
    root_dir: "../myapp-ebpf",
    ..Default::default()
};
aya_build::build_ebpf([ebpf_package], Toolchain::default());
```

`main.rs` 中通过 `include_bytes_aligned!` 将编译好的 BPF 字节码嵌入到最终二进制中：

```rust
let mut ebpf = aya::Ebpf::load(aya::include_bytes_aligned!(concat!(
    env!("OUT_DIR"),
    "/myapp"
)))?;
```

---

## 步骤 5：验证编译产物

```bash
# 检查文件类型（确认是 ARM64 二进制）
file target/aarch64-unknown-linux-gnu/release/myapp
# 预期输出: ELF 64-bit LSB executable, ARM aarch64, ...

# 查看动态链接器
aarch64-buildroot-linux-gnu-readelf -l target/aarch64-unknown-linux-gnu/release/myapp \
    | grep interpreter
# 预期输出类似: [Requesting program interpreter: /lib/ld-linux-aarch64.so.1]

# 查看依赖的动态库
aarch64-buildroot-linux-gnu-readelf -d target/aarch64-unknown-linux-gnu/release/myapp \
    | grep NEEDED

# 确认是静态链接还是动态链接
aarch64-buildroot-linux-gnu-readelf -d target/aarch64-unknown-linux-gnu/release/myapp \
    | grep -E "STATIC|DYNAMIC"
```

> **提示**：如果希望完全静态链接（避免虚拟机中缺库），可在 `.cargo/config.toml` 中添加 RUSTFLAGS：
> ```toml
> [target.aarch64-unknown-linux-gnu]
> rustflags = ["-C", "target-feature=+crt-static"]
> ```
> 这会生成完全静态的二进制，文件较大但部署简单。

---

## 步骤 6：部署到虚拟机

### 方式 A：打包到根文件系统（推荐，随镜像一起部署）

```bash
# 拷贝编译产物到 prac 目录
cp ~/workspace/buildroot-study/my-work/myapp/target/aarch64-unknown-linux-gnu/release/myapp \
    ~/workspace/buildroot-study/my-work/prac/

# 打包到 Buildroot 根文件系统
cd ~/workspace/buildroot-study/my-work
./scripts/copy_prac_to_rootfs.sh ~/workspace/buildroot-2023.11.1/output/target

# 重新生成根文件系统镜像
cd ~/workspace/buildroot-2023.11.1
make
```

执行后，`myapp` 会出现在虚拟机的 `/home/prac/myapp`。

### 方式 B：运行时通过 scp 传输（虚拟机已启动且有网络）

```bash
scp ~/workspace/buildroot-study/my-work/myapp/target/aarch64-unknown-linux-gnu/release/myapp \
    root@<虚拟机IP>:/home/prac/
```

---

## 步骤 7：在虚拟机中运行

### 7.1 启动并登录虚拟机

使用 Buildroot 生成的 QEMU 启动脚本或镜像启动虚拟机。

### 7.2 运行 XDP 程序

```bash
# 进入程序目录
cd /home/prac

# 添加执行权限
chmod +x myapp

# 运行（需指定网卡接口）
./myapp --iface eth0
# 输出: Waiting for Ctrl-C...
```

程序会：
1. 加载内嵌的 eBPF 字节码到内核
2. 初始化 eBPF 日志记录器
3. 将 XDP 程序挂载到指定网卡
4. 等待 Ctrl-C 信号

按 `Ctrl-C` 退出，eBPF 程序会自动从网卡卸载。

### 7.3 查看 eBPF 日志

```bash
# 查看内核日志（eBPF 程序的 info! 输出）
dmesg | tail -10
# 预期看到: "received a packet"（每收到一个数据包输出一次）

# 或者在另一个终端中实时查看
dmesg -w
```

### 7.4 验证 eBPF 程序已挂载

```bash
# 查看 XDP 程序挂载状态
bpftool net list
# 预期输出类似:
# xdp:
# eth0(5) generic id 42

# 查看已加载的 BPF 程序
bpftool prog list
```

---

## 完整操作速查

```bash
# === 一次性环境配置 ===
rustup target add aarch64-unknown-linux-gnu
# 编辑 myapp/.cargo/config.toml，添加 [target.aarch64-unknown-linux-gnu] 段

# === 每次编译 ===
export PATH=$PATH:/home/luckfox/workspace/buildroot-2023.11.1/output/host/bin

cd ~/workspace/buildroot-study/my-work/myapp

# 1. 编译 eBPF 程序（本机）
cargo build --package myapp-ebpf --release

# 2. 交叉编译用户态程序（aarch64）
cargo +nightly build \
    --package myapp \
    --target aarch64-unknown-linux-gnu \
    --release \
    -Z build-std=core,std,alloc,proc_macro,test

# 3. 验证
file target/aarch64-unknown-linux-gnu/release/myapp

# 4. 部署
cp target/aarch64-unknown-linux-gnu/release/myapp ~/workspace/buildroot-study/my-work/prac/
cd ~/workspace/buildroot-study/my-work
./scripts/copy_prac_to_rootfs.sh ~/workspace/buildroot-2023.11.1/output/target
cd ~/workspace/buildroot-2023.11.1 && make

# === 虚拟机中运行 ===
cd /home/prac && ./myapp --iface eth0
```

---

## 常见问题

**Q1: `cargo +nightly build` 报 `the `-Z` flag is only accepted on the nightly channel`？**

确认 nightly 工具链已安装：

```bash
rustup toolchain install nightly --component rust-src
rustup run nightly rustc --version
```

**Q2: `error: no such subcommand: `which``？**

这是 `bpf-linker` 未安装的提示。安装：

```bash
cargo install bpf-linker
```

**Q3: 交叉编译时报 `error: linking with `cc` failed: exit status: 1`？**

链接器未配置或路径错误。检查 `.cargo/config.toml` 中的 `linker` 路径是否正确：

```bash
ls /home/luckfox/workspace/buildroot-2023.11.1/output/host/bin/aarch64-buildroot-linux-gnu-gcc
```

**Q4: 虚拟机中运行 `./myapp: not found`？**

动态链接器路径不匹配。排查方式：

```bash
# 在主机上查看程序期望的链接器
aarch64-buildroot-linux-gnu-readelf -l myapp | grep interpreter

# 在虚拟机中确认该链接器存在
ls /lib/ld-linux-aarch64.so.1
```

如果不存在，考虑静态编译（在 `.cargo/config.toml` 中添加 `rustflags = ["-C", "target-feature=+crt-static"]`）。

**Q5: 虚拟机中 `./myapp --iface eth0` 报 `failed to attach the XDP program`？**

可能原因：
- **网卡不存在**：`ip link show` 查看可用网卡名
- **XDP 驱动不支持**：尝试 `XdpMode::Skb` 模式（在 `main.rs` 中修改）
- **权限不足**：XDP 挂载需要 root 权限，确保以 root 登录

**Q6: 如何在本机快速测试逻辑（不交叉编译）？**

```bash
cd ~/workspace/buildroot-study/my-work/myapp

# 本机构建（x86，用于开发调试）
cargo build --release

# 本机运行（需要 root 权限加载 eBPF）
sudo ./target/release/myapp --iface lo
```

> 注意：本机测试需要内核支持 eBPF，且 `bpf-linker` 生成的 BPF 字节码在 x86 内核中同样可用。

**Q7: 如何单独重新编译 eBPF 程序？**

```bash
# 只重新编译 eBPF 部分
cargo build --package myapp-ebpf --release

# 然后重新编译用户态程序（build.rs 会重新嵌入新的 eBPF 字节码）
cargo +nightly build --package myapp --target aarch64-unknown-linux-gnu --release -Z build-std=core,std,alloc,proc_macro,test
```

**Q8: 编译耗时太长？**

- eBPF 程序通常很小，编译很快
- 交叉编译耗时长主要因为 `-Z build-std` 需要重新编译标准库（首次约 2-5 分钟）
- 标准库编译结果会被 cargo 缓存，后续增量编译会快很多
- 可使用 `sccache` 加速：
  ```bash
  cargo install sccache
  export RUSTC_WRAPPER=sccache
  ```

---

## 进阶：一键编译部署脚本

**文件：`buildroot-study/my-work/scripts/build_myapp.sh`**

```bash
#!/bin/bash
#=============================================================================
# build_myapp.sh — 一键交叉编译并部署 myapp eBPF 程序
#
# 用法:
#   ./build_myapp.sh              # 编译并部署
#   ./build_myapp.sh build-only   # 仅编译，不部署
#   ./build_myapp.sh clean        # 清理编译产物
#=============================================================================

set -e

MYAPP_DIR=~/workspace/buildroot-study/my-work/myapp
BUILDROOT_DIR=~/workspace/buildroot-2023.11.1
PRAC_DIR=~/workspace/buildroot-study/my-work/prac
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET=aarch64-unknown-linux-gnu
TARGET_DIR=target/${TARGET}/release

export PATH=$PATH:${BUILDROOT_DIR}/output/host/bin

case "${1}" in
    clean)
        echo "=== 清理编译产物 ==="
        cd ${MYAPP_DIR}
        cargo clean
        rm -rf target
        echo "清理完成。"
        exit 0
        ;;
    build-only)
        DEPLOY="no"
        ;;
    *)
        DEPLOY="yes"
        ;;
esac

echo "============================================"
echo "  交叉编译 myapp (eBPF/XDP)"
echo "============================================"
echo "  目标架构: ${TARGET}"
echo "  工具链:    aarch64-buildroot-linux-gnu-gcc"
echo "--------------------------------------------"

# 1. 构建 eBPF 程序
echo "[1/3] 构建 eBPF 程序 (本机)..."
cd ${MYAPP_DIR}
cargo build --package myapp-ebpf --release
echo "  eBPF 程序构建完成"

# 2. 交叉编译用户态程序
echo "[2/3] 交叉编译用户态程序 (${TARGET})..."
cargo +nightly build \
    --package myapp \
    --target ${TARGET} \
    --release \
    -Z build-std=core,std,alloc,proc_macro,test
echo "  用户态程序构建完成"

# 3. 验证
echo "--------------------------------------------"
echo "  编译产物信息:"
file ${TARGET_DIR}/myapp
echo "--------------------------------------------"

if [ "${DEPLOY}" = "yes" ]; then
    # 4. 部署
    echo "[3/3] 部署到根文件系统..."
    cp ${TARGET_DIR}/myapp ${PRAC_DIR}/
    "${SCRIPT_DIR}/copy_prac_to_rootfs.sh" ${BUILDROOT_DIR}/output/target
    echo "--------------------------------------------"
    echo "  部署完成！"
    echo ""
    echo "  下一步:"
    echo "    cd ${BUILDROOT_DIR} && make"
    echo "    启动虚拟机 → cd /home/prac && ./myapp --iface eth0"
fi

echo "============================================"
```

使用方式：

```bash
cd ~/workspace/buildroot-study/my-work
chmod +x scripts/build_myapp.sh

./scripts/build_myapp.sh             # 编译并部署
./scripts/build_myapp.sh build-only  # 仅编译，不部署
./scripts/build_myapp.sh clean       # 清理
```
