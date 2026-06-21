# Buildroot study docs

这里的文档按“先搭环境，再构建，再观测”的路径组织。建议优先阅读主线文档，历史文档只在需要对照早期实验记录时再看。

## 主线顺序

1. `1_add_software.md`：理解 Buildroot 如何选择和启用软件包。
2. `2_cross.md`：使用 Buildroot 生成的 aarch64 工具链交叉编译用户态程序。
3. `3_kernel.md`：交叉编译外部内核模块并部署到 QEMU guest。
4. `5_aya_ebpf.md`：准备 Aya eBPF/XDP 交叉编译环境。
5. `6_bpf_helllo.md`：把 eBPF/XDP 示例部署到 rootfs 并在 guest 内验证。
6. `7_observe.md`：使用 ftrace、trace-cmd、perf、uprobe 做通用观测。
7. `8_v4l2.md`：搭建 V4L2/media kernel fragment、vivid/vimc 和基础观测路径。
8. `9_v4l2_v1/9_v4l2_v2.md`：第 8 章的后续深化实验；第 9 章给出实验题，第 10 章附实际虚拟机输出和标准答案。

## 补充和历史材料

- `4_v4l2.md`：早期 v4l2loopback 方案，适合了解虚拟摄像头背景。
- `5_bugfix.md`：已遇到过的 ftrace 和 bpftool/libsframe 修复记录。
- `9_v4l2_v1/9_v4l2_v1.md`：V4L2 实验初版。
- `9_v4l2_v1/orig.md`：原始实验记录。
- `9_v4l2_v1/fire_graph1/`：火焰图脚本和一次 V4L2 perf 数据样例。

## 路径约定

除特别说明外，文档中的命令默认在容器内执行：

```bash
cd /home/luckfox/workspace/buildroot-study/my-work
```

Buildroot 目录默认是：

```bash
/home/luckfox/workspace/buildroot-2023.11.1
```
