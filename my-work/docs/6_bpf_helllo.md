# 6. eBPF/XDP 程序部署到 rootfs 并在 QEMU 虚拟机中验证

本文记录 `myapp` 从宿主机交叉编译、复制到 Buildroot 根文件系统、重新生成镜像、启动 QEMU 虚拟机，到在虚拟机内运行并观察 XDP/eBPF 挂载结果的完整流程。

以下路径基于当前工程布局：

```text
/home/luckfox/workspace/buildroot-study/my-work
├── myapp/                         # Aya eBPF 工程
├── prac/                          # 待打包进虚拟机 /home/prac 的目录
└── scripts/
    ├── build_myapp.sh             # 编译、验证、复制到 output/target
    └── copy_prac_to_rootfs.sh     # 将 prac 拷贝到 Buildroot output/target/home/prac

/home/luckfox/workspace/buildroot-2023.11.1
├── output/target                  # Buildroot rootfs 暂存目录
└── output/images
    ├── Image
    ├── rootfs.ext2
    ├── rootfs.ext4 -> rootfs.ext2
    └── start-qemu.sh              # QEMU 启动脚本
```

## 关键结论

`scripts/copy_prac_to_rootfs.sh` 只会把文件复制到 Buildroot 的 `output/target` 暂存目录。复制完成后必须在 Buildroot 根目录执行一次 `make`，这样文件才会进入 `output/images/rootfs.ext2` 镜像。QEMU 启动时使用的是 `output/images/rootfs.ext4`，它是指向 `rootfs.ext2` 的符号链接。

## 步骤 1：编译并复制到 rootfs 暂存目录

推荐直接使用一键脚本：

```bash
cd /home/luckfox/workspace/buildroot-study/my-work
scripts/build_myapp.sh
```

该脚本会完成：

1. 检查 Rust stable/nightly、nightly `rust-src`、`bpf-linker`、`aarch64-unknown-linux-gnu` target、Buildroot 交叉编译器和 `myapp/.cargo/config.toml`。
2. 编译 `myapp-ebpf` 为 eBPF 字节码，目标为 `bpfel-unknown-none`。
3. 交叉编译用户态 `myapp` 为 aarch64 ELF，目标为 `aarch64-unknown-linux-gnu`。
4. 验证最终用户态二进制是 `ARM aarch64`，并用交叉 `readelf` 检查动态链接器和动态库依赖。
5. 复制 `myapp` 到 `prac/`。
6. 调用 `scripts/copy_prac_to_rootfs.sh`，将整个 `prac/` 目录复制到 Buildroot 的 `output/target/home/prac/`。

脚本中的关键编译命令如下：

```bash
cd /home/luckfox/workspace/buildroot-study/my-work/myapp

cargo +nightly build \
    --package myapp-ebpf \
    --target bpfel-unknown-none \
    --release \
    -Z build-std=core

cargo +nightly build \
    --package myapp \
    --target aarch64-unknown-linux-gnu \
    --release \
    -Z build-std=core,std,alloc,proc_macro,test
```

注意：第二个命令交叉编译用户态 `myapp` 时，`myapp/myapp/build.rs` 还会通过 `aya_build::build_ebpf` 构建 eBPF 对象，并把生成的 `OUT_DIR/myapp` 嵌入用户态程序。也就是说，脚本第一步显式编译的 `target/bpfel-unknown-none/release/myapp` 可用于单独验证 eBPF 字节码，但最终运行的二进制是 `target/aarch64-unknown-linux-gnu/release/myapp`，其中已内嵌 eBPF 对象。

实际复制过程中的关键输出如下：

```text
拷贝 myapp -> /home/luckfox/workspace/buildroot-study/my-work/prac/
'/home/luckfox/workspace/buildroot-study/my-work/myapp/target/aarch64-unknown-linux-gnu/release/myapp' -> '/home/luckfox/workspace/buildroot-study/my-work/prac/myapp'

拷贝 prac 到根文件系统
源路径:  /home/luckfox/workspace/buildroot-study/my-work/scripts/../prac
目标路径: /home/luckfox/workspace/buildroot-2023.11.1/output/target/home/prac

  拷贝完成！/home/prac 中的文件：
    .gitkeep
    myapp
    observe/obs_demo
    observe/obs_demo.c
    test1.c
    xdp_traffic.sh
```

复制后可以在宿主机确认：

```bash
ls -l /home/luckfox/workspace/buildroot-2023.11.1/output/target/home/prac
file /home/luckfox/workspace/buildroot-2023.11.1/output/target/home/prac/myapp
```

预期能看到 `myapp` 存在且是 aarch64 程序：

```text
-rwxr-xr-x ... myapp

ELF 64-bit LSB pie executable, ARM aarch64, dynamically linked,
interpreter /lib/ld-linux-aarch64.so.1
```

### 手动编译和复制方式

如果只想跳过脚本的部署步骤，可以先只编译：

```bash
cd /home/luckfox/workspace/buildroot-study/my-work
scripts/build_myapp.sh build-only
```

然后手动复制已编译好的用户态二进制：

```bash
cd /home/luckfox/workspace/buildroot-study/my-work

cp -v myapp/target/aarch64-unknown-linux-gnu/release/myapp prac/
chmod +x prac/myapp

scripts/copy_prac_to_rootfs.sh \
    /home/luckfox/workspace/buildroot-2023.11.1/output/target
```

如果完全不用 `scripts/build_myapp.sh`，需要先手动完成两段 Cargo 编译：

```bash
export PATH="$PATH:/home/luckfox/workspace/buildroot-2023.11.1/output/host/bin"
cd /home/luckfox/workspace/buildroot-study/my-work/myapp

cargo +nightly build \
    --package myapp-ebpf \
    --target bpfel-unknown-none \
    --release \
    -Z build-std=core

cargo +nightly build \
    --package myapp \
    --target aarch64-unknown-linux-gnu \
    --release \
    -Z build-std=core,std,alloc,proc_macro,test

file target/aarch64-unknown-linux-gnu/release/myapp
```

确认 `file` 输出包含 `ARM aarch64` 后，再执行上面的复制步骤。

这一步只更新 `output/target/home/prac/`，还没有更新 QEMU 使用的镜像。

## 步骤 2：重新生成 Buildroot rootfs 镜像

进入 Buildroot 工程根目录执行：

```bash
cd /home/luckfox/workspace/buildroot-2023.11.1
make
```

成功后会重新生成：

```text
output/images/rootfs.ext2
output/images/rootfs.ext4 -> rootfs.ext2
```

本次实测中 `make` 的关键输出如下：

```text
>>>   Generating filesystem image rootfs.ext2
Creating regular file /home/luckfox/workspace/buildroot-2023.11.1/output/images/rootfs.ext2
Creating filesystem with 131072 4k blocks and 32768 inodes
Copying files into the device: done
Writing superblocks and filesystem accounting information: done
ln -sf rootfs.ext2 /home/luckfox/workspace/buildroot-2023.11.1/output/images/rootfs.ext4
```

可以检查镜像时间戳确认它确实被重新生成：

```bash
ls -l /home/luckfox/workspace/buildroot-2023.11.1/output/images/rootfs.ext2
ls -l /home/luckfox/workspace/buildroot-2023.11.1/output/images/rootfs.ext4
```

示例结果：

```text
-rw-r--r-- 1 luckfox luckfox 536870912 Jun 12 07:07 rootfs.ext2
lrwxrwxrwx 1 luckfox luckfox        11 Jun 12 07:07 rootfs.ext4 -> rootfs.ext2
```

注意：Buildroot 在生成 rootfs 时会 strip 目标文件，所以 `output/target/home/prac/myapp` 的大小可能小于 Cargo `target/.../release/myapp`，这是正常现象。

## 步骤 3：启动 QEMU 虚拟机

启动脚本位于：

```text
/home/luckfox/workspace/buildroot-2023.11.1/output/images/start-qemu.sh
```

启动命令：

```bash
cd /home/luckfox/workspace/buildroot-2023.11.1/output/images
./start-qemu.sh
```

该脚本实际使用的关键参数包括：

```text
qemu-system-aarch64
-M virt
-cpu cortex-a53
-nographic
-kernel Image
-append "rootwait root=/dev/vda console=ttyAMA0"
-drive file=rootfs.ext4,if=none,format=raw,id=hd0
-device virtio-blk-device,drive=hd0
-netdev user,id=eth0
-device virtio-net-device,netdev=eth0
```

启动后等待出现登录提示：

```text
Welcome to Buildroot
buildroot login:
```

输入：

```text
root
```

当前配置 root 密码为空，因此直接回车即可进入 shell。

## 步骤 4：在虚拟机内确认环境和文件

登录后先确认虚拟机架构：

```sh
uname -a
uname -m
which bpftool
bpftool version
```

实测输出：

```text
Linux buildroot 6.1.44 #3 SMP Fri Jun 12 06:46:35 UTC 2026 aarch64 GNU/Linux
aarch64
/usr/sbin/bpftool
bpftool v7.1.0
using libbpf v1.1
features: libbfd, skeletons
```

进入部署目录：

```sh
cd /home/prac
pwd
ls -l
```

实测输出：

```text
/home/prac
total 2092
-rwxr-xr-x    1 root     root       2130544 Jun 12 07:07 myapp
drwxr-xr-x    2 root     root          4096 Jun 12 07:07 observe
-rw-r--r--    1 root     root             0 Jun  7 10:35 test1.c
-rwxr-xr-x    1 root     root          2928 Jun  9 05:24 xdp_traffic.sh
```

确认网卡 `eth0` 存在：

```sh
ip link show eth0
```

示例输出：

```text
3: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP mode DEFAULT group default qlen 1000
    link/ether 52:54:00:12:34:56 brd ff:ff:ff:ff:ff:ff
```

也可以用简短格式确认 IPv4 地址：

```sh
ip -brief addr show eth0
```

当前实测：

```text
eth0             UP             10.0.2.15/24 fec0::5054:ff:fe12:3456/64 fe80::5054:ff:fe12:3456/64
```

如果刚启动时看到 `NO-CARRIER` 或 `state DOWN`，可以等待 DHCP 完成，或执行：

```sh
ip link set eth0 up
```

## 步骤 5：前台运行 myapp

最直接的运行方式：

```sh
cd /home/prac
./myapp --iface eth0
```

成功时程序会停在：

```text
Waiting for Ctrl-C...
```

这表示用户态程序已经完成：

1. 加载内嵌 eBPF 对象。
2. 初始化 Aya eBPF logger。
3. 找到名为 `myapp` 的 XDP 程序。
4. 调用 `program.load()` 加载到内核。
5. 调用 `program.attach("eth0", XdpMode::default())` 挂载到 `eth0`。

按 `Ctrl-C` 后，程序正常退出：

```text
Exiting...
```

本次实测完整结果：

```text
[   38.243060][  T121] virtio_net virtio1 eth0: XDP request 2 queues but max is 1. XDP_TX and XDP_REDIRECT will operate in a slower locked tx mode.
Waiting for Ctrl-C...
Exiting...
```

前台运行时，按 `Ctrl-C` 退出后的返回码为：

```text
0
```

运行时内核可能打印下面的提示：

```text
virtio_net virtio1 eth0: XDP request 2 queues but max is 1.
XDP_TX and XDP_REDIRECT will operate in a slower locked tx mode.
```

实际串口里这两句可能出现在同一行。这是 virtio-net 队列数量相关提示，不是失败。只要程序打印 `Waiting for Ctrl-C...` 并且 `bpftool` 能看到 XDP 程序挂载，就说明运行成功。

如果接口名写错，程序会返回错误，例如：

```sh
./myapp --iface nope
```

实测输出：

```text
Error: failed to attach the XDP program with default mode - try changing XdpMode::default() to XdpMode::Skb

Caused by:
    unknown network interface nope
```

## 步骤 6：观察 XDP/eBPF 挂载结果

如果前台运行 `./myapp --iface eth0`，当前 shell 会被程序占住。为了同时观察结果，建议后台运行并把日志写入文件：

```sh
cd /home/prac
rm -f /tmp/myapp.log

./myapp --iface eth0 > /tmp/myapp.log 2>&1 &
pid=$!

sleep 2
echo "myapp pid: $pid"
```

### 6.0 先启动后台流量脚本

工程的 `prac/` 目录中提供了一个虚拟机内使用的后台流量脚本：

```text
/home/prac/xdp_traffic.sh
```

它会循环通过 `eth0` 产生 ICMP 流量：

- ping QEMU user-net 网关 `10.0.2.2`
- ping 虚拟机自己的 `eth0` IPv4 地址
- 默认每 1 秒执行一轮
- 日志写入 `/tmp/xdp_traffic.log`
- pid 写入 `/tmp/xdp_traffic.pid`

推荐验证顺序是：先启动流量脚本，再启动 `myapp`。这样 `myapp` attach XDP 后马上能观察到持续进入 `eth0` 的包。

在虚拟机内执行：

```sh
cd /home/prac
./xdp_traffic.sh start
./xdp_traffic.sh status
tail -f /tmp/xdp_traffic.log
```

本次实测输出：

```text
started: pid 126
log: /tmp/xdp_traffic.log
running: pid 126
log: /tmp/xdp_traffic.log

xdp traffic generator started
iface=eth0 target=10.0.2.2 interval=1
2026-06-12 07:17:07
ping gateway 10.0.2.2
gateway ping ok
ping self 10.0.2.15
self ping ok
2026-06-12 07:17:08
ping gateway 10.0.2.2
gateway ping ok
ping self 10.0.2.15
self ping ok
```

另一个 shell 或停止 `tail -f` 后，启动 `myapp`：

```sh
cd /home/prac
RUST_LOG=info ./myapp --iface eth0
```

如果不想占住 shell，可以后台运行：

```sh
cd /home/prac
RUST_LOG=info ./myapp --iface eth0 > /tmp/myapp.log 2>&1 &
pid=$!
sleep 3
cat /tmp/myapp.log
```

预期 `myapp` 日志中除了生命周期日志，还可能看到 eBPF 侧日志：

```text
Waiting for Ctrl-C...
[INFO  myapp] received a packet
[INFO  myapp] received a packet
[INFO  myapp] received a packet
```

注意：必须设置 `RUST_LOG=info` 才能看到 `info!(&ctx, "received a packet")` 这类 eBPF 日志。若不设置该环境变量，通常只能看到 `Waiting for Ctrl-C...` 和 `Exiting...`。

停止流量脚本：

```sh
./xdp_traffic.sh stop
```

### 6.1 使用 bpftool 查看网卡上的 XDP 程序

```sh
bpftool net list
```

实测输出：

```text
xdp:
eth0(3) driver id 10

tc:

flow_dissector:
```

这里的关键点是 `xdp:` 下出现了 `eth0(3) driver id ...`，表示 `eth0` 上已经挂载了 XDP 程序。具体 id 每次加载都会变化。

### 6.2 使用 bpftool 查看已加载的 BPF 程序

```sh
bpftool prog list
```

实测输出：

```text
10: xdp  name myapp  tag cc0d4a258d3d63cb  gpl
        loaded_at 2026-06-12T07:17:09+0000  uid 0
        xlated 2176B  jited 1400B  memlock 4096B  map_ids 9,10
        btf_id 18
```

判断标准：

- 程序类型是 `xdp`。
- 程序名是 `myapp`。
- 能看到 `jited`，说明内核已完成 JIT 编译。
- `memlock`、`map_ids`、`btf_id` 等字段存在，说明程序和关联 map 已经进入内核。

### 6.3 使用 ip 查看 eth0 的 XDP 附加信息

```sh
ip -details link show eth0
```

实测输出中的关键部分：

```text
3: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 xdp ...
    prog/xdp id 10 name myapp tag cc0d4a258d3d63cb jited load_time ... btf_id 18
```

判断标准：

- 第一行包含 `xdp`。
- 后面包含 `prog/xdp id ... name myapp`。
- `id` 与 `bpftool prog list` 中的程序 id 一致。

### 6.4 产生网络流量

当前 eBPF 程序会在收到包时打印日志：

```rust
info!(&ctx, "received a packet");
```

可以用 ping 产生经过 `eth0` 的流量：

```sh
ping -c 2 10.0.2.2
```

实测输出：

```text
PING 10.0.2.2 (10.0.2.2): 56 data bytes
64 bytes from 10.0.2.2: seq=0 ttl=255 time=0.737 ms
64 bytes from 10.0.2.2: seq=1 ttl=255 time=0.648 ms

--- 10.0.2.2 ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss
round-trip min/avg/max = 0.648/0.692/0.737 ms
```

说明虚拟机内 `eth0` 网络可用，XDP 程序挂载后没有阻断正常流量。当前 `myapp` 源码中 `try_myapp()` 返回 `XDP_PASS`，所以包会继续走正常网络协议栈。

### 6.5 停止后台程序并查看日志

停止 `myapp`：

```sh
kill -INT "$pid"
sleep 1
```

当前 BusyBox `ash` 在后台任务已经打印 `Done` 后，再执行 `wait "$pid"` 可能返回 `127`。后台验证时不要把 `wait` 的返回码作为硬性成功条件，重点看 `/tmp/myapp.log` 是否出现 `Exiting...`，以及停止后 XDP 是否已经卸载：

```sh
bpftool net list
```

查看程序日志：

```sh
cat /tmp/myapp.log
```

实测输出：

```text
Waiting for Ctrl-C...
[INFO  myapp] received a packet
[INFO  myapp] received a packet
[INFO  myapp] received a packet
[INFO  myapp] received a packet
[INFO  myapp] received a packet
[INFO  myapp] received a packet
[INFO  myapp] received a packet
Exiting...
```

## 一次性验证命令

虚拟机内可以直接复制下面这段命令，完成后台运行、观察、停止和查看日志：

```sh
cd /home/prac
rm -f /tmp/myapp.log

./xdp_traffic.sh start

sleep 2

RUST_LOG=info ./myapp --iface eth0 > /tmp/myapp.log 2>&1 &
pid=$!

sleep 2

echo "=== bpftool net list ==="
bpftool net list

echo "=== bpftool prog list ==="
bpftool prog list

echo "=== ip -details link show eth0 ==="
ip -details link show eth0

echo "=== generate traffic ==="
ping -c 2 10.0.2.2 || true

kill -INT "$pid"
sleep 1

./xdp_traffic.sh stop

echo "=== myapp log ==="
cat /tmp/myapp.log

echo "=== traffic generator log ==="
tail -n 30 /tmp/xdp_traffic.log

echo "=== bpftool net list after stop ==="
bpftool net list
```

本次按上述流程实测的关键输出：

```text
=== traffic generator log ===
ping gateway 10.0.2.2
gateway ping ok
ping self 10.0.2.15
self ping ok

=== bpftool net list ===
xdp:
eth0(3) driver id 10

=== bpftool prog list ===
10: xdp  name myapp  tag cc0d4a258d3d63cb  gpl
        xlated 2176B  jited 1400B  memlock 4096B

=== ip -details link show eth0 ===
prog/xdp id 10 name myapp tag cc0d4a258d3d63cb jited

=== myapp log ===
Waiting for Ctrl-C...
[INFO  myapp] received a packet
[INFO  myapp] received a packet
[INFO  myapp] received a packet
[INFO  myapp] received a packet
[INFO  myapp] received a packet
Exiting...

=== bpftool net list after stop ===
xdp:

tc:

flow_dissector:
```

成功时应同时满足：

- `bpftool net list` 在 `xdp:` 下显示 `eth0(...) driver id ...`。
- `bpftool prog list` 显示 `xdp name myapp`。
- `ip -details link show eth0` 显示 `prog/xdp id ... name myapp`。
- `/tmp/xdp_traffic.log` 持续显示 `gateway ping ok` 或 `self ping ok`。
- `/tmp/myapp.log` 显示 `Waiting for Ctrl-C...`、`[INFO  myapp] received a packet` 和 `Exiting...`。
- 停止后 `bpftool net list` 的 `xdp:` 下不再显示 `eth0(...) driver id ...`。

## 关闭虚拟机

在 VM 内执行：

```sh
poweroff -f
```

或者在 QEMU 串口中按：

```text
Ctrl-A x
```

## 常见问题

### 只复制到 output/target 后，虚拟机里看不到新文件

原因是还没有重新生成 `output/images/rootfs.ext2`。

解决：

```bash
cd /home/luckfox/workspace/buildroot-2023.11.1
make
```

然后重新启动 QEMU。

### 运行 myapp 报 No such file or directory

如果 `/home/prac/myapp` 明明存在但执行时报 `No such file or directory`，常见原因是动态解释器缺失。宿主机检查：

```bash
file /home/luckfox/workspace/buildroot-2023.11.1/output/target/home/prac/myapp
ls -l /home/luckfox/workspace/buildroot-2023.11.1/output/target/lib/ld-linux-aarch64.so.1
```

当前实测解释器是：

```text
/lib/ld-linux-aarch64.so.1
```

### bpftool 缺少 libsframe.so

如果 VM 内运行 `bpftool` 提示缺少 `libsframe.so.*`，参考：

```text
docs/5_bugfix.md
```

修复后需要重新执行：

```bash
cd /home/luckfox/workspace/buildroot-2023.11.1
make binutils-reinstall
make
```

### 运行后只看到 Waiting for Ctrl-C

这是正常现象。该程序是长时间运行的 XDP loader，成功 attach 后会等待 `Ctrl-C`。需要观察挂载状态时，使用后台运行方式，再执行 `bpftool net list`、`bpftool prog list` 和 `ip -details link show eth0`。
