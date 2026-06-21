# buildroot-study

这是一个独立的 Buildroot 学习工程。它由两部分组成：

- `Dockerfile`：构建和当前教程对齐的 Ubuntu 24.04 + Buildroot 2023.11.1 学习环境。
- `my-work/`：教程、脚本、示例程序和 eBPF/V4L2 实验代码集合。

## 环境对齐

当前 Dockerfile 对齐的验证环境：

- Host family: Ubuntu 24.04 / x86_64 / WSL2
- Buildroot: 2023.11.1
- Target: QEMU aarch64 virt / Cortex-A53
- Kernel: Linux 6.1.44
- Rootfs: ext4, 512M
- Kernel fragments: `observe-kernel.config` + `v4l2-kernel.config`

镜像内会准备 Buildroot、QEMU、aarch64 交叉编译工具、Rust nightly/stable、`bpf-linker`、`bindgen`、`cargo-generate`、Clang/LLVM、pahole，以及 V4L2/eBPF/trace/perf 教程所需的 Buildroot 配置。镜像不会写入 Codex auth 或任何 API key。

## 构建镜像

```bash
cd buildroot-study
docker build -t buildroot-study .
```

如果不使用默认阿里云 apt 镜像：

```bash
docker build --build-arg APT_MIRROR=archive.ubuntu.com -t buildroot-study .
```

## 启动容器

```bash
docker run --rm -it \
  --name buildroot-study \
  --privileged \
  -v "$PWD":/home/luckfox/workspace/buildroot-study \
  buildroot-study
```

进入容器后默认目录是：

```bash
/home/luckfox/workspace/buildroot-study/my-work
```

Buildroot 目录是：

```bash
/home/luckfox/workspace/buildroot-2023.11.1
```

## 首次构建 Buildroot

```bash
cd /home/luckfox/workspace/buildroot-2023.11.1
make
```

构建完成后，镜像和启动脚本位于：

```bash
output/images/Image
output/images/rootfs.ext2
output/images/start-qemu.sh
```

`Dockerfile` 会在环境搭建阶段预先创建 `output/images/start-qemu.sh`，不依赖 Buildroot 的 `board/qemu/post-image.sh` 成功执行。脚本启动时如果发现 `rootfs.ext2` 已存在但 `rootfs.ext4` 链接缺失，会自动补齐 `rootfs.ext4 -> rootfs.ext2`。

启动 QEMU：

```bash
cd /home/luckfox/workspace/buildroot-2023.11.1/output/images
./start-qemu.sh
```

## 复现实验

推荐阅读顺序：

1. `my-work/docs/1_add_software.md`
2. `my-work/docs/2_cross.md`
3. `my-work/docs/3_kernel.md`
4. `my-work/docs/5_aya_ebpf.md`
5. `my-work/docs/6_bpf_helllo.md`
6. `my-work/docs/7_observe.md`
7. `my-work/docs/8_v4l2.md`
8. `my-work/docs/9_v4l2_v1/9_v4l2_v2.md`：第 8 章之后的 V4L2 深化实验题；第 10 章附标准答案。

`4_v4l2.md` 和 `9_v4l2_v1/orig.md` 保留为历史/补充材料；V4L2 主线优先看 `8_v4l2.md`，再看 `9_v4l2_v2.md` 中的第 9 章实验题和第 10 章标准答案。

## 常用脚本

```bash
cd /home/luckfox/workspace/buildroot-study/my-work

# 查看或切换内核 fragment
scripts/apply_kernel_fragments.sh --show
scripts/apply_kernel_fragments.sh --all --reconfigure

# 将 my-work/prac 打包到 Buildroot output/target/home/prac
scripts/oneclick.sh

# 编译并部署 Aya eBPF/XDP 示例
scripts/build_myapp.sh deps-check
scripts/build_myapp.sh
```

Dockerfile 已将 `my-work/prac` 纳入 Buildroot post-build 脚本，执行 `make` 重新生成 rootfs 时会自动复制到 guest 的 `/home/prac`。
