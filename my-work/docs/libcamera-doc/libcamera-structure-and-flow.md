# libcamera 仓库结构、构建体系与运行流程调研

> 调研对象：Raspberry Pi `libcamera` fork  
> 仓库版本：`v0.7.1+rpt20260609`  
> Commit：`06c385619acb10bbfb33f52f3abeb8f8c095f42b`  
> 调研日期：2026-07-19

## 1. 核心结论

掌握这个仓库最快的方法，不是逐目录阅读，而是同时沿着两条主线追踪：

1. Meson 如何选择平台、生成代码并组装构建目标。
2. 一个 `Request` 如何经过 Pipeline、IPA、V4L2，最终变成完成帧。

当前仓库是 Raspberry Pi 维护的 fork，默认目标明确偏向 `rpi/pisp` 和
`rpi/vc4`。如果目标是 Raspberry Pi 5，应优先阅读 PiSP 路径，而不是平均
研究所有平台。

仓库当前约有：

- 1511 个 Git 受控文件；
- 约 19 万行 C/C++；
- 102 个 Meson 构建文件；
- 约 3.35 万行 Raspberry Pi Pipeline/IPA 相关 C/C++。

最重要的代码结构可以概括为：

```text
应用
  ↓
CameraManager / Camera / Request / Stream / FrameBuffer
  ↓
PipelineHandler 通用请求和状态管理
  ↓
RPi PipelineHandlerBase
  ↓
PipelineHandlerPiSP / PiSPCameraData
  ↓
RP1 CFE + PiSP Back End
  ↕
RPi IPA / Controller / 3A algorithms / tuning JSON
```

## 2. 从构建体系理解仓库

### 2.1 顶层构建顺序

顶层入口是 [`meson.build`](../libcamera/meson.build)，主要子目录顺序为：

```text
utils → include → src → Documentation → test
```

这个顺序体现了构建依赖：

```text
utils/codegen
    │
    ├── YAML → controls、properties、formats 的 C++ 代码
    └── mojom → IPA 接口、序列化器、proxy、proxy worker
             │
include ─────┘
    │
src/libcamera
    ├── libcamera-base.so
    └── libcamera.so
           ├── 公共 Camera API
           ├── Media Controller / V4L2 封装
           ├── Pipeline Handler
           ├── IPA 管理和 IPC
           └── 被选择的平台实现
    │
src/ipa
    ├── ipa_rpi_pisp.so
    └── ipa_rpi_vc4.so
    │
应用和兼容层
    ├── cam / qcam
    ├── GStreamer
    ├── Python
    ├── Android HAL
    └── V4L2 compatibility
```

### 2.2 主要构建产物

| 产物 | 作用 | 构建入口 |
|---|---|---|
| `libcamera-base.so` | 线程、事件循环、Object、Signal、Timer、日志 | [`src/libcamera/base/meson.build`](../libcamera/src/libcamera/base/meson.build) |
| `libcamera.so` | 公共 API、设备模型、Pipeline、IPA 管理 | [`src/libcamera/meson.build`](../libcamera/src/libcamera/meson.build) |
| `ipa_rpi_pisp.so` | Pi 5 图像算法和 PiSP 参数生成 | [`src/ipa/rpi/pisp/meson.build`](../libcamera/src/ipa/rpi/pisp/meson.build) |
| `ipa_rpi_vc4.so` | Pi 4 及更早平台的算法适配 | [`src/ipa/rpi/vc4/meson.build`](../libcamera/src/ipa/rpi/vc4/meson.build) |
| `raspberrypi_ipa_proxy` | IPA 隔离进程和 IPC | [`src/libcamera/proxy/worker/meson.build`](../libcamera/src/libcamera/proxy/worker/meson.build) |
| `cam` | 命令行测试和采集应用 | [`src/apps/cam/meson.build`](../libcamera/src/apps/cam/meson.build) |
| `gstlibcamera.so` | GStreamer source plugin | [`src/gstreamer/meson.build`](../libcamera/src/gstreamer/meson.build) |
| `_libcamera` | Python pybind11 扩展 | [`src/py/libcamera/meson.build`](../libcamera/src/py/libcamera/meson.build) |
| `v4l2-compat.so` | 将传统 V4L2 应用适配到 libcamera | [`src/v4l2/meson.build`](../libcamera/src/v4l2/meson.build) |

### 2.3 Raspberry Pi 默认构建选择

构建选项位于 [`meson_options.txt`](../libcamera/meson_options.txt)。

当前 fork 的主要默认值是：

- IPA：`rpi/pisp`、`rpi/vc4`；
- Pipeline：`rpi/pisp`、`rpi/vc4`；
- `cam`、`qcam`、文档、测试默认关闭；
- V4L2 compatibility 默认开启；
- GStreamer、Python 等根据依赖自动判断；
- PiSP 依赖 `libpisp`，缺失时通过
  [`subprojects/libpisp.wrap`](../libcamera/subprojects/libpisp.wrap) 获取
  Raspberry Pi `libpisp` v1.5.0。

需要特别检查一个构建异常：`pipelines` 选项中同时存在两处 `value`
定义。由于当前调研环境未安装 Meson，尚未实际验证所使用 Meson 版本对该
写法的处理，应在第一次配置构建时优先确认。

### 2.4 构建时代码生成

这个仓库不能只把 `.cpp` 看成源码全貌，许多关键接口由构建过程生成。

#### Controls、Properties 和 Formats

输入文件：

```text
src/libcamera/control_ids_core.yaml
src/libcamera/control_ids_debug.yaml
src/libcamera/control_ids_draft.yaml
src/libcamera/control_ids_rpi.yaml
src/libcamera/property_ids_core.yaml
src/libcamera/property_ids_draft.yaml
src/libcamera/formats.yaml
```

生成结果包括：

```text
control_ids.h / control_ids.cpp
property_ids.h / property_ids.cpp
formats.h
GStreamer control properties
Python control/property/format bindings
```

相关入口：

- [`include/libcamera/meson.build`](../libcamera/include/libcamera/meson.build)
- [`utils/codegen`](../libcamera/utils/codegen)

#### IPA 接口和 IPC

RPi Pipeline 与 IPA 的协议定义在：

- [`include/libcamera/ipa/raspberrypi.mojom`](../libcamera/include/libcamera/ipa/raspberrypi.mojom)

Meson 会生成：

```text
raspberrypi_ipa_interface.h
raspberrypi_ipa_serializer.h
raspberrypi_ipa_proxy.h
raspberrypi_ipa_proxy.cpp
raspberrypi_ipa_proxy_worker.cpp
```

Pipeline 与 mojom 文件的映射在：

- [`include/libcamera/ipa/meson.build`](../libcamera/include/libcamera/ipa/meson.build)

这套生成机制使 Pipeline 无需关心 IPA 是运行在内部线程还是独立进程。

### 2.5 IPA 签名和隔离

如果构建时可以生成并验证 IPA 签名，可信 IPA 可以通过 threaded proxy
在进程内运行。如果签名不可用或强制隔离，则使用 generated proxy worker
在单独进程运行，通过 Unix socket IPC 交换序列化数据。

关键实现：

- [`include/libcamera/internal/ipa_manager.h`](../libcamera/include/libcamera/internal/ipa_manager.h)
- [`src/libcamera/ipa_manager.cpp`](../libcamera/src/libcamera/ipa_manager.cpp)
- [`src/libcamera/ipa_proxy.cpp`](../libcamera/src/libcamera/ipa_proxy.cpp)

## 3. 代码分层

### 3.1 应用公共 API

目录：

- [`include/libcamera`](../libcamera/include/libcamera)
- [`src/libcamera`](../libcamera/src/libcamera)

主要对象：

| 对象 | 作用 |
|---|---|
| `CameraManager` | 启动内部线程、枚举设备、管理 Camera 生命周期 |
| `Camera` | 相机状态机及应用操作入口 |
| `CameraConfiguration` | 多个 Stream 的配置集合 |
| `Stream` | 一个相机输出流 |
| `FrameBuffer` | DMA-BUF 图像缓冲区及帧元数据 |
| `Request` | 一帧或一组同步输出的 buffers、controls 和 metadata |
| `ControlList` | 应用控制、传感器控制、IPA metadata 的通用容器 |

### 3.2 通用核心层

核心对象：

| 对象 | 作用 |
|---|---|
| `PipelineHandler` | 平台 Pipeline 的抽象接口、请求排序和完成管理 |
| `DeviceEnumerator` | 枚举 Linux Media Controller 设备 |
| `MediaDevice` / `MediaEntity` | 表示 Media Controller 拓扑 |
| `V4L2VideoDevice` | V4L2 video node 封装 |
| `V4L2Subdevice` | V4L2 subdevice 封装 |
| `CameraSensor` | 传感器格式、属性和控制抽象 |
| `IPAManager` | 查找、验证、加载或隔离 IPA 模块 |

关键文件：

- [`src/libcamera/camera_manager.cpp`](../libcamera/src/libcamera/camera_manager.cpp)
- [`include/libcamera/internal/pipeline_handler.h`](../libcamera/include/libcamera/internal/pipeline_handler.h)
- [`src/libcamera/pipeline_handler.cpp`](../libcamera/src/libcamera/pipeline_handler.cpp)
- [`src/libcamera/device_enumerator.cpp`](../libcamera/src/libcamera/device_enumerator.cpp)
- [`src/libcamera/media_device.cpp`](../libcamera/src/libcamera/media_device.cpp)
- [`src/libcamera/v4l2_videodevice.cpp`](../libcamera/src/libcamera/v4l2_videodevice.cpp)
- [`src/libcamera/v4l2_subdevice.cpp`](../libcamera/src/libcamera/v4l2_subdevice.cpp)

### 3.3 Raspberry Pi Pipeline 层

RPi Pipeline 分为公共基类和两个硬件实现：

```text
src/libcamera/pipeline/rpi/
├── common/
│   ├── pipeline_base.cpp
│   ├── rpi_stream.cpp
│   └── delayed_controls.cpp
├── pisp/
│   └── pisp.cpp
└── vc4/
    └── vc4.cpp
```

公共基类负责：

- StreamRole 到默认格式的映射；
- CameraConfiguration 验证；
- 传感器配置；
- IPA 加载和配置；
- 内部、外部 buffer 管理；
- Request 队列；
- 延迟控制；
- metadata 合并；
- Request 完成判定。

PiSP/VC4 子类负责：

- 匹配具体 Media Controller 设备；
- 查找和打开平台 V4L2 video nodes；
- 设置平台格式、crop 和 links；
- 构造 ISP 硬件配置；
- 处理平台特有 buffer 回调和状态机。

### 3.4 Raspberry Pi IPA 层

```text
src/ipa/rpi/
├── common/
│   └── ipa_base.cpp
├── cam_helper/
│   ├── cam_helper.cpp
│   └── cam_helper_imx*.cpp
├── controller/
│   ├── controller.cpp
│   └── rpi/
│       ├── agc.cpp
│       ├── awb.cpp
│       ├── af.cpp
│       ├── alsc.cpp
│       ├── ccm.cpp
│       ├── denoise.cpp
│       ├── hdr.cpp
│       └── ...
├── pisp/
│   ├── pisp.cpp
│   └── data/*.json
└── vc4/
    ├── vc4.cpp
    └── data/*.json
```

其中：

- `IpaBase` 处理通用控制、时序、metadata 和 Controller 调度；
- `Controller` 从 tuning JSON 中动态创建算法；
- 每个算法按顺序执行 `initialise`、`switchMode`、`prepare`、`process`；
- `cam_helper_*` 描述驱动未完全表达的传感器特性；
- `pisp.cpp` 或 `vc4.cpp` 把算法结果翻译成对应 ISP 的硬件参数；
- `data/*.json` 是每种 sensor/模组的 tuning 数据。

## 4. 启动与设备发现流程

启动主流程：

```text
CameraManager::start()
  → 创建 CameraManager 专用线程
  → CameraManager::Private::init()
  → IPAManager 初始化
  → DeviceEnumerator 枚举 Media Controller 设备
  → 遍历已注册 PipelineHandlerFactory
  → PipelineHandlerPiSP::match()
  → 匹配 rp1-cfe 和 pispbe
  → 遍历 MEDIA_ENT_F_CAM_SENSOR entity
  → 创建 CameraSensor 和 PiSPCameraData
  → 加载 Pipeline 配置、IPA、tuning JSON
  → 连接 V4L2/IPA signals
  → 创建并注册 Camera
```

关键入口：

- [`CameraManager::Private::start()`](../libcamera/src/libcamera/camera_manager.cpp)
- [`CameraManager::Private::createPipelineHandlers()`](../libcamera/src/libcamera/camera_manager.cpp)
- [`PipelineHandlerPiSP::match()`](../libcamera/src/libcamera/pipeline/rpi/pisp/pisp.cpp)
- [`PipelineHandlerBase::registerCamera()`](../libcamera/src/libcamera/pipeline/rpi/common/pipeline_base.cpp)
- [`PiSPCameraData::platformRegister()`](../libcamera/src/libcamera/pipeline/rpi/pisp/pisp.cpp)

Pipeline handler 通过 `REGISTER_PIPELINE_HANDLER` 宏静态注册工厂，而不是由
CameraManager 显式创建某个具体平台类。

## 5. Raspberry Pi 5 硬件拓扑

Pi 5 Pipeline 匹配两个 Media Controller 设备：

```text
Sensor
  │
  ▼
CSI-2 receiver
  │
  ▼
RP1 CFE
  ├── rp1-cfe-fe_image0     Bayer image
  ├── rp1-cfe-fe_stats      inline statistics
  ├── rp1-cfe-embedded      sensor embedded metadata
  └── rp1-cfe-fe_config     FE configuration
  │
  ▼
PiSP Back End
  ├── pispbe-input
  ├── pispbe-config
  ├── pispbe-output0
  ├── pispbe-output1
  ├── TDN input/output
  └── HDR stitch input/output
```

代码入口：

- [`src/libcamera/pipeline/rpi/pisp/pisp.cpp`](../libcamera/src/libcamera/pipeline/rpi/pisp/pisp.cpp)

PiSP 对应 Pi 5；VC4 使用：

```text
Sensor → Unicam → bcm2835-isp
```

两者共享：

- `PipelineHandlerBase`；
- `raspberrypi.mojom`；
- `IpaBase`；
- `Controller` 和 3A 算法；
- CamHelper 传感器适配；
- 大部分 tuning 文件结构。

## 6. 应用侧捕获流程

标准应用调用顺序：

```text
CameraManager::start
→ 取得 Camera
→ Camera::acquire
→ Camera::generateConfiguration
→ CameraConfiguration::validate
→ Camera::configure
→ FrameBufferAllocator::allocate
→ Camera::createRequest
→ Request::addBuffer
→ Camera::start
→ Camera::queueRequest
→ Camera::requestCompleted
→ Request::reuse
→ 再次 queueRequest
→ Camera::stop
→ Camera::release
```

建议先阅读：

- [`test/camera/capture.cpp`](../libcamera/test/camera/capture.cpp)
- [`Documentation/guides/application-developer.rst`](../libcamera/Documentation/guides/application-developer.rst)

公共 `Camera` API 并不直接访问硬件，而是通过 `Object::invokeMethod()` 将
操作切换到 CameraManager 线程：

- `configure/start/stop` 使用 blocking connection；
- `queueRequest` 使用 queued connection；
- V4L2 事件和 Pipeline 状态主要在 CameraManager 线程处理；
- Request 完成后通过 Signal 回调应用。

关键文件：

- [`src/libcamera/camera.cpp`](../libcamera/src/libcamera/camera.cpp)
- [`src/libcamera/pipeline_handler.cpp`](../libcamera/src/libcamera/pipeline_handler.cpp)

## 7. 一帧在 PiSP 中的完整流程

```text
应用提交 Request
    │
    ▼
Camera::queueRequest
    │ queued invoke
    ▼
PipelineHandler::queueRequest
    ├── Request prepare/fence
    ├── 分配 request sequence
    └── queueRequestDevice
    │
    ▼
RPi::PipelineHandlerBase::queueRequestDevice
    ├── 外部输出 buffer 放入各 Stream
    ├── Request 放入 requestQueue_
    └── handleState()
    │
    ▼
CFE 已经循环采集内部 buffer
    ├── Bayer
    ├── Stats
    └── Embedded metadata
    │
    ▼
PiSPCameraData::cfeBufferDequeue
    ├── 查询该帧实际生效的 sensor controls
    ├── 记录 sensor timestamp / wall clock
    └── 聚合为 CfeJob
    │
    ▼
PiSPCameraData::tryRunPipeline
    ├── 对齐 Request controls
    ├── 构造 PrepareParams
    └── ipa_->prepareIsp()
    │
    ▼
IpaBase::prepareIsp
    ├── applyControls()
    ├── 解析 embedded metadata
    ├── 填充 DeviceStatus
    ├── 对齐 delayed AGC/request metadata
    ├── processStats()
    │     ├── 解析 PiSP statistics
    │     ├── Controller::process()
    │     ├── 生成下一帧 exposure/gain
    │     └── emit setDelayedControls
    ├── Controller::prepare()
    ├── 生成 FE/BE ISP 参数
    └── emit prepareIspComplete
    │
    ▼
PiSPCameraData::prepareIspComplete
    ├── 将 Bayer 放入 PiSP Back End
    └── 设置 State::IpaComplete
    │
    ▼
PiSP BE 输出 buffer
    │
    ▼
PiSPCameraData::beOutputDequeue
    ├── 可选软件 downscale/格式转换
    └── completeBuffer
    │
    ▼
CameraData::checkRequestCompleted
    ├── 等待所有应用 buffer 完成
    ├── 等待 IPA metadata 完成
    └── PipelineHandler::completeRequest
    │
    ▼
Camera::requestCompleted
    │
    ▼
应用回调
```

关键入口：

- [`PipelineHandler::queueRequest()`](../libcamera/src/libcamera/pipeline_handler.cpp)
- [`PipelineHandlerBase::queueRequestDevice()`](../libcamera/src/libcamera/pipeline/rpi/common/pipeline_base.cpp)
- [`PiSPCameraData::cfeBufferDequeue()`](../libcamera/src/libcamera/pipeline/rpi/pisp/pisp.cpp)
- [`PiSPCameraData::tryRunPipeline()`](../libcamera/src/libcamera/pipeline/rpi/pisp/pisp.cpp)
- [`IpaBase::prepareIsp()`](../libcamera/src/ipa/rpi/common/ipa_base.cpp)
- [`IpaBase::processStats()`](../libcamera/src/ipa/rpi/common/ipa_base.cpp)
- [`CameraData::checkRequestCompleted()`](../libcamera/src/libcamera/pipeline/rpi/common/pipeline_base.cpp)

## 8. 最关键的难点：控制时序

曝光、增益、VBLANK 等传感器控制并不是写入后立即作用于同一帧。

真实关系类似：

```text
Request N 提交控制
    │
    ├── VBLANK 可能较早生效
    ├── Exposure 经过 exposureDelay
    └── Gain 经过 gainDelay
           │
           ▼
某个后续 Sensor Frame 实际使用这些值
           │
           ▼
DelayedControls 根据 V4L2 sequence 找回生效控制
           │
           ▼
与这一帧的 Bayer、Stats、IPA metadata 重新关联
```

相关实现：

- [`src/libcamera/pipeline/rpi/common/delayed_controls.cpp`](../libcamera/src/libcamera/pipeline/rpi/common/delayed_controls.cpp)
- [`src/libcamera/pipeline/rpi/common/pipeline_base.cpp`](../libcamera/src/libcamera/pipeline/rpi/common/pipeline_base.cpp)
- [`src/ipa/rpi/common/ipa_base.cpp`](../libcamera/src/ipa/rpi/common/ipa_base.cpp)

`delayContext`、`ipaContext`、`Request::sequence()` 和 V4L2 buffer sequence
表达的是不同但相关的时序。理解它们是掌握 RPi Pipeline 的核心。

## 9. IPA Controller 与 tuning

### 9.1 Controller 调度

Controller 从 tuning JSON 的 `algorithms` 列表创建算法：

```text
Controller::read
→ createAlgorithm
→ Algorithm::read
→ initialise
→ switchMode
→ 每帧 prepare
→ 每帧 process
```

代码：

- [`src/ipa/rpi/controller/controller.cpp`](../libcamera/src/ipa/rpi/controller/controller.cpp)
- [`src/ipa/rpi/controller/algorithm.cpp`](../libcamera/src/ipa/rpi/controller/algorithm.cpp)

算法通过静态 `RegisterAlgorithm` 注册，tuning JSON 中的名字决定实际创建
哪些算法。

### 9.2 prepare 与 process

- `process(stats, metadata)`：消费统计，计算 AGC、AWB、AF 等下一步结果；
- `prepare(metadata)`：把已有算法结果转换为当前帧需要的 ISP 参数。

PiSP 将统计标记为 `statsInline=true`，因此统计数据随 CFE Bayer 帧同时
可用，可以在 `prepareIsp()` 中先处理 stats，再准备 ISP。

### 9.3 tuning JSON

例如：

- [`src/ipa/rpi/pisp/data/imx708.json`](../libcamera/src/ipa/rpi/pisp/data/imx708.json)

主要包括：

- black level；
- lux estimation；
- defect pixel correction；
- noise model；
- green equalisation；
- spatial/temporal/chroma denoise；
- AWB priors 和色温曲线；
- AGC exposure modes、metering modes、constraints；
- ALSC lens shading；
- CCM；
- contrast/gamma；
- sharpen；
- autofocus；
- HDR、sync、tonemap 等。

### 9.4 CamHelper

CamHelper 处理传感器私有特性：

- 寄存器增益值和线性增益之间的换算；
- exposure lines 和真实曝光时间的换算；
- embedded metadata 解析；
- mode sensitivity；
- 启动或模式切换时需要隐藏、忽略的帧数；
- 特定传感器的控制延迟或特殊规则。

代码：

- [`src/ipa/rpi/cam_helper`](../libcamera/src/ipa/rpi/cam_helper)

## 10. 配置文件的不同职责

### 10.1 Pipeline YAML

示例：

- [`src/libcamera/pipeline/rpi/pisp/data/example.yaml`](../libcamera/src/libcamera/pipeline/rpi/pisp/data/example.yaml)

它控制 Pipeline 的资源和调度策略，例如：

- CFE config/stats buffer 数量；
- CFE 预排队 job 数量；
- camera timeout；
- 是否禁用 temporal denoise；
- 是否禁用 HDR；
- Controller 算法运行频率限制。

运行时可通过：

```bash
LIBCAMERA_RPI_CONFIG_FILE=/path/to/config.yaml
```

指定配置。

### 10.2 IPA tuning JSON

按 sensor model 自动选择，例如 `imx708.json`，主要控制图像算法参数。

### 10.3 Control YAML

定义对应用暴露的类型安全 API，并在构建时生成 C++、Python 和 GStreamer
代码。

不要将这三类文件混在一起理解：

```text
Pipeline YAML      → buffer、timeout、资源和调度
IPA tuning JSON    → 图像算法和画质参数
Control YAML       → 对应用暴露的 API 定义
```

## 11. 推荐阅读顺序

不要一开始钻进 AGC/AWB 数学实现。建议顺序如下：

1. [`Documentation/guides/application-developer.rst`](../libcamera/Documentation/guides/application-developer.rst)  
   建立应用侧对象模型。

2. [`test/camera/capture.cpp`](../libcamera/test/camera/capture.cpp)  
   阅读最短的完整捕获闭环。

3. [`meson.build`](../libcamera/meson.build) 和
   [`meson_options.txt`](../libcamera/meson_options.txt)  
   理解当前究竟编译了什么。

4. [`src/libcamera/camera_manager.cpp`](../libcamera/src/libcamera/camera_manager.cpp)  
   理解设备怎样变成 `Camera`。

5. [`src/libcamera/camera.cpp`](../libcamera/src/libcamera/camera.cpp) 和
   [`include/libcamera/internal/pipeline_handler.h`](../libcamera/include/libcamera/internal/pipeline_handler.h)  
   理解公共 API 如何委派给 Pipeline。

6. [`src/libcamera/pipeline_handler.cpp`](../libcamera/src/libcamera/pipeline_handler.cpp)  
   理解 Request 的准备、排序和完成。

7. [`src/libcamera/pipeline/rpi/common/pipeline_base.cpp`](../libcamera/src/libcamera/pipeline/rpi/common/pipeline_base.cpp)  
   理解 RPi 公共配置、启动、队列、控制时序和完成逻辑。

8. [`src/libcamera/pipeline/rpi/pisp/pisp.cpp`](../libcamera/src/libcamera/pipeline/rpi/pisp/pisp.cpp)  
   理解 Pi 5 硬件拓扑和每帧状态机。

9. [`include/libcamera/ipa/raspberrypi.mojom`](../libcamera/include/libcamera/ipa/raspberrypi.mojom)  
   理解 Pipeline/IPA 协议。

10. [`src/ipa/rpi/common/ipa_base.cpp`](../libcamera/src/ipa/rpi/common/ipa_base.cpp)  
    理解统计、controls、metadata 的流动。

11. [`src/ipa/rpi/controller/controller.cpp`](../libcamera/src/ipa/rpi/controller/controller.cpp)  
    理解算法调度。

12. 选择一个算法和一个 tuning JSON 深入研究。  
    推荐从 AGC 开始，因为它最能体现 sensor control 延迟和统计闭环。

补充文档：

- [`Documentation/guides/pipeline-handler.rst`](../libcamera/Documentation/guides/pipeline-handler.rst)
- [`Documentation/guides/ipa.rst`](../libcamera/Documentation/guides/ipa.rst)

## 12. 建议的构建验证方法

当前调研环境是 `x86_64`，没有安装 Meson/Ninja，也没有现成 build 目录，
因此本报告基于源码和构建定义的静态分析，尚未进行 Pi 5 硬件运行验证。

在具备依赖的 Pi 5 环境中，可以建立最小学习构建：

```bash
cd ~/workspace/raspi5/libcamera

meson setup build-pisp \
  -Dpipelines=rpi/pisp \
  -Dipas=rpi/pisp \
  -Dcam=enabled \
  -Dqcam=disabled \
  -Dgstreamer=disabled \
  -Dpycamera=disabled \
  -Dv4l2=disabled \
  -Dtest=false

meson configure build-pisp
meson introspect build-pisp --targets
ninja -C build-pisp
```

可进一步查看 Ninja 目标：

```bash
ninja -C build-pisp -t targets
```

如果安装了 Graphviz，可生成目标依赖图：

```bash
ninja -C build-pisp -t graph > /tmp/libcamera-build.dot
dot -Tsvg /tmp/libcamera-build.dot \
  -o /tmp/libcamera-build.svg
```

## 13. 建议的运行时验证方法

枚举相机：

```bash
LIBCAMERA_LOG_LEVELS='*:DEBUG' cam -l
```

捕获并重点查看 RPi Pipeline 和 IPA：

```bash
LIBCAMERA_LOG_LEVELS='RPI:DEBUG,IPARPI:DEBUG' \
cam -c 1 --capture=20
```

建议优先设置断点或增加日志的位置：

```text
CameraManager::Private::createPipelineHandlers
PipelineHandlerPiSP::match
PipelineHandlerBase::registerCamera
PipelineHandlerBase::configure
PipelineHandlerBase::start
PipelineHandlerBase::queueRequestDevice
PiSPCameraData::cfeBufferDequeue
PiSPCameraData::tryRunPipeline
IpaBase::prepareIsp
IpaBase::processStats
CameraData::metadataReady
CameraData::checkRequestCompleted
PipelineHandler::completeRequest
```

建议每条日志同时记录：

```text
Request sequence
V4L2 buffer sequence
IPA context
delay context
buffer ID/mask
sensor timestamp
pipeline state
```

这样可以把 Request、真实 sensor frame、controls 生效帧和 ISP 输出重新对应
起来。

## 14. 最终掌握目标

完成第一轮阅读后，应能够回答以下问题：

1. 为什么当前构建只包含 PiSP/VC4 Pipeline 和 IPA？
2. 一个 Media Controller sensor entity 如何变成应用可见的 `Camera`？
3. `Camera::queueRequest()` 为什么不直接调用 V4L2 `QBUF`？
4. Pipeline Handler、CameraData 和 IPA 分别保存什么状态？
5. Bayer、Stats、Embedded、ISP Config 和应用输出 buffer 如何流动？
6. 为什么 exposure/gain 要经过 `DelayedControls`？
7. `process()` 和 `prepare()` 分别为哪一帧服务？
8. Request 为什么必须同时等待 buffer 和 metadata？
9. Pipeline YAML、tuning JSON 和 Control YAML 的职责有什么不同？
10. PiSP 和 VC4 哪些代码共享，哪些是硬件相关的？

如果这些问题能够沿着代码给出答案，就已经掌握了这个仓库最核心的结构和
运行流程。剩余内容主要是其他平台 Pipeline、应用适配层，以及单个图像算法
的深入细节。
