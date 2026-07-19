# 基于 libcamera 的全栈开发方向建议

> 推荐项目：Raspberry Pi 5 外触发、低延迟、可追溯的智能质检相机  
> 涉及范围：硬件、固件、Device Tree、Linux Media/V4L2、libcamera
> Pipeline、IPA 算法、应用和性能测量  
> 编写日期：2026-07-19

## 1. 推荐方向

建议实现一个表面功能非常普通的相机应用：

> Raspberry Pi 5 显示实时预览，用户框选曝光区域；光电传感器检测到物体后
> 触发全局快门和补光，应用保存对应图像及完整曝光、时间戳和触发元数据。

它对用户只有几个常见功能：

1. 实时预览；
2. 框选自动曝光区域；
3. 进入等待触发状态；
4. 检测到物体时拍照；
5. 保存图像和元数据。

但要真正做到确定性、低延迟和逐帧可追溯，需要贯通：

```text
硬件电气
→ MCU/定时固件
→ Device Tree
→ Sensor kernel driver
→ V4L2 controls
→ RP1 CFE
→ libcamera controls
→ RPi PiSP Pipeline
→ mojom/IPA IPC
→ AGC/ROI 算法
→ tuning JSON
→ C++ 应用
→ tracing 和性能测量
```

这个项目适合作为掌握 libcamera 的主线工程，因为每一层的修改都围绕一个
清晰的产品需求，不是为了学习而人为制造无关改动。

## 2. 现有软件栈基础

本地工作区已经包含：

```text
~/workspace/raspi5/
├── linux       stable_20260715
├── libcamera   v0.7.1+rpt20260609
└── libcamera-doc
```

### 2.1 Linux 已有 IMX296 外触发支持

本地 IMX296 驱动已经支持外触发，但目前主要由 module parameter 或
Device Tree 固定配置：

- [`imx296.c`](../linux/drivers/media/i2c/imx296.c) 中定义全局
  `trigger_mode`；
- 驱动在 `stream_on` 时向 IMX296 写入触发模式寄存器；
- [`imx296-overlay.dts`](../linux/arch/arm/boot/dts/overlays/imx296-overlay.dts)
  提供 `sync-sink` overlay 参数；
- overlay 还提供 `always-on`，防止相机电源关闭时钳制 XTRIG 等 I/O。

这意味着当前系统能够使用外触发，但应用还不能通过 libcamera 灵活配置
触发模式，也缺少完整的 trigger/request/frame 对齐语义。

### 2.2 IMX296 外触发曝光模型

Raspberry Pi 官方文档说明：

- Global Shutter Camera 可通过板载 XTR 输入触发；
- 曝光时间等于 XTR 低电平宽度加约 `14.26µs`；
- 同一个触发信号可以连接多个相机，用于硬件同步。

参考：

- [Raspberry Pi：External Trigger on the GS Camera](https://www.raspberrypi.com/documentation/usage/camera/raspicam/raspiyuv.md)

libcamera 本地代码已经包含这个换算：

- [`cam_helper_imx296.cpp`](../libcamera/src/ipa/rpi/cam_helper/cam_helper_imx296.cpp)

其中：

```cpp
exposureLines = (exposure - 14.26us) / timePerLine;
exposure = exposureLines * timePerLine + 14.26us;
```

因此推荐方向不是重新发明外触发，而是将内核中已有的传感器能力、libcamera
的控制和元数据模型、IPA 自动曝光以及应用需求连接起来。

## 3. 产品目标

### 3.1 应用功能

最终应用应包含：

```text
实时预览
ROI 框选
Arm/Disarm
触发状态显示
单帧保存
连续触发保存
曝光/增益/延迟显示
触发丢失和错配告警
性能统计导出
```

### 3.2 每帧元数据

建议为每个保存的图像同时生成 JSON：

```json
{
  "requestSequence": 1024,
  "triggerSequence": 998,
  "triggerTimestamp": 123456789000,
  "sensorTimestamp": 123456803260,
  "requestCompleteTimestamp": 123489000000,
  "triggerPulseWidthUs": 10000,
  "reportedExposureUs": 10014,
  "analogueGain": 2.0,
  "digitalGain": 1.0,
  "frameDurationUs": 33333,
  "roi": [320, 180, 640, 360],
  "droppedFrames": 0
}
```

系统必须能够回答：

1. 这是第几个物理触发？
2. 它对应哪个 sensor frame？
3. 哪个 libcamera Request 接收了它？
4. 实际曝光和增益是多少？
5. 从触发到 SOF 用了多久？
6. 从 SOF 到应用收到图像用了多久？
7. 是否发生了触发丢失、重复或错配？

## 4. 推荐系统架构

```text
光电传感器
     │
     ▼
RP2040/Pico 或硬件定时器
     ├── 产生 IMX296 XTR
     ├── 控制 LED strobe
     ├── 维护 trigger sequence
     └── 记录 trigger timestamp
                  │
                  ▼
IMX296 → CSI-2 → RP1 CFE → PiSP BE → DMA-BUF
                  │              ▲
                  │ Stats        │ ISP parameters
                  ▼              │
              RPi IPA / ROI-AE
                  │
                  ▼
          libcamera Request metadata
                  │
                  ▼
          C++ 预览/采集应用
```

### 4.1 为什么需要硬件触发器

不建议用普通 Linux 用户态 GPIO 循环产生高精度触发：

- 用户态线程会受到 Linux 调度影响；
- 系统负载变化会改变 GPIO 翻转时刻；
- 预览、写盘、网络或编码都可能放大抖动；
- 难以精确协调曝光和 LED strobe。

高精度 XTR 和闪光时序应交给：

- RP2040/Pico；
- 硬件 PWM；
- FPGA；
- 专用 timing controller。

Linux 负责：

- 配置触发器；
- arm/disarm；
- 设置下一次 pulse width；
- 接收 trigger sequence/timestamp；
- 采集、处理和保存图像。

### 4.2 硬件注意事项

外触发实施前必须确认：

- XTR 电平兼容；
- 是否需要移除相机板上的指定元件；
- 相机供电关闭时是否钳制 XTR；
- LED strobe 驱动是否与传感器电气隔离；
- 示波器探头和地线不会影响信号质量。

以 Raspberry Pi 官方外触发文档为准，不应直接把 3.3V 或 5V GPIO 接到
未确认电气规格的相机同步引脚。

## 5. 各层修改建议

| 层次 | 修改目标 |
|---|---|
| 硬件 | IMX296、XTR 电平接口、RP2040/PWM、LED strobe、光电传感器 |
| 触发固件 | 生成精确 pulse、维护 trigger sequence、允许设置周期和脉宽 |
| Linux sensor driver | 将固定 trigger mode 改成停止状态下可配置的 V4L2 control |
| Device Tree | 描述默认 trigger mode、always-on、触发器和 flash 连接 |
| RP1 CFE | 验证 SOF timestamp，必要时增加 tracepoint/触发序号传播 |
| libcamera controls | 增加 TriggerMode、TriggerSequence、AeRegions 等 |
| RPi Pipeline | 配置触发模式、处理稀疏 trigger timeout、对齐 Request |
| IPA | 动态 ROI 测光；外触发模式输出 pulse width 和 gain |
| 应用 | 预览、ROI、arm、触发、保存、元数据和性能统计 |
| 测试 | 示波器/逻辑分析仪、LTTng、图像亮度和稳定性测试 |

## 6. Linux 内核修改

### 6.1 当前实现

重点文件：

- [`drivers/media/i2c/imx296.c`](../linux/drivers/media/i2c/imx296.c)
- [`arch/arm/boot/dts/overlays/imx296-overlay.dts`](../linux/arch/arm/boot/dts/overlays/imx296-overlay.dts)
- [`arch/arm/boot/dts/overlays/README`](../linux/arch/arm/boot/dts/overlays/README)

当前行为大致为：

```text
module parameter 或 DT trigger-mode
    ↓
probe 时读取 DT
    ↓
stream_on 时选择最终 trigger mode
    ↓
写 IMX296_CTRL0B / IMX296_LOWLAGTRG
```

### 6.2 Runtime TriggerMode Control

第一项内核开发建议，是将 trigger mode 变成 session 级控制：

```text
FreeRunning
ExternalTrigger
```

设计要求：

- 只能在相机停止 streaming 时修改；
- `stream_on` 后 grab control；
- `stream_off` 后解除 grab；
- 非法值在驱动层拒绝；
- Device Tree 仍作为默认值；
- module parameter 只保留兼容用途或逐步废弃；
- 不允许在一帧采集过程中切换 trigger mode。

本地内核目前没有通用的 camera sensor external-trigger 标准 control。

短期学习型 fork 可以：

```text
使用 Raspberry Pi 私有 V4L2 CID
```

如果准备向 Linux 上游提交，则应：

```text
先在 linux-media 社区讨论通用 UAPI
→ 明确 TriggerMode 的跨厂商语义
→ 再定义稳定 ABI
```

不要未经讨论直接创造永久的公共 UAPI。

### 6.3 Flash/Strobe

内核已经存在标准 V4L2 Flash controls，例如：

```text
V4L2_CID_FLASH_LED_MODE
V4L2_CID_FLASH_STROBE_SOURCE
V4L2_CID_FLASH_STROBE
V4L2_CID_FLASH_TIMEOUT
V4L2_CID_FLASH_INTENSITY
```

如果补光硬件允许，建议将 LED 控制器建模为 V4L2 flash subdevice，而不是
把 LED GPIO 逻辑硬编码进 IMX296 sensor driver。

### 6.4 RP1 CFE

相关代码：

- [`drivers/media/platform/raspberrypi/rp1_cfe`](../linux/drivers/media/platform/raspberrypi/rp1_cfe)
- [`drivers/media/platform/raspberrypi/pisp_be`](../linux/drivers/media/platform/raspberrypi/pisp_be)

第一阶段不应为了“全栈修改”而强行改 CFE。先验证：

- buffer timestamp 是否确实对应 SOF；
- V4L2 sequence 在丢帧、稀疏触发时是否连续；
- CFE timeout 是否由 kernel 还是 libcamera 主导；
- 是否有足够的 tracing 观察 IRQ、DMA 和 buffer completion。

只有发现 timestamp 精度、事件传播或丢帧可观察性不足时，再修改 CFE。

## 7. libcamera Control API

### 7.1 建议新增的 RPi vendor controls

建议先在：

- [`src/libcamera/control_ids_rpi.yaml`](../libcamera/src/libcamera/control_ids_rpi.yaml)

增加：

```text
TriggerMode
    Input, session/control
    FreeRunning / ExternalTrigger

TriggerPulseWidth
    Input, microseconds
    指定下一次或后续触发曝光脉宽

TriggerSequence
    Output metadata
    物理触发序号

TriggerTimestamp
    Output metadata
    触发边沿时间戳

AppliedTriggerPulseWidth
    Output metadata
    当前帧实际使用的 pulse width

AeRegions
    Input
    应用指定的动态曝光测光区域
```

第一版放在 `controls::rpi`，不要过早修改公共 core controls。完成原型并
证明语义稳定、具有跨平台价值后，再讨论公共 API。

### 7.2 控制分类

要明确区分：

```text
Session Controls
    在 configure/start 前设置
    例如 TriggerMode

Per-request Controls
    每个 Request 可以不同
    例如 AeRegions、下一次 TriggerPulseWidth

Metadata
    驱动、Pipeline 或 IPA 返回
    例如 TriggerSequence、AppliedTriggerPulseWidth
```

不要把 `TriggerMode` 做成每帧控制，因为硬件模式切换需要停止 streaming。

## 8. Pipeline 与 IPA 协议

RPi Pipeline/IPA 接口定义在：

- [`include/libcamera/ipa/raspberrypi.mojom`](../libcamera/include/libcamera/ipa/raspberrypi.mojom)

建议增加类似的数据：

```text
struct TriggerParams {
    uint32 sequence;
    int64 timestamp;
    uint32 pulseWidthUs;
    bool externalTriggerEnabled;
};

struct TriggerStatus {
    uint32 sequence;
    int64 timestamp;
    uint32 appliedPulseWidthUs;
};
```

具体放入：

- `InitParams`：硬件是否支持外触发；
- `ConfigParams`：当前会话是否外触发；
- `PrepareParams`：当前帧 trigger sequence/timestamp；
- `ProcessParams`：统计对应的 trigger 信息；
- `metadataReady`：向应用报告实际结果；
- 新的 Event：向 Pipeline/触发控制器提交下一次 pulse width。

通过 mojom 生成 serializer/proxy，可以同时支持：

- IPA 进程内运行；
- IPA 独立进程运行；
- 数据通过 IPC 传输。

## 9. RPi PiSP Pipeline 修改

主要文件：

- [`src/libcamera/pipeline/rpi/common/pipeline_base.cpp`](../libcamera/src/libcamera/pipeline/rpi/common/pipeline_base.cpp)
- [`src/libcamera/pipeline/rpi/common/delayed_controls.cpp`](../libcamera/src/libcamera/pipeline/rpi/common/delayed_controls.cpp)
- [`src/libcamera/pipeline/rpi/pisp/pisp.cpp`](../libcamera/src/libcamera/pipeline/rpi/pisp/pisp.cpp)

### 9.1 稀疏触发 Timeout

当前连续采集模型会根据 frame duration 设置 CFE dequeue timeout。

外触发可能几秒或几分钟才出现一次，因此必须区分：

```text
FreeRunningTimeout
    连续出帧中断，通常意味着硬件故障

TriggerArmedTimeout
    尚未收到物理 trigger，不应立即视为相机故障

CaptureInProgressTimeout
    已收到 trigger，但预期时间内没有 sensor frame
```

可以将 Pipeline 状态扩展为：

```text
Stopped
Idle
Armed
TriggerReceived
Busy
IpaComplete
Error
```

不要简单地把 timeout 设成无限大，否则真实硬件故障将无法恢复。

### 9.2 Trigger 与 Request 对齐

必须建立：

```text
triggerSequence
→ V4L2 buffer sequence
→ delayContext
→ ipaContext
→ Request::sequence()
```

建议新建一个类似 `DelayedControls` 的小型关联队列：

```text
TriggeredFrame {
    triggerSequence;
    triggerTimestamp;
    pulseWidth;
    expectedSensorSequence;
}
```

出现以下情况时必须明确报告：

- trigger 到来但没有可用 Request；
- Request 已排队但长期没有 trigger；
- sensor sequence 跳变；
- 一个 trigger 得到多个 frame；
- frame 到来但没有 trigger metadata；
- IPA metadata 和输出 buffer 对应不同 trigger。

### 9.3 Request 完成条件

外触发 Request 的完成条件应是：

```text
所有应用输出 buffer 完成
AND IPA metadata 完成
AND trigger metadata 已关联
```

不能只根据图像 buffer 完成就通知应用。

### 9.4 利用现有 DelayedControls

当前 Pipeline 已用：

- [`delayed_controls.cpp`](../libcamera/src/libcamera/pipeline/rpi/common/delayed_controls.cpp)

解决 exposure、gain、VBLANK 写入后跨若干帧生效的问题。

Trigger 对齐可以借鉴它的设计：

- 以 sequence/cookie 为索引；
- 将提交值和实际生效帧分离；
- frame dequeue 时再关联；
- metadata 返回实际使用值而非仅返回请求值。

## 10. IPA 与动态 ROI 自动曝光

### 10.1 当前 AGC 能力

当前 RPi AGC 已支持：

```text
centre-weighted
spot
matrix
custom
```

但 custom 权重主要来自 tuning JSON，还不是应用按 Request 动态提供的 ROI。

主要入口：

- [`src/ipa/rpi/common/ipa_base.cpp`](../libcamera/src/ipa/rpi/common/ipa_base.cpp)
- [`src/ipa/rpi/controller/rpi/agc.cpp`](../libcamera/src/ipa/rpi/controller/rpi/agc.cpp)
- [`src/ipa/rpi/controller/rpi/agc_channel.cpp`](../libcamera/src/ipa/rpi/controller/rpi/agc_channel.cpp)

### 10.2 动态 AeRegions

建议流程：

```text
应用提交 AeRegions
    ↓
Camera/IPA 校验矩形范围
    ↓
将输出坐标转换成 sensor crop 坐标
    ↓
转换成 PiSP 统计区域
    ↓
生成 15×15 AGC weights
    ↓
AgcChannel 使用动态权重
    ↓
metadata 返回实际裁剪和量化后的 AeRegions
```

需要处理：

- ScalerCrop；
- sensor analog crop；
- binning；
- ISP crop；
- ROI 越界；
- ROI 太小；
- 多 ROI 的权重合并；
- Request 控制延迟。

### 10.3 外触发下的曝光语义

在 free-running 模式：

```text
AGC 输出 ExposureTime
→ CamHelper 转成 sensor exposure lines
→ V4L2_CID_EXPOSURE
```

在 external-trigger 模式：

```text
曝光主要由 XTR 低电平宽度决定
```

因此 AGC 应输出：

```text
下一次 TriggerPulseWidth
下一次 AnalogueGain
当前 ISP DigitalGain
```

而不能继续假设 `V4L2_CID_EXPOSURE` 独立决定曝光。

这要求明确区分：

```text
RequestedExposure
RequestedPulseWidth
AppliedPulseWidth
ReportedExposure
```

### 10.4 tuning 文件

建议复制而不是直接修改默认文件：

```text
src/ipa/rpi/pisp/data/imx296.json
→ imx296_triggered_experimental.json
```

重点调节：

- AGC convergence；
- exposure modes；
- gain/exposure trade-off；
- noise model；
- black level；
- denoise；
- target brightness；
- ROI metering weights；
- 闪光场景的 AWB/CCM。

参考：

- [Raspberry Pi Camera Algorithm and Tuning Guide](https://datasheets.raspberrypi.com/camera/raspberry-pi-camera-guide.pdf)

## 11. 触发控制器固件

建议 RP2040 固件支持：

```text
ARM
DISARM
SET_PERIOD
SET_PULSE_WIDTH
SET_STROBE_DELAY
SET_STROBE_WIDTH
GET_STATUS
GET_LAST_TRIGGER
QUEUE_NEXT_TRIGGER_CONFIG
```

每次触发记录：

```text
sequence
trigger timestamp
pulse width
strobe delay
strobe width
error flags
```

通信可选：

| 接口 | 优点 | 缺点 |
|---|---|---|
| UART | 简单、易调试 | 带宽和时延一般 |
| SPI | 低延迟、确定性较好 | 驱动和协议更复杂 |
| USB CDC | 开发方便 | USB 调度会带来抖动 |
| RP1 PWM | 无额外 MCU | 动态协议和 trigger sequence 管理更难 |

第一版推荐：

```text
RP2040 负责硬实时
UART/SPI 负责低频配置和状态
```

不要让每个 trigger 都依赖 Linux 临时发送命令；应预先 queue 下一次配置。

## 12. 应用层设计

### 12.1 为什么先写 C++

第一版应直接使用 C++ libcamera API，因为：

- 能直接访问 Request、FrameBuffer、ControlList；
- 更容易跟踪线程和 buffer 生命周期；
- 减少 Python runtime 对延迟测量的影响；
- 方便添加 tracepoint；
- 可以保持 DMA-BUF 零拷贝；
- 与 libcamera 内部调试符号对应更直接。

参考：

- [`test/camera/capture.cpp`](../libcamera/test/camera/capture.cpp)
- [`src/apps/cam/camera_session.cpp`](../libcamera/src/apps/cam/camera_session.cpp)
- [`Documentation/guides/application-developer.rst`](../libcamera/Documentation/guides/application-developer.rst)

### 12.2 线程划分

建议：

```text
Camera thread
    Request 和 buffer completion

Preview thread
    DRM/SDL/Qt 显示

Writer thread
    编码和写盘

Trigger-control thread
    RP2040/UART/SPI 或内核设备

Metrics thread
    延迟、抖动、丢帧和 histogram
```

CameraManager callback 中禁止：

- 磁盘写入；
- JPEG/PNG 编码；
- 网络发送；
- 长时间 mutex；
- 同步等待 GUI；
- 等待触发器响应。

callback 应只做：

```text
读取 metadata
→ 记录 timestamp
→ 将 CompletedFrame 放入无阻塞队列
→ 立即 reuse/queue 可复用 Request
```

### 12.3 零拷贝

性能目标是：

```text
CFE/PiSP DMA-BUF
→ Preview/Encoder import
→ 不经过 CPU memcpy
```

写盘或软件处理需要 mmap 时，也应：

- 只映射必要 plane；
- 不复制到中间大缓冲区；
- 与 Camera thread 解耦；
- 明确 DMA-BUF cache synchronization。

## 13. 端到端观测

### 13.1 现有 tracepoints

libcamera 已有：

- [`include/libcamera/internal/tracepoints/request.tp`](../libcamera/include/libcamera/internal/tracepoints/request.tp)
- [`include/libcamera/internal/tracepoints/pipeline.tp`](../libcamera/include/libcamera/internal/tracepoints/pipeline.tp)

现有事件包括：

```text
request_construct
request_queue
request_device_queue
request_complete_buffer
request_complete
ipa_call_begin
ipa_call_end
```

### 13.2 建议新增事件

```text
trigger_arm
trigger_received
cfe_sof
cfe_bayer_dequeue
cfe_stats_dequeue
ipa_process_begin/end
ipa_prepare_begin/end
be_queue
be_output_dequeue
trigger_request_matched
trigger_request_mismatch
```

每个事件至少记录：

```text
request pointer/cookie
request sequence
trigger sequence
V4L2 sequence
ipaContext
delayContext
buffer ID/mask
sensor timestamp
wall clock
pipeline state
```

### 13.3 硬件测量

软件时间戳不能完全替代示波器。

建议同时测量：

```text
XTR
LED strobe
XVS/可用同步输出
可选光电二极管输出
```

软件中记录：

```text
trigger command timestamp
MCU trigger timestamp
CFE SOF timestamp
buffer dequeue timestamp
IPA begin/end
BE complete timestamp
RequestComplete timestamp
写盘完成 timestamp
```

## 14. 分阶段目标

### 阶段 0：建立不可修改的基线

先不改代码：

- IMX296 连续预览；
- 固定 30Hz 外触发；
- 记录 `SensorTimestamp`、`FrameWallClock`、Request sequence；
- 示波器观察 XTR、同步信号和 LED；
- 测量延迟、抖动、丢帧和 CPU 使用率；
- 保存测试环境、命令和原始数据。

没有基线，就无法证明后续优化是否有效。

### 阶段 1：Runtime TriggerMode

完成：

- 内核 IMX296 runtime V4L2 trigger control；
- 应用通过 libcamera 选择 free-running/external-trigger；
- 不修改 module parameter；
- 不需要重启；
- streaming 时禁止切换；
- 普通连续采集无回归。

### 阶段 2：触发帧可追溯

完成：

```text
triggerSequence
→ sensor sequence
→ requestSequence
→ output buffer
→ metadata
```

验收：

- 连续 10,000 次触发无重复、无错配；
- 每个成功 trigger 恰好对应一个 Request；
- 稀疏触发等待期间不会错误进入 camera timeout；
- 丢触发时应用收到明确状态；
- 序号不会静默偏移。

### 阶段 3：动态 ROI 自动曝光

完成：

- 应用动态提交 AeRegions；
- ROI 正确映射到 PiSP statistics；
- AGC 使用动态 weights；
- metadata 返回实际 ROI；
- 不同 ScalerCrop 下仍正确。

建议验收：

- ROI 改变后 5 个有效帧内达到目标亮度 ±10%；
- 曝光不过度振荡；
- ROI 外背景变化不会显著影响目标曝光；
- ROI 越界和极小 ROI 有明确处理。

### 阶段 4：外触发闭环曝光

完成：

```text
Stats
→ IPA AGC
→ 下一次 TriggerPulseWidth
→ RP2040
→ XTR
→ 当前帧实际 pulse metadata
```

验收：

- `reportedExposure ≈ pulseWidth + 14.26µs`；
- Requested、Applied、Reported 三组值可以区分；
- trigger sequence 与 AGC 输出正确对齐；
- 高低亮度切换时不出现控制错帧；
- MCU 命令未及时到达时使用明确的 fallback。

### 阶段 5：延迟和稳定性调优

建议初始指标：

- 30fps 全分辨率连续运行 30 分钟无丢帧；
- 10,000 次硬件触发无 metadata 错配；
- `SOF → RequestComplete` P99 小于两个 frame period；
- trigger-to-SOF jitter 优化后至少比基线降低 50%；
- Camera callback 中无阻塞 I/O；
- 图像主路径保持 DMA-BUF 零拷贝；
- timeout 后能够 stop/reconfigure/start 恢复；
- thermal throttling 时有明确指标和告警。

指标最终应根据第一阶段实测基线调整，而不是先假定硬件一定能达到某个绝对
微秒值。

## 15. 推荐的第一轮 Patch 顺序

建议按以下顺序提交，便于测试和回滚：

1. **Kernel：IMX296 trigger-mode V4L2 control**
   - 不涉及 libcamera；
   - 使用 `v4l2-ctl` 单独验证。

2. **Application：最小 C++ 触发采集器**
   - 先使用现有 DT 外触发；
   - 建立延迟和丢帧基线。

3. **libcamera：RPi TriggerMode control**
   - 从应用映射到 V4L2 sensor control；
   - session 级生效。

4. **libcamera：Trigger metadata**
   - TriggerSequence；
   - TriggerTimestamp；
   - AppliedPulseWidth。

5. **Pipeline：外触发状态和 timeout**
   - Armed 状态；
   - trigger watchdog；
   - trigger/request 对齐。

6. **Tracing：端到端观测**
   - 软件 trace 与示波器测量关联。

7. **IPA：动态 AeRegions**
   - 先在 free-running 模式验证。

8. **IPA/固件：外触发 AGC 闭环**
   - AGC 输出下一次 pulse width。

9. **Flash/Strobe**
   - 最后加入补光和色彩 tuning。

这个顺序保证每一步都可以独立验收。

## 16. 不建议一开始做的内容

第一阶段不要同时加入：

- 双相机立体视觉；
- 多帧 HDR；
- 神经网络 AWB；
- 目标检测模型；
- H.264 网络推流；
- Python GUI；
- 云端控制；
- 多进程相机同步。

这些功能会掩盖 trigger、frame、Request、control timing 的基础问题。

先完成单个 IMX296 的确定性闭环，再扩展到双相机。

Pi 5 支持连接两颗相机，但官方文档也说明跨相机同步和 3A 有额外限制：

- [Raspberry Pi Camera Software](https://www.raspberrypi.com/documentation/computers/camera_software.html)

双相机可以作为第二阶段：

```text
同一 XTR 驱动两颗 IMX296
→ 每颗相机独立 Request queue
→ triggerSequence 作为公共关联键
→ 对比 SensorTimestamp
→ 再处理 3A 同步
```

## 17. 关于 Linux Media Request API

Linux Media Request API 能把特定 controls 和 buffer 关联到同一个 request，
适用于逐帧配置复杂媒体流水线：

- [Linux Kernel Media Request API](https://www.kernel.org/doc/html/latest/userspace-api/media/mediactl/request-api.html)

但当前 RPi Pipeline 已经使用：

```text
libcamera Request
DelayedControls
ipaContext
delayContext
内部 buffer queues
```

因此建议：

1. 第一版继续使用 `DelayedControls`；
2. 完成 trigger/request 对齐；
3. 测量现有模型的限制；
4. 再评估 RP1 CFE、PiSP BE 和 sensor 是否适合统一迁移到 Media Request API。

不要在项目开始时同时重写底层请求模型，否则很难区分问题来自外触发还是
Request API 改造。

## 18. 最终验收问题

项目完成时，应能沿代码和测量数据回答：

1. 应用设置 TriggerMode 后，最终是哪个 sensor register 改变？
2. 为什么 TriggerMode 不能在 streaming 中途切换？
3. 物理 trigger 如何与 V4L2 sequence 对齐？
4. 触发时没有可用 Request 会发生什么？
5. Request 排队但长时间没有 trigger 会发生什么？
6. 稀疏触发为什么不会被误判为 camera timeout？
7. `SensorTimestamp` 对应 SOF、EOF 还是 buffer completion？
8. `TriggerTimestamp` 和 `SensorTimestamp` 是否在同一时钟域？
9. exposure/gain/pulse width 分别在哪一帧生效？
10. IPA `process()` 和 `prepare()` 分别服务哪一帧？
11. AeRegions 如何从应用坐标变成 PiSP stats weights？
12. Requested、Applied、Reported exposure 为什么必须区分？
13. Request 为什么必须等待 buffer、IPA metadata 和 trigger metadata？
14. SOF 到应用回调的主要延迟来自哪里？
15. 系统如何检测 trigger 丢失、frame 丢失和 metadata 错配？
16. 哪些改动适合保留为 RPi vendor extension，哪些值得上游化？

如果这些问题都有代码、trace 和示波器证据，就真正完成了从硬件到应用的
全栈 libcamera 开发，而不仅是写了一个相机界面。

## 19. 项目最终价值

该方向最终产出的不仅是一个应用，还包括：

```text
一套 IMX296 runtime trigger kernel 接口
一套 libcamera trigger control/metadata 语义
一个适配外触发的 PiSP Pipeline 状态机
一个可动态配置 ROI 的 RPi AGC
一个确定性的硬件触发控制器
一个直接使用 libcamera 的 C++ 应用
一套端到端 tracing 和性能测试方法
一套可复用的图像质量 tuning 流程
```

这套成果可以进一步扩展到：

- 流水线质检；
- 高速扫码；
- 运动分析；
- 显微成像；
- 双目同步；
- 机器人视觉；
- 低延迟工业录像；
- 多机位硬件同步。

它既有清晰的演示效果，也足以覆盖 libcamera 最核心的设备、Pipeline、
Request、control timing、IPA 和图像算法机制。
