# 7. 在 QEMU 虚拟机中使用 ftrace、trace-cmd、perf 和 uprobe

本文面向 Buildroot 生成的 ARM64 QEMU 虚拟机，演示如何在虚拟机内观察内核和用户态程序的运行行为。

本文分为两章：

1. 使用 `ftrace` 和 `trace-cmd` 观察内核事件、函数调用和调度行为。
2. 使用 `perf`、`trace-cmd` 和 `uprobe` 观察 CPU 性能、系统调用和用户态函数。

以下路径基于当前工程布局：

```text
/home/luckfox/workspace/buildroot-study/my-work
├── docs/
├── prac/                          # 待打包进虚拟机 /home/prac 的目录
└── scripts/
    └── copy_prac_to_rootfs.sh

/home/luckfox/workspace/buildroot-2023.11.1
├── .config
├── output/build/linux-6.1.44/.config
├── output/target
└── output/images
    ├── Image
    ├── rootfs.ext2
    ├── rootfs.ext4 -> rootfs.ext2
    └── start-qemu.sh
```

当前工程已经启用了本文大部分实验所需的内核能力和工具：

| 项目 | 当前状态 |
|------|----------|
| 内核版本 | `6.1.44` |
| 目标架构 | `aarch64` |
| `CONFIG_TRACING` | 已启用 |
| `CONFIG_FTRACE` | 已启用 |
| `CONFIG_FUNCTION_TRACER` | 已启用 |
| `CONFIG_FUNCTION_GRAPH_TRACER` | 已启用 |
| `CONFIG_KPROBES` / `CONFIG_KPROBE_EVENTS` | 已启用 |
| `CONFIG_UPROBES` / `CONFIG_UPROBE_EVENTS` | 已启用 |
| `CONFIG_PERF_EVENTS` | 已启用 |
| `CONFIG_FTRACE_SYSCALLS` | 已启用，`perf trace` 和 `syscalls:*` tracepoint 可用 |
| `trace-cmd` | 已安装到 rootfs |
| `perf` | 已安装到 rootfs |
| `strace` | 已安装到 rootfs，可作为 syscall 观察对照工具 |

## 准备工作：启动虚拟机并确认环境

宿主机启动 QEMU：

```bash
cd /home/luckfox/workspace/buildroot-2023.11.1/output/images
./start-qemu.sh
```

QEMU 控制台会打印内核启动日志，最后进入登录提示：

```text
Welcome to Buildroot
buildroot login:
```

输入 `root` 登录。当前 root 密码为空，直接回车即可。

登录后先确认系统信息：

```sh
uname -a
uname -m
which trace-cmd
which perf
which strace
zcat /proc/config.gz | grep -E 'CONFIG_(PERF_EVENTS|KPROBE_EVENTS|UPROBE_EVENTS|FTRACE_SYSCALLS)='
```

当前镜像中的典型输出如下：

```text
# uname -a
Linux buildroot 6.1.44 #3 SMP Fri Jun 12 06:46:35 UTC 2026 aarch64 GNU/Linux

# uname -m
aarch64

# which trace-cmd
/usr/bin/trace-cmd

# which perf
/usr/bin/perf

# which strace
/usr/bin/strace

# zcat /proc/config.gz | grep -E 'CONFIG_(PERF_EVENTS|KPROBE_EVENTS|UPROBE_EVENTS|FTRACE_SYSCALLS)='
CONFIG_PERF_EVENTS=y
CONFIG_KPROBE_EVENTS=y
CONFIG_UPROBE_EVENTS=y
CONFIG_FTRACE_SYSCALLS=y
```

如果你重新构建过内核，优先以 `/proc/config.gz` 的输出为准。本文后续的 syscall 观察实验依赖 `CONFIG_FTRACE_SYSCALLS=y`。

当前 rootfs 没有安装 `file` 和 `nm`。需要查看 ELF 类型和符号偏移时，在宿主机使用 Buildroot 交叉工具链里的 `file`、`aarch64-buildroot-linux-gnu-nm` 等工具。

# 第一章：在 QEMU 虚拟机中使用 ftrace 和 trace-cmd

`ftrace` 是 Linux 内核自带的追踪框架。它不依赖额外守护进程，接口主要暴露在 tracefs/debugfs 中。`trace-cmd` 是 ftrace 的用户态封装工具，用来简化录制、查看和保存 trace 数据。

本章目标：

1. 挂载 tracefs。
2. 直接读写 ftrace 文件接口。
3. 用 `function` tracer 观察内核函数。
4. 用 `function_graph` tracer 观察函数调用层级和耗时。
5. 用 `trace-cmd` 录制调度事件和函数事件。

## 1.1 挂载 tracefs

在虚拟机内执行：

```sh
mount -t tracefs nodev /sys/kernel/tracing 2>/dev/null || true
mount -t debugfs nodev /sys/kernel/debug 2>/dev/null || true

ls /sys/kernel/tracing
```

如果 tracefs 已经挂载，第一条 `mount` 可能没有输出，这是正常现象。`ls` 会看到一批 ftrace 控制文件：

```text
README
available_events
available_filter_functions
available_tracers
buffer_percent
buffer_size_kb
buffer_total_size_kb
current_tracer
dyn_ftrace_total_info
dynamic_events
```

如果 `/sys/kernel/tracing` 是空目录，可以检查 debugfs 下的旧路径：

```sh
ls /sys/kernel/debug/tracing
```

新内核推荐使用：

```text
/sys/kernel/tracing
```

后续命令统一使用这个路径。

## 1.2 查看当前支持的 tracer

```sh
cd /sys/kernel/tracing
cat available_tracers
cat current_tracer
```

典型输出：

```text
# cat available_tracers
timerlat osnoise blk function_graph wakeup_dl wakeup_rt wakeup irqsoff function nop

# cat current_tracer
nop
```

说明：

| tracer | 用途 |
|--------|------|
| `nop` | 不启用函数 tracer，只使用事件缓冲区 |
| `function` | 记录内核函数入口 |
| `function_graph` | 记录函数调用层级、返回和耗时 |
| `wakeup` / `wakeup_rt` | 分析任务唤醒延迟 |
| `irqsoff` | 分析关中断时间 |
| `timerlat` / `osnoise` | 分析定时器延迟和系统噪声 |

## 1.3 用 ftrace 观察内核事件

先清空旧 trace，并开启调度事件：

```sh
cd /sys/kernel/tracing

echo 0 > tracing_on
echo > trace

echo 1 > events/sched/sched_switch/enable
echo 1 > tracing_on

sleep 1

echo 0 > tracing_on
cat trace | head -40
```

QEMU 控制台会看到类似输出：

```text
# cat trace | head -40
# tracer: nop
#
# entries-in-buffer/entries-written: 15/15   #P:1
#
#                                _-----=> irqs-off/BH-disabled
#                               / _----=> need-resched
#                              | / _---=> hardirq/softirq
#                              || / _--=> preempt-depth
#                              ||| / _-=> migrate-disable
#                              |||| /     delay
#           TASK-PID     CPU#  |||||  TIMESTAMP  FUNCTION
#              | |         |   |||||     |         |
              sh-109     [000] d....    47.313766: sched_switch: prev_comm=sh prev_pid=109 prev_prio=120 prev_state=S ==> next_comm=swapper/0 next_pid=0 next_prio=120
          <idle>-0       [000] d....    47.314362: sched_switch: prev_comm=swapper/0 prev_pid=0 prev_prio=120 prev_state=R ==> next_comm=rcu_sched next_pid=14 next_prio=120
       rcu_sched-14      [000] d....    47.314414: sched_switch: prev_comm=rcu_sched prev_pid=14 prev_prio=120 prev_state=I ==> next_comm=swapper/0 next_pid=0 next_prio=120
          <idle>-0       [000] d....    47.337996: sched_switch: prev_comm=swapper/0 prev_pid=0 prev_prio=120 prev_state=R ==> next_comm=kworker/0:2 next_pid=110 next_prio=120
```

这个输出说明：

- shell 执行 `sleep 1` 后被调度出去，CPU 进入 `<idle>` / `swapper/0`。
- 这 1 秒内也可能穿插 `rcu_sched`、`kworker` 等内核线程调度。
- 实际 PID、时间戳和中间线程会随启动后的系统状态变化，重点看 `sched_switch` 的 `prev_comm` / `next_comm`。

关闭事件，避免后续实验混入旧配置：

```sh
echo 0 > events/sched/sched_switch/enable
echo > trace
```

## 1.4 用 function tracer 观察内核函数调用

`function` tracer 会记录函数入口。直接打开会产生大量输出，因此必须先设置过滤器。

下面只观察 `vfs_read` 和 `vfs_write`：

```sh
cd /sys/kernel/tracing

echo 0 > tracing_on
echo nop > current_tracer
echo > trace
echo > set_ftrace_filter

echo vfs_read > set_ftrace_filter
echo vfs_write >> set_ftrace_filter

echo function > current_tracer
echo 1 > tracing_on

echo "hello ftrace" > /tmp/ftrace.txt
cat /tmp/ftrace.txt

echo 0 > tracing_on
cat trace | head -30
```

QEMU 控制台现象：

```text
# echo "hello ftrace" > /tmp/ftrace.txt
# cat /tmp/ftrace.txt
hello ftrace

# cat trace | head -30
# tracer: function
#
# entries-in-buffer/entries-written: 166/166   #P:1
#
#                                _-----=> irqs-off/BH-disabled
#                               / _----=> need-resched
#                              | / _---=> hardirq/softirq
#                              || / _--=> preempt-depth
#                              ||| / _-=> migrate-disable
#                              |||| /     delay
#           TASK-PID     CPU#  |||||  TIMESTAMP  FUNCTION
#              | |         |   |||||     |         |
              sh-109     [000] .....    48.549981: vfs_write <-ksys_write
              sh-109     [000] .....    48.550130: vfs_read <-ksys_read
              sh-109     [000] .....    48.550148: vfs_write <-ksys_write
              sh-109     [000] .....    48.550213: vfs_read <-ksys_read
```

读这个 trace 时重点看三列：

| 列 | 含义 |
|----|------|
| `TASK-PID` | 触发函数的进程和 PID |
| `TIMESTAMP` | trace 时间戳 |
| `FUNCTION` | 被记录的函数，箭头右边是调用者 |

`cat /tmp/ftrace.txt` 会触发 `vfs_read` 读取文件，同时触发 `vfs_write` 把内容写到控制台。

实验结束后恢复：

```sh
echo 0 > tracing_on
echo nop > current_tracer
echo > set_ftrace_filter
echo > trace
```

## 1.5 用 function_graph tracer 看函数层级和耗时

`function_graph` 比 `function` 更适合看函数耗时。当前示例只过滤 `vfs_read`，因此输出主要展示每次 `vfs_read()` 的耗时，不一定展开完整子调用树。

仍然只过滤 `vfs_read`：

```sh
cd /sys/kernel/tracing

echo 0 > tracing_on
echo nop > current_tracer
echo > trace
echo > set_ftrace_filter
echo vfs_read > set_ftrace_filter

echo function_graph > current_tracer
echo 1 > tracing_on

cat /etc/os-release > /dev/null

echo 0 > tracing_on
cat trace | head -60
```

QEMU 控制台会看到类似输出：

```text
# cat trace | head -60
# tracer: function_graph
#
# CPU  DURATION                  FUNCTION CALLS
# |     |   |                     |   |   |   |
 0) ! 149.456 us  |  vfs_read();
 0) + 12.288 us   |  vfs_read();
 0) + 11.584 us   |  vfs_read();
 0) + 11.648 us   |  vfs_read();
 0) + 12.864 us   |  vfs_read();
 0) ! 103.888 us  |  vfs_read();
 ------------------------------------------
 0)     sh-109     =>    cat-133
 ------------------------------------------
```

这里能直接看到：

- 每一行都是一次被过滤到的 `vfs_read()` 调用。
- 右侧的 `us` 是该次调用耗时。
- `+` / `!` 是 function graph 的耗时标记，表示调用耗时超过不同阈值。
- 中间的 `sh => cat` 表示记录期间发生了任务切换。

实验结束后恢复：

```sh
echo 0 > tracing_on
echo nop > current_tracer
echo > set_ftrace_filter
echo > trace
```

## 1.6 使用 trace_marker 给 trace 插入人工标记

`trace_marker` 可以把用户自定义文本写进 trace 缓冲区，方便把“实验开始/结束”标记和内核事件对齐。

```sh
cd /sys/kernel/tracing

echo 0 > tracing_on
echo nop > current_tracer
echo > trace
echo 1 > events/sched/sched_switch/enable
echo 1 > tracing_on

echo "BEGIN sleep experiment" > trace_marker
sleep 1
echo "END sleep experiment" > trace_marker

echo 0 > tracing_on
cat trace | grep -E "tracing_mark_write|sched_switch" | head -20
```

控制台输出示例：

```text
              sh-94      [000] ....   501.127184: tracing_mark_write: BEGIN sleep experiment
           sleep-139     [000] d....   501.129033: sched_switch: prev_comm=sleep prev_pid=139 prev_state=S ==> next_comm=swapper/0 next_pid=0
          <idle>-0       [000] d....   502.129690: sched_switch: prev_comm=swapper/0 prev_pid=0 prev_state=R ==> next_comm=sleep next_pid=139
              sh-94      [000] ....   502.132552: tracing_mark_write: END sleep experiment
```

这类标记在复杂实验中很有用。例如先写入 `BEGIN ping`，再执行 `ping`，最后写入 `END ping`，就能从 trace 中截出这段操作对应的内核行为。

清理：

```sh
echo 0 > events/sched/sched_switch/enable
echo > trace
```

## 1.7 用 trace-cmd 录制调度事件

`trace-cmd` 会替你操作 ftrace 文件，并把结果保存为 `trace.dat`。这比手动 `cat trace` 更适合长时间记录。

录制 `sleep 1` 期间的调度事件：

```sh
cd /tmp
trace-cmd record -e sched:sched_switch sleep 1
```

QEMU 控制台现象：

```text
# trace-cmd record -e sched:sched_switch sleep 1
CPU0 data recorded at offset=0x165000
    4096 bytes in size
```

生成的文件：

```sh
ls -lh /tmp/trace.dat
```

输出：

```text
-rw-r--r--    1 root     root        1.4M Jun 12 06:59 /tmp/trace.dat
```

查看报告：

```sh
trace-cmd report | head -40
```

典型输出：

```text
  could not load plugin '/usr/lib64/traceevent/plugins/plugin_python_loader.so'
/usr/lib64/traceevent/plugins/plugin_python_loader.so: undefined symbol: Py_Initialize

trace-cmd: No such file or directory
  Error: expected type 4 but read 5
cpus=1
           sleep-138   [000]    84.733069: sched_switch:         sleep:138 [120] S ==> swapper/0:0 [120]
          <idle>-0     [000]    85.733490: sched_switch:         swapper/0:0 [120] R ==> sleep:138 [120]
```

`trace-cmd report` 的好处是输出已经按事件格式解析，不需要自己解释 ftrace 原始字段。

当前 rootfs 中 `trace-cmd report` 会先打印一段 `plugin_python_loader.so` 相关警告和 `expected type` 提示，但随后仍会输出 `cpus=1` 以及事件内容。只要后面能看到事件行，本实验就算成功。

## 1.8 用 trace-cmd 录制函数调用

只录制 `vfs_read`：

```sh
cd /tmp
trace-cmd record -p function -l vfs_read sh -c 'cat /etc/os-release > /dev/null'
trace-cmd report | head -40
```

控制台输出示例：

```text
# trace-cmd record -p function -l vfs_read sh -c 'cat /etc/os-release > /dev/null'
  plugin 'function'
CPU0 data recorded at offset=0x165000
    4096 bytes in size

# trace-cmd report | head -40
  could not load plugin '/usr/lib64/traceevent/plugins/plugin_python_loader.so'
/usr/lib64/traceevent/plugins/plugin_python_loader.so: undefined symbol: Py_Initialize

trace-cmd: No such file or directory
  Error: expected type 4 but read 5
cpus=1
             cat-144   [000]    88.123804: function:             vfs_read
             cat-144   [000]    88.124167: function:             vfs_read
```

这个实验和手动 ftrace 的 `function` tracer 本质相同，只是 `trace-cmd` 自动完成：

- 设置 tracer。
- 设置函数过滤器。
- 启动目标命令。
- 停止记录。
- 保存 `trace.dat`。

## 1.9 用 trace-cmd 同时录制多个事件

观察 `ping` 时的系统调用和调度：

```sh
cd /tmp
trace-cmd record \
    -e sched:sched_switch \
    -e irq:irq_handler_entry \
    ping -c 2 10.0.2.2

trace-cmd report | head -60
```

QEMU 控制台先看到 `ping` 自身输出：

```text
PING 10.0.2.2 (10.0.2.2): 56 data bytes
64 bytes from 10.0.2.2: seq=0 ttl=255 time=6.021 ms
64 bytes from 10.0.2.2: seq=1 ttl=255 time=0.582 ms

--- 10.0.2.2 ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss
round-trip min/avg/max = 0.582/3.301/6.021 ms
```

随后查看 trace 报告，可以看到网络收包中断和任务切换：

```text
cpus=1
            ping-149   [000]    90.697755: irq_handler_entry:    irq=11 name=arch_timer
            ping-149   [000]    90.698915: irq_handler_entry:    irq=16 name=virtio1
            ping-149   [000]    90.702294: sched_switch:         ping:149 [120] S ==> swapper/0:0 [120]
          <idle>-0     [000]    91.702174: sched_switch:         swapper/0:0 [120] R ==> ping:149 [120]
            ping-149   [000]    91.702639: irq_handler_entry:    irq=16 name=virtio1
```

这说明：

- `ping` 发包后睡眠等待响应。
- virtio 网卡中断到来。
- 内核唤醒 `ping` 处理回包。

## 1.10 ftrace 常见清理命令

实验中如果发现 trace 输出异常多，先执行下面的清理命令：

```sh
cd /sys/kernel/tracing

echo 0 > tracing_on
echo nop > current_tracer
echo > set_ftrace_filter
echo > set_ftrace_notrace

find events -name enable -exec sh -c 'echo 0 > "$1"' _ {} \;

echo > trace
```

如果 BusyBox `find` 不支持 `-exec`，可以重启 QEMU，或者手动关闭本次开启的事件：

```sh
echo 0 > events/sched/sched_switch/enable
echo 0 > events/irq/irq_handler_entry/enable
```

# 第二章：使用 perf、trace-cmd 和 uprobe

`perf`、`trace-cmd` 和 `uprobe` 解决的问题不同：

| 工具/机制 | 观察对象 | 典型问题 |
|-----------|----------|----------|
| `perf stat` | 硬件/软件计数器 | 命令消耗了多少 CPU、发生多少上下文切换 |
| `perf record/report` | 采样热点 | 程序时间花在哪些函数里 |
| `perf trace` | 系统调用 | 程序调用了哪些 syscall |
| `trace-cmd record` | tracepoint 事件 | 录制 syscall、调度和中断事件 |
| `uprobe` | 用户态函数入口/返回 | 某个用户态函数是否被调用、参数是什么 |

当前镜像可直接演示 `perf`、`trace-cmd` syscall tracepoint 和内核原生 `uprobe`。

如果只做第二章实验，也需要先挂载 tracefs：

```sh
mount -t tracefs nodev /sys/kernel/tracing 2>/dev/null || true
mount -t debugfs nodev /sys/kernel/debug 2>/dev/null || true
```

## 2.1 准备一个可观测的用户态程序

为了让 `perf` 和 `uprobe` 有稳定目标，使用仓库中已经准备好的小程序 `prac/observe/obs_demo.c`。源码如下：

```bash
cd /home/luckfox/workspace/buildroot-study/my-work
sed -n '1,120p' prac/observe/obs_demo.c
```

关键内容：

```c
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

__attribute__((noinline))
static uint64_t busy_loop(unsigned long rounds)
{
    uint64_t x = 0;

    for (unsigned long i = 0; i < rounds; i++) {
        x += (i * 2654435761UL) ^ (x >> 3);
    }

    return x;
}

__attribute__((noinline))
int target_func(int value)
{
    printf("target_func(%d)\n", value);
    return value * 2 + 1;
}

int main(int argc, char **argv)
{
    int loops = 5;

    if (argc > 1)
        loops = atoi(argv[1]);

    printf("obs_demo pid=%d loops=%d\n", getpid(), loops);

    for (int i = 0; i < loops; i++) {
        uint64_t r = busy_loop(20000000UL);
        int y = target_func(i);
        printf("round=%d busy=%llu result=%d\n",
               i, (unsigned long long)r, y);
        usleep(200000);
    }

    return 0;
}
```

交叉编译。这里刻意使用 `-O0 -g -fno-omit-frame-pointer -rdynamic`，便于 `perf` 和 `uprobe` 解析符号：

```bash
export PATH=$PATH:/home/luckfox/workspace/buildroot-2023.11.1/output/host/bin

aarch64-buildroot-linux-gnu-gcc \
    -O0 -g -fno-omit-frame-pointer -rdynamic \
    -o prac/observe/obs_demo \
    prac/observe/obs_demo.c

file prac/observe/obs_demo
aarch64-buildroot-linux-gnu-nm -n prac/observe/obs_demo | grep target_func
```

宿主机输出示例：

```text
prac/observe/obs_demo: ELF 64-bit LSB pie executable, ARM aarch64, version 1 (SYSV), dynamically linked, interpreter /lib/ld-linux-aarch64.so.1, for GNU/Linux 6.1.0, with debug_info, not stripped
0000000000000b24 T target_func
```

当前 VM 内没有 `file` 和 `nm`，所以上面两条检查在宿主机执行。

把程序打包进 rootfs：

```bash
cd /home/luckfox/workspace/buildroot-study/my-work
scripts/copy_prac_to_rootfs.sh /home/luckfox/workspace/buildroot-2023.11.1/output/target

cd /home/luckfox/workspace/buildroot-2023.11.1
make
```

重新启动 QEMU 后，在虚拟机中运行：

```sh
cd /home/prac/observe
chmod +x obs_demo
./obs_demo 3
```

控制台输出：

```text
# ./obs_demo 3
obs_demo pid=173 loops=3
target_func(0)
round=0 busy=424709638891447267 result=1
target_func(1)
round=1 busy=424709638891447267 result=3
target_func(2)
round=2 busy=424709638891447267 result=5
```

Buildroot 重新生成 rootfs 时会 strip 目标文件，但由于编译时加了 `-rdynamic`，当前 VM 中 `perf probe -x ./obs_demo target_func` 仍能通过动态符号找到 `target_func`。如果你改了编译选项，后续 `perf probe` 找不到函数名，可以在宿主机把该文件加入 Buildroot strip 排除列表：

```bash
cd /home/luckfox/workspace/buildroot-2023.11.1
make menuconfig
```

配置路径：

```text
Build options
  -> executables that should not be stripped
```

填入：

```text
home/prac/observe/obs_demo
```

也可以把该文件所在目录加入：

```text
Build options
  -> directories that should be skipped when stripping
```

填入：

```text
home/prac/observe
```

注意：Buildroot 的 strip 排除路径按 `output/target` 作为根目录填写，通常不要带开头的 `/`。

然后重新执行：

```bash
make
```

## 2.2 使用 perf stat 看整体计数器

在虚拟机内执行：

```sh
cd /home/prac/observe
perf stat ./obs_demo 3
```

程序先正常输出：

```text
obs_demo pid=181 loops=3
target_func(0)
round=0 busy=424709638891447267 result=1
target_func(1)
round=1 busy=424709638891447267 result=3
target_func(2)
round=2 busy=424709638891447267 result=5
```

命令结束后，`perf stat` 在控制台打印统计结果：

```text
 Performance counter stats for './obs_demo 3':

            333.02 msec task-clock                       #    0.356 CPUs utilized
                 8      context-switches                 #   24.023 /sec
                 0      cpu-migrations                   #    0.000 /sec
                45      page-faults                      #  135.127 /sec
         332644459      cycles                           #    0.999 GHz
   <not supported>      instructions
   <not supported>      branches
   <not supported>      branch-misses

       0.935374208 seconds time elapsed

       0.323947000 seconds user
       0.011851000 seconds sys
```

在 QEMU 中，硬件 PMU 支持取决于 QEMU 和内核配置。如果看到下面的报错：

```text
Error:
No permission to enable cycles event.
```

或：

```text
The cycles event is not supported.
```

可以改用软件事件：

```sh
perf stat -e task-clock,context-switches,cpu-migrations,page-faults ./obs_demo 3
```

软件事件的输出示例：

```text
 Performance counter stats for './obs_demo 3':

            339.46 msec task-clock                       #    0.360 CPUs utilized
                 6      context-switches                 #   17.675 /sec
                 0      cpu-migrations                   #    0.000 /sec
                46      page-faults                      #  135.508 /sec

       0.942979088 seconds time elapsed
```

这个实验说明：

- `task-clock` 接近程序实际占用 CPU 的时间。
- `time elapsed` 是墙上时间，包含 `usleep()` 睡眠。
- `context-switches` 能反映程序睡眠和唤醒引起的调度切换。

## 2.3 使用 perf record/report 找热点函数

采样运行：

```sh
cd /home/prac/observe
perf record -F 99 -g ./obs_demo 4
```

QEMU 控制台现象：

```text
# perf record -F 99 -g ./obs_demo 4
obs_demo pid=157 loops=4
target_func(0)
round=0 busy=424709638891447267 result=1
...
target_func(3)
round=3 busy=424709638891447267 result=7
[ perf record: Woken up 1 times to write data ]
[ perf record: Captured and wrote 0.007 MB perf.data (54 samples) ]
```

查看报告：

```sh
perf report --stdio --sort comm,dso,symbol | head -60
```

典型输出：

```text
# Children      Self  Command   Shared Object      Symbol
# ........  ........  ........  .....................  ...................................
#
    99.56%    99.56%  obs_demo  obs_demo               [.] 0x0000000000000ad4
            |
            ---_start
               __libc_start_main
               main
               0x55681b7ad4
```

当前 rootfs 重新生成时会 strip 目标文件，因此 `perf report` 在 VM 内通常只能显示地址，例如 `0x0000000000000ad4`，而不是 `busy_loop`。从调用链仍能看出热点集中在 `main` 下方的用户态地址，原因是程序把大部分 CPU 时间都花在循环计算里。

如果你的环境里希望看到函数名但 `perf report` 只显示地址，常见原因是：

- 程序被 strip，符号表丢失。
- 编译时没有加 `-g`。
- 编译优化过高并内联了函数。

教学实验建议使用：

```text
-O0 -g -fno-omit-frame-pointer -rdynamic
```

如果希望 `perf report` 直接显示 `busy_loop`，需要让 Buildroot 不 strip `home/prac/observe/obs_demo`，或者在宿主机保留带符号文件并用 perf 的符号路径选项做离线解析。

## 2.4 使用 perf top 实时看热点

`perf top` 会实时刷新热点函数，适合观察长时间运行程序。先启动一个较长的程序：

```sh
cd /home/prac/observe
./obs_demo 100 &
pid=$!
echo $pid
```

控制台输出：

```text
# ./obs_demo 100 &
# pid=$!
# echo $pid
204
obs_demo pid=204 loops=100
target_func(0)
round=0 busy=424709638891447267 result=1
```

运行 `perf top`：

```sh
perf top -e cpu-clock -p $pid
```

界面会持续刷新，能看到类似内容：

```text
Samples: ... of event 'cpu-clock'
Overhead  Shared Object  Symbol
  ...     obs_demo       [.] 0x0000000000000ad4
  ...     [kernel]       [k] ...
```

按 `q` 退出 `perf top`。

当前 VM 的 `cycles` 事件可用，但 `cpu-clock` 是更稳定的软件事件，适合教学演示。

停止后台程序：

```sh
kill $pid
```

## 2.5 使用 perf trace 观察系统调用

`perf trace` 类似轻量版 `strace`，可以观察系统调用。

```sh
cd /home/prac/observe
perf trace ./obs_demo 1
```

控制台输出示例：

```text
         ? obs_demo pid=162 loops=1
(         ): obs_demo/162  ... [continued]: execve()) = 0
     5.733 ( 0.033 ms): obs_demo/162 brk() = 0x55833c8000
     7.281 ( 0.009 ms): obs_demo/162 getpid() = 162
     7.611 ( 0.183 ms): obs_demo/162 write(fd: 1</dev/console>, buf: 0x55833c82a0, count: 25) = 25
target_func(0)
   148.959 ( 0.252 ms): obs_demo/162 write(fd: 1</dev/console>, buf: 0x55833c82a0, count: 15) = 15
round=0 busy=424709638891447267 result=1
   150.731 ( 0.257 ms): obs_demo/162 write(fd: 1</dev/console>, buf: 0x55833c82a0, count: 41) = 41
   152.222 (200.914 ms): obs_demo/162 clock_nanosleep(rqtp: 0x7fcdcab670) = 0
   353.369 (         ): obs_demo/162 exit_group() = ?
```

这个输出把用户程序打印和 syscall 记录混在一起。可以看出：

- `printf()` 最终变成 `write()`。
- `usleep()` 最终变成 `clock_nanosleep()`。
- 程序最后调用 `exit_group(0)` 退出。

当前内核已经启用 syscall tracepoint：

```sh
zcat /proc/config.gz | grep FTRACE_SYSCALLS
```

预期输出：

```text
CONFIG_FTRACE_SYSCALLS=y
```

如果这里没有输出，说明虚拟机启动的不是当前重新构建的内核镜像，或者内核配置没有同步到 rootfs。需要回到 Buildroot 内核配置启用：

```text
Kernel hacking
  -> Tracers
     -> Trace syscalls
```

启用后重新构建内核和镜像，再启动 QEMU。

## 2.6 使用 trace-cmd 录制 syscall tracepoint

`perf trace` 适合直接阅读 syscall 流程；如果需要把 syscall 事件保存成 `trace.dat`，可以用 `trace-cmd record`。

先确认当前内核导出了按 syscall 名称拆分的事件：

```sh
cd /sys/kernel/tracing
ls events/syscalls | grep -E 'sys_enter_(write|clock_nanosleep)|sys_exit_(write|clock_nanosleep)'
```

预期能看到：

```text
sys_enter_clock_nanosleep
sys_enter_write
sys_enter_writev
sys_exit_clock_nanosleep
sys_exit_write
sys_exit_writev
```

录制 `obs_demo` 的 `write()` 和 `clock_nanosleep()`：

```sh
cd /home/prac/observe
trace-cmd record \
    -e syscalls:sys_enter_write \
    -e syscalls:sys_exit_write \
    -e syscalls:sys_enter_clock_nanosleep \
    -e syscalls:sys_exit_clock_nanosleep \
    ./obs_demo 1
```

查看报告：

```sh
trace-cmd report | head -80
```

输出示例：

```text
  could not load plugin '/usr/lib64/traceevent/plugins/plugin_python_loader.so'
/usr/lib64/traceevent/plugins/plugin_python_loader.so: undefined symbol: Py_Initialize

trace-cmd: No such file or directory
  Error: expected type 4 but read 5
cpus=1
        obs_demo-172   [000]   113.053555: sys_enter_write:      fd: 0x00000001, buf: 0x557928b2a0, count: 0x00000019
        obs_demo-172   [000]   113.053998: sys_exit_write:       0x19
        obs_demo-172   [000]   113.161296: sys_enter_write:      fd: 0x00000001, buf: 0x557928b2a0, count: 0x0000000f
        obs_demo-172   [000]   113.161457: sys_exit_write:       0xf
        obs_demo-172   [000]   113.161481: sys_enter_write:      fd: 0x00000001, buf: 0x557928b2a0, count: 0x00000029
        obs_demo-172   [000]   113.161637: sys_exit_write:       0x29
        obs_demo-172   [000]   113.161707: sys_enter_clock_nanosleep: which_clock: 0x00000000, flags: 0x00000000, rqtp: 0x7fc50751d0, rmtp: 0x00000000
        obs_demo-172   [000]   113.362287: sys_exit_clock_nanosleep: 0x0
```

这个实验可以和 `perf trace` 对照：

- `sys_enter_write` 对应进入 `write()`，能看到 `fd`、`buf`、`count`。
- `sys_exit_write` 对应 `write()` 返回，例如 `0x19`、`0xf`、`0x29` 分别表示 25、15、41 字节。
- `sys_enter_clock_nanosleep` / `sys_exit_clock_nanosleep` 对应 `usleep(200000)`。

`trace-cmd` 默认把结果写到当前目录的 `trace.dat`。如果要保留多次实验结果，可以用 `-o` 指定文件名：

```sh
trace-cmd record -o /tmp/obs_syscall.dat -e syscalls:sys_enter_write ./obs_demo 1
trace-cmd report -i /tmp/obs_syscall.dat
```

## 2.7 使用内核原生 uprobe 观察用户态函数

`uprobe` 是内核机制，可以在用户态 ELF 的函数入口处挂探针。它不要求目标程序主动配合。

内核的 `uprobe_events` 接口要求使用 `PATH:OFFSET`。也就是说，需要先拿到 `target_func` 在 ELF 文件中的偏移，再把偏移写入 `uprobe_events`。

虚拟机当前 rootfs 没有安装 `nm`，可以在宿主机确认：

```bash
aarch64-buildroot-linux-gnu-nm -n /home/luckfox/workspace/buildroot-study/my-work/prac/observe/obs_demo | grep target_func
```

输出：

```text
0000000000000b24 T target_func
```

这里的 `0xb24` 就是后续要用的 offset。不同编译器、不同优化选项可能导致 offset 不同，实际操作时以你自己的 `nm` 输出为准。

在虚拟机内使用 ftrace 的 `uprobe_events` 创建探针。下面命令中的 `0xb24` 需要替换成你实际查到的 offset：

```sh
cd /sys/kernel/tracing

echo 0 > tracing_on
echo > trace

echo 'p:obs/target_func /home/prac/observe/obs_demo:0xb24 value=%x0' > uprobe_events
echo 1 > events/obs/target_func/enable
echo 1 > tracing_on
```

这里的含义：

| 字段 | 含义 |
|------|------|
| `p:` | 函数入口探针 |
| `obs/target_func` | 事件组名 `obs`，事件名 `target_func` |
| `/home/prac/observe/obs_demo:0xb24` | 对该 ELF 的 `0xb24` 偏移挂 uprobe |
| `value=%x0` | ARM64 第一个整型参数在寄存器 `x0` |

运行目标程序：

```sh
cd /home/prac/observe
./obs_demo 3
```

程序自身输出：

```text
obs_demo pid=229 loops=3
target_func(0)
round=0 busy=424709638891447267 result=1
target_func(1)
round=1 busy=424709638891447267 result=3
target_func(2)
round=2 busy=424709638891447267 result=5
```

查看 uprobe trace：

```sh
cd /sys/kernel/tracing
echo 0 > tracing_on
cat trace | grep target_func
```

控制台会看到：

```text
        obs_demo-175     [000] .....   146.139820: target_func: (0x5589328b24) value=0x0
        obs_demo-175     [000] .....   146.451060: target_func: (0x5589328b24) value=0x1
        obs_demo-175     [000] .....   146.757331: target_func: (0x5589328b24) value=0x2
```

这说明 `target_func()` 被调用了 3 次，参数分别是 `0`、`1`、`2`。

清理 uprobe：

```sh
cd /sys/kernel/tracing
echo 0 > events/obs/target_func/enable
echo > uprobe_events
echo > trace
```

## 2.8 使用 uretprobe 观察用户态函数返回值

返回探针使用 `r:`。在 `uprobe_events` 里，返回值推荐用 `$retval` 获取。

```sh
cd /sys/kernel/tracing

echo 0 > tracing_on
echo > trace
echo > uprobe_events

echo 'r:obs/target_func_ret /home/prac/observe/obs_demo:0xb24 retval=$retval' > uprobe_events
echo 1 > events/obs/target_func_ret/enable
echo 1 > tracing_on

cd /home/prac/observe
./obs_demo 3

cd /sys/kernel/tracing
echo 0 > tracing_on
cat trace | grep target_func_ret
```

控制台输出：

```text
        obs_demo-178     [000] .....   147.212790: target_func_ret: (0x557bff8bc4 <- 0x557bff8b24) retval=0x1
        obs_demo-178     [000] .....   147.522020: target_func_ret: (0x557bff8bc4 <- 0x557bff8b24) retval=0x3
        obs_demo-178     [000] .....   147.829348: target_func_ret: (0x557bff8bc4 <- 0x557bff8b24) retval=0x5
```

返回值 `1`、`3`、`5` 对应源码：

```c
return value * 2 + 1;
```

清理：

```sh
echo 0 > events/obs/target_func_ret/enable
echo > uprobe_events
echo > trace
```

## 2.9 用 perf probe 添加 uprobe

`perf probe` 可以帮你创建 uprobe 事件，不需要直接写 `uprobe_events`。

先添加探针：

```sh
cd /home/prac/observe
perf probe -x ./obs_demo target_func
```

控制台输出示例：

```text
Added new event:
  probe_obs_demo:target_func (on target_func in /home/prac/observe/obs_demo)

You can now use it in all perf tools, such as:

        perf record -e probe_obs_demo:target_func -aR sleep 1
```

查看 perf 已知事件：

```sh
PERF_PAGER=cat perf probe -l
```

输出：

```text
  probe_obs_demo:target_func (on target_func in /home/prac/observe/obs_demo)
```

当前 VM 的 `perf probe -l`、`perf script` 等命令在串口中可能默认进入 pager，输出里会混入控制字符。前面加 `PERF_PAGER=cat` 可以强制直接打印到控制台。

录制事件：

```sh
perf record -e probe_obs_demo:target_func ./obs_demo 3
```

输出：

```text
obs_demo pid=244 loops=3
target_func(0)
round=0 busy=424709638891447267 result=1
target_func(1)
round=1 busy=424709638891447267 result=3
target_func(2)
round=2 busy=424709638891447267 result=5
[ perf record: Woken up 1 times to write data ]
[ perf record: Captured and wrote 0.001 MB perf.data (3 samples) ]
```

查看脚本化输出：

```sh
PERF_PAGER=cat perf script
```

示例：

```text
        obs_demo   187 [000]   174.003607: probe_obs_demo:target_func: (5568e94b24)
        obs_demo   187 [000]   174.308748: probe_obs_demo:target_func: (5568e94b24)
        obs_demo   187 [000]   174.618434: probe_obs_demo:target_func: (5568e94b24)
```

删除探针：

```sh
perf probe -d probe_obs_demo:target_func
```

控制台输出：

```text
Removed event: probe_obs_demo:target_func
```

## 2.10 两种 uprobe 方法对比

| 方法 | 命令入口 | 优点 | 适合场景 |
|------|----------|------|----------|
| ftrace `uprobe_events` | 写 `/sys/kernel/tracing/uprobe_events` | 内核原生、依赖最少 | Buildroot 小系统、工具不完整时 |
| `perf probe` | `perf probe -x` | 自动创建事件，可和 `perf record/script` 串联 | 性能采样和事件记录 |

在当前 Buildroot QEMU 环境中，最稳妥的学习顺序是：

1. 先用 ftrace `uprobe_events` 理解 uprobe 的底层形式。
2. 再用 `perf probe` 学会把 uprobe 事件接入 perf。

## 2.11 常见问题

**Q: `echo 'p:...' > uprobe_events` 报 `No such file or directory`。**

先确认 tracefs 已挂载：

```sh
mount -t tracefs nodev /sys/kernel/tracing 2>/dev/null || true
ls /sys/kernel/tracing/uprobe_events
```

如果文件不存在，检查内核配置：

```sh
zcat /proc/config.gz | grep UPROBE
```

需要：

```text
CONFIG_UPROBES=y
CONFIG_UPROBE_EVENTS=y
```

**Q: uprobe 按函数名挂不上。**

检查目标二进制是否保留符号：

```bash
aarch64-buildroot-linux-gnu-nm -n prac/observe/obs_demo | grep target_func
```

如果没有输出，用 `-g -rdynamic` 重新编译，并避免 Buildroot strip。

**Q: `perf record -g` 没有调用栈。**

教学程序编译时加：

```text
-fno-omit-frame-pointer
```

同时优先用 `-O0` 或 `-O1` 避免函数被内联。

**Q: `perf stat` 的 `cycles` 不可用。**

QEMU 虚拟机中硬件 PMU 不一定可用，改用软件事件：

```sh
perf stat -e task-clock,context-switches,page-faults ./obs_demo 3
```

## 本章小结

- `ftrace` 适合直接观察内核事件和函数路径，依赖少，非常适合 Buildroot 小系统。
- `trace-cmd` 是 ftrace 的高层工具，适合录制和离线查看。
- `perf stat` 看整体计数器，`perf record/report` 看热点，`perf trace` 看 syscall。
- `uprobe` 能在不修改用户程序源码的情况下观察用户态函数。
