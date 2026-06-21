# 9. Buildroot QEMU 中的 V4L2 与观测性实验

本文把 V4L2 学习路线落实成可以在当前 Buildroot + QEMU 虚拟机里执行的实验。文中的命令和输出来自本机实际运行，输出做了必要删减，但没有改写为“示意输出”。

实验环境：

```text
Buildroot: /home/luckfox/workspace/buildroot-2023.11.1
实验目录:  /home/luckfox/workspace/buildroot-study/my-work
目标系统:  Buildroot aarch64 guest
内核版本:  Linux 6.1.44
虚拟机:    qemu-system-aarch64 -M virt -cpu cortex-a53 -smp 1
虚拟摄像头: vivid
```

本文的学习目标：

1. 看到一次 V4L2 抓帧如何从用户态 ioctl 进入内核。
2. 把 `VIDIOC_QBUF`、`VIDIOC_DQBUF` 等 ioctl 映射到 V4L2 core 和 VB2。
3. 使用 ftrace、tracepoint、kprobe、perf、trace-cmd 观察时序、热点和调度。
4. 为后续分析 CAMSS/CAMX/ISP 代码建立方法，而不是只记命令。

## 0. 环境准备

### 0.1 宿主机确认内核配置

宿主机执行：

```bash
grep -E -n "CONFIG_(MEDIA_SUPPORT|VIDEO_DEV|V4L_TEST_DRIVERS|VIDEO_VIVID|VIDEOBUF2_V4L2|TRACING|FTRACE|FUNCTION_TRACER|FUNCTION_GRAPH_TRACER|KPROBE_EVENTS|PERF_EVENTS|DEBUG_FS|KALLSYMS|STACKTRACE|FRAME_POINTER)=" \
  /home/luckfox/workspace/buildroot-2023.11.1/output/build/linux-6.1.44/.config
```

实际输出：

```text
224:CONFIG_KALLSYMS=y
236:CONFIG_PERF_EVENTS=y
2635:CONFIG_MEDIA_SUPPORT=y
2651:CONFIG_VIDEO_DEV=y
2774:CONFIG_V4L_TEST_DRIVERS=y
2778:CONFIG_VIDEO_VIVID=m
2783:CONFIG_VIDEOBUF2_V4L2=m
4186:CONFIG_FRAME_POINTER=y
4194:CONFIG_DEBUG_FS=y
4301:CONFIG_STACKTRACE=y
4348:CONFIG_TRACING=y
4351:CONFIG_FTRACE=y
4353:CONFIG_FUNCTION_TRACER=y
4354:CONFIG_FUNCTION_GRAPH_TRACER=y
4371:CONFIG_KPROBE_EVENTS=y
```

这说明：

- `CONFIG_MEDIA_SUPPORT`、`CONFIG_VIDEO_DEV`：V4L2/media 子系统已经打开。
- `CONFIG_V4L_TEST_DRIVERS`、`CONFIG_VIDEO_VIVID=m`：`vivid` 虚拟摄像头驱动会以模块形式构建。
- `CONFIG_VIDEOBUF2_V4L2=m`：VB2 的 V4L2 适配层存在，后面能观察 `vb2_ioctl_qbuf` 等函数。
- `CONFIG_TRACING`、`CONFIG_FTRACE`、`CONFIG_KPROBE_EVENTS`、`CONFIG_PERF_EVENTS`：ftrace、kprobe、perf 的内核支持已经打开。
- `CONFIG_FRAME_POINTER`、`CONFIG_STACKTRACE`：有利于得到更完整的调用栈。

### 0.2 宿主机确认模块和镜像

宿主机执行：

```bash
find /home/luckfox/workspace/buildroot-2023.11.1/output/target/lib/modules/6.1.44 \
  -name '*vivid*.ko' -o -name 'videobuf2*.ko' -o -name 'v4l2-tpg.ko' | sort
```

实际输出：

```text
/home/luckfox/workspace/buildroot-2023.11.1/output/target/lib/modules/6.1.44/kernel/drivers/media/common/v4l2-tpg/v4l2-tpg.ko
/home/luckfox/workspace/buildroot-2023.11.1/output/target/lib/modules/6.1.44/kernel/drivers/media/common/videobuf2/videobuf2-common.ko
/home/luckfox/workspace/buildroot-2023.11.1/output/target/lib/modules/6.1.44/kernel/drivers/media/common/videobuf2/videobuf2-dma-contig.ko
/home/luckfox/workspace/buildroot-2023.11.1/output/target/lib/modules/6.1.44/kernel/drivers/media/common/videobuf2/videobuf2-memops.ko
/home/luckfox/workspace/buildroot-2023.11.1/output/target/lib/modules/6.1.44/kernel/drivers/media/common/videobuf2/videobuf2-v4l2.ko
/home/luckfox/workspace/buildroot-2023.11.1/output/target/lib/modules/6.1.44/kernel/drivers/media/common/videobuf2/videobuf2-vmalloc.ko
/home/luckfox/workspace/buildroot-2023.11.1/output/target/lib/modules/6.1.44/kernel/drivers/media/test-drivers/vivid/vivid.ko
```

宿主机执行：

```bash
ls -lh /home/luckfox/workspace/buildroot-2023.11.1/output/images/Image \
       /home/luckfox/workspace/buildroot-2023.11.1/output/images/rootfs.ext2 \
       /home/luckfox/workspace/buildroot-2023.11.1/output/images/start-qemu.sh
file /home/luckfox/workspace/buildroot-2023.11.1/output/images/Image
```

实际输出：

```text
-rw-r--r-- 1 luckfox luckfox  21M Jun 12 10:26 /home/luckfox/workspace/buildroot-2023.11.1/output/images/Image
-rw-r--r-- 1 luckfox luckfox 512M Jun 12 17:25 /home/luckfox/workspace/buildroot-2023.11.1/output/images/rootfs.ext2
-rwxrwxrwx 1 luckfox luckfox  844 Jun 12 17:02 /home/luckfox/workspace/buildroot-2023.11.1/output/images/start-qemu.sh
/home/luckfox/workspace/buildroot-2023.11.1/output/images/Image: Linux kernel ARM64 boot executable Image, little-endian, 4K pages
```

这说明镜像和根文件系统已经生成，可以直接启动 QEMU。

### 0.3 启动 QEMU

宿主机执行：

```bash
cd /home/luckfox/workspace/buildroot-2023.11.1/output/images
./start-qemu.sh
```

启动日志关键输出：

```text
Booting Linux on physical CPU 0x0000000000 [0x410fd034]
Linux version 6.1.44 (luckfox@3f7b1b2e40c5) ... #6 SMP Fri Jun 12 10:26:35 UTC 2026
ftrace: allocating 31071 entries in 122 pages
mc: Linux media interface: v0.10
videodev: Linux video capture interface: v2.00
hw perfevents: enabled with armv8_pmuv3 PMU driver, 7 counters available
Welcome to Buildroot
buildroot login:
```

登录：

```text
buildroot login: root
#
```

这些启动日志说明：

- `ftrace: allocating ...`：ftrace 函数追踪表已经初始化。
- `mc: Linux media interface`：media controller 子系统已注册。
- `videodev: Linux video capture interface`：V4L2 核心已注册。
- `hw perfevents`：perf 可以使用 ARM PMU 采样。

### 0.4 Guest 内确认工具和 tracefs

虚拟机内执行：

```sh
uname -a
uname -m
zcat /proc/config.gz | grep -E 'CONFIG_(MEDIA_SUPPORT|VIDEO_DEV|V4L_TEST_DRIVERS|VIDEO_VIVID|VIDEOBUF2_V4L2|TRACING|FTRACE|FUNCTION_TRACER|FUNCTION_GRAPH_TRACER|KPROBE_EVENTS|PERF_EVENTS|FTRACE_SYSCALLS)='
for t in v4l2-ctl strace perf trace-cmd yavta; do command -v "$t" || echo "$t missing"; done
mount -t tracefs nodev /sys/kernel/tracing 2>/dev/null || true
mount -t debugfs nodev /sys/kernel/debug 2>/dev/null || true
cat /sys/kernel/tracing/available_tracers
cat /sys/kernel/tracing/current_tracer
```

实际输出：

```text
Linux buildroot 6.1.44 #6 SMP Fri Jun 12 10:26:35 UTC 2026 aarch64 GNU/Linux

-----------------

aarch64

-----------------

CONFIG_PERF_EVENTS=y
CONFIG_MEDIA_SUPPORT=y
CONFIG_VIDEO_DEV=y
CONFIG_V4L_TEST_DRIVERS=y
CONFIG_VIDEO_VIVID=m
CONFIG_VIDEOBUF2_V4L2=m
CONFIG_TRACING=y
CONFIG_FTRACE=y
CONFIG_FUNCTION_TRACER=y
CONFIG_FUNCTION_GRAPH_TRACER=y
CONFIG_KPROBE_EVENTS=y

-----------------

/usr/bin/v4l2-ctl
/usr/bin/strace
/usr/bin/perf
/usr/bin/trace-cmd
/usr/bin/yavta

-----------------

blk function_graph wakeup_dl wakeup_rt wakeup irqsoff function nop

-----------------

nop
```

这说明：

- 当前 guest 是 aarch64 Buildroot，内核版本为 6.1.44。
- `v4l2-ctl`、`strace`、`perf`、`trace-cmd`、`yavta` 都在 rootfs 里。
- tracefs 可用，并支持 `function`、`function_graph`、`wakeup` 等 tracer。
- 当前 tracer 是 `nop`，表示函数 tracer 没有开启。

### 0.5 加载 vivid 并验证设备

虚拟机内执行：

```sh
modprobe vivid n_devs=1
sleep 1
dmesg | tail -14
ls -l /dev/video* /dev/media* 2>/dev/null
v4l2-ctl --list-devices
v4l2-ctl -d /dev/video0 -D
```

实际输出摘录：

```text
vivid-000: using single planar format API
vivid-000: V4L2 capture device registered as video0
vivid-000: V4L2 output device registered as video1
vivid-000: V4L2 capture device registered as vbi0, supports raw and sliced VBI
vivid-000: V4L2 output device registered as vbi1, supports raw and sliced VBI
vivid-000: V4L2 capture device registered as swradio0
vivid-000: V4L2 receiver device registered as radio0
vivid-000: V4L2 transmitter device registered as radio1
vivid-000: V4L2 metadata capture device registered as video2
vivid-000: V4L2 metadata output device registered as video3
vivid-000: V4L2 touch capture device registered as v4l-touch0

--------------

crw-------    1 root     root      251,   0 Jun 12 17:15 /dev/media0
crw-------    1 root     root       81,   0 Jun 12 17:15 /dev/video0
crw-------    1 root     root       81,   1 Jun 12 17:15 /dev/video1
crw-------    1 root     root       81,   7 Jun 12 17:15 /dev/video2
crw-------    1 root     root       81,   8 Jun 12 17:15 /dev/video3

--------------

vivid (platform:vivid-000):
        /dev/video0
        /dev/video1
        /dev/video2
        /dev/video3
        /dev/radio0
        /dev/radio1
        /dev/vbi0
        /dev/vbi1
        /dev/swradio0
        /dev/v4l-touch0
        /dev/media0

--------------

Driver Info:
        Driver name      : vivid
        Card type        : vivid
        Bus info         : platform:vivid-000
        Driver version   : 6.1.44
        Capabilities     : 0x9dbf0df7
                Video Capture
                Video Output
                Video Overlay
                VBI Capture
                VBI Output
                Sliced VBI Capture
                Sliced VBI Output
                RDS Capture
                RDS Output
                SDR Capture
                Metadata Capture
                Metadata Output
                Tuner
                Touch Device
                HW Frequency Seek
                Modulator
                Audio
                Radio
                Read/Write
                Streaming
                Extended Pix Format
                Device Capabilities
        Device Caps      : 0x05230005
                Video Capture
                Video Overlay
                Tuner
                Audio
                Read/Write
                Streaming
                Extended Pix Format
```

这说明：

- `/dev/video0` 是 `vivid` 的 capture 节点。
- `Device Caps` 中有 `Video Capture` 和 `Streaming`，说明可以做 V4L2 streaming 抓帧。
- `Read/Write` 也存在，但本文重点学习 mmap streaming，因为真实 camera pipeline 通常绕不开 buffer queue。

### 0.6 查看完整设备能力、格式和控制项

虚拟机内执行：

```sh
v4l2-ctl -d /dev/video0 --all | head -120
```

实际输出摘录：

```text
Driver Info:
        Driver name      : vivid
        Card type        : vivid
        Bus info         : platform:vivid-000
        Driver version   : 6.1.44
        Capabilities     : 0x9dbf0df7
                Video Capture
                Video Output
                Video Overlay
                VBI Capture
                VBI Output
                Sliced VBI Capture
                Sliced VBI Output
                RDS Capture
                RDS Output
                SDR Capture
                Metadata Capture
                Metadata Output
                Tuner
                Touch Device
                HW Frequency Seek
                Modulator
                Audio
                Radio
                Read/Write
                Streaming
                Extended Pix Format
                Device Capabilities
        Device Caps      : 0x05230005
                Video Capture
                Video Overlay
                Tuner
                Audio
                Read/Write
                Streaming
                Extended Pix Format
Media Driver Info:
        Driver name      : vivid
        Model            : vivid
        Bus info         : platform:vivid-000
        Media version    : 6.1.44
        Driver version   : 6.1.44
Interface Info:
        ID               : 0x03000003
        Type             : V4L Video
Entity Info:
        ID               : 0x00000001 (1)
        Name             : vivid-000-vid-cap
        Function         : V4L2 I/O
        Pad 0x01000002   : 0: Sink
Priority: 2
Frequency for tuner 0: 2804 (175.250000 MHz)
Tuner 0:
        Name                 : TV Tuner
        Type                 : Analog TV
Video input : 0 (Webcam 0: ok)
Format Video Capture:
        Width/Height      : 640/480
        Pixel Format      : 'YUYV' (YUYV 4:2:2)
        Field             : None
        Bytes per Line    : 1280
        Size Image        : 614400
        Colorspace        : sRGB
Streaming Parameters Video Capture:
        Capabilities     : timeperframe
        Frames per second: 5.000 (5/1)
        Read buffers     : 1

User Controls

                     brightness 0x00980900 (int)    : min=0 max=255 step=1 default=128 value=128 flags=slider
                       contrast 0x00980901 (int)    : min=0 max=255 step=1 default=128 value=128 flags=slider
                     saturation 0x00980902 (int)    : min=0 max=255 step=1 default=128 value=128 flags=slider
                            hue 0x00980903 (int)    : min=-128 max=128 step=1 default=0 value=0 flags=slider
```

这说明：

- 当前格式是 `640x480 YUYV`。
- `Size Image = 614400`，即 `640 * 480 * 2` 字节。
- `Frames per second: 5.000`，后续 `DQBUF` 等待约 0.2 秒是合理的。
- `vivid` 暴露很多控制项，适合学习 `QUERYCTRL`、`G_CTRL`、`S_CTRL` 等 V4L2 控制路径。

### 0.7 设置格式并抓 5 帧

虚拟机内执行：

```sh
v4l2-ctl -d /dev/video0 --get-fmt-video
v4l2-ctl -d /dev/video0 --set-fmt-video=width=640,height=480,pixelformat=YUYV
v4l2-ctl -d /dev/video0 --get-fmt-video
v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=5 --stream-to=/tmp/vivid-yuyv.raw
ls -l /tmp/vivid-yuyv.raw
wc -c /tmp/vivid-yuyv.raw
```

实际输出：
```text
Format Video Capture:
        Width/Height      : 640/360
        Pixel Format      : 'YUYV' (YUYV 4:2:2)
        Field             : None
        Bytes per Line    : 1280
        Size Image        : 460800
        Colorspace        : sRGB
        Transfer Function : Default (maps to sRGB)
        YCbCr/HSV Encoding: Default (maps to ITU-R 601)
        Quantization      : Default (maps to Limited Range)
        Flags             :
```
```text
Format Video Capture:
        Width/Height      : 640/480
        Pixel Format      : 'YUYV' (YUYV 4:2:2)
        Field             : None
        Bytes per Line    : 1280
        Size Image        : 614400
        Colorspace        : sRGB
        Transfer Function : Default (maps to sRGB)
        YCbCr/HSV Encoding: Default (maps to ITU-R 601)
        Quantization      : Default (maps to Limited Range)
        Flags             :
#
```
```text
<<<<<
-rw-r--r--    1 root     root       3072000 Jun 12 17:15 /tmp/vivid-yuyv.raw
3072000 /tmp/vivid-yuyv.raw
```

这说明：

- 第一次查询时默认是 `640x360`。
- 设置后变成 `640x480 YUYV`。
- `<<<<<` 是 `v4l2-ctl` 每抓到一帧打印一个 `<`。
- 文件大小 `3072000 = 640 * 480 * 2 * 5`，说明确实抓到了 5 帧。

### 0.8 查看 media controller 拓扑

虚拟机内执行：

```sh
media-ctl -p -d /dev/media0 | head -100
```

实际输出：

```text
Media controller API version 6.1.44

Media device information
------------------------
driver          vivid
model           vivid
serial
bus info        platform:vivid-000
hw revision     0x0
driver version  6.1.44

Device topology
- entity 1: vivid-000-vid-cap (1 pad, 0 link)
            type Node subtype V4L flags 0
            device node name /dev/video0
        pad0: Sink

- entity 5: vivid-000-vid-out (1 pad, 0 link)
            type Node subtype V4L flags 0
            device node name /dev/video1
        pad0: Source

- entity 9: vivid-000-vbi-cap (1 pad, 0 link)
            type Node subtype Unknown flags 0
            device node name /dev/vbi0
        pad0: Sink

- entity 13: vivid-000-vbi-out (1 pad, 0 link)
             type Node subtype Unknown flags 0
             device node name /dev/vbi1
        pad0: Source

- entity 17: vivid-000-sdr-cap (1 pad, 0 link)
             type Node subtype Unknown flags 0
             device node name /dev/swradio0
        pad0: Sink

- entity 23: vivid-000-meta-cap (1 pad, 0 link)
             type Node subtype V4L flags 0
             device node name /dev/video2
        pad0: Sink

- entity 27: vivid-000-meta-out (1 pad, 0 link)
             type Node subtype V4L flags 0
             device node name /dev/video3
        pad0: Source

- entity 31: vivid-000-touch-cap (1 pad, 0 link)
             type Node subtype V4L flags 0
             device node name /dev/v4l-touch0
        pad0: Sink
```

这说明 `/dev/video0` 不只是一个字符设备，它也是 media controller 里的一个 entity。后面分析真实 camera 时，sensor、CSI、ISP、DMA 都会以 entity/pad/link 的形式连接起来。

## 1. 先理解 V4L2 的用户态行为

### 1.1 使用 strace 抓 ioctl

虚拟机内执行：

```sh
rm -f /tmp/ioctl.log /tmp/strace.raw
strace -ttT -o /tmp/ioctl.log -e trace=ioctl \
  v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=3 --stream-to=/tmp/strace.raw

grep -E 'VIDIOC_(QUERYCAP|REQBUFS|QUERYBUF|QBUF|STREAMON|DQBUF|STREAMOFF|G_FMT|S_FMT|ENUM_FMT|ENUMINPUT|G_INPUT|S_INPUT)' \
  /tmp/ioctl.log | head -120

grep 'VIDIOC_DQBUF' /tmp/ioctl.log

ls -l /tmp/strace.raw

wc -c /tmp/strace.raw
```

实际输出摘录：

```text
<<<

--------------------

17:16:00.974623 ioctl(3, VIDIOC_QUERYCAP, {driver="vivid", card="vivid", bus_info="platform:vivid-000", version=KERNEL_VERSION(6, 1, 44), capabilities=V4L2_CAP_VIDEO_CAPTURE|...|V4L2_CAP_STREAMING|..., device_caps=V4L2_CAP_VIDEO_CAPTURE|...|V4L2_CAP_STREAMING}) = 0 <0.000202>
17:16:00.981353 ioctl(3, VIDIOC_QUERYCAP, {driver="vivid", card="vivid", bus_info="platform:vivid-000", version=KERNEL_VERSION(6, 1, 44), capabilities=V4L2_CAP_VIDEO_CAPTURE|...|V4L2_CAP_STREAMING|..., device_caps=V4L2_CAP_VIDEO_CAPTURE|...|V4L2_CAP_STREAMING}) = 0 <0.000136>
17:16:01.027113 ioctl(3, VIDIOC_G_INPUT, [0]) = 0 <0.000126>
17:16:01.027648 ioctl(3, VIDIOC_ENUMINPUT, {index=0, name="Webcam 0", type=V4L2_INPUT_TYPE_CAMERA, ...}) = 0 <0.000172>
17:16:01.028725 ioctl(3, VIDIOC_REQBUFS, {type=V4L2_BUF_TYPE_VIDEO_CAPTURE, memory=V4L2_MEMORY_MMAP, count=4 => 4}) = 0 <0.001056>
17:16:01.030354 ioctl(3, VIDIOC_QUERYBUF, {type=V4L2_BUF_TYPE_VIDEO_CAPTURE, index=0, memory=V4L2_MEMORY_MMAP, m.offset=0, length=614400, ...}) = 0 <0.000143>
17:16:01.031019 ioctl(3, VIDIOC_QUERYBUF, {type=V4L2_BUF_TYPE_VIDEO_CAPTURE, index=1, memory=V4L2_MEMORY_MMAP, m.offset=0x96000, length=614400, ...}) = 0 <0.000143>
17:16:01.031526 ioctl(3, VIDIOC_QUERYBUF, {type=V4L2_BUF_TYPE_VIDEO_CAPTURE, index=2, memory=V4L2_MEMORY_MMAP, m.offset=0x12c000, length=614400, ...}) = 0 <0.000130>
17:16:01.032032 ioctl(3, VIDIOC_QUERYBUF, {type=V4L2_BUF_TYPE_VIDEO_CAPTURE, index=3, memory=V4L2_MEMORY_MMAP, m.offset=0x1c2000, length=614400, ...}) = 0 <0.000131>
17:16:01.034021 ioctl(3, VIDIOC_QBUF, {type=V4L2_BUF_TYPE_VIDEO_CAPTURE, index=0, memory=V4L2_MEMORY_MMAP, ... flags=V4L2_BUF_FLAG_MAPPED|V4L2_BUF_FLAG_QUEUED|...}) = 0 <0.000167>
17:16:01.034759 ioctl(3, VIDIOC_QBUF, {type=V4L2_BUF_TYPE_VIDEO_CAPTURE, index=1, memory=V4L2_MEMORY_MMAP, ...}) = 0 <0.000132>
17:16:01.035217 ioctl(3, VIDIOC_QBUF, {type=V4L2_BUF_TYPE_VIDEO_CAPTURE, index=2, memory=V4L2_MEMORY_MMAP, ...}) = 0 <0.000125>
17:16:01.035709 ioctl(3, VIDIOC_QBUF, {type=V4L2_BUF_TYPE_VIDEO_CAPTURE, index=3, memory=V4L2_MEMORY_MMAP, ...}) = 0 <0.000166>
17:16:01.036985 ioctl(3, VIDIOC_STREAMON, [V4L2_BUF_TYPE_VIDEO_CAPTURE]) = 0 <0.000473>
17:16:01.038755 ioctl(3, VIDIOC_DQBUF, {type=V4L2_BUF_TYPE_VIDEO_CAPTURE, index=0, memory=V4L2_MEMORY_MMAP, ... timestamp={tv_sec=123, tv_usec=991}, ...}) = 0 <0.000570>
17:16:01.043649 ioctl(3, VIDIOC_QBUF, {type=V4L2_BUF_TYPE_VIDEO_CAPTURE, index=0, memory=V4L2_MEMORY_MMAP, ...}) = 0 <0.000166>
17:16:01.045134 ioctl(3, VIDIOC_DQBUF, {type=V4L2_BUF_TYPE_VIDEO_CAPTURE, index=1, memory=V4L2_MEMORY_MMAP, ... timestamp={tv_sec=123, tv_usec=200110}, ...}) = 0 <0.193456>
17:16:01.242992 ioctl(3, VIDIOC_QBUF, {type=V4L2_BUF_TYPE_VIDEO_CAPTURE, index=1, memory=V4L2_MEMORY_MMAP, ...}) = 0 <0.000185>
17:16:01.244840 ioctl(3, VIDIOC_DQBUF, {type=V4L2_BUF_TYPE_VIDEO_CAPTURE, index=2, memory=V4L2_MEMORY_MMAP, ... timestamp={tv_sec=123, tv_usec=400134}, ...}) = 0 <0.193755>
17:16:01.441508 ioctl(3, VIDIOC_QBUF, {type=V4L2_BUF_TYPE_VIDEO_CAPTURE, index=2, memory=V4L2_MEMORY_MMAP, ...}) = 0 <0.000172>
17:16:01.443367 ioctl(3, VIDIOC_STREAMOFF, [V4L2_BUF_TYPE_VIDEO_CAPTURE]) = 0 <0.000386>
17:16:01.444683 ioctl(3, VIDIOC_STREAMOFF, [V4L2_BUF_TYPE_VIDEO_CAPTURE]) = 0 <0.000136>
17:16:01.446951 ioctl(3, VIDIOC_REQBUFS, {type=V4L2_BUF_TYPE_VIDEO_CAPTURE, memory=V4L2_MEMORY_MMAP, count=0 => 0}) = 0 <0.001245>

--------------------

17:16:01.038755 ioctl(3, VIDIOC_DQBUF, ...) = 0 <0.000570>
17:16:01.045134 ioctl(3, VIDIOC_DQBUF, ...) = 0 <0.193456>
17:16:01.244840 ioctl(3, VIDIOC_DQBUF, ...) = 0 <0.193755>

--------------------

-rw-r--r--    1 root     root       1843200 Jun 12 17:16 /tmp/strace.raw

------------------

1843200 /tmp/strace.raw
```

### 1.2 输出含义

一次 mmap streaming 抓帧的用户态生命周期是：

```text
VIDIOC_QUERYCAP       查询设备能力
VIDIOC_REQBUFS        申请 buffer，这里申请 4 个 mmap buffer
VIDIOC_QUERYBUF       查询每个 buffer 的 offset/length
mmap                  v4l2-ctl 内部把 buffer 映射到用户态，strace 这里只过滤 ioctl 所以没显示
VIDIOC_QBUF           把 buffer 入队，交给驱动/VB2
VIDIOC_STREAMON       启动采集流
VIDIOC_DQBUF          等待并取回完成的 buffer
VIDIOC_QBUF           处理完一帧后重新入队
VIDIOC_STREAMOFF      停止流
VIDIOC_REQBUFS count=0 释放 buffer
```

最关键的是 `DQBUF`：

- 第一帧 `DQBUF` 只花了 `0.000570s`，因为启动后很快有 buffer ready。
- 后两帧分别花了 `0.193456s` 和 `0.193755s`。
- `vivid` 当前帧率是 5 fps，也就是每帧约 `0.2s`，所以 `DQBUF` 慢不是 bug，而是在等待下一帧完成。

### 1.3 学到什么

用户态看到的“摄像头慢”，常常具体表现为 `VIDIOC_DQBUF` 阻塞。后续定位要继续问：

- 是驱动没有按时完成 buffer？
- 是真实硬件中断没来？
- 是线程被调度打断？
- 是用户态处理太慢，导致 buffer 没及时重新 `QBUF`？

这一节先把问题锚定到用户态 syscall 时序上。

## 2. 用 ftrace 抓 V4L2 入口函数

### 2.1 先确认可追踪函数

虚拟机内执行：

```sh
stty cols 240 rows 80
export TERM=dumb
cd /sys/kernel/tracing
grep -E '^(v4l2_ioctl|video_ioctl2|video_usercopy|__video_do_ioctl|v4l_.*buf|v4l_streamon|v4l_streamoff)' \
  available_filter_functions | head -80
```

实际输出：

```text
v4l2_ioctl
v4l_streamon
v4l_streamoff
v4l_stub_g_fbuf
v4l_stub_s_fbuf
v4l_stub_expbuf
v4l_create_bufs
v4l_reqbufs
__video_do_ioctl
v4l_querybuf
v4l_qbuf
v4l_dqbuf
v4l_prepare_buf
video_usercopy
video_ioctl2
v4l_print_buftype
v4l_print_exportbuffer
v4l_print_framebuffer
v4l_print_buffer
v4l_print_requestbuffers
v4l_print_create_buffers
```

这说明 V4L2 core 的入口函数都能被 ftrace 追踪。

### 2.2 使用 function tracer

虚拟机内执行：

```sh
cd /sys/kernel/tracing
echo 0 > tracing_on
echo nop > current_tracer
echo > trace
echo > set_ftrace_filter
printf 'v4l2_ioctl\nvideo_ioctl2\nvideo_usercopy\n__video_do_ioctl\nv4l_reqbufs\nv4l_querybuf\nv4l_qbuf\nv4l_dqbuf\nv4l_streamon\nv4l_streamoff\n' > set_ftrace_filter
echo function > current_tracer
echo 1 > tracing_on

v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=2 --stream-to=/tmp/ftrace-func.raw

echo 0 > tracing_on
cat trace | grep -E 'v4l2_ioctl|video_ioctl2|video_usercopy|__video_do_ioctl|v4l_(reqbufs|querybuf|qbuf|dqbuf|streamon|streamoff)' | head -120
```

实际输出前半段摘录：

```text
<<
        v4l2-ctl-147     [000] .....   190.936956: v4l2_ioctl <-__arm64_sys_ioctl
        v4l2-ctl-147     [000] .....   190.937329: video_ioctl2 <-v4l2_ioctl
        v4l2-ctl-147     [000] .....   190.937355: video_usercopy <-video_ioctl2
        v4l2-ctl-147     [000] .....   190.937372: __video_do_ioctl <-video_usercopy
        v4l2-ctl-147     [000] .....   190.937406: v4l2_ioctl <-__arm64_sys_ioctl
        v4l2-ctl-147     [000] .....   190.937407: video_ioctl2 <-v4l2_ioctl
        v4l2-ctl-147     [000] .....   190.937408: video_usercopy <-video_ioctl2
        v4l2-ctl-147     [000] .....   190.937412: __video_do_ioctl <-video_usercopy
        ...
```

这段说明每个用户态 `ioctl()` 进入内核后，会先走：

```text
__arm64_sys_ioctl
  -> v4l2_ioctl
      -> video_ioctl2
          -> video_usercopy
              -> __video_do_ioctl
```

前半段很多重复，是因为 `v4l2-ctl` 在 streaming 前会查询大量 controls、input、format 等能力。

继续筛核心 buffer 操作：

```sh
grep -E 'v4l_(reqbufs|querybuf|qbuf|dqbuf|streamon|streamoff)' trace | head -80
```

实际输出：

```text
        v4l2-ctl-147     [000] .....   190.940223: v4l_reqbufs <-__video_do_ioctl
        v4l2-ctl-147     [000] .....   190.941181: v4l_querybuf <-__video_do_ioctl
        v4l2-ctl-147     [000] .....   190.941209: v4l_querybuf <-__video_do_ioctl
        v4l2-ctl-147     [000] .....   190.941223: v4l_querybuf <-__video_do_ioctl
        v4l2-ctl-147     [000] .....   190.941237: v4l_querybuf <-__video_do_ioctl
        v4l2-ctl-147     [000] .....   190.941631: v4l_qbuf <-__video_do_ioctl
        v4l2-ctl-147     [000] .....   190.941665: v4l_qbuf <-__video_do_ioctl
        v4l2-ctl-147     [000] .....   190.941675: v4l_qbuf <-__video_do_ioctl
        v4l2-ctl-147     [000] .....   190.941685: v4l_qbuf <-__video_do_ioctl
        v4l2-ctl-147     [000] .....   190.941717: v4l_streamon <-__video_do_ioctl
        v4l2-ctl-147     [000] .....   190.942033: v4l_dqbuf <-__video_do_ioctl
        v4l2-ctl-147     [000] .....   190.944401: v4l_qbuf <-__video_do_ioctl
        v4l2-ctl-147     [000] .....   190.944532: v4l_dqbuf <-__video_do_ioctl
        v4l2-ctl-147     [000] .....   191.141745: v4l_qbuf <-__video_do_ioctl
        v4l2-ctl-147     [000] .....   191.141874: v4l_streamoff <-__video_do_ioctl
        v4l2-ctl-147     [000] .....   191.142226: v4l_streamoff <-__video_do_ioctl
        v4l2-ctl-147     [000] .....   191.142803: v4l_reqbufs <-__video_do_ioctl
```

### 2.3 function_graph 补充观察

当前镜像里 `function_graph` 可以产生输出，但它容易混入 timer interrupt、RCU 等噪声。本文主线不依赖它。

虚拟机内执行：

```sh
cd /sys/kernel/tracing
echo 0 > tracing_on
echo nop > current_tracer
echo > trace
echo > set_graph_function
echo function_graph > current_tracer
echo video_ioctl2 > set_graph_function
echo 1 > options/funcgraph-proc
echo 1 > tracing_on

v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=1 --stream-to=/tmp/fgraph.raw

echo 0 > tracing_on
head -60 trace
echo nop > current_tracer
echo > set_graph_function
```

实际输出摘录：
```text
# head -60 trace
# tracer: function_graph
#
# CPU  TASK/PID         DURATION                  FUNCTION CALLS
# |     |    |           |   |                     |   |   |   |
 0)  v4l2-ct-160   |               |  video_ioctl2() {
 0)  v4l2-ct-160   |               |    video_usercopy() {
 0)  v4l2-ct-160   | + 45.712 us   |      __video_do_ioctl();
 0)  v4l2-ct-160   | ! 181.520 us  |    }
 0)  v4l2-ct-160   | ! 356.160 us  |  }
 0)  v4l2-ct-160   |               |  video_ioctl2() {
 0)  v4l2-ct-160   |               |    video_usercopy() {
 0)  v4l2-ct-160   | + 12.144 us   |      __video_do_ioctl();
 0)  v4l2-ct-160   | + 44.912 us   |    }
 0)  v4l2-ct-160   | + 51.872 us   |  }
 0)  v4l2-ct-160   |               |  video_ioctl2() {
 0)  v4l2-ct-160   |               |    video_usercopy() {
 0)  v4l2-ct-160   |   7.424 us    |      __video_do_ioctl();
 0)  v4l2-ct-160   | + 14.272 us   |    }
 0)  v4l2-ct-160   | + 20.480 us   |  }
 0)  v4l2-ct-160   |               |  video_ioctl2() {
 0)  v4l2-ct-160   |               |    video_usercopy() {
 0)  v4l2-ct-160   |   6.592 us    |      __video_do_ioctl();
 0)  v4l2-ct-160   | + 13.168 us   |    }
 0)  v4l2-ct-160   | + 18.912 us   |  }
 0)  v4l2-ct-160   |               |  video_ioctl2() {
 0)  v4l2-ct-160   |               |    video_usercopy() {
 0)  v4l2-ct-160   |   5.360 us    |      __video_do_ioctl();
 0)  v4l2-ct-160   | + 11.408 us   |    }
 0)  v4l2-ct-160   | + 17.152 us   |  }
 0)  v4l2-ct-160   |               |  video_ioctl2() {
 0)  v4l2-ct-160   |               |    video_usercopy() {
 0)  v4l2-ct-160   |   5.072 us    |      __video_do_ioctl();
 0)  v4l2-ct-160   | + 11.008 us   |    }
 0)  v4l2-ct-160   | + 16.544 us   |  }
 0)  v4l2-ct-160   |               |  video_ioctl2() {
 0)  v4l2-ct-160   |               |    video_usercopy() {
 0)  v4l2-ct-160   |   5.440 us    |      __video_do_ioctl();
 0)  v4l2-ct-160   | + 15.104 us   |    }
 0)  v4l2-ct-160   | + 23.344 us   |  }
 0)  v4l2-ct-160   |               |  video_ioctl2() {
 0)  v4l2-ct-160   |               |    video_usercopy() {
 0)  v4l2-ct-160   |   3.648 us    |      __video_do_ioctl();
 0)  v4l2-ct-160   | + 10.128 us   |    }
 0)  v4l2-ct-160   | + 15.920 us   |  }
 0)  v4l2-ct-160   |               |  video_ioctl2() {
 0)  v4l2-ct-160   |               |    video_usercopy() {
 0)  v4l2-ct-160   |   4.688 us    |      __video_do_ioctl();
 0)  v4l2-ct-160   | + 10.816 us   |    }
 0)  v4l2-ct-160   | + 16.400 us   |  }
 0)  v4l2-ct-160   |               |  video_ioctl2() {
 0)  v4l2-ct-160   |               |    video_usercopy() {
 0)  v4l2-ct-160   |   3.664 us    |      __video_do_ioctl();
 0)  v4l2-ct-160   |   9.888 us    |    }
 0)  v4l2-ct-160   | + 15.424 us   |  }
 0)  v4l2-ct-160   |               |  video_ioctl2() {
 0)  v4l2-ct-160   |               |    video_usercopy() {
 0)  v4l2-ct-160   |   3.664 us    |      __video_do_ioctl();
 0)  v4l2-ct-160   |   9.760 us    |    }
 0)  v4l2-ct-160   | + 15.216 us   |  }
 0)  v4l2-ct-160   |               |  video_ioctl2() {
```
```text
札记：本段标记存疑，因为我实际没有复现这里的结果。复现的结果是上面的text块的结果，也就是某些内核的函数我看不见。
<
# tracer: function_graph
#
# CPU  TASK/PID         DURATION                  FUNCTION CALLS
# |     |    |           |   |                     |   |   |   |
 0)  v4l2-ct-220   |               |  video_ioctl2() {
 0)  v4l2-ct-220   | + 48.528 us   |    irq_enter_rcu();
 0)  v4l2-ct-220   |               |    do_interrupt_handler() {
 0)  v4l2-ct-220   |   ==========> |
 0)  v4l2-ct-220   |               |      gic_handle_irq() {
 0)  v4l2-ct-220   |               |        generic_handle_domain_irq() {
 0)  v4l2-ct-220   |   1.328 us    |          __irq_resolve_mapping();
 0)  v4l2-ct-220   |               |          handle_percpu_devid_irq() {
 0)  v4l2-ct-220   |               |            arch_timer_handler_virt() {
 0)  v4l2-ct-220   |               |              hrtimer_interrupt() {
 0)  v4l2-ct-220   |                ...
```

这说明 `function_graph` 能看到层级和耗时，但在 QEMU 单核环境里非常容易被时钟中断打断。实际学习 V4L2 时，`function`、kprobe 和 tracepoint 更聚焦。

### 2.4 学到什么

这一节把用户态和内核入口对应起来：

```text
userspace ioctl(VIDIOC_QBUF)
  -> __arm64_sys_ioctl
      -> v4l2_ioctl
          -> video_ioctl2
              -> video_usercopy
                  -> __video_do_ioctl
                      -> v4l_qbuf
```

这一步非常重要。以后你看到用户态卡在某个 ioctl，就知道内核里应该从 V4L2 core 的哪条路径开始看。

## 3. 抓 VB2 缓冲区路径

VB2 是 V4L2 的通用 buffer queue 框架。真实 camera 驱动通常不会自己从零管理所有 buffer，而是接入 VB2。

### 3.1 查找 VB2 函数

虚拟机内执行：

```sh
cd /sys/kernel/tracing
grep -E '^vb2_.*(reqbufs|querybuf|qbuf|dqbuf|streamon|streamoff|mmap)' \
  available_filter_functions | head -80
```

实际输出：

```text
vb2_core_querybuf [videobuf2_common]
vb2_mmap [videobuf2_common]
vb2_core_reqbufs [videobuf2_common]
vb2_core_streamoff [videobuf2_common]
vb2_core_qbuf [videobuf2_common]
vb2_core_streamon [videobuf2_common]
vb2_core_dqbuf [videobuf2_common]
vb2_dqbuf [videobuf2_v4l2]
vb2_ioctl_dqbuf [videobuf2_v4l2]
vb2_fop_mmap [videobuf2_v4l2]
vb2_streamon [videobuf2_v4l2]
vb2_streamoff [videobuf2_v4l2]
vb2_querybuf [videobuf2_v4l2]
vb2_ioctl_querybuf [videobuf2_v4l2]
vb2_qbuf [videobuf2_v4l2]
vb2_ioctl_qbuf [videobuf2_v4l2]
vb2_reqbufs [videobuf2_v4l2]
vb2_ioctl_reqbufs [videobuf2_v4l2]
vb2_ioctl_streamoff [videobuf2_v4l2]
vb2_ioctl_streamon [videobuf2_v4l2]
vb2_dc_mmap [videobuf2_dma_contig]
vb2_dc_dmabuf_ops_mmap [videobuf2_dma_contig]
vb2_vmalloc_mmap [videobuf2_vmalloc]
vb2_vmalloc_dmabuf_ops_mmap [videobuf2_vmalloc]
```

这说明：

- `vb2_ioctl_*` 是 V4L2 ioctl ops 层。
- `vb2_core_*` 是 VB2 核心 buffer 状态机。
- `videobuf2_vmalloc`、`videobuf2_dma_contig` 是不同内存后端。`vivid` 常用 vmalloc，真实 SoC camera 常见 DMA contiguous 或 DMA-BUF。

### 3.2 用 kprobe 抓 VB2 核心函数和调用栈

虚拟机内执行：

```sh
cd /sys/kernel/tracing
echo 0 > tracing_on
echo nop > current_tracer
echo > trace
echo > set_ftrace_filter
echo > set_ftrace_notrace
for e in events/kprobes/*/enable; do [ -e "$e" ] && echo 0 > "$e"; done
echo > kprobe_events

echo 'p:probe_vb2_reqbufs vb2_core_reqbufs' >> kprobe_events
echo 'p:probe_vb2_qbuf vb2_core_qbuf' >> kprobe_events
echo 'p:probe_vb2_dqbuf vb2_core_dqbuf' >> kprobe_events
echo 'p:probe_vb2_streamon vb2_core_streamon' >> kprobe_events
echo 'p:probe_vb2_streamoff vb2_core_streamoff' >> kprobe_events

cat kprobe_events
for e in events/kprobes/probe_vb2_*/enable; do echo 1 > "$e"; done
echo stacktrace > events/kprobes/probe_vb2_qbuf/trigger
echo 1 > tracing_on

v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=2 --stream-to=/tmp/vb2-kprobe.raw

echo 0 > tracing_on
grep -E 'probe_vb2|<stack trace>|=>|vb2_|v4l_|video_ioctl2|v4l2_ioctl|__arm64_sys_ioctl' trace | head -220
```

实际 `kprobe_events`：

```text
p:kprobes/probe_vb2_reqbufs vb2_core_reqbufs
p:kprobes/probe_vb2_qbuf vb2_core_qbuf
p:kprobes/probe_vb2_dqbuf vb2_core_dqbuf
p:kprobes/probe_vb2_streamon vb2_core_streamon
p:kprobes/probe_vb2_streamoff vb2_core_streamoff
```

实际 trace 摘录：

```text
<<
        v4l2-ctl-157     [000] d....   271.331500: probe_vb2_reqbufs: (vb2_core_reqbufs+0x0/0x550 [videobuf2_common])
        v4l2-ctl-157     [000] d....   271.333387: probe_vb2_qbuf: (vb2_core_qbuf+0x0/0x6d0 [videobuf2_common])
        v4l2-ctl-157     [000] d....   271.333581: <stack trace>
 => kprobe_trace_func
 => kprobe_dispatcher
 => kprobe_breakpoint_handler
 => call_break_hook
 => brk_handler
 => do_debug_exception
 => el1_dbg
 => el1h_64_sync_handler
 => el1h_64_sync
 => vb2_core_qbuf
 => vb2_ioctl_qbuf
 => v4l_qbuf
 => __video_do_ioctl
 => video_usercopy
 => video_ioctl2
 => v4l2_ioctl
 => __arm64_sys_ioctl
 => invoke_syscall
 => el0_svc_common.constprop.0
 => do_el0_svc
 => el0_svc
 => el0t_64_sync_handler
 => el0t_64_sync
        v4l2-ctl-157     [000] d....   271.333752: probe_vb2_streamon: (vb2_core_streamon+0x0/0x1a0 [videobuf2_common])
        v4l2-ctl-157     [000] d....   271.334073: probe_vb2_dqbuf: (vb2_core_dqbuf+0x0/0x730 [videobuf2_common])
        v4l2-ctl-157     [000] d....   271.336383: probe_vb2_qbuf: (vb2_core_qbuf+0x0/0x6d0 [videobuf2_common])
        v4l2-ctl-157     [000] d....   271.336510: probe_vb2_dqbuf: (vb2_core_dqbuf+0x0/0x730 [videobuf2_common])
        v4l2-ctl-157     [000] d....   271.533862: probe_vb2_qbuf: (vb2_core_qbuf+0x0/0x6d0 [videobuf2_common])
        v4l2-ctl-157     [000] d....   271.534053: probe_vb2_streamoff: (vb2_core_streamoff+0x0/0xd0 [videobuf2_common])
        v4l2-ctl-157     [000] d....   271.534407: probe_vb2_streamoff: (vb2_core_streamoff+0x0/0xd0 [videobuf2_common])
        v4l2-ctl-157     [000] d....   271.534994: probe_vb2_reqbufs: (vb2_core_reqbufs+0x0/0x550 [videobuf2_common])
```

```text
札记：实际复制到的输出如下
 grep -E 'probe_vb2|<stack trace>|=>|vb2_|v4l_|video_ioctl2|v4l2_ioctl|__arm64_sys_ioctl' trace | head -220
#                                _-----=> irqs-off/BH-disabled
#                               / _----=> need-resched
#                              | / _---=> hardirq/softirq
#                              || / _--=> preempt-depth
#                              ||| / _-=> migrate-disable
        v4l2-ctl-167     [000] d....  2530.986591: probe_vb2_reqbufs: (vb2_core_reqbufs+0x0/0x550 [videobuf2_common])
        v4l2-ctl-167     [000] d....  2530.988210: probe_vb2_qbuf: (vb2_core_qbuf+0x0/0x6d0 [videobuf2_common])
        v4l2-ctl-167     [000] d....  2530.989149: <stack trace>
 => kprobe_trace_func
 => kprobe_dispatcher
 => kprobe_breakpoint_handler
 => call_break_hook
 => brk_handler
 => do_debug_exception
 => el1_dbg
 => el1h_64_sync_handler
 => el1h_64_sync
 => vb2_core_qbuf
 => vb2_ioctl_qbuf
 => v4l_qbuf
 => __video_do_ioctl
 => video_usercopy
 => video_ioctl2
 => v4l2_ioctl
 => __arm64_sys_ioctl
 => invoke_syscall
 => el0_svc_common.constprop.0
 => do_el0_svc
 => el0_svc
 => el0t_64_sync_handler
 => el0t_64_sync
        v4l2-ctl-167     [000] d....  2530.989551: probe_vb2_qbuf: (vb2_core_qbuf+0x0/0x6d0 [videobuf2_common])
        v4l2-ctl-167     [000] d....  2530.989557: <stack trace>
 => kprobe_trace_func
 => kprobe_dispatcher
 => kprobe_breakpoint_handler
 => call_break_hook
 => brk_handler
 => do_debug_exception
 => el1_dbg
 => el1h_64_sync_handler
 => el1h_64_sync
 => vb2_core_qbuf
 => vb2_ioctl_qbuf
 => v4l_qbuf
 => __video_do_ioctl
 => video_usercopy
 => video_ioctl2
 => v4l2_ioctl
 => __arm64_sys_ioctl
 => invoke_syscall
 => el0_svc_common.constprop.0
 => do_el0_svc
 => el0_svc
 => el0t_64_sync_handler
 => el0t_64_sync
        v4l2-ctl-167     [000] d....  2530.989573: probe_vb2_qbuf: (vb2_core_qbuf+0x0/0x6d0 [videobuf2_common])
        v4l2-ctl-167     [000] d....  2530.989576: <stack trace>
 => kprobe_trace_func
 => kprobe_dispatcher
 => kprobe_breakpoint_handler
 => call_break_hook
 => brk_handler
 => do_debug_exception
 => el1_dbg
 => el1h_64_sync_handler
 => el1h_64_sync
 => vb2_core_qbuf
 => vb2_ioctl_qbuf
 => v4l_qbuf
 => __video_do_ioctl
 => video_usercopy
 => video_ioctl2
 => v4l2_ioctl
 => __arm64_sys_ioctl
 => invoke_syscall
 => el0_svc_common.constprop.0
 => do_el0_svc
 => el0_svc
 => el0t_64_sync_handler
 => el0t_64_sync
        v4l2-ctl-167     [000] d....  2530.989587: probe_vb2_qbuf: (vb2_core_qbuf+0x0/0x6d0 [videobuf2_common])
        v4l2-ctl-167     [000] d....  2530.989589: <stack trace>
 => kprobe_trace_func
 => kprobe_dispatcher
 => kprobe_breakpoint_handler
 => call_break_hook
 => brk_handler
 => do_debug_exception
 => el1_dbg
 => el1h_64_sync_handler
 => el1h_64_sync
 => vb2_core_qbuf
 => vb2_ioctl_qbuf
 => v4l_qbuf
 => __video_do_ioctl
 => video_usercopy
 => video_ioctl2
 => v4l2_ioctl
 => __arm64_sys_ioctl
 => invoke_syscall
 => el0_svc_common.constprop.0
 => do_el0_svc
 => el0_svc
 => el0t_64_sync_handler
 => el0t_64_sync
        v4l2-ctl-167     [000] d....  2530.989667: probe_vb2_streamon: (vb2_core_streamon+0x0/0x1a0 [videobuf2_common])
        v4l2-ctl-167     [000] d....  2530.989989: probe_vb2_dqbuf: (vb2_core_dqbuf+0x0/0x730 [videobuf2_common])
        v4l2-ctl-167     [000] d....  2530.992129: probe_vb2_qbuf: (vb2_core_qbuf+0x0/0x6d0 [videobuf2_common])
        v4l2-ctl-167     [000] d....  2530.992136: <stack trace>
 => kprobe_trace_func
 => kprobe_dispatcher
 => kprobe_breakpoint_handler
 => call_break_hook
 => brk_handler
 => do_debug_exception
 => el1_dbg
 => el1h_64_sync_handler
 => el1h_64_sync
 => vb2_core_qbuf
 => vb2_ioctl_qbuf
 => v4l_qbuf
 => __video_do_ioctl
 => video_usercopy
 => video_ioctl2
 => v4l2_ioctl
 => __arm64_sys_ioctl
 => invoke_syscall
 => el0_svc_common.constprop.0
 => do_el0_svc
 => el0_svc
 => el0t_64_sync_handler
 => el0t_64_sync
        v4l2-ctl-167     [000] d....  2530.992267: probe_vb2_dqbuf: (vb2_core_dqbuf+0x0/0x730 [videobuf2_common])
        v4l2-ctl-167     [000] d....  2531.191280: probe_vb2_qbuf: (vb2_core_qbuf+0x0/0x6d0 [videobuf2_common])
        v4l2-ctl-167     [000] d....  2531.191293: <stack trace>
 => kprobe_trace_func
 => kprobe_dispatcher
 => kprobe_breakpoint_handler
 => call_break_hook
 => brk_handler
 => do_debug_exception
 => el1_dbg
 => el1h_64_sync_handler
 => el1h_64_sync
 => vb2_core_qbuf
 => vb2_ioctl_qbuf
 => v4l_qbuf
 => __video_do_ioctl
 => video_usercopy
 => video_ioctl2
 => v4l2_ioctl
 => __arm64_sys_ioctl
 => invoke_syscall
 => el0_svc_common.constprop.0
 => do_el0_svc
 => el0_svc
 => el0t_64_sync_handler
 => el0t_64_sync
        v4l2-ctl-167     [000] d....  2531.191452: probe_vb2_streamoff: (vb2_core_streamoff+0x0/0xd0 [videobuf2_common])
        v4l2-ctl-167     [000] d....  2531.191812: probe_vb2_streamoff: (vb2_core_streamoff+0x0/0xd0 [videobuf2_common])
        v4l2-ctl-167     [000] d....  2531.192479: probe_vb2_reqbufs: (vb2_core_reqbufs+0x0/0x550 [videobuf2_common])

```

### 3.3 输出含义

这段栈把 V4L2 core 和 VB2 串起来了：

```text
userspace ioctl(VIDIOC_QBUF)
  -> __arm64_sys_ioctl
      -> v4l2_ioctl
          -> video_ioctl2
              -> video_usercopy
                  -> __video_do_ioctl
                      -> v4l_qbuf
                          -> vb2_ioctl_qbuf
                              -> vb2_core_qbuf
```

一次 2 帧抓取的核心 VB2 顺序是：

```text
REQBUFS    -> vb2_core_reqbufs
QBUF x4    -> vb2_core_qbuf
STREAMON   -> vb2_core_streamon
DQBUF      -> vb2_core_dqbuf
QBUF       -> vb2_core_qbuf
DQBUF      -> vb2_core_dqbuf
QBUF       -> vb2_core_qbuf
STREAMOFF  -> vb2_core_streamoff
REQBUFS 0  -> vb2_core_reqbufs
```

### 3.4 清理 kprobe

切换到 tracepoint 实验前要清理动态 kprobe，否则输出会混在一起。

虚拟机内执行：

```sh
cd /sys/kernel/tracing
echo 0 > tracing_on
for e in events/kprobes/*/enable; do [ -e "$e" ] && echo 0 > "$e"; done
[ -e events/kprobes/probe_vb2_qbuf/trigger ] && echo '!stacktrace' > events/kprobes/probe_vb2_qbuf/trigger 2>/dev/null || true
echo > kprobe_events
cat kprobe_events
```

实际输出为空，表示 kprobe 已清理。

### 3.5 学到什么

V4L2 core 负责把 ioctl 分发到具体 operation，VB2 负责 buffer 状态机。以后读 camera 驱动时，要重点找驱动如何填充：

- `vb2_queue`
- `queue_setup`
- `buf_queue`
- `start_streaming`
- `stop_streaming`
- buffer done 路径，例如 `vb2_buffer_done()`

## 4. 观察 V4L2/VB2 tracepoint 事件流

相比 function tracer，tracepoint 更接近业务时序。它不会只告诉你“调用了哪个函数”，还会告诉你哪个 buffer 入队、哪个 buffer done、哪个 buffer 出队。

### 4.1 查看可用事件

虚拟机内执行：

```sh
cd /sys/kernel/tracing
find events -maxdepth 2 -type d | grep -E 'events/(v4l2|vb2)' | sort
find events -path '*/v4l2*' -maxdepth 3 -type f -name format | sed 's#/format##' | head -80
find events -path '*/vb2*' -maxdepth 3 -type f -name format | sed 's#/format##' | head -80
```

实际输出：

```text
events/v4l2
events/v4l2/v4l2_dqbuf
events/v4l2/v4l2_qbuf
events/v4l2/vb2_v4l2_buf_done
events/v4l2/vb2_v4l2_buf_queue
events/v4l2/vb2_v4l2_dqbuf
events/v4l2/vb2_v4l2_qbuf
events/vb2
events/vb2/vb2_buf_done
events/vb2/vb2_buf_queue
events/vb2/vb2_dqbuf
events/vb2/vb2_qbuf

----------------------

events/v4l2/v4l2_dqbuf
events/v4l2/v4l2_qbuf
events/v4l2/vb2_v4l2_buf_done
events/v4l2/vb2_v4l2_buf_queue
events/v4l2/vb2_v4l2_dqbuf
events/v4l2/vb2_v4l2_qbuf

----------------------

events/vb2/vb2_buf_done
events/vb2/vb2_buf_queue
events/vb2/vb2_dqbuf
events/vb2/vb2_qbuf
events/v4l2/vb2_v4l2_buf_done
events/v4l2/vb2_v4l2_buf_queue
events/v4l2/vb2_v4l2_dqbuf
events/v4l2/vb2_v4l2_qbuf
```

### 4.2 启用事件并抓 3 帧

虚拟机内执行：

```sh
cd /sys/kernel/tracing
echo 0 > tracing_on
echo nop > current_tracer
echo > trace
for e in events/v4l2/*/enable events/vb2/*/enable; do [ -e "$e" ] && echo 0 > "$e"; done
for e in events/v4l2/*/enable events/vb2/*/enable; do [ -e "$e" ] && echo 1 > "$e"; done
echo 1 > tracing_on

v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=3 --stream-to=/tmp/v4l2-events-clean.raw

echo 0 > tracing_on
cat trace | grep -E 'v4l2_|vb2_' | head -140
for e in events/v4l2/*/enable events/vb2/*/enable; do [ -e "$e" ] && echo 0 > "$e"; done
```

实际输出摘录：

```text
<<<
        v4l2-ctl-177     [000] .....   423.122686: vb2_qbuf: owner = 00000000be1b8c83, queued = 1, owned_by_drv = 0, index = 0, type = 1, bytesused = 614400, timestamp = 0
        v4l2-ctl-177     [000] .....   423.122704: v4l2_qbuf: minor = 0, index = 0, type = VIDEO_CAPTURE, bytesused = 614400, flags = MAPPED|QUEUED|TIMESTAMP_UNKNOWN|TIMESTAMP_MONOTONIC, field = ANY, timestamp = 0, ... sequence = 0
        v4l2-ctl-177     [000] .....   423.122715: vb2_qbuf: owner = 00000000be1b8c83, queued = 2, owned_by_drv = 0, index = 1, type = 1, bytesused = 614400, timestamp = 0
        v4l2-ctl-177     [000] .....   423.122716: v4l2_qbuf: minor = 0, index = 1, type = VIDEO_CAPTURE, bytesused = 614400, flags = MAPPED|QUEUED|TIMESTAMP_UNKNOWN|TIMESTAMP_MONOTONIC, field = ANY, timestamp = 0, ... sequence = 0
        v4l2-ctl-177     [000] .....   423.122724: vb2_qbuf: owner = 00000000be1b8c83, queued = 3, owned_by_drv = 0, index = 2, type = 1, bytesused = 614400, timestamp = 0
        v4l2-ctl-177     [000] .....   423.122732: vb2_qbuf: owner = 00000000be1b8c83, queued = 4, owned_by_drv = 0, index = 3, type = 1, bytesused = 614400, timestamp = 0
        v4l2-ctl-177     [000] .....   423.122774: vb2_buf_queue: owner = 00000000be1b8c83, queued = 4, owned_by_drv = 1, index = 0, type = 1, bytesused = 614400, timestamp = 0
        v4l2-ctl-177     [000] .....   423.122776: vb2_buf_queue: owner = 00000000be1b8c83, queued = 4, owned_by_drv = 2, index = 1, type = 1, bytesused = 614400, timestamp = 0
        v4l2-ctl-177     [000] .....   423.122777: vb2_buf_queue: owner = 00000000be1b8c83, queued = 4, owned_by_drv = 3, index = 2, type = 1, bytesused = 614400, timestamp = 0
        v4l2-ctl-177     [000] .....   423.122778: vb2_buf_queue: owner = 00000000be1b8c83, queued = 4, owned_by_drv = 4, index = 3, type = 1, bytesused = 614400, timestamp = 0
 vivid-000-vid-c-178     [000] .....   423.123440: vb2_buf_done: owner = 00000000be1b8c83, queued = 4, owned_by_drv = 3, index = 0, type = 1, bytesused = 614400, timestamp = 0
        v4l2-ctl-177     [000] .....   423.123616: vb2_dqbuf: owner = 00000000be1b8c83, queued = 3, owned_by_drv = 3, index = 0, type = 1, bytesused = 614400, timestamp = 423291722320
        v4l2-ctl-177     [000] .....   423.123622: v4l2_dqbuf: minor = 0, index = 0, type = VIDEO_CAPTURE, bytesused = 614400, flags = MAPPED|TIMESTAMP_UNKNOWN|TIMESTAMP_MONOTONIC, field = NONE, timestamp = 423291722000, ... sequence = 0
        v4l2-ctl-177     [000] .....   423.125453: vb2_qbuf: owner = 00000000be1b8c83, queued = 4, owned_by_drv = 3, index = 0, type = 1, bytesused = 614400, timestamp = 0
        v4l2-ctl-177     [000] .....   423.125456: vb2_buf_queue: owner = 00000000be1b8c83, queued = 4, owned_by_drv = 4, index = 0, type = 1, bytesused = 614400, timestamp = 0
 vivid-000-vid-c-178     [000] .....   423.315857: vb2_buf_done: owner = 00000000be1b8c83, queued = 4, owned_by_drv = 3, index = 1, type = 1, bytesused = 614400, timestamp = 0
        v4l2-ctl-177     [000] .....   423.315937: vb2_dqbuf: owner = 00000000be1b8c83, queued = 3, owned_by_drv = 3, index = 1, type = 1, bytesused = 614400, timestamp = 423484122592
        v4l2-ctl-177     [000] .....   423.315944: v4l2_dqbuf: minor = 0, index = 1, type = VIDEO_CAPTURE, bytesused = 614400, flags = MAPPED|TIMESTAMP_UNKNOWN|TIMESTAMP_MONOTONIC, field = NONE, timestamp = 423484122000, ... sequence = 1
        v4l2-ctl-177     [000] .....   423.318600: vb2_qbuf: owner = 00000000be1b8c83, queued = 4, owned_by_drv = 3, index = 1, type = 1, bytesused = 614400, timestamp = 0
 vivid-000-vid-c-178     [000] .....   423.519888: vb2_buf_done: owner = 00000000be1b8c83, queued = 4, owned_by_drv = 3, index = 2, type = 1, bytesused = 614400, timestamp = 0
        v4l2-ctl-177     [000] .....   423.519972: vb2_dqbuf: owner = 00000000be1b8c83, queued = 3, owned_by_drv = 3, index = 2, type = 1, bytesused = 614400, timestamp = 423688162768
        v4l2-ctl-177     [000] .....   423.519979: v4l2_dqbuf: minor = 0, index = 2, type = VIDEO_CAPTURE, bytesused = 614400, flags = MAPPED|TIMESTAMP_UNKNOWN|TIMESTAMP_MONOTONIC, field = NONE, timestamp = 423688162000, ... sequence = 2
        v4l2-ctl-177     [000] .....   423.522111: vb2_buf_done: owner = 00000000be1b8c83, queued = 4, owned_by_drv = 3, index = 3, type = 1, bytesused = 614400, timestamp = 0
        v4l2-ctl-177     [000] .....   423.522117: vb2_buf_done: owner = 00000000be1b8c83, queued = 4, owned_by_drv = 2, index = 0, type = 1, bytesused = 614400, timestamp = 0
        v4l2-ctl-177     [000] .....   423.522122: vb2_buf_done: owner = 00000000be1b8c83, queued = 4, owned_by_drv = 1, index = 1, type = 1, bytesused = 614400, timestamp = 0
        v4l2-ctl-177     [000] .....   423.522126: vb2_buf_done: owner = 00000000be1b8c83, queued = 4, owned_by_drv = 0, index = 2, type = 1, bytesused = 614400, timestamp = 0
```

### 4.3 输出含义

这段事件流比函数调用更接近真实业务：

```text
v4l2-ctl          vb2_qbuf / v4l2_qbuf      用户态把 4 个 buffer 入队
v4l2-ctl          vb2_buf_queue             STREAMON 后 buffer 交给驱动
vivid-000-vid-c   vb2_buf_done              vivid 内核线程生成一帧并完成 buffer
v4l2-ctl          vb2_dqbuf / v4l2_dqbuf    用户态 DQBUF 取走完成帧
v4l2-ctl          vb2_qbuf                  用户态把该 buffer 重新入队
```

`vivid-000-vid-c` 是 vivid 的视频采集线程。真实硬件平台上，对应的完成路径可能来自中断 handler、tasklet、workqueue 或 kthread，最终也会走到 `vb2_buffer_done()` 一类逻辑。

### 4.4 学到什么

tracepoint 适合回答：

- 哪个 buffer index 入队？
- 哪个线程完成了 buffer？
- buffer done 和用户态 `DQBUF` 的时间差是多少？
- 帧序号是否连续？
- streamoff 时是否还有未完成 buffer 被 flush？

这是以后分析真实 camera pipeline 最重要的视角。

## 5. 用 perf 做热点分析

### 5.1 perf record：写 raw 文件版本

虚拟机内执行：

```sh
cd /tmp
rm -f perf.data perf_report.txt perf.raw
perf record -g -o /tmp/perf.data -- \
  v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=20 --stream-to=/tmp/perf.raw
perf report --stdio -i /tmp/perf.data --sort comm,dso,symbol | head -120 > /tmp/perf_report.txt
cat /tmp/perf_report.txt
ls -l /tmp/perf.data /tmp/perf.raw
wc -c /tmp/perf.raw
```

实际输出摘录：

```text
perf: interrupt took too long (7905 > 2500), lowering kernel.perf_event_max_sample_rate to 25250
perf: interrupt took too long (10030 > 9881), lowering kernel.perf_event_max_sample_rate to 19750
perf: interrupt took too long (12566 > 12537), lowering kernel.perf_event_max_sample_rate to 15750
perf: interrupt took too long (15718 > 15707), lowering kernel.perf_event_max_sample_rate to 12500
<<<perf: interrupt took too long (19705 > 19647), lowering kernel.perf_event_max_sample_rate to 10000
<<<< 5.01 fps
<<<<< 5.01 fps
perf: interrupt took too long (24659 > 24631), lowering kernel.perf_event_max_sample_rate to 8000
<<<<< 5.00 fps
<<<
[ perf record: Woken up 1 times to write data ]
[ perf record: Captured and wrote 0.080 MB /tmp/perf.data (312 samples) ]

# Samples: 312  of event 'cycles'
# Event count (approx.): 73287417
#
# Children      Self  Command   Shared Object          Symbol
    85.37%     0.00%  v4l2-ctl  v4l2-ctl               [.] 0x00000055877be1b0
            |
            ---0x55877be1b0
               __libc_start_main
               |
               |--84.71%--0x7fa5f623a0
               |          |
               |          |--78.33%--0x55877bdc34
               |          |          0x55877d6920
               |          |          |
               |          |          |--70.28%--0x55877d48f4
               |          |          |          |
               |          |          |          |--64.24%--0x55877d3f04
               |          |          |          |          0x55877d0e38
               |          |          |          |          _IO_fwrite
               |          |          |          |          _IO_file_xsputn
               |          |          |          |          |
               |          |          |          |          |--59.23%--0x7fa5fa1bdc
               |          |          |          |          |          _IO_file_write
               |          |          |          |          |          write
               |          |          |          |          |          |
               |          |          |          |          |           --58.62%--el0t_64_sync
               |          |          |          |          |                     __arm64_sys_write
               |          |          |          |          |                     ksys_write
               |          |          |          |          |                     vfs_write
               |          |          |          |          |                     generic_file_write_iter
               |          |          |          |          |                     __generic_file_write_iter
               |          |          |          |          |                     generic_perform_write
               |          |          |          |          |                     |
               |          |          |          |          |                      --57.95%--__generic_file_write_iter
               |          |          |          |          |                                |
               |          |          |          |          |                                 --57.21%--generic_perform_write
               |          |          |          |          |                                           |
               |          |          |          |          |                                           |--46.73%--shmem_write_begin
               |          |          |          |          |                                           |--5.38%--__arch_copy_from_user

-rw-------    1 root     root         86640 Jun 12 17:21 /tmp/perf.data
-rw-r--r--    1 root     root      12288000 Jun 12 17:21 /tmp/perf.raw
12288000 /tmp/perf.raw
```

### 5.2 输出含义

这个 perf 结果说明：如果把每帧都写到 `/tmp/perf.raw`，热点主要变成文件写入路径：

```text
v4l2-ctl
  -> _IO_fwrite
      -> write
          -> __arm64_sys_write
              -> vfs_write
                  -> generic_perform_write
                      -> shmem_write_begin
                      -> __arch_copy_from_user
```

这不是坏结果，而是一个重要提醒：性能分析必须考虑观测对象本身。你以为自己在分析 camera，实际上可能在分析“把帧写到文件”的成本。

### 5.3 perf record：不写 raw 文件版本

虚拟机内执行：

```sh
cd /tmp
rm -f perf_nofile.data perf_nofile_report.txt
perf record -g -o /tmp/perf_nofile.data -- \
  v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=20
perf report --stdio -i /tmp/perf_nofile.data --sort comm,dso,symbol | head -140 > /tmp/perf_nofile_report.txt
cat /tmp/perf_nofile_report.txt
ls -l /tmp/perf_nofile.data
```

实际输出摘录：

```text
<<<<<<< 5.00 fps
<<<<< 5.00 fps
<<<<< 5.00 fps
<<<
[ perf record: Woken up 1 times to write data ]
[ perf record: Captured and wrote 0.028 MB /tmp/perf_nofile.data (144 samples) ]

# Samples: 144  of event 'cycles'
# Event count (approx.): 28412245
#
# Children      Self  Command   Shared Object           Symbol
    62.92%     0.00%  v4l2-ctl  v4l2-ctl                [.] 0x000000556e1ac1b0
            |
            ---0x556e1ac1b0
               __libc_start_main
               |
               |--60.45%--0x7fa0eb63a0
               |          |
               |          |--44.01%--0x556e1abc34
               |          |          |
               |          |          |--43.18%--0x556e1c4920
               |          |          |          |
               |          |          |          |--23.16%--0x556e1c28f4
               |          |          |          |          |
               |          |          |          |          |--9.85%--0x556e1c2040
               |          |          |          |          |          _IO_file_overflow
               |          |          |          |          |          _IO_do_write
               |          |          |          |          |          _IO_file_write
               |          |          |          |          |          write
               |          |          |          |          |
               |          |          |          |          |--7.12%--0x556e1c1e00
               |          |          |          |          |          ioctl
               |          |          |          |          |          |
               |          |          |          |          |           --3.56%--el0t_64_sync
               |          |          |          |          |                     __arm64_sys_ioctl
               |          |          |          |          |                     v4l2_ioctl
               |          |          |          |          |                     video_ioctl2
               |          |          |          |          |                     video_usercopy
               |          |          |          |          |                     |
               |          |          |          |          |                     |--1.77%--__video_do_ioctl
               |          |          |          |          |                     |          v4l_dqbuf
               |          |          |          |          |                     |          vb2_ioctl_dqbuf
               |          |          |          |          |                     |          vb2_dqbuf
               |          |          |          |          |                     |          vb2_core_dqbuf
               |          |          |          |          |
               |          |          |          |          |--3.51%--0x556e1c1f8c
               |          |          |          |          |          ioctl
               |          |          |          |          |          |
               |          |          |          |          |           --1.78%--el0t_64_sync
               |          |          |          |          |                     __arm64_sys_ioctl
               |          |          |          |          |                     v4l2_ioctl
               |          |          |          |          |                     video_ioctl2
               |          |          |          |          |                     video_usercopy
               |          |          |          |          |                     __video_do_ioctl
               |          |          |          |          |                     v4l_qbuf
               |          |          |          |          |                     vb2_ioctl_qbuf
               |          |          |          |          |                     vb2_qbuf
               |          |          |          |          |                     vb2_core_qbuf
               |          |          |          |          |                     __enqueue_in_driver
               |          |          |          |
               |          |          |          |--8.11%--0x556e1c2800
               |          |          |          |          |
               |          |          |          |          |--4.79%--0x556e1bdc60
               |          |          |          |          |          ioctl
               |          |          |          |          |          |
               |          |          |          |          |           --3.98%--el0t_64_sync
               |          |          |          |          |                     __arm64_sys_ioctl
               |          |          |          |          |                     v4l2_ioctl
               |          |          |          |          |                     video_ioctl2
               |          |          |          |          |                     video_usercopy
               |          |          |          |          |                     __video_do_ioctl
               |          |          |          |          |                     v4l_reqbufs
               |          |          |          |          |                     vidioc_reqbufs
               |          |          |          |          |                     vb2_ioctl_reqbufs
               |          |          |          |          |                     vb2_core_reqbufs
               |          |          |          |          |                     __vb2_queue_free

-rw-------    1 root     root         32824 Jun 12 17:22 /tmp/perf_nofile.data
```

### 5.4 输出含义

不写 raw 文件后，perf 里能看到 V4L2 ioctl 路径：

```text
ioctl
  -> __arm64_sys_ioctl
      -> v4l2_ioctl
          -> video_ioctl2
              -> video_usercopy
                  -> __video_do_ioctl
                      -> v4l_dqbuf
                          -> vb2_ioctl_dqbuf
                              -> vb2_dqbuf
                                  -> vb2_core_dqbuf
```

也能看到：

```text
v4l_qbuf -> vb2_ioctl_qbuf -> vb2_qbuf -> vb2_core_qbuf -> __enqueue_in_driver
v4l_reqbufs -> vb2_ioctl_reqbufs -> vb2_core_reqbufs -> __vb2_queue_free
```

终端输出本身仍有 `write` 成本，因为 `v4l2-ctl` 会打印 `<` 和 fps。真实分析时可以降低日志输出，或者让 workload 更接近目标场景。

### 5.5 学到什么

perf 的价值不是“列出函数名”，而是回答：

- 时间主要花在文件写入、用户态处理、ioctl、驱动，还是调度等待？
- 调用栈里有没有 `copy_to_user`、`copy_from_user`、内存分配、cache 操作？
- 观测方式是否改变了热点？

## 6. 生成火焰图

当前 VM 已经能用 `perf script` 导出采样栈，这是生成火焰图的输入。

虚拟机内执行：

```sh
perf script -i /tmp/perf_nofile.data | head -80 > /tmp/perf_script_head.txt
cat /tmp/perf_script_head.txt
```

实际输出摘录：

```text
perf-exec   194   530.854819:          1 cycles:
        ffffffc0081f4378 arch_local_irq_restore+0x8 ([kernel.kallsyms])
        ffffffc008204e1c perf_event_exec+0x1ac ([kernel.kallsyms])
        ffffffc0082cc42c begin_new_exec+0x73c ([kernel.kallsyms])
        ffffffc008334cbc load_elf_binary+0x2fc ([kernel.kallsyms])
        ffffffc0082cb0e8 bprm_execve+0x278 ([kernel.kallsyms])
        ffffffc0082cb8e4 do_execveat_common.isra.0+0x1a4 ([kernel.kallsyms])
        ffffffc0082cc988 __arm64_sys_execve+0x48 ([kernel.kallsyms])
        ffffffc008028c7c invoke_syscall+0x5c ([kernel.kallsyms])
        ffffffc008028e54 el0_svc_common.constprop.0+0x104 ([kernel.kallsyms])
        ffffffc008028eb4 do_el0_svc+0x34 ([kernel.kallsyms])
        ffffffc00895ad10 el0_svc+0x30 ([kernel.kallsyms])
        ffffffc00895b194 el0t_64_sync_handler+0xf4 ([kernel.kallsyms])
        ffffffc008011548 el0t_64_sync+0x18c ([kernel.kallsyms])
              7fb2a1998c [unknown] ([unknown])

perf-exec   194   530.854907:          1 cycles:
        ffffffc0081f4378 arch_local_irq_restore+0x8 ([kernel.kallsyms])
        ffffffc008204e1c perf_event_exec+0x1ac ([kernel.kallsyms])
        ffffffc0082cc42c begin_new_exec+0x73c ([kernel.kallsyms])
        ffffffc008334cbc load_elf_binary+0x2fc ([kernel.kallsyms])
        ...
```

完整导出命令：

```sh
perf script -i /tmp/perf_nofile.data > /tmp/perf.script
```

然后可以把 `/tmp/perf.script` 拷到宿主机，用 FlameGraph 工具生成 SVG：

```bash
stackcollapse-perf.pl perf.script > out.folded
flamegraph.pl out.folded > v4l2.svg
```

火焰图的读法：

- 横向宽度表示采样占比，不是调用先后顺序。
- 宽的栈表示热点。
- 如果 `_IO_fwrite/write/vfs_write` 很宽，说明你主要在分析写文件。
- 如果 `vb2_core_dqbuf` 或调度相关栈很宽，要进一步结合 tracepoint 和 sched 事件分析等待原因。

## 7. 观察调度与延迟

很多 camera 问题不是算法慢，而是线程等待帧、被抢占或没有及时被唤醒。`vivid` 的 5 fps 输出很适合观察这种行为。

### 7.1 用 ftrace sched 事件

虚拟机内执行：

```sh
cd /sys/kernel/tracing
echo 0 > tracing_on
echo nop > current_tracer
echo > trace
for e in events/sched/sched_switch/enable events/sched/sched_wakeup/enable events/sched/sched_waking/enable; do echo 1 > "$e"; done
echo 1 > tracing_on

v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=3 --stream-to=/tmp/sched.raw

echo 0 > tracing_on
grep -E 'v4l2-ctl|vivid-000-vid-c|sched_switch|sched_wakeup|sched_waking' trace | head -160
for e in events/sched/sched_switch/enable events/sched/sched_wakeup/enable events/sched/sched_waking/enable; do echo 0 > "$e"; done
```

实际输出摘录：

```text
<<<
              sh-108     [000] d....   594.133606: sched_switch: prev_comm=sh prev_pid=108 prev_prio=120 prev_state=S ==> next_comm=sh next_pid=204 next_prio=120
        v4l2-ctl-204     [000] d....   594.147389: sched_switch: prev_comm=v4l2-ctl prev_pid=204 prev_prio=120 prev_state=D ==> next_comm=kthreadd next_pid=2 next_prio=120
        kthreadd-2       [000] d....   594.147665: sched_switch: prev_comm=rcu_sched prev_pid=14 prev_prio=120 prev_state=I ==> next_comm=kthreadd next_pid=205 next_prio=120
 vivid-000-vid-c-205     [000] d....   594.147689: sched_waking: comm=v4l2-ctl pid=204 prio=120 target_cpu=000
 vivid-000-vid-c-205     [000] dN...   594.147694: sched_wakeup: comm=v4l2-ctl pid=204 prio=120 target_cpu=000
 vivid-000-vid-c-205     [000] d....   594.147701: sched_switch: prev_comm=kthreadd prev_pid=205 prev_prio=120 prev_state=D ==> next_comm=v4l2-ctl next_pid=204 next_prio=120
        v4l2-ctl-204     [000] d....   594.147718: sched_waking: comm=vivid-000-vid-c pid=205 prio=120 target_cpu=000
        v4l2-ctl-204     [000] d....   594.147721: sched_wakeup: comm=vivid-000-vid-c pid=205 prio=120 target_cpu=000
        v4l2-ctl-204     [000] d....   594.147799: sched_switch: prev_comm=v4l2-ctl prev_pid=204 prev_prio=120 prev_state=S ==> next_comm=vivid-000-vid-c next_pid=205 next_prio=120
 vivid-000-vid-c-205     [000] d....   594.148118: sched_waking: comm=v4l2-ctl pid=204 prio=120 target_cpu=000
 vivid-000-vid-c-205     [000] dN...   594.148123: sched_wakeup: comm=v4l2-ctl pid=204 prio=120 target_cpu=000
 vivid-000-vid-c-205     [000] d....   594.148132: sched_switch: prev_comm=vivid-000-vid-c prev_pid=205 prev_prio=120 prev_state=R ==> next_comm=v4l2-ctl next_pid=204 next_prio=120
        v4l2-ctl-204     [000] d....   594.150014: sched_switch: prev_comm=v4l2-ctl prev_pid=204 prev_prio=120 prev_state=S ==> next_comm=vivid-000-vid-c next_pid=205 next_prio=120
 vivid-000-vid-c-205     [000] d....   594.347858: sched_waking: comm=v4l2-ctl pid=204 prio=120 target_cpu=000
 vivid-000-vid-c-205     [000] dN...   594.347894: sched_wakeup: comm=v4l2-ctl pid=204 prio=120 target_cpu=000
 vivid-000-vid-c-205     [000] d....   594.347912: sched_switch: prev_comm=vivid-000-vid-c prev_pid=205 prev_prio=120 prev_state=R ==> next_comm=v4l2-ctl next_pid=204 next_prio=120
        v4l2-ctl-204     [000] d....   594.349940: sched_switch: prev_comm=v4l2-ctl prev_pid=204 prev_prio=120 prev_state=S ==> next_comm=vivid-000-vid-c next_pid=205 next_prio=120
 vivid-000-vid-c-205     [000] d....   594.547927: sched_waking: comm=v4l2-ctl pid=204 prio=120 target_cpu=000
 vivid-000-vid-c-205     [000] dN...   594.547965: sched_wakeup: comm=v4l2-ctl pid=204 prio=120 target_cpu=000
 vivid-000-vid-c-205     [000] d....   594.547983: sched_switch: prev_comm=vivid-000-vid-c prev_pid=205 prev_prio=120 prev_state=R ==> next_comm=v4l2-ctl next_pid=204 next_prio=120
        v4l2-ctl-204     [000] d....   594.549969: sched_switch: prev_comm=v4l2-ctl prev_pid=204 prev_prio=120 prev_state=D ==> next_comm=vivid-000-vid-c next_pid=205 next_prio=120
 vivid-000-vid-c-205     [000] d....   594.550013: sched_waking: comm=v4l2-ctl pid=204 prio=120 target_cpu=000
 vivid-000-vid-c-205     [000] dN...   594.550020: sched_wakeup: comm=v4l2-ctl pid=204 prio=120 target_cpu=000
 vivid-000-vid-c-205     [000] d....   594.550138: sched_switch: prev_comm=vivid-000-vid-c prev_pid=205 prev_prio=120 prev_state=X ==> next_comm=v4l2-ctl next_pid=204 next_prio=120
```

### 7.2 输出含义

关键线程：

- `v4l2-ctl-204`：用户态抓帧进程。
- `vivid-000-vid-c-205`：vivid 的 capture 线程。

关键现象：

- `v4l2-ctl` 进入 `S` 或 `D` 状态，说明它在等待。
- `vivid-000-vid-c` 运行并唤醒 `v4l2-ctl`。
- 594.347 到 594.547 之间约 0.2 秒，对应 5 fps 的帧间隔。

因此 `DQBUF` 慢的直接原因是：用户态睡眠等待下一帧，vivid 线程在帧完成后唤醒它。

### 7.3 用 trace-cmd 录制 sched 事件

虚拟机内执行：

- [ ] ```sh
  cd /tmp
  rm -f trace.dat trace_report.txt
  trace-cmd record -o /tmp/trace.dat \
    -e sched:sched_switch -e sched:sched_wakeup -- \
    v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=2 --stream-to=/tmp/tracecmd.raw
  
  trace-cmd report /tmp/trace.dat | grep -E 'v4l2-ctl|vivid-000-vid-c|sched_switch|sched_wakeup' | head -80 > /tmp/trace_report.txt
  cat /tmp/trace_report.txt
  ls -l /tmp/trace.dat /tmp/tracecmd.raw
  ```


实际输出摘录：

```text
<<
CPU0 data recorded at offset=0x2c9000
    4096 bytes in size
  could not load plugin '/usr/lib64/traceevent/plugins/plugin_python_loader.so'
/usr/lib64/traceevent/plugins/plugin_python_loader.so: undefined symbol: Py_Initialize

trace-cmd: No such file or directory
  Error: expected type 4 but read 5

        v4l2-ctl-211   [000]   633.847598: sched_wakeup:         rcu_sched:14 [120]<CANT FIND FIELD success> CPU:000
        v4l2-ctl-211   [000]   633.847828: sched_switch:         v4l2-ctl:211 [120] R ==> rcu_sched:14 [120]
       rcu_sched-14    [000]   633.847877: sched_switch:         rcu_sched:14 [120] W ==> v4l2-ctl:211 [120]
        v4l2-ctl-211   [000]   633.859189: sched_switch:         v4l2-ctl:211 [120] D ==> kthreadd:2 [120]
 vivid-000-vid-c-212   [000]   633.859347: sched_wakeup:         v4l2-ctl:211 [120]<CANT FIND FIELD success> CPU:000
 vivid-000-vid-c-212   [000]   633.859371: sched_switch:         kthreadd:212 [120] D ==> v4l2-ctl:211 [120]
        v4l2-ctl-211   [000]   633.859395: sched_wakeup:         vivid-000-vid-c:212 [120]<CANT FIND FIELD success> CPU:000
        v4l2-ctl-211   [000]   633.859677: sched_switch:         v4l2-ctl:211 [120] S ==> kworker/0:2:109 [120]
       rcu_sched-14    [000]   633.859772: sched_switch:         rcu_sched:14 [120] W ==> vivid-000-vid-c:212 [120]
 vivid-000-vid-c-212   [000]   633.860093: sched_wakeup:         v4l2-ctl:211 [120]<CANT FIND FIELD success> CPU:000
 vivid-000-vid-c-212   [000]   633.860105: sched_switch:         vivid-000-vid-c:212 [120] R ==> v4l2-ctl:211 [120]
        v4l2-ctl-211   [000]   633.862360: sched_switch:         v4l2-ctl:211 [120] S ==> vivid-000-vid-c:212 [120]
 vivid-000-vid-c-212   [000]   634.059907: sched_wakeup:         v4l2-ctl:211 [120]<CANT FIND FIELD success> CPU:000
 vivid-000-vid-c-212   [000]   634.059923: sched_switch:         vivid-000-vid-c:212 [120] R ==> v4l2-ctl:211 [120]
        v4l2-ctl-211   [000]   634.062051: sched_switch:         v4l2-ctl:211 [120] D ==> vivid-000-vid-c:212 [120]
 vivid-000-vid-c-212   [000]   634.062114: sched_wakeup:         v4l2-ctl:211 [120]<CANT FIND FIELD success> CPU:000
 vivid-000-vid-c-212   [000]   634.062253: sched_switch:         vivid-000-vid-c:212 [120] Z ==> v4l2-ctl:211 [120]

-rw-r--r--    1 root     root       2924544 Jun 12 17:24 /tmp/trace.dat
-rw-r--r--    1 root     root       1228800 Jun 12 17:24 /tmp/tracecmd.raw
```

`trace-cmd report` 在当前 rootfs 里有 Python plugin 加载警告和字段解析提示，但仍然输出了 sched 事件。实际分析时，如果要长期使用 trace-cmd，建议修正 traceevent plugin 配置；短期学习可以直接读 tracefs 的 `trace` 文件。

### 7.4 学到什么

调度 trace 用来回答：

- `DQBUF` 等待期间，用户线程是否在睡眠？
- 谁唤醒了用户线程？
- 唤醒后是否马上运行，还是被其他线程抢占？
- 真实系统中帧间 jitter 是来自硬件、驱动，还是调度？

这一步开始接近真实 camera 性能调优。

## 8. 一个完整的抓帧时序实验

### 8.1 建议一次性采集的文件

虚拟机内可以按下面方式采集三类信息。

用户态 ioctl：

```sh
strace -ttT -o /tmp/ioctl.log -e trace=ioctl \
  v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=5 --stream-to=/tmp/capture.raw
```

V4L2/VB2 事件流：

```sh
cd /sys/kernel/tracing
echo 0 > tracing_on
echo nop > current_tracer
echo > trace
for e in events/v4l2/*/enable events/vb2/*/enable; do [ -e "$e" ] && echo 1 > "$e"; done
echo 1 > tracing_on
v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=5 --stream-to=/tmp/capture-trace.raw
echo 0 > tracing_on
cat trace > /tmp/v4l2_trace.log
for e in events/v4l2/*/enable events/vb2/*/enable; do [ -e "$e" ] && echo 0 > "$e"; done
```

perf 热点：

```sh
perf record -g -o /tmp/perf.data -- \
  v4l2-ctl -d /dev/video0 --stream-mmap --stream-count=20
perf report --stdio -i /tmp/perf.data > /tmp/perf_report.txt
```

你最终得到：

```text
/tmp/ioctl.log        用户态 ioctl 时序
/tmp/v4l2_trace.log   V4L2/VB2 buffer 事件流
/tmp/perf_report.txt  CPU 热点和调用栈
/tmp/perf.data        perf 原始采样数据
```

### 8.2 用本次实验回答四个问题

问题 1：一次抓帧经历哪些 ioctl？

从 `/tmp/ioctl.log` 的实际输出看：

```text
VIDIOC_QUERYCAP
VIDIOC_G_INPUT
VIDIOC_ENUMINPUT
VIDIOC_REQBUFS
VIDIOC_QUERYBUF
VIDIOC_QBUF
VIDIOC_STREAMON
VIDIOC_DQBUF
VIDIOC_QBUF
VIDIOC_STREAMOFF
VIDIOC_REQBUFS count=0
```

问题 2：这些 ioctl 在内核里对应哪些 V4L2/VB2 路径？

从 ftrace 和 kprobe 的实际输出看：

```text
__arm64_sys_ioctl
  -> v4l2_ioctl
      -> video_ioctl2
          -> video_usercopy
              -> __video_do_ioctl
                  -> v4l_qbuf / v4l_dqbuf / v4l_reqbufs
                      -> vb2_ioctl_qbuf / vb2_ioctl_dqbuf / vb2_ioctl_reqbufs
                          -> vb2_core_qbuf / vb2_core_dqbuf / vb2_core_reqbufs
```

问题 3：哪一步耗时最长？

从 strace 的实际输出看：

```text
VIDIOC_DQBUF = 0 <0.193456>
VIDIOC_DQBUF = 0 <0.193755>
```

`DQBUF` 耗时最长，因为它在等待下一帧。当前 vivid 帧率是 5 fps，理论帧间隔约 0.2 秒，和观测结果一致。

问题 4：是否存在调度延迟或内存拷贝热点？

从 sched trace 看：

```text
v4l2-ctl 进入 S/D 状态等待
vivid-000-vid-c 唤醒 v4l2-ctl
帧间隔约 0.2 秒
```

从 perf 看：

```text
写 raw 文件版本热点主要在 write/vfs_write/generic_perform_write/shmem_write_begin
不写 raw 文件版本可以看到 ioctl -> v4l2_ioctl -> vb2_core_dqbuf/qbuf/reqbufs
```

所以在本次 QEMU + vivid 实验中，长等待主要是帧率导致的 `DQBUF` 等待；如果把帧写到文件，文件写入和内存拷贝会成为明显热点。

## 9. 推荐学习路线

按照下面顺序练习，不要一开始就陷入 function_graph 的细节：

1. `v4l2-ctl + strace`

   先掌握用户态 ioctl 生命周期，尤其是 `REQBUFS/QBUF/STREAMON/DQBUF`。

2. `ftrace function`

   把用户态 ioctl 映射到 `v4l2_ioctl -> video_ioctl2 -> video_usercopy -> __video_do_ioctl`。

3. `kprobe + stacktrace`

   精准抓 `vb2_core_qbuf`、`vb2_core_dqbuf` 等关键函数，确认 V4L2 core 到 VB2 的调用栈。

4. `V4L2/VB2 tracepoint`

   从函数调用切换到 buffer 业务时序，观察 `qbuf -> buf_queue -> buf_done -> dqbuf`。

5. `perf record/report`

   学会判断热点到底在 camera 路径、文件 I/O、内存拷贝，还是用户态处理。

6. `sched_* tracepoint / trace-cmd`

   分析线程何时睡眠、何时被唤醒、是否被其他线程抢占。

7. `perf script + FlameGraph`

   把调用栈转换成时间占比视角，适合更复杂的真实系统。

## 10. 最终能力

完成本文实验后，你应该能做到：

- 看到一个 V4L2 抓帧程序，就能画出 `userspace -> ioctl -> V4L2 core -> VB2 -> driver` 的路径。
- 通过 `strace` 判断是不是 `DQBUF` 慢。
- 通过 tracepoint 判断 buffer 是否按预期入队、完成、出队。
- 通过 kprobe 找到 V4L2/VB2 的内核调用栈。
- 通过 perf 判断热点是否来自文件 I/O、内存拷贝、ioctl 处理或其他路径。
- 通过 sched 事件判断用户线程是否被及时唤醒。

这套方法迁移到真实 camera 驱动时，`vivid-000-vid-c` 会换成真实驱动的中断、workqueue 或 kthread；`/dev/video0` 后面也会多出 sensor、CSI、ISP、DMA 等 media entities。但分析方法是同一套。