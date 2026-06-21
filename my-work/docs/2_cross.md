# 2. 交叉编译与部署

本文说明如何在本机交叉编译 C/C++ 程序，生成可在虚拟机（ARM aarch64）中运行的二进制文件。

---

## 背景

本项目的 Buildroot 已针对 **ARM Cortex-A53 (aarch64)** 架构完成了编译，交叉编译工具链自动生成在 `output/host/` 下。在 x86 主机上编译出的程序无法直接在 ARM 虚拟机中运行，必须使用交叉编译器。

```
┌─────────────┐                    ┌──────────────────┐
│  x86 主机    │  交叉编译          │  ARM 虚拟机       │
│  (WSL2)     │ ──── a.out ──────> │  (aarch64)       │
│             │                    │                  │
│  编译器:     │                    │  ./a.out         │
│  aarch64-   │                    │  Hello World!    │
│  buildroot- │                    │                  │
│  linux-gnu- │                    │                  │
│  gcc        │                    │                  │
└─────────────┘                    └──────────────────┘
```

---

## 步骤 1：设置交叉编译环境

### 1.1 工具链位置

| 项目 | 路径 |
|------|------|
| 工具链根目录 | `buildroot-2023.11.1/output/host/` |
| 编译器所在目录 | `buildroot-2023.11.1/output/host/bin/` |
| 编译器前缀 | `aarch64-buildroot-linux-gnu-` |
| 目标 sysroot | `buildroot-2023.11.1/output/host/aarch64-buildroot-linux-gnu/sysroot/` |

### 1.2 设置环境变量

每次打开新终端时，执行以下命令将交叉编译器加入 PATH：

```bash
export PATH=$PATH:/home/luckfox/workspace/buildroot-2023.11.1/output/host/bin
export CROSS_COMPILE=aarch64-buildroot-linux-gnu-
export CC=aarch64-buildroot-linux-gnu-gcc
export CXX=aarch64-buildroot-linux-gnu-g++
```

> **建议**：将以上三行追加到 `~/.bashrc`，避免每次手动设置。

### 1.3 验证工具链可用

```bash
aarch64-buildroot-linux-gnu-gcc --version
```

预期输出类似：

```
aarch64-buildroot-linux-gnu-gcc.br_real (Buildroot 2023.11.1) 12.3.0
```

---

## 步骤 2：编写源程序

在 `/home/luckfox/workspace/buildroot-study/my-work/prac/` 目录下创建源文件。该目录会在 Buildroot 编译时自动打包进根文件系统的 `/home/prac/`。

### 2.1 C 程序示例

**文件：`/home/luckfox/workspace/buildroot-study/my-work/prac/hello.c`**

```c
#include <stdio.h>

int main(void)
{
    printf("Hello from ARM64!\n");
    return 0;
}
```

### 2.2 C++ 程序示例

**文件：`/home/luckfox/workspace/buildroot-study/my-work/prac/hello.cpp`**

```cpp
#include <iostream>

int main()
{
    std::cout << "Hello from ARM64 C++!" << std::endl;
    return 0;
}
```

---

## 步骤 3：交叉编译

### 3.1 直接使用编译器（单个文件）

```bash
# 编译 C 程序
aarch64-buildroot-linux-gnu-gcc \
    -o buildroot-study/my-work/prac/hello \
    buildroot-study/my-work/prac/hello.c

# 编译 C++ 程序
aarch64-buildroot-linux-gnu-g++ \
    -o buildroot-study/my-work/prac/hello_cpp \
    buildroot-study/my-work/prac/hello.cpp
```

### 3.2 指定 sysroot（链接系统库时需要）

如果程序需要链接 Buildroot 提供的库（如 libcurl、libsqlite3 等），需指定 sysroot：

```bash
SYSROOT=/home/luckfox/workspace/buildroot-2023.11.1/output/host/aarch64-buildroot-linux-gnu/sysroot

aarch64-buildroot-linux-gnu-gcc \
    --sysroot=$SYSROOT \
    -o buildroot-study/my-work/prac/myapp \
    buildroot-study/my-work/prac/myapp.c \
    -lcurl -lsqlite3
```

### 3.3 使用 Makefile（多文件项目）

**文件：`buildroot-study/my-work/prac/Makefile`**

```makefile
CROSS_COMPILE ?= aarch64-buildroot-linux-gnu-
CC      = $(CROSS_COMPILE)gcc
CFLAGS  = -Wall -O2
TARGET  = hello
SRCS    = hello.c

all: $(TARGET)

$(TARGET): $(SRCS)
	$(CC) $(CFLAGS) -o $@ $^

clean:
	rm -f $(TARGET)

.PHONY: all clean
```

使用方式：

```bash
cd buildroot-study/my-work/prac
make                  # 编译
make CROSS_COMPILE=   # 如需在本机编译测试（不交叉编译）
make clean            # 清理
```

### 3.4 编译选项参考

| 选项 | 含义 | 使用场景 |
|------|------|---------|
| `-O2` | 二级优化（默认推荐） | 发布版本 |
| `-Os` | 优化体积 | 存储空间紧张 |
| `-O0 -g` | 无优化 + 调试符号 | 调试阶段 |
| `-Wall` | 启用常用编译警告 | 始终建议开启 |
| `-static` | 静态链接 | 避免库依赖问题（体积大） |
| `--sysroot=<path>` | 指定交叉编译 sysroot | 链接第三方库时需要 |
| `-I<path>` | 添加头文件搜索路径 | 使用自定义头文件 |
| `-L<path>` | 添加库文件搜索路径 | 使用自定义库 |
| `-l<name>` | 链接指定库（如 `-lpthread`） | 链接系统/第三方库 |

---

## 步骤 4：验证编译产物

```bash
# 检查文件类型（确认是 ARM64 二进制）
file buildroot-study/my-work/prac/hello
# 输出: hello: ELF 64-bit LSB executable, ARM aarch64, ...

# 查看动态链接的库
aarch64-buildroot-linux-gnu-readelf -d buildroot-study/my-work/prac/hello | grep NEEDED

# 确认没有链接到 x86 主机库（ldd 在交叉编译下不可用，需用 readelf）
```

> **重要**：不要在本机直接运行交叉编译的程序，会报 `cannot execute binary file: Exec format error`。必须部署到 ARM 虚拟机中运行。

---

## 步骤 5：部署到虚拟机

将编译好的程序放入 `/home/luckfox/workspace/buildroot-study/my-work/prac/` 目录，然后运行拷贝脚本：

```bash
# 方式 A：通过 Buildroot post-build 脚本（随系统镜像一起打包）
cd /home/luckfox/workspace/buildroot-study/my-work
scripts/copy_prac_to_rootfs.sh /home/luckfox/workspace/buildroot-2023.11.1/output/target

# 然后重新生成根文件系统镜像
cd /home/luckfox/workspace/buildroot-2023.11.1
make
```

> 执行后，`prac/` 下的所有文件会出现在虚拟机 `/home/prac/` 目录中。

### 或者：运行时通过 scp 传输（如果虚拟机已启动且有网络）

```bash
# 在主机上执行
scp buildroot-study/my-work/prac/hello root@<虚拟机IP>:/home/prac/
```

---

## 步骤 6：在虚拟机中运行验证

虚拟机启动后：

```bash
# 进入程序目录
cd /home/prac

# 添加执行权限（如有需要）
chmod +x hello

# 运行
./hello
# 预期输出: Hello from ARM64!
```

---

## 完整操作速查

```bash
# 1. 设置环境（一次）
export PATH=$PATH:/home/luckfox/workspace/buildroot-2023.11.1/output/host/bin

# 2. 编译
aarch64-buildroot-linux-gnu-gcc -o buildroot-study/my-work/prac/hello buildroot-study/my-work/prac/hello.c

# 3. 验证
file buildroot-study/my-work/prac/hello

# 4. 打包到根文件系统
cd /home/luckfox/workspace/buildroot-study/my-work
scripts/copy_prac_to_rootfs.sh /home/luckfox/workspace/buildroot-2023.11.1/output/target
cd /home/luckfox/workspace/buildroot-2023.11.1 && make

# 5. 启动虚拟机 → 运行
# cd /home/prac && ./hello
```

---

## 常见问题

**Q1: `aarch64-buildroot-linux-gnu-gcc: command not found`？**

工具链不在 PATH 中，执行：

```bash
export PATH=$PATH:/home/luckfox/workspace/buildroot-2023.11.1/output/host/bin
```

如果 `output/host/bin/` 目录为空，说明 Buildroot 尚未完成编译，先执行 `make`。

**Q2: 编译时报 `fatal error: xxx.h: No such file or directory`？**

缺头文件。检查该头文件对应的库是否已在 menuconfig 中启用（参见 `1_add_software.md`）。如果已启用，手动指定 sysroot：

```bash
aarch64-buildroot-linux-gnu-gcc --sysroot=<sysroot路径> ...
```

**Q3: 运行时提示 `./hello: not found` 但文件确实存在？**

这是动态链接器路径不匹配的典型现象。解决方案：

- **方案 A**：静态编译，添加 `-static` 选项
- **方案 B**：确认 Buildroot 使用的 C 库（glibc/musl/uClibc）与工具链匹配

先用 `readelf -l hello | grep interpreter` 查看程序期望的链接器路径。

**Q4: 如何在本机快速测试逻辑（不做交叉编译）？**

```bash
# 用本机 gcc 编译一个 x86 版本做功能验证
gcc -o test_x86 hello.c
./test_x86               # 本机可运行

# 确认无误后再用交叉编译器生成 ARM 版本
aarch64-buildroot-linux-gnu-gcc -o buildroot-study/my-work/prac/hello hello.c
```

> 注意：本机测试只能验证逻辑，不能验证字节序、内存对齐等平台差异。

**Q5: 交叉编译器支持哪些架构特性？**

```bash
# 查看编译器默认启用的架构选项
aarch64-buildroot-linux-gnu-gcc -Q --help=target | head -20

# 查看预定义的宏（确认架构和平台）
aarch64-buildroot-linux-gnu-gcc -dM -E - < /dev/null | grep -E "aarch64|ARM|__linux"
```
