# ftrace trace 输出为空/不可用修复

## 问题现象

QEMU 虚拟机内直接执行下面命令时，`/sys/kernel/tracing/current_tracer` 不存在，或后续 `cat trace` 不能稳定打印 trace 输出：

```sh
echo function > /sys/kernel/tracing/current_tracer
echo > /sys/kernel/tracing/set_ftrace_filter
echo > /sys/kernel/tracing/trace
sleep 1
cat /sys/kernel/tracing/trace | head -50
```

## 原因

内核已启用 `CONFIG_FTRACE=y` 和 `CONFIG_FUNCTION_TRACER=y`，但 rootfs 默认没有挂载 `tracefs`，启动后 `/sys/kernel/tracing` 只是空目录，ftrace 控制文件不可用。

## 修改方法

新增 Buildroot post-build 脚本：

```text
board/qemu/aarch64-virt/post-build.sh
```

脚本在目标 rootfs 中创建 `/sys/kernel/tracing`、`/sys/kernel/debug`，并向 `/etc/fstab` 追加：

```fstab
tracefs		/sys/kernel/tracing	tracefs	defaults	0	0
debugfs		/sys/kernel/debug	debugfs	defaults	0	0
```

同时在当前 `.config` 和 `configs/qemu_aarch64_virt_defconfig` 中启用：

```text
BR2_ROOTFS_POST_BUILD_SCRIPT="board/qemu/aarch64-virt/post-build.sh"
```

## 重新编译

在 Buildroot 根目录执行：

```sh
make olddefconfig
make
```

## 验证

QEMU 启动后确认 tracefs/debugfs 自动挂载：

```sh
mount | grep -E 'tracefs|debugfs'
```

输出包含：

```text
tracefs on /sys/kernel/tracing type tracefs (rw,relatime)
debugfs on /sys/kernel/debug type debugfs (rw,relatime)
```

再次执行问题命令，`cat /sys/kernel/tracing/trace | head -50` 已能打印：

```text
# tracer: function
# entries-in-buffer/entries-written: ...
...
sh-... [000] ..... ...: file_ra_state_init <-do_dentry_open
```

建议读 trace 前先执行 `echo 0 > /sys/kernel/tracing/tracing_on`，避免全量 `function` tracer 在打印过程中继续追踪自身输出。

# bpftool 缺失 libsframe.so 修复

## 问题现象

QEMU 虚拟机内运行 `bpftool` 时提示类似错误：

```sh
bpftool: error while loading shared libraries: libsframe.so.0: cannot open shared object file: No such file or directory
```

## 原因

`bpftool` 会使用 `libbfd`/`libopcodes` 支持 BPF JIT 反汇编。Buildroot 的 `binutils` 包在 staging 目录安装了 `bfd`、`opcodes`、`libiberty` 和 `libsframe`，但是在没有启用完整 target `binutils binaries` 时，target rootfs 只安装了 `bfd` 和 `opcodes`，漏装了 `libsframe`。

`binutils 2.40/2.41` 提供并使用 `libsframe`，因此 target rootfs 中存在 `libbfd`/`libopcodes` 但没有 `libsframe.so.*` 时，`bpftool` 会在运行期动态链接失败。

## 修改方法

编辑 `package/binutils/binutils.mk`，在已有的 `BR2_PACKAGE_BINUTILS_HAS_NO_LIBSFRAME` 条件下增加 target 端 `libsframe` 安装命令，并在 `BINUTILS_INSTALL_TARGET_CMDS` 中调用它。

补丁内容如下：

```diff
diff --git a/package/binutils/binutils.mk b/package/binutils/binutils.mk
--- a/package/binutils/binutils.mk
+++ b/package/binutils/binutils.mk
@@
 ifeq ($(BR2_PACKAGE_BINUTILS_HAS_NO_LIBSFRAME),)
 define BINUTILS_INSTALL_STAGING_LIBSFRAME
 	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)/libsframe DESTDIR=$(STAGING_DIR) install
 endef
+
+define BINUTILS_INSTALL_TARGET_LIBSFRAME
+	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)/libsframe DESTDIR=$(TARGET_DIR) install
+endef
 endif
@@
 define BINUTILS_INSTALL_TARGET_CMDS
 	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)/bfd DESTDIR=$(TARGET_DIR) install
 	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)/opcodes DESTDIR=$(TARGET_DIR) install
+	$(BINUTILS_INSTALL_TARGET_LIBSFRAME)
 endef
 endif
```

该条件判断很重要：`binutils 2.39` 和 ARC 版本没有 `libsframe`，不能无条件执行 `make -C libsframe install`。

## 重新编译

修改完成后在 Buildroot 根目录执行：

```sh
make binutils-reinstall
make
```

如果已有构建缓存导致结果不干净，执行完整重建相关包：

```sh
make binutils-dirclean
make bpftool-dirclean
make
```

如果 `make` 过程中进入内核构建并报类似下面的错误，说明 `output/build/linux-*` 里的内核 `.cmd` 中间文件被截断或损坏：

```sh
*** unterminated call to function 'wildcard': missing ')'
```

这不是 `libsframe` 修复引入的问题，清理内核构建目录后重新执行完整构建：

```sh
make linux-dirclean
make
```

## 验证

在宿主机 Buildroot 根目录检查 target rootfs：

```sh
find output/target -name 'libsframe.so*'
readelf -d output/target/usr/lib/libbfd*.so | grep NEEDED
```

启动 QEMU 后在虚拟机内检查：

```sh
ldd /usr/sbin/bpftool
bpftool version
```

预期结果：

- `output/target` 内存在 `/usr/lib/libsframe.so.*`。
- `ldd /usr/sbin/bpftool` 不再显示 `libsframe.so.* => not found`。
- `bpftool version` 能正常输出版本信息。
