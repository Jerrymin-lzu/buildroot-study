# 3. 交叉编译内核模块

本文说明如何交叉编译 Linux 内核模块（`.ko` 文件），使其可在 ARM 虚拟机中通过 `insmod` 加载。

---

## 背景

内核模块与普通用户态程序不同：

- 内核模块**必须与目标内核版本一致**（包括内核配置），否则 `insmod` 会报 `Invalid module format`
- 内核模块编译需要**已配置并至少部分编译过的内核源码树**（需要头文件、`Module.symvers` 等）
- 不能直接用 `gcc -c` 编译，必须通过**内核构建系统（kbuild）**

本项目 Buildroot 已完成内核编译，源码树可直接用于模块编译：

| 项目 | 路径/值 |
|------|--------|
| 内核源码树 | `buildroot-2023.11.1/output/build/linux-6.1.44/` |
| 内核版本 | `6.1.44` |
| 目标架构 | `arm64` (ARM Cortex-A53) |
| 交叉编译器 | `aarch64-buildroot-linux-gnu-` |
| 模块安装路径 | `/lib/modules/6.1.44/`（虚拟机内） |

---

## 步骤 1：设置环境

```bash
# 设置交叉编译器 PATH
export PATH=$PATH:/home/luckfox/workspace/buildroot-2023.11.1/output/host/bin

# 内核源码树路径（后续 Makefile 会用到）
export KERNEL_DIR=/home/luckfox/workspace/buildroot-2023.11.1/output/build/linux-6.1.44
```

---

## 步骤 2：编写内核模块源码

在 `/home/luckfox/workspace/buildroot-study/my-work/prac/` 下创建一个子目录存放模块源码。

### 2.1 最简单的模块示例

**文件：`buildroot-study/my-work/prac/hello_mod/hello.c`**

```c
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>

static int __init hello_init(void)
{
    pr_info("Hello kernel module loaded!\n");
    return 0;
}

static void __exit hello_exit(void)
{
    pr_info("Hello kernel module unloaded!\n");
}

module_init(hello_init);
module_exit(hello_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Your Name");
MODULE_DESCRIPTION("A simple hello world kernel module");
```

### 2.2 带参数和更多功能的模块示例

**文件：`buildroot-study/my-work/prac/params_mod/params.c`**

```c
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>

static int debug = 0;
module_param(debug, int, 0644);
MODULE_PARM_DESC(debug, "Enable debug output");

static char *name = "world";
module_param(name, charp, 0644);
MODULE_PARM_DESC(name, "Name to greet");

static int __init params_init(void)
{
    pr_info("Hello %s! (debug=%d)\n", name, debug);
    return 0;
}

static void __exit params_exit(void)
{
    pr_info("Goodbye %s!\n", name);
}

module_init(params_init);
module_exit(params_exit);

MODULE_LICENSE("GPL");
```

---

## 步骤 3：编写模块 Makefile

内核模块的 Makefile 遵循 kbuild 语法，与普通程序 Makefile 不同。

**文件：`buildroot-study/my-work/prac/hello_mod/Makefile`**

```makefile
# 模块目标名（最终生成 hello.ko）
obj-m := hello.o

# 内核源码树路径（由环境变量指定，或用绝对路径）
KERNEL_DIR ?= /home/luckfox/workspace/buildroot-2023.11.1/output/build/linux-6.1.44

# 交叉编译器前缀
CROSS_COMPILE ?= aarch64-buildroot-linux-gnu-

# 目标架构
ARCH ?= arm64

all:
	$(MAKE) -C $(KERNEL_DIR) \
		ARCH=$(ARCH) \
		CROSS_COMPILE=$(CROSS_COMPILE) \
		M=$(PWD) \
		modules

clean:
	$(MAKE) -C $(KERNEL_DIR) \
		ARCH=$(ARCH) \
		CROSS_COMPILE=$(CROSS_COMPILE) \
		M=$(PWD) \
		clean

.PHONY: all clean
```

> **关键说明**：
> - `obj-m := hello.o` — 告诉 kbuild 将 `hello.c` 编译为模块（`obj-y` 表示编译进内核）
> - `-C $(KERNEL_DIR)` — 进入内核源码树，使用内核顶层 Makefile
> - `M=$(PWD)` — 告诉内核构建系统模块源码在当前目录
> - 编译实际由内核构建系统执行，我们的 Makefile 只负责转发

### 多源文件模块

如果模块由多个 `.c` 文件组成：

```makefile
# 最终生成 mymodule.ko，由 file1.o和 file2.o 链接而成
obj-m := mymodule.o
mymodule-objs := file1.o file2.o
```

---

## 步骤 4：交叉编译模块

```bash
cd buildroot-study/my-work/prac/hello_mod
make
```

编译输出：

```
make -C .../linux-6.1.44 ARCH=arm64 CROSS_COMPILE=aarch64-buildroot-linux-gnu- M=... modules
  CC [M]  .../hello.o
  MODPOST .../Module.symvers
  CC [M]  .../hello.mod.o
  LD [M]  .../hello.ko
```

产物文件：

| 文件 | 说明 |
|------|------|
| `hello.ko` | **内核模块**，部署到虚拟机 |
| `hello.o` | 目标文件（中间产物） |
| `hello.mod.c` / `hello.mod.o` | 模块元信息（自动生成） |
| `modules.order` | 模块加载顺序（自动生成，可忽略） |
| `Module.symvers` | 符号版本信息（自动生成，可忽略） |

---

## 步骤 5：验证模块信息

```bash
# 确认是 ARM64 内核模块
file hello.ko
# 输出: hello.ko: ELF 64-bit LSB relocatable, ARM aarch64, ...

# 查看模块详细信息
modinfo hello.ko
# 输出:
#   filename:       .../hello.ko
#   license:        GPL
#   description:    A simple hello world kernel module
#   author:         Your Name
#   vermagic:       6.1.44 SMP mod_unload aarch64

# 查看 vermagic（确认与目标内核匹配）
modinfo hello.ko | grep vermagic
# vermagic:       6.1.44 SMP mod_unload aarch64
```

> **vermagic 必须与虚拟机内核的版本完全一致**，否则 `insmod` 会失败。检查虚拟机内核版本：
> ```bash
> # 在虚拟机中执行
> uname -r
> ```

---

## 步骤 6：部署到虚拟机

### 方式 A：通过 prac 目录打包进根文件系统

```bash
# 拷贝 .ko 文件到 prac
cp buildroot-study/my-work/prac/hello_mod/hello.ko buildroot-study/my-work/prac/

# 打包进根文件系统
cd /home/luckfox/workspace/buildroot-study/my-work
scripts/copy_prac_to_rootfs.sh /home/luckfox/workspace/buildroot-2023.11.1/output/target
cd /home/luckfox/workspace/buildroot-2023.11.1 && make

# 或者：直接拷贝到模块目录（推荐）
mkdir -p /home/luckfox/workspace/buildroot-2023.11.1/output/target/lib/modules/6.1.44/extra
cp buildroot-study/my-work/prac/hello_mod/hello.ko \
    /home/luckfox/workspace/buildroot-2023.11.1/output/target/lib/modules/6.1.44/extra/
```

### 方式 B：运行时通过 scp 传输（虚拟机已启动）

```bash
scp hello.ko root@<虚拟机IP>:/lib/modules/6.1.44/extra/
```

---

## 步骤 7：在虚拟机中加载模块

```bash
# 方法 1：insmod（需提供完整路径，不自动解决依赖）
insmod /lib/modules/6.1.44/extra/hello.ko

# 方法 2：modprobe（推荐，自动解决依赖，需先 depmod）
depmod -a                         # 刷新模块依赖数据库（首次或模块变更后执行）
modprobe hello                    # 不需要路径和 .ko 后缀

# 查看内核日志（模块的 pr_info 输出在这里）
dmesg | tail -5
# [  123.456] Hello kernel module loaded!

# 查看已加载的模块
lsmod | grep hello
# hello                  16384  0

# 卸载模块
rmmod hello
# dmesg: Hello kernel module unloaded!
```

---

## 常用操作速查

```bash
# === 在主机上 ===
cd buildroot-study/my-work/prac/hello_mod

# 编译
make

# 清理
make clean

# 重新编译（先 clean 再 make）
make clean && make

# 验证
file hello.ko
modinfo hello.ko

# 部署
cp hello.ko /home/luckfox/workspace/buildroot-2023.11.1/output/target/lib/modules/6.1.44/extra/
cd /home/luckfox/workspace/buildroot-2023.11.1 && make

# === 在虚拟机中 ===
depmod -a
modprobe hello           # 加载
dmesg | tail -5          # 查看日志
lsmod | grep hello       # 查看状态
rmmod hello              # 卸载
```

---

## 故障排查

### Q1: `insmod: Invalid module format`

**原因**：模块 vermagic 与运行中内核不匹配。

**排查**：

```bash
# 在主机上查看模块 vermagic
modinfo hello.ko | grep vermagic

# 在虚拟机中查看内核 vermagic
uname -r
cat /proc/version
```

确保 Buildroot 内核版本与虚拟机运行的内核是同一个构建产物。

### Q2: `insmod: Unknown symbol in module`

**原因**：模块引用了内核未导出的符号，或依赖另一个未加载的模块。

**排查**：

```bash
# 查看模块依赖了哪些符号
aarch64-buildroot-linux-gnu-nm -u hello.ko

# 在虚拟机中查看内核已导出的符号
cat /proc/kallsyms | grep <符号名>
```

### Q3: `make` 报 `Nothing to be done for 'modules'`

内核源码树的 `Module.symvers` 可能不存在。需要让 Buildroot 至少编译过一次内核：

```bash
cd buildroot-2023.11.1
make linux-rebuild
```

### Q4: `make` 报 `Missing files for modpost`

确保内核源码树已经过完整编译（不只是配置）。执行：

```bash
cd buildroot-2023.11.1
make linux
```

### Q5: 如何在开发阶段快速迭代（避免每次 make 整个 Buildroot）？

只需单独编译模块并 scp 到虚拟机：

```bash
# 主机上
cd buildroot-study/my-work/prac/hello_mod
make clean && make
scp hello.ko root@<虚拟机IP>:/lib/modules/6.1.44/extra/

# 虚拟机中
rmmod hello            # 先卸载旧版本
insmod /lib/modules/6.1.44/extra/hello.ko  # 加载新版本
```

### Q6: 卸载模块时报 `rmmod: Module is in use`

有进程正在使用该模块：

```bash
# 查看被哪些进程使用
lsmod | grep hello
# 第 3 列 "Used by" 如果非 0，说明被其他模块依赖

# 强制卸载（可能导致内核不稳定，仅开发调试用）
rmmod -f hello
```

---

## 进阶：通过 menuconfig 集成为 Buildroot 包

当模块开发稳定后，可将其做成正式的 Buildroot 包，通过 menuconfig 管理。

### 目录结构

```
package/hello-mod/
├── Config.in
└── hello-mod.mk
```

### Config.in

```kconfig
config BR2_PACKAGE_HELLO_MOD
    bool "hello-mod"
    depends on BR2_LINUX_KERNEL
    help
      A simple hello world kernel module.
```

### hello-mod.mk

```makefile
################################################################################
#
# hello-mod
#
################################################################################

HELLO_MOD_VERSION = 1.0
HELLO_MOD_SITE = /home/luckfox/workspace/buildroot-study/my-work/prac/hello_mod
HELLO_MOD_SITE_METHOD = local

# 源码在子目录 hello_mod/ 中，每个文件对应一个 .o
HELLO_MOD_MODULE_SUBDIRS = .

$(eval $(kernel-module))
$(eval $(generic-package))
```

> `$(eval $(kernel-module))` 必须在 `$(eval $(generic-package))` **之前**调用。

### 注册到菜单

在 `package/Config.in` 末尾添加：

```kconfig
source "package/hello-mod/Config.in"
```

### 使用

```bash
cd buildroot-2023.11.1
make menuconfig
# Target packages → 勾选 hello-mod → Save → Exit
make
```

模块会自动编译并安装到 `output/target/lib/modules/6.1.44/extra/`。

---

## 内核模块 Makefile 完整示例

```makefile
# 单文件模块
obj-m := hello.o

# 多文件模块
# obj-m := mymodule.o
# mymodule-objs := file1.o file2.o file3.o

# 条件编译
# hello-objs-$(CONFIG_FEATURE_A) += feature_a.o
# ccflags-y := -DDEBUG -I$(src)/include

KERNEL_DIR  ?= /home/luckfox/workspace/buildroot-2023.11.1/output/build/linux-6.1.44
CROSS_COMPILE ?= aarch64-buildroot-linux-gnu-
ARCH        ?= arm64

all:
	$(MAKE) -C $(KERNEL_DIR) \
		ARCH=$(ARCH) \
		CROSS_COMPILE=$(CROSS_COMPILE) \
		M=$(PWD) \
		modules

clean:
	$(MAKE) -C $(KERNEL_DIR) \
		ARCH=$(ARCH) \
		CROSS_COMPILE=$(CROSS_COMPILE) \
		M=$(PWD) \
		clean

install:
	cp *.ko /home/luckfox/workspace/buildroot-2023.11.1/output/target/lib/modules/6.1.44/extra/

.PHONY: all clean install
```
