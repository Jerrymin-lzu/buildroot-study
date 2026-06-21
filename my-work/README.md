# my-work

`my-work` 是 `buildroot-study` 的教程、脚本、示例程序和实验材料集合。它依赖上层 `buildroot-study/Dockerfile` 准备 Buildroot/QEMU/交叉编译/eBPF/V4L2 学习环境。

## 路径约定

当前宿主机路径：

```bash
/home/luckfox/workspace/my_work/buildroot-study/my-work
```

容器内默认路径：

```bash
/home/luckfox/workspace/buildroot-study/my-work
```

Buildroot 默认路径：

```bash
/home/luckfox/workspace/buildroot-2023.11.1
```

QEMU guest 内示例目录：

```bash
/home/prac
```

## 上层工程结构

`buildroot-study` 当前按两部分组织：

- `Dockerfile`：构建和当前教程对齐的 Ubuntu 24.04 + Buildroot 2023.11.1 学习环境。
- `my-work/`：教程文档、脚本、示例程序和实验材料集合。

上层关键文件：

- `buildroot-study/Dockerfile`：安装 Buildroot 依赖、QEMU、aarch64 交叉工具链、Rust/Aya eBPF 工具链、V4L2/trace/perf 相关包；下载 Buildroot 2023.11.1；写入 kernel fragments、post-build 脚本、Buildroot `.config`；复制 `my-work`；并手动生成 `output/images/start-qemu.sh`。
- `buildroot-study/README.md`：工程入口说明，解释如何构建 Docker 镜像、启动容器、构建 Buildroot、运行 QEMU，以及推荐教程阅读顺序。
- `buildroot-study/.dockerignore`：控制 Docker build context，排除 `.git`、`target/`、`output/`、`dl/`、`.cache/`、`.o`、`.ko` 等构建产物。

## my-work 目录树

```text
my-work/
├── README.md
├── docs/
│   ├── README.md
│   ├── 1_add_software.md
│   ├── 2_cross.md
│   ├── 3_kernel.md
│   ├── 4_v4l2.md
│   ├── 5_aya_ebpf.md
│   ├── 5_bugfix.md
│   ├── 6_bpf_helllo.md
│   ├── 7_observe.md
│   ├── 8_v4l2.md
│   └── 9_v4l2_v1/
├── scripts/
├── prac/
└── myapp/
```

## 推荐学习顺序

1. `docs/1_add_software.md`：Buildroot 软件包选择与配置。
2. `docs/2_cross.md`：C/C++ 用户态程序交叉编译和部署。
3. `docs/3_kernel.md`：外部内核模块交叉编译。
4. `docs/5_aya_ebpf.md`：Aya eBPF/XDP 交叉编译。
5. `docs/6_bpf_helllo.md`：eBPF/XDP 程序部署到 rootfs 并在 QEMU guest 内验证。
6. `docs/7_observe.md`：ftrace、trace-cmd、perf、uprobe 观测。
7. `docs/8_v4l2.md`：V4L2 fragment、vivid/vimc 和基础观测。
8. `docs/9_v4l2_v1/9_v4l2_v2.md`：第 8 章的后续深化实验；第 9 章是实验题，第 10 章附实际虚拟机输出和标准答案。

`docs/4_v4l2.md`、`docs/9_v4l2_v1/9_v4l2_v1.md` 和 `docs/9_v4l2_v1/orig.md` 保留为历史版本和补充材料。

## docs 文件说明

- `docs/README.md`：文档阅读路线和路径约定。
- `docs/1_add_software.md`：说明如何在 Buildroot 中搜索、选择和启用软件包。
- `docs/2_cross.md`：说明如何使用 Buildroot 生成的 aarch64 工具链交叉编译用户态程序，并部署到 QEMU guest。
- `docs/3_kernel.md`：说明如何交叉编译外部内核模块，并在 guest 中加载验证。
- `docs/4_v4l2.md`：早期 v4l2loopback 虚拟摄像头方案，主要作为历史和背景材料保留。
- `docs/5_aya_ebpf.md`：说明 Aya eBPF/XDP 交叉编译环境、Cargo 配置和部署流程。
- `docs/5_bugfix.md`：记录 ftrace trace 输出为空、bpftool/libsframe 缺失等问题的修复方法。
- `docs/6_bpf_helllo.md`：说明如何将 eBPF/XDP 示例打包进 rootfs，并在 QEMU guest 中运行验证。
- `docs/7_observe.md`：说明如何在 QEMU guest 中使用 ftrace、trace-cmd、perf 和 uprobe 做通用观测。
- `docs/8_v4l2.md`：当前主线 V4L2/media 教程，覆盖 kernel fragment、vivid/vimc、trace/perf 观测路径。

## docs/9_v4l2_v1 文件说明

- `9_v4l2_v1.md`：V4L2 观测实验初版。
- `9_v4l2_v2.md`：V4L2 观测实验题和标准答案版；当前更推荐阅读。文内第 9 章恢复为问题和任务清单，第 10 章附实际虚拟机输出、分析和结论。
- `orig.md`：原始实验记录。
- `fire_graph1/flamegraph.pl`：生成火焰图的 Perl 脚本。
- `fire_graph1/stackcollapse-perf.pl`：将 `perf script` 输出折叠为火焰图输入格式的脚本。
- `fire_graph1/perf.script`：一次 V4L2 perf script 原始输出样例。
- `fire_graph1/out.folded`：折叠后的调用栈数据。
- `fire_graph1/v4l2.svg`：根据样例数据生成的 V4L2 火焰图。

## scripts 文件说明

- `scripts/apply_kernel_fragments.sh`：管理 Buildroot `.config` 中的 `BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES`，支持列出、查看、启用、追加、移除、清空 kernel fragment，也可以触发 `make olddefconfig`、`make linux-reconfigure` 或完整 `make`。
- `scripts/build_myapp.sh`：一键检查依赖、交叉编译、验证和部署 Aya eBPF/XDP 示例。常用子命令包括 `deps-check`、`build-only`、`deploy-only`、`verify`、`clean`。
- `scripts/copy_prac_to_rootfs.sh`：将 `my-work/prac` 复制到 Buildroot `output/target/home/prac`，用于重新生成 rootfs 前同步实验文件。
- `scripts/oneclick.sh`：`copy_prac_to_rootfs.sh` 的简化入口，会自动推断 Buildroot 目录并复制 `prac/`。

常用命令：

```bash
cd /home/luckfox/workspace/buildroot-study/my-work

scripts/apply_kernel_fragments.sh --show
scripts/apply_kernel_fragments.sh --all --reconfigure
scripts/build_myapp.sh deps-check
scripts/oneclick.sh
```

## prac 文件说明

`prac/` 会被 Buildroot post-build 脚本复制到 guest 的 `/home/prac`，用于放置可以直接在 QEMU guest 中运行的示例和工具。

- `prac/.gitkeep`：占位文件，用于保留目录。
- `prac/myapp`：已经编译好的 aarch64 ELF 可执行文件，来自 Aya eBPF/XDP 用户态 loader。
- `prac/test1.c`：空的 C 示例文件，占位或临时实验用。
- `prac/xdp_traffic.sh`：在 guest 内制造 `eth0` 流量，用于触发 XDP 程序。
- `prac/observe/obs_demo.c`：用于 perf、uprobe、ftrace 观测的 C demo 源码。
- `prac/observe/obs_demo`：已经编译好的 aarch64 ELF demo，带 debug info，用于观测实验。

## myapp 工程说明

`myapp/` 是一个 Aya eBPF/XDP Rust workspace，包含用户态 loader、eBPF 程序和公共 crate。

顶层文件：

- `myapp/Cargo.toml`：workspace 配置，包含 `myapp`、`myapp-common`、`myapp-ebpf` 三个成员。
- `myapp/Cargo.lock`：Rust 依赖锁定文件。
- `myapp/.cargo/config.toml`：配置 aarch64 交叉链接器，指向 Buildroot 生成的 `aarch64-buildroot-linux-gnu-gcc`。
- `myapp/.gitignore`：Rust 工程忽略规则。
- `myapp/README.md`：Aya 模板生成的 myapp 原始说明。
- `myapp/Brewfile`：macOS 上安装 LLVM 的辅助文件，Linux/Docker 主流程通常不用。
- `myapp/rustfmt.toml`：Rust 格式化配置。
- `myapp/pre-script.rhai`：Aya 模板生成相关脚本配置。
- `myapp/LICENSE-APACHE`、`myapp/LICENSE-MIT`、`myapp/LICENSE-GPL2`：许可证文件。

用户态程序：

- `myapp/myapp/Cargo.toml`：用户态 loader crate 配置。
- `myapp/myapp/build.rs`：构建时调用 `aya_build` 编译 eBPF 子工程。
- `myapp/myapp/src/main.rs`：用户态程序，加载内嵌 eBPF object，将 XDP 程序 attach 到默认网卡 `eth0`，等待 Ctrl-C 退出。

eBPF 程序：

- `myapp/myapp-ebpf/Cargo.toml`：eBPF crate 配置。
- `myapp/myapp-ebpf/build.rs`：检查 `bpf-linker` 并让 Cargo 在 linker 变化时重新构建。
- `myapp/myapp-ebpf/src/main.rs`：XDP eBPF 程序，收到包后输出 `received a packet`，然后返回 `XDP_PASS`。
- `myapp/myapp-ebpf/src/lib.rs`：库目标占位，用于满足工程结构。

公共 crate：

- `myapp/myapp-common/Cargo.toml`：公共 crate 配置。
- `myapp/myapp-common/src/lib.rs`：`#![no_std]` 公共库，目前基本为空，后续可放用户态和 eBPF 共享的数据结构。

## Git 管理状态

当前检查结果：

- `/home/luckfox/workspace/my_work/buildroot-study` 内没有 `.git`。
- `/home/luckfox/workspace/my_work/buildroot-study` 不属于任何上层 Git 仓库。
- `/home/luckfox/workspace/my_work` 本身也不是 Git 仓库。
- `/home/luckfox/workspace/my_work/myapp/.git` 是另一个独立 Git 仓库，和 `buildroot-study` 没有父子管理关系。

因此，`buildroot-study` 当前不是 Git 管理的工程。如果需要版本化，可以在 `buildroot-study` 目录执行：

```bash
git init
git add .
git commit -m "Initialize buildroot study project"
```

版本化前建议确认是否要保留 `prac/myapp`、`prac/observe/obs_demo` 这类已经编译好的二进制产物。如果希望仓库只保存源码和文档，可以把这些二进制加入 `.gitignore` 或在提交前移除。
