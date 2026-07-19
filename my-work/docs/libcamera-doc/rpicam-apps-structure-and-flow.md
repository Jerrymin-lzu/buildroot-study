# rpicam-apps 仓库结构、构建体系与运行流程调研

> 调研对象：Raspberry Pi `rpicam-apps`  
> 项目版本：`v1.12.0`（`v1.12.0-9-gd34adeb`）  
> Commit：`d34adeb63c7eb4117efca8d4ed7969dd1b6492b5`  
> 调研日期：2026-07-19

## 1. 核心结论

掌握 `rpicam-apps` 最快的方法，同样不是逐目录平均阅读，而是同时沿着两条
主线追踪：

1. Meson 如何把公共 `librpicam_app`、应用、编码器、预览和后处理插件组装
   起来。
2. 一个 libcamera `Request` 完成后，如何被后处理、预览、编码和输出共同
   消费，最终在最后一个消费者释放时自动复用并重新入队。

这个仓库不是 libcamera 的另一个 Pipeline Handler，而是位于 libcamera
公共 API 之上的 Raspberry Pi 应用框架。它的核心价值是把相机配置、DMA-BUF
分配、Request 循环、预览、编码、文件/网络输出和后处理组织成可复用组件。

最重要的代码结构可以概括为：

```text
rpicam-hello / still / vid / raw / jpeg / detect
                    │
                    ▼
                RPiCamApp
       ┌────────────┼──────────────┐
       │            │              │
       ▼            ▼              ▼
  PostProcessor   Preview      RPiCamEncoder
       │            │              │
       │            │              ▼
       │            │        Encoder → Output
       │            │
       └────────────┴──────┐
                           ▼
              CompletedRequestPtr 生命周期
                           │
                           ▼
             libcamera Camera / Request / Stream
                           │
                           ▼
                 RPi PiSP 或 VC4 Pipeline
```

其中最值得优先理解的不是某个 JPEG 或 AI 算法，而是
[`CompletedRequest`](../rpicam-apps/core/completed_request.hpp)：

- libcamera 完成回调把原始 `Request` 包装为 `CompletedRequestPtr`；
- 后处理、应用消息、预览和编码都可以持有同一帧的 `shared_ptr`；
- 预览完成、编码输入释放、应用局部变量销毁都会各自释放引用；
- 最后一个引用释放时，自定义 deleter 调用 `RPiCamApp::queueRequest()`；
- 原 Request 被重新添加 buffers、合并新的 controls，再次提交给 libcamera。

这套引用计数机制同时承担了：

- buffer 所有权；
- 多消费者同步；
- 相机背压；
- Request 自动循环。

当前仓库约有：

- 151 个 Git 受控文件；
- 94 个 C++ 源文件/头文件；
- 约 1.90 万行 C++；
- 12 个 Meson 构建文件；
- 约 6928 行后处理 C++；
- 26 个后处理 JSON 资源文件。

对于 Raspberry Pi 5 还需要特别注意：PiSP 平台没有本仓库所使用的 VC4
V4L2 H.264 硬件编码路径。请求 `--codec h264` 时，代码会动态加载 libav
编码插件并回退到 `libx264`。因此 Pi 5 的默认 H.264 能力实际上依赖构建时
是否找到 libav 以及运行时是否有 `libx264`。

## 2. 从构建体系理解仓库

### 2.1 顶层构建顺序

顶层入口是 [`meson.build`](../rpicam-apps/meson.build)，主要执行顺序为：

```text
项目和编译选项
  → 查找 libcamera、dl
  → core
  → encoder
  → image
  → output
  → post_processing_stages
  → preview
  → utils
  → 生成 config.h
  → 生成 version.cpp
  → 构建 librpicam_app
  → apps
```

各子目录不是各自构建一套完全独立的库。大部分目录会持续向顶层的
`rpicam_app_src` 和 `rpicam_app_dep` 追加源文件与依赖，最后统一构成
`librpicam_app`：

```text
core/*.cpp
encoder/{encoder,h264,mjpeg,null}_encoder.cpp
image/{jpeg,png,bmp,yuv,dng}.cpp
output/*.cpp
post_processing_stages/{framework,helpers}.cpp
preview/{preview,null_preview}.cpp
generated version.cpp
                  │
                  ▼
            librpicam_app.so
                  │
                  ├── rpicam-hello
                  ├── rpicam-still
                  ├── rpicam-vid
                  ├── rpicam-raw
                  ├── rpicam-jpeg
                  └── rpicam-detect（仅启用 TFLite 时）
```

预览后端、libav 编码器和具体后处理 stage 则大多构建为运行时动态加载的
`.so`，避免把所有可选依赖直接链接进公共库。

### 2.2 主要构建产物

| 产物 | 作用 | 构建入口 |
|---|---|---|
| `librpicam_app.so` | 相机公共框架、buffer、基础编码/预览/输出、静态图像保存 | [`meson.build`](../rpicam-apps/meson.build) |
| `rpicam-hello` | 最短的预览和 Request 循环示例 | [`apps/rpicam_hello.cpp`](../rpicam-apps/apps/rpicam_hello.cpp) |
| `rpicam-still` | 完整静态图像、ZSL、timelapse、AF-on-capture | [`apps/rpicam_still.cpp`](../rpicam-apps/apps/rpicam_still.cpp) |
| `rpicam-vid` | 视频编码、暂停、分段、网络和音频 | [`apps/rpicam_vid.cpp`](../rpicam-apps/apps/rpicam_vid.cpp) |
| `rpicam-raw` | 将 Bayer raw stream 原样输出 | [`apps/rpicam_raw.cpp`](../rpicam-apps/apps/rpicam_raw.cpp) |
| `rpicam-jpeg` | 最小“预览后拍一张 JPEG”应用 | [`apps/rpicam_jpeg.cpp`](../rpicam-apps/apps/rpicam_jpeg.cpp) |
| `rpicam-detect` | TFLite 检测触发静态图像拍摄 | [`apps/rpicam_detect.cpp`](../rpicam-apps/apps/rpicam_detect.cpp) |
| `libav-encoder.so` | libav 视频/音频编码和容器封装 | [`encoder/meson.build`](../rpicam-apps/encoder/meson.build) |
| `core-postproc.so` | HDR、运动检测、负片、声音辅助对焦 | [`post_processing_stages/meson.build`](../rpicam-apps/post_processing_stages/meson.build) |
| `opencv-postproc.so` | 标注、绘制、模糊、Sobel、UDP 等 | 同上 |
| `tflite-postproc.so` | TFLite 分类、检测、姿态和分割 | 同上 |
| `hailo-postproc.so` | Hailo 推理和后处理 | [`post_processing_stages/hailo/meson.build`](../rpicam-apps/post_processing_stages/hailo/meson.build) |
| `imx500-postproc.so` | IMX500 网络输出解析 | [`post_processing_stages/imx500/meson.build`](../rpicam-apps/post_processing_stages/imx500/meson.build) |
| `drm-preview.so` | DRM/KMS 预览 | [`preview/meson.build`](../rpicam-apps/preview/meson.build) |
| `egl-preview.so` | X11/EGL 预览 | 同上 |
| `wayland-egl-preview.so` | 原生 Wayland/EGL 预览 | 同上 |
| `qt-preview.so` | Qt 预览 | 同上 |

### 2.3 必选依赖和可选功能

必选依赖包括：

- C++20；
- libcamera；
- `dl`；
- Boost `program_options`；
- pthread；
- libexif；
- libjpeg；
- libtiff；
- libpng。

构建选项位于 [`meson_options.txt`](../rpicam-apps/meson_options.txt)：

| 选项 | 默认 | 影响 |
|---|---|---|
| `enable_libav` | `auto` | libav 编码插件、容器和音频 |
| `enable_drm` | `auto` | DRM 预览 |
| `enable_egl` | `auto` | X11 EGL 预览 |
| `enable_wayland` | `auto` | Wayland EGL 预览 |
| `enable_qt` | `auto` | Qt5/Qt6 预览 |
| `enable_opencv` | `disabled` | OpenCV 后处理 |
| `enable_tflite` | `disabled` | TFLite 后处理及 `rpicam-detect` |
| `enable_hailo` | `auto` | HailoRT/Tappas 后处理；同时依赖 OpenCV |
| `enable_imx500` | `false` | IMX500 后处理 |
| `disable_rpi_features` | `false` | 禁用 RPi 私有同步 controls |
| `neon_flags` | `auto` | ARM NEON/向量化编译参数 |

`disable_rpi_features` 的名字容易产生误解。它主要屏蔽
`controls::rpi::SyncMode/SyncReady` 等私有同步功能，并不会把这个项目变成
通用 USB 摄像头应用；平台探测、DMA heap、Pi Pipeline controls 等整体设计
仍然明显面向 Raspberry Pi。

### 2.4 构建时代码生成

这个仓库的代码生成规模比 libcamera 小，但仍有三个关键生成点。

#### `config.h`

各子目录把安装目录和特性宏写入 `conf_data`：

```text
ENCODER_LIB_DIR
POSTPROC_LIB_DIR
PREVIEW_LIB_DIR
LIBAV_PRESENT
LIBDRM_PRESENT
LIBEGL_PRESENT
WAYLAND_PRESENT
QT_PRESENT
HAILORT_LIB_PATH
```

顶层随后生成 `config.h`。运行时的插件扫描默认目录来自这个文件，而不是
硬编码在 C++ 中。

#### `version.cpp`

[`utils/version.py`](../rpicam-apps/utils/version.py) 与 Meson `vcs_tag()` 共同
从项目版本、Git commit、dirty 状态和构建时间生成 `version.cpp`。
`rpicam-* --version` 会同时报告：

- rpicam-apps 构建版本；
- 已发现的预览/编码能力；
- libcamera 构建版本。

#### Wayland 协议代码

Wayland 预览会用 `wayland-scanner` 将：

```text
xdg-shell.xml
xdg-decoration-unstable-v1.xml
```

生成客户端 header 和 C glue，再构建为独立静态协议库，最终链接进
`wayland-egl-preview.so`。

### 2.5 动态模块和静态注册

三类扩展使用同一种模式：

```text
安装目录中的 *.so
  → DlLib / dlopen
  → 动态库全局构造函数运行
  → RegisterPreview / RegisterEncoder / RegisterStage
  → 名称到 Create 函数的全局 factory map
  → 根据 CLI 或 JSON 名称创建实例
```

关键实现：

- [`core/dl_lib.cpp`](../rpicam-apps/core/dl_lib.cpp)
- [`preview/preview.cpp`](../rpicam-apps/preview/preview.cpp)
- [`encoder/encoder.cpp`](../rpicam-apps/encoder/encoder.cpp)
- [`post_processing_stages/post_processing_stage.cpp`](../rpicam-apps/post_processing_stages/post_processing_stage.cpp)

默认安装目录是：

```text
${prefix}/${libdir}/rpicam-apps-preview
${prefix}/${libdir}/rpicam-apps-encoder
${prefix}/${libdir}/rpicam-apps-postproc
```

也可以通过 `--preview-libs`、`--encoder-libs` 和 `--post-process-libs`
覆盖。Hailo 是一个特殊情况：加载 Hailo 后处理模块前，代码会先以
`RTLD_GLOBAL | RTLD_NOW` 加载 `libhailort.so`，让插件能够解析所需符号。

## 3. 代码分层

### 3.1 应用入口层

[`apps`](../rpicam-apps/apps) 中的程序都遵循相同骨架：

```text
构造 RPiCamApp 或派生类
  → Options::Parse
  → 可选打印参数
  → event_loop
  → OpenCamera
  → Configure*
  → StartCamera
  → Wait 处理 Msg
  → 析构时兜底 Stop/Teardown/Close
```

| 应用 | 基类 | 配置 | 帧的主要去向 |
|---|---|---|---|
| `rpicam-hello` | `RPiCamApp` | Viewfinder | Preview |
| `rpicam-still` | `RPiCamApp` | Viewfinder/Still/ZSL | JPEG/PNG/BMP/YUV/DNG |
| `rpicam-jpeg` | `RPiCamApp` | Viewfinder → Still | JPEG |
| `rpicam-vid` | `RPiCamEncoder` | Video | Encoder → Output，同时 Preview |
| `rpicam-raw` | `RPiCamEncoder` | Video + Raw | NullEncoder → Output |
| `rpicam-detect` | `RPiCamApp` | Viewfinder → Still | 后处理 metadata 触发 JPEG |

应用层主要负责“什么时候结束、什么时候拍照、选择哪条 stream”，而不直接
管理 Request 和 buffer。

### 3.2 `RPiCamApp` 公共核心层

核心文件：

- [`core/rpicam_app.hpp`](../rpicam-apps/core/rpicam_app.hpp)
- [`core/rpicam_app.cpp`](../rpicam-apps/core/rpicam_app.cpp)

主要对象：

| 对象/成员 | 作用 |
|---|---|
| `CameraManager` | 启动 libcamera、枚举相机 |
| `Camera` | acquire/configure/start/queue/stop |
| `CameraConfiguration` | 当前 use case 的多流配置 |
| `frame_buffers_` | 每条 Stream 的外部分配 FrameBuffer |
| `mapped_buffers_` | FrameBuffer 到 mmap spans 的映射 |
| `requests_` | 循环使用的 libcamera Requests |
| `completed_requests_` | 尚被一个或多个消费者持有的完成帧 |
| `MessageQueue<Msg>` | libcamera/后处理线程到应用 event loop 的线程安全队列 |
| `controls_` | 下一次 start 或下一次可回收 Request 要应用的 controls |
| `PostProcessor` | 完成帧进入应用前的 stage pipeline |
| `Preview` | 异步预览后端 |

`RPiCamApp` 向应用暴露的核心操作是：

```text
OpenCamera / CloseCamera
ConfigureViewfinder / ConfigureStill / ConfigureVideo / ConfigureZsl
StartCamera / StopCamera / Teardown
Wait / ShowPreview / SetControls
ViewfinderStream / StillStream / VideoStream / RawStream / LoresStream
```

### 3.3 帧结果和 metadata 层

[`CompletedRequest`](../rpicam-apps/core/completed_request.hpp) 保存：

```text
应用 sequence
Request::BufferMap 的副本
libcamera ControlList metadata 的副本
原始 Request 指针
瞬时帧率
后处理 Metadata
```

这里存在两类 metadata：

1. `libcamera::ControlList metadata`  
   来自 Pipeline/IPA，包括曝光、增益、时间戳、AF 状态等类型安全 controls。

2. `Metadata post_process_metadata`  
   rpicam-apps 自己的 `string → std::any` 线程安全容器，用于 stage 间交换
   检测框、分类结果、标注文字、运动检测结果等。

[`FrameInfo`](../rpicam-apps/core/frame_info.hpp) 将常用 libcamera metadata
解析为 `%frame`、`%fps`、`%exp`、`%ag`、`%afstate` 等预览文字 token。

### 3.4 编码、输出和静态图像层

视频路径被有意拆为两层：

```text
Encoder
  → 把 YUV/Bayer 输入变成 H.264、MJPEG、libav packet 或原始数据

Output
  → 处理暂停、等待关键帧、时间戳连续性、文件、网络、分段和环形缓冲
```

编码器：

- [`H264Encoder`](../rpicam-apps/encoder/h264_encoder.cpp)：VC4 的
  `/dev/video11` V4L2 M2M 硬件编码；
- [`MjpegEncoder`](../rpicam-apps/encoder/mjpeg_encoder.cpp)：4 个 CPU 编码
  线程，并用输出线程恢复帧顺序；
- [`NullEncoder`](../rpicam-apps/encoder/null_encoder.cpp)：不编码，仅异步
  转发原始 buffer；
- [`LibAvEncoder`](../rpicam-apps/encoder/libav_encoder.cpp)：libav codec、
  mux、网络 URL 和可选音频。

输出器：

- [`FileOutput`](../rpicam-apps/output/file_output.cpp)：文件/stdout、split、
  segment、wrap；
- [`NetOutput`](../rpicam-apps/output/net_output.cpp)：TCP/UDP socket；
- [`CircularOutput`](../rpicam-apps/output/circular_output.cpp)：内存环形缓存，
  析构时从第一个关键帧起写盘；
- [`Output`](../rpicam-apps/output/output.cpp)：无输出或作为公共状态机基类。

静态图像不经过 `Encoder/Output` 抽象，而是直接调用
[`image`](../rpicam-apps/image) 中的函数：

| 格式 | 实现 | 关键行为 |
|---|---|---|
| JPEG | `jpeg.cpp` | YUV 编码、缩略图、EXIF、曝光/增益 metadata |
| PNG | `png.cpp` | BGR/RGB 数据写 PNG |
| BMP | `bmp.cpp` | RGB 数据写 BMP |
| YUV/RGB 原始文件 | `yuv.cpp` | 按 stride 去 padding 后写出 |
| DNG | `dng.cpp` | Bayer unpack、PiSP 压缩解码、TIFF/DNG tags |

### 3.5 后处理层

后处理由三部分构成：

```text
PostProcessor
  → 读取 JSON、创建 stage、调度每帧和保持输出顺序

PostProcessingStage
  → Read / AdjustConfig / Configure / Start / Process / Stop / Teardown

具体 stages
  → 修改图像 buffer、生成 metadata、丢弃帧或触发外部动作
```

后处理 stage 可分为：

- 基础：HDR、运动检测、负片、声音对焦；
- OpenCV：Sobel、face detect、标注、检测框绘制、对象模糊、UDP；
- TFLite：分类、对象检测、姿态、语义分割；
- Hailo：YOLO、分类、姿态、分割、SCRFD；
- IMX500：读取 sensor/firmware 产生的推理 metadata。

### 3.6 与 libcamera 的边界

rpicam-apps 使用 libcamera 公共 API：

```text
CameraManager
Camera
CameraConfiguration / StreamConfiguration
Stream / FrameBuffer / Request
ControlList / properties / controls
```

它不直接调用 PiSP/VC4 Pipeline Handler，但仍有少量平台相关操作：

- 扫描 `/dev/video*` 判断 VC4、PiSP 或 legacy stack；
- 过滤 USB camera；
- 使用 Raspberry Pi DMA heap；
- VC4 时选择 `rpi_apps.yaml`；
- 使用 `controls::rpi::ScalerCrops` 和相机同步 controls；
- 为 IMX708 sensor HDR 直接操作 V4L2 subdevice；
- VC4 硬件 H.264 编码器固定打开 `/dev/video11`。

所以准确的边界是：

```text
相机采集和 ISP     → 通过 libcamera
应用 buffer 管理   → rpicam-apps 自己完成
视频 H.264 编码    → VC4 时直接使用独立 V4L2 codec；PiSP 时通常使用 libav
少量平台开关       → sysfs/V4L2 subdevice/RPi 私有 controls
```

## 4. 启动、平台探测与相机发现流程

启动主流程：

```text
main
  → 构造 RPiCamApp
      → 构造 Options
          → get_platform()
              → 扫描 /dev/video0..255
              → VIDIOC_QUERYCAP
              → bcm2835-isp = VC4
              → pispbe = PISP
              → bm2835 mmal = legacy
      → legacy/unknown 平台直接报错
      → 可选设置 VC4 LIBCAMERA_RPI_CONFIG_FILE
  → Options::Parse
      → 解析 CLI
      → 解析 --config 文件
      → 解析时间、mode、ROI、AF、AWB 等
      → 可选设置 LIBCAMERA_RPI_TUNING_FILE
      → RPiCamApp::initCameraManager()
      → CameraManager::start()
      → 枚举并排序 Raspberry Pi cameras
      → 可选处理 IMX708 sensor HDR
  → event_loop
      → RPiCamApp::OpenCamera()
          → 加载并选择 Preview
          → 选择 --camera 索引
          → Camera::acquire()
          → 加载后处理插件和 JSON
          → 枚举 Raw sensor modes
```

关键入口：

- [`get_platform()`](../rpicam-apps/core/options.cpp)
- [`Options::Parse()`](../rpicam-apps/core/options.cpp)
- [`OptsInternal::Parse()`](../rpicam-apps/core/options.cpp)
- [`RPiCamApp::initCameraManager()`](../rpicam-apps/core/rpicam_app.cpp)
- [`RPiCamApp::OpenCamera()`](../rpicam-apps/core/rpicam_app.cpp)

相机列表还有两条应用策略：

```text
id 含 "/usb" → 从列表中删除
剩余 camera  → 按 id 降序排序，再用 --camera 索引选择
```

因此 `--camera N` 是 rpicam-apps 自己排序后的索引，不应假设等于
`/dev/videoN`。

### 4.1 IMX708 sensor HDR 特例

`--hdr sensor` 或 `--hdr auto` 对 IMX708 的处理发生在正式 OpenCamera
之前：

```text
扫描 /sys/class/video4linux/v4l-subdev*
  → 识别 imx708 driver module 和目标 camera id
  → 打开 /dev/v4l-subdevN
  → V4L2_CID_WIDE_DYNAMIC_RANGE
  → 如果值改变，重建 CameraManager 并重新枚举
```

这是因为 sensor HDR 会改变可见模式，必须在 libcamera 最终枚举/配置前生效。
`--hdr single-exp` 则是 libcamera/PiSP control，不走这条 subdevice 路径。

### 4.2 sensor mode 枚举和选择

`OpenCamera()` 生成一个 Raw configuration，遍历所有 Bayer pixel format 和
size，形成 `sensor_modes_`。

如果用户显式设置帧率，还会逐个临时 validate/configure mode，从
`FrameDurationLimits.min` 计算该模式最高 fps。最终配置时，
`selectMode()` 按以下因素打分：

```text
宽度差
+ 高度差
+ 宽高比惩罚
+ bit depth 惩罚
+ 不能达到目标 fps 的惩罚
```

选择结果再写入：

```text
Raw StreamConfiguration
CameraConfiguration::sensorConfig.outputSize
CameraConfiguration::sensorConfig.bitDepth
```

应用只指定宽高时，并不是简单地要求一个输出分辨率；raw stream 和
`sensorConfig` 还会影响 Pipeline 最终选择哪种 sensor readout mode。

## 5. Stream 配置与 DMA-BUF 拓扑

### 5.1 四种配置模式

| 配置函数 | StreamRoles | 应用可见名字 | 典型用途 |
|---|---|---|---|
| `ConfigureViewfinder` | Viewfinder + 可选 Viewfinder(lores) + Raw | `viewfinder`、`lores`、`raw` | 预览/分析 |
| `ConfigureStill` | StillCapture + Raw | `still`、`raw` | 单张高质量拍摄 |
| `ConfigureVideo` | VideoRecording + Raw + 可选 Viewfinder(lores) | `video`、`raw`、`lores` | 视频编码 |
| `ConfigureZsl` | StillCapture + Viewfinder + Raw | `still`、`viewfinder`、`raw` | 不重配的静态图像捕获 |

除非使用 `--no-raw`，常规 viewfinder/video 也会请求 raw stream。它不仅用于
保存 Bayer，还用于明确 sensor mode，并使各 stream 使用同一个 Request
时序。

主要默认格式：

```text
viewfinder/video/lores → YUV420
still                  → YUV420、BGR888、RGB888、BGR161616 或 RGB161616
raw                    → Pipeline 接受的 Bayer packed/unpacked/PiSP compressed
```

视频色彩空间按输出选择：

- MJPEG/YUV420：sYCC；
- 720p 及以上：Rec.709；
- 较小视频：SMPTE 170M。

Still 使用 sYCC。Preview 后端当前只接受 YUV420。

### 5.2 配置阶段顺序

每个 `Configure*()` 最终都遵循：

```text
Camera::generateConfiguration(StreamRoles)
  → 覆盖 pixelFormat/size/bufferCount/colorSpace/orientation
  → 可选选择 raw sensor mode
  → PostProcessor::AdjustConfig(use_case, main_config)
  → 设置 denoise control
  → setupCapture()
      → CameraConfiguration::validate()
      → Camera::configure()
      → 为每条 stream 分配 DMA-BUF
      → mmap
      → 启动 preview thread
  → 建立 "viewfinder"/"video"/"still"/"raw"/"lores" 名称映射
  → PostProcessor::Configure()
```

后处理的 `AdjustConfig()` 发生在 libcamera validate/configure 之前，所以
stage 可以修改主 stream 格式或尺寸。`Configure()` 则发生在最终 stream
指针已经可用之后。

### 5.3 外部 buffer 分配

rpicam-apps 没有使用 `libcamera::FrameBufferAllocator`。它自行从：

```text
/dev/dma_heap/vidbuf_cached
  → 不存在时回退 /dev/dma_heap/linux,cma
```

分配每条 stream 的 `config.frameSize`，然后：

```text
DMA_HEAP_IOCTL_ALLOC
  → DMA_BUF_SET_NAME
  → 构造单 plane FrameBuffer
  → mmap(PROT_READ | PROT_WRITE, MAP_SHARED)
  → 保存 FrameBuffer → Span 映射
```

关键实现：

- [`core/dma_heaps.cpp`](../rpicam-apps/core/dma_heaps.cpp)
- [`RPiCamApp::setupCapture()`](../rpicam-apps/core/rpicam_app.cpp)
- [`core/buffer_sync.cpp`](../rpicam-apps/core/buffer_sync.cpp)

YUV420 虽然逻辑上有 Y/U/V 三个平面，但这里位于一个连续 DMA-BUF 中，使用
一个 FrameBuffer plane；U/V 地址由 stride 和 height 计算。

### 5.4 Request 组装

`makeRequests()` 为每条 stream 建立 free buffer queue，并按轮次从每条
stream 取出一个 buffer 加入同一个 Request：

```text
Request 0 = video[0] + raw[0] + lores[0]
Request 1 = video[1] + raw[1] + lores[1]
...
```

第一条 stream 的 buffer 数决定 Request 数。其他并发 stream 如果提前耗尽，
代码会报：

```text
concurrent streams need matching numbers of buffers
```

因此配置函数会主动把 raw/lores/viewfinder 的 `bufferCount` 对齐主 stream。
视频主 stream 默认使用 6 个 buffer，以容纳编码和预览的异步延迟。

## 6. 各应用的运行流程

### 6.1 最短捕获闭环：`rpicam-hello`

```text
OpenCamera
→ ConfigureViewfinder
→ StartCamera
→ Wait(RequestComplete)
→ ShowPreview
→ CompletedRequestPtr 最终释放
→ Request 自动复用
→ 到 timeout 或 preview Quit
```

收到 `Timeout` 时，应用不重做配置和 buffer，只执行：

```text
StopCamera → StartCamera
```

这也是理解公共框架最短的入口。

### 6.2 视频：`rpicam-vid`

```text
创建 Output
→ 注册 encoded output/metadata callbacks
→ OpenCamera
→ ConfigureVideo
→ StartEncoder
→ StartCamera
→ 每个 RequestComplete
     ├── 处理 keypress/signal
     ├── EncodeBuffer(video stream)
     └── ShowPreview(video stream)
→ timeout/frames/signal
→ StopCamera
→ StopEncoder
```

暂停/恢复并不停止 Camera 或 Encoder。`Output::Signal()` 只切换是否接收编码
输出；恢复时等待下一个关键帧，再从该点开始写出，并调整 timestamp offset
保持输出时间连续。

### 6.3 静态图像：`rpicam-still`

`rpicam-still` 是仓库里最复杂的应用状态机：

```text
普通模式
  Viewfinder
    → timeout / key / signal / timelapse
    → 可选触发 AF scan 并等待完成
    → StopCamera
    → Teardown
    → ConfigureStill
    → StartCamera
    → 收到 Still frame
    → StopCamera
    → JPEG/PNG/BMP/YUV + 可选 DNG/metadata
    → 单拍退出，或重新配置 Viewfinder

--immediate
  直接 ConfigureStill，不先预览

--zsl
  ConfigureZsl 同时保留 still + viewfinder
    → 预览阶段已经持续产生完整 still buffer
    → 触发时直接保存当前同步 Request 中的 still
    → 不 Stop/Teardown/Configure
```

ZSL 的代价是持续使用 still capture 配置和更大的 buffers，收益是避免 mode
switch 和重新启动 Pipeline，也能让 PiSP temporal denoise 保持历史。

### 6.4 `rpicam-jpeg`

这是比 `rpicam-still` 更小的模式切换示例：

```text
Viewfinder 跑到 timeout
  → Stop/Teardown
  → ConfigureStill/Start
  → 收到第一张 still
  → Stop
  → jpeg_save
  → 退出
```

它不实现 ZSL、timelapse、keypress 和复杂 AF 捕获状态。

### 6.5 `rpicam-raw`

`rpicam-raw` 复用整个视频管线，但：

```text
ConfigureVideo
  → 取得 RawStream
NullEncoder
  → 不改变 buffer 内容
Output
  → 写出连续 Bayer frames
```

应用强制：

```text
codec = yuv420
denoise = cdn_off
nopreview = true
```

这里的 `yuv420` 仅用于选择 NullEncoder；真正交给它的是 raw stream，输出
仍然是 sensor Bayer/PiSP raw 格式。

### 6.6 `rpicam-detect`

这个目标只在启用 TFLite 时构建。其流程是：

```text
Viewfinder + PostProcessor
  → object_detect_tf 产生 object_detect.results
  → event loop 检查目标名字和最小帧间隔
  → 命中后 Stop/Teardown
  → ConfigureStill/Start
  → 保存 JPEG
  → 回到 Viewfinder
```

检测结果不是 libcamera metadata，而是
`CompletedRequest::post_process_metadata` 中的 `std::vector<Detection>`。

## 7. 一帧视频的完整流程

下面按启用后处理、预览和编码的 `rpicam-vid` 路径追踪一帧：

```text
libcamera Pipeline 完成 Request
    │
    ▼
RPiCamApp::requestComplete(Request *)
    ├── 检查 RequestCancelled → Timeout
    ├── 对每个 DMA-BUF 执行 DMA_BUF_SYNC_START | READ
    ├── 复制 BufferMap 和 libcamera metadata
    ├── Request::reuse()
    ├── 创建 CompletedRequest
    ├── 创建带自定义 deleter 的 CompletedRequestPtr
    ├── 计算 SensorTimestamp 对应的瞬时 fps
    └── PostProcessor::Process(payload)
    │
    ▼
PostProcessor
    ├── 无 stages：直接 callback
    └── 有 stages：
          ├── 每帧启动一个 worker
          ├── 同一帧内按 JSON 顺序运行 stage->Process()
          ├── 不同帧可以并行
          └── outputThread 按输入顺序等待 futures
    │
    ▼
PostProcessor callback
    └── Msg(RequestComplete, payload) → MessageQueue
    │
    ▼
rpicam-vid event_loop / app.Wait()
    ├── RPiCamEncoder::EncodeBuffer(payload, VideoStream)
    │     ├── BufferReadSync
    │     ├── 选择 FrameWallClock 或 buffer timestamp
    │     ├── encode_buffer_queue_ 持有一个 shared_ptr 引用
    │     └── Encoder::EncodeBuffer(fd, size, mem, info, timestamp)
    │
    └── RPiCamApp::ShowPreview(payload, VideoStream)
          ├── preview 空闲：preview_item_ 持有一个 shared_ptr 引用
          └── preview 忙：只丢这一帧的预览，不阻塞编码
    │
    ├───────────────────────────────┐
    ▼                               ▼
Encoder 路径                    Preview thread
    │                               ├── BufferReadSync
    │                               ├── FrameInfo
    │                               ├── preview_completed_requests_[fd]
    │                               │   持有 shared_ptr
    │                               └── Preview::Show(fd, span, info)
    │
    ▼                               ▼
Encoder input done              Preview backend done
    ├── 可选 MetadataReady          └── done_callback(fd)
    └── encode queue pop                └── map erase，释放引用
        释放 shared_ptr 引用
    │
    ▼
Encoder output ready
    └── Output::OutputReady
          ├── pause/keyframe/restart 状态
          ├── timestamp offset
          ├── File/Net/Circular output
          ├── PTS
          └── metadata
    │
    ▼
应用 msg、后处理、预览、编码持有的引用全部释放
    │
    ▼
CompletedRequestPtr 自定义 deleter
    │
    ▼
RPiCamApp::queueRequest(CompletedRequest *)
    ├── 取回 BufferMap
    ├── 确认 completed_requests_ 中仍存在且 camera_started_
    ├── DMA_BUF_SYNC_END | READ
    ├── Request::addBuffer 恢复所有 stream buffers
    ├── 合并 SetControls 暂存的 controls
    └── Camera::queueRequest
```

关键入口：

- [`RPiCamApp::requestComplete()`](../rpicam-apps/core/rpicam_app.cpp)
- [`PostProcessor::Process()`](../rpicam-apps/core/post_processor.cpp)
- [`RPiCamEncoder::EncodeBuffer()`](../rpicam-apps/core/rpicam_encoder.hpp)
- [`RPiCamApp::ShowPreview()`](../rpicam-apps/core/rpicam_app.cpp)
- [`RPiCamApp::previewThread()`](../rpicam-apps/core/rpicam_app.cpp)
- [`RPiCamApp::queueRequest()`](../rpicam-apps/core/rpicam_app.cpp)
- [`Output::OutputReady()`](../rpicam-apps/output/output.cpp)

### 7.1 H.264 编码内部流程

VC4 的 `H264Encoder` 使用 V4L2 M2M 两个 queue：

```text
Camera YUV DMA-BUF
  → VIDEO_OUTPUT_MPLANE / V4L2_MEMORY_DMABUF
  → /dev/video11 codec
  → VIDEO_CAPTURE_MPLANE / V4L2_MEMORY_MMAP
  → encoded H.264 buffer
```

线程关系：

```text
应用线程 EncodeBuffer
  → QBUF codec input

pollThread
  ├── DQBUF input
  │     → input_done_callback
  │     → 释放 camera frame 引用
  └── DQBUF encoded capture
        → output_queue

outputThread
  → output_ready_callback
  → Output 写文件/网络
  → 重新 QBUF encoded capture buffer
```

相机 buffer 可以在编码后的 bitstream 尚未写完之前释放，因为 codec 已经
完成输入 DMA-BUF 的读取。

### 7.2 MJPEG 和 libav 的区别

MJPEG：

```text
4 个 encodeThread 并行 JPEG
  → 每帧带单调 index
  → outputThread 找到下一个 index
  → 恢复原始帧顺序
```

libav：

```text
Camera DMA-BUF/内存
  → AVFrame
  → videoThread
  → AVCodec
  → elementary H.264 时回调 Output
  → 容器/音视频时由 AVFormatContext 直接 mux/write
```

如果 codec 使用 `AV_PIX_FMT_DRM_PRIME`，AVFrame 保存
`AVDRMFrameDescriptor` 并引用 DMA-BUF fd；否则 AVBuffer 直接包装 mmap
内存。二者都通过 `releaseBuffer()` 通知相机输入 buffer 已可复用。

音频由独立 `audioThread`：

```text
Pulse/ALSA input
  → decode
  → swresample
  → AVAudioFifo
  → audio encode
  → 按 video_start_ts 和 --av-sync 对齐
  → mux
```

## 8. 最关键的难点：帧生命周期、线程与控制时序

### 8.1 `CompletedRequestPtr` 才是真正的 buffer owner

libcamera 发出完成 signal 时，硬件已经完成该 Request，但应用 buffer 仍不
能马上重新提交，因为：

- 后处理可能正在读写；
- preview backend 可能仍在扫描显示；
- encoder 可能仍在 DMA 读取；
- 应用可能正在保存 still image。

`CompletedRequestPtr` 将这些消费者统一为引用计数：

```text
引用数 > 0
  → 至少一个消费者仍可能访问 buffer
  → Request 不可重新入队

引用数 == 0
  → 自定义 deleter
  → queueRequest
  → buffer 重新交给 camera
```

所以调用代码不需要显式“return buffer”。只要不再保留
`CompletedRequestPtr`，buffer 就会自然回到相机。

### 8.2 线程模型

| 执行上下文 | 主要工作 |
|---|---|
| libcamera CameraManager 线程 | `requestComplete()` signal callback |
| 应用主线程 | `Wait()`、状态机、保存图像、发起 preview/encode |
| 每帧 detached 后处理 worker | 顺序运行该帧所有 stages |
| PostProcessor output thread | 等待 futures，恢复完成帧顺序并投递消息 |
| Preview thread | 选择预览帧、构造 FrameInfo、调用后端 |
| Preview backend 内部线程/事件 | 显示完成后归还 fd |
| Encoder poll/encode/video threads | 消费相机输入、产生编码输出 |
| Encoder output thread | 调用 Output |
| libav audio thread | 音频捕获、重采样、编码 |

`queueRequest()` 可能由上述任何一个最后释放 shared pointer 的线程触发，
所以它用：

- `camera_stop_mutex_` 防止与 StopCamera 并发；
- `completed_requests_mutex_` 管理仍有效的完成帧；
- `control_mutex_` 合并运行时 controls。

### 8.3 引用计数形成自然背压

如果预览、后处理、编码或文件写入变慢，完成帧会更久地持有 camera buffer，
可重新提交的 Request 减少，最终让采集速度自然受限。

不同路径对背压的策略并不相同：

- preview 只有一个待处理 `preview_item_`，忙时丢预览，不额外阻塞相机；
- encoder queue 会持有每个已提交输入帧；
- postprocessor 可并行处理不同帧，但按原顺序输出；
- still 保存函数同步执行，因此保存结束前该帧不会回收；
- buffer 数量是系统允许的最大 in-flight 深度。

这解释了为什么 video 默认使用 6 个 buffers，以及为什么增加 buffer count
只能吸收短期抖动，不能解决持续低于实时速度的消费者。

### 8.4 DMA cache coherency

CPU 和设备共享 DMA-BUF 时，代码显式维护同步区间：

```text
Request 完成
  → DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ
  → CPU/postprocess/encoder/preview 访问

最后一个消费者释放
  → DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ
  → buffer 再次交给 camera
```

只读代码使用 `BufferReadSync` 获取 mmap spans；修改图像的 stage 使用
`BufferWriteSync`，其作用域执行 `START/END | DMA_BUF_SYNC_RW`。

忽略这层同步可能在 cache-coherent 表现较好的机器上暂时“能用”，但不代表
DMA buffer 生命周期正确。

### 8.5 Stop、Teardown 和旧帧

停止流程必须允许应用仍持有旧 `CompletedRequestPtr`：

```text
StopCamera
  → camera_->stop()
  → PostProcessor::Stop()
  → camera_started_ = false
  → disconnect requestCompleted
  → completed_requests_.clear()
  → msg queue clear
  → requests_.clear()

旧 CompletedRequestPtr 之后释放
  → queueRequest()
  → 找不到 completed_requests_ 记录或 camera 未启动
  → 删除包装对象，但不重新提交 Request
```

只有 `Teardown()` 才会停止 preview thread、unmap buffers、清空
configuration 和 stream maps。普通 timeout restart 只 Stop/Start，因而可以
复用同一配置和 buffers；viewfinder/still mode switch 则必须
Stop → Teardown → Configure。

### 8.6 Controls 何时生效

Controls 分两类进入相机：

```text
StartCamera 前积累的 controls_
  → Camera::start(&controls_)

运行时 SetControls()
  → 暂存在 controls_
  → 下一次某个 CompletedRequest 最终释放
  → queueRequest()
  → merge 到这个可复用 Request
  → Camera::queueRequest()
```

由于已经有多个 Requests in flight，“下一次回收的 Request”不等于
“调用 SetControls 后紧邻的 sensor frame”。而曝光、增益等在 libcamera
Pipeline 内部还会经历 sensor control delay。

因此完整时序是：

```text
应用 SetControls
  → 某个可用 Request 携带 controls 入队
  → libcamera Request sequence
  → Pipeline/IPA 延迟控制
  → 某个后续 sensor frame 实际生效
  → 完成帧 metadata 报告实际结果
```

调试动态 controls 时，应同时记录 rpicam-apps `CompletedRequest::sequence`、
libcamera metadata 中的 `SensorTimestamp`、请求携带的 control 和完成
metadata，而不能只按应用循环次数推断。

## 9. Preview、后处理、Encoder 与 Output 的调度

### 9.1 Preview backend 选择

`make_preview()` 先加载所有 preview `.so`，再按以下策略选择：

```text
--nopreview
  → NullPreview

--preview-backend NAME
  → 只尝试 NAME

自动模式且 WAYLAND_DISPLAY 非空
  → wayland-egl → egl → drm

自动模式且非 Wayland
  → egl → drm

所有后端失败
  → NullPreview
```

`--qt-preview` 会被解析成 `--preview-backend qt`。Qt 不在自动候选列表中。

Preview 的重要契约是：

```text
Show(fd, span, info)
  → backend 可以异步持有 fd
  → 显示结束必须 done_callback(fd)
  → RPiCamApp 才释放该帧引用
```

NullPreview 在 `Show()` 内立即回调。DRM/EGL/Wayland/Qt 则在替换或完成显示
后回调。

### 9.2 后处理配置和执行顺序

后处理 JSON 顶层 key 的顺序决定 stage 顺序。例如：

```json
{
    "object_detect_tf": {
        "model_file": "...",
        "labels_file": "..."
    },
    "object_detect_draw_cv": {
        "line_thickness": 2
    },
    "annotate_cv": {
        "text": "%frame"
    }
}
```

执行关系是：

```text
object_detect_tf
  → post_process_metadata["object_detect.results"]
  → object_detect_draw_cv 读取结果并修改主图像
  → annotate_cv 再绘制文字
```

同一帧内 stages 串行，因而 metadata 生产者必须写在消费者之前。不同帧的
整条 stage chain 可以并行。

配置生命周期：

```text
Read(JSON)
  → 一次，读取 stage 参数

AdjustConfig(use_case, config)
  → 每次 Configure*，可改变主 stream 配置

Configure()
  → 最终 stream 已建立，缓存 stream/info

Start()
  → 每次 Camera start

Process(completed_request)
  → 每帧

Stop()
  → 每次 Camera stop

Teardown()
  → configuration/buffer 即将销毁
```

Stage 的 `Process()` 返回 `true` 表示丢弃整帧。PostProcessor 会停止运行
该帧后续 stages，并且不向应用消息队列投递；shared pointer 最终释放后
Request 仍会正常回收。

### 9.3 `rpicam-apps` JSON 中的 lores 请求

后处理 JSON 可包含特殊顶层对象：

```json
{
    "rpicam-apps": {
        "lores": {
            "width": 400,
            "height": 300,
            "format": "yuv420",
            "par": false
        }
    }
}
```

它不创建 stage，而是在 OpenCamera 阶段回写 Options，要求后续
`ConfigureViewfinder/Video` 创建 lores stream。支持格式包括 YUV420 和
RGB/BGR 映射。TensorFlow、运动检测、face detect 等 stage 通常消费 lores，
主 stream 仍用于预览、编码或绘制。

### 9.4 Encoder 选择

`Encoder::Create()` 的实际选择逻辑：

```text
codec=yuv420
  → NullEncoder

codec=mjpeg
  → MjpegEncoder

codec=h264 + VC4
  → H264Encoder (/dev/video11)

codec=h264 + PiSP
  → LibAvEncoder + libx264

codec=libav
  → LibAvEncoder
     ├── VC4 可用 h264_v4l2m2m
     └── 非 VC4 时默认 h264_v4l2m2m 被改为 libx264
```

这条平台分支位于
[`encoder/encoder.cpp`](../rpicam-apps/encoder/encoder.cpp)，不是
libcamera Pipeline 内部行为。

### 9.5 Output 状态机

`Output::OutputReady()` 的状态是：

```text
DISABLED
  → pause 或 signal 后不输出

WAITING_KEYFRAME
  → 初始状态或 pause 恢复
  → 丢弃非关键帧

RUNNING
  → 从关键帧开始输出
```

从 pause 恢复时标记 `FLAG_RESTART`：

- FileOutput 可因 `--split` 打开新文件；
- 时间戳减去 pause 期间的 offset，保持连续；
- segment 只在关键帧边界切换；
- CircularOutput 保存每帧长度、关键帧和 timestamp，退出时跳到首个可解码
  关键帧。

libav 非 elementary stream 是一个例外：packet 在 `LibAvEncoder` 内部直接
进入 AVFormat muxer，因此 circular、segment、save-pts、split 和 pause
等基于 `Output` 的功能会被明确拒绝。H.264 elementary stream 仍走 Output。

## 10. 配置文件和环境变量的不同职责

### 10.1 CLI 和 `--config`

[`Options`](../rpicam-apps/core/options.hpp) 使用 Boost Program Options。
命令行先解析，`--config` 指向的文本文件随后读取；重复参数由 variables map
和命令行值规则合并。

它负责：

- 应用行为：timeout、输出、keypress、timelapse、segment；
- stream：尺寸、mode、buffer count、lores；
- controls：曝光、增益、AWB、AF、ROI、色彩、HDR；
- backend：preview、encoder、postprocess library path；
- 编码：codec、bitrate、profile、level、audio。

### 10.2 后处理 JSON

[`assets`](../rpicam-apps/assets) 中的 JSON：

- 决定创建哪些 stages；
- 决定 stage 运行顺序；
- 配置模型、阈值、ROI、绘制和算法参数；
- 可隐式请求 lores stream。

它不配置 libcamera IPA 的 AGC/AWB/denoise 算法。

### 10.3 libcamera tuning JSON

`--tuning-file` 被转成：

```bash
LIBCAMERA_RPI_TUNING_FILE=/path/to/sensor.json
```

这个文件由 libcamera RPi IPA 读取，控制传感器/ISP 图像算法。它和
rpicam-apps 后处理 JSON 属于完全不同的阶段：

```text
IPA tuning
  → Bayer/ISP/3A
  → libcamera 输出 YUV
  → rpicam-apps post-processing JSON
  → CPU/accelerator 后处理
```

### 10.4 libcamera Pipeline YAML

在 VC4 平台，如果用户没有预设 `LIBCAMERA_RPI_CONFIG_FILE`，rpicam-apps
会尝试：

```text
/usr/local/share/libcamera/pipeline/rpi/vc4/rpi_apps.yaml
/usr/share/libcamera/pipeline/rpi/vc4/rpi_apps.yaml
```

Pipeline YAML 控制 libcamera 内部 buffers、资源和调度，不是 rpicam-apps
自己的 stream/encoder 配置。

### 10.5 构建选项和生成的 `config.h`

Meson options 决定哪些插件被编译；`config.h` 记录默认安装目录和可用宏；
运行时 factory 再扫描真实 `.so`。

不要将这些配置混在一起：

```text
Meson options/config.h       → 编译并安装哪些能力、插件在哪里
CLI/--config                 → 本次应用怎样采集、编码和输出
Post-processing JSON         → YUV/metadata 后处理 stage chain
libcamera tuning JSON        → IPA/3A/ISP 画质算法
libcamera Pipeline YAML      → Pipeline buffer、资源和调度
```

## 11. 推荐阅读顺序

建议按以下顺序建立完整模型：

1. [`apps/rpicam_hello.cpp`](../rpicam-apps/apps/rpicam_hello.cpp)  
   看最短的 Open/Configure/Start/Wait/Preview 闭环。

2. [`core/rpicam_app.hpp`](../rpicam-apps/core/rpicam_app.hpp)  
   建立公共 API、成员状态和 stream 名称模型。

3. [`core/completed_request.hpp`](../rpicam-apps/core/completed_request.hpp)  
   先理解 Request 被 `reuse()` 后为什么仍能通过包装对象保存 buffers。

4. [`core/rpicam_app.cpp`](../rpicam-apps/core/rpicam_app.cpp) 中的
   `setupCapture()`、`makeRequests()`、`requestComplete()` 和
   `queueRequest()`。  
   这是仓库最核心的 buffer/Request 闭环。

5. 同一文件中的 `StartCamera()`、`StopCamera()`、`SetControls()`。  
   理解 controls 和并发停止。

6. [`apps/rpicam_vid.cpp`](../rpicam-apps/apps/rpicam_vid.cpp) 和
   [`core/rpicam_encoder.hpp`](../rpicam-apps/core/rpicam_encoder.hpp)。  
   理解完成帧怎样同时进入预览和编码。

7. [`encoder/encoder.cpp`](../rpicam-apps/encoder/encoder.cpp) 和
   [`encoder/h264_encoder.cpp`](../rpicam-apps/encoder/h264_encoder.cpp)。  
   理解 factory、Pi 4/Pi 5 分支和 codec input/output buffer 生命周期。

8. [`output/output.cpp`](../rpicam-apps/output/output.cpp) 与
   [`output/file_output.cpp`](../rpicam-apps/output/file_output.cpp)。  
   理解 keyframe、pause、split、segment 和 timestamps。

9. [`preview/preview.cpp`](../rpicam-apps/preview/preview.cpp) 与一个具体后端。  
   理解动态插件和 preview done callback。

10. [`core/post_processor.cpp`](../rpicam-apps/core/post_processor.cpp) 与
    [`post_processing_stages/post_processing_stage.hpp`](../rpicam-apps/post_processing_stages/post_processing_stage.hpp)。  
    理解 stage 生命周期、帧间并行和有序输出。

11. [`post_processing_stages/motion_detect_stage.cpp`](../rpicam-apps/post_processing_stages/motion_detect_stage.cpp)。  
    这是较短的 lores + metadata stage 示例。

12. [`apps/rpicam_still.cpp`](../rpicam-apps/apps/rpicam_still.cpp)。  
    最后再看 viewfinder/still/ZSL/timelapse/AF 状态切换。

13. [`image/jpeg.cpp`](../rpicam-apps/image/jpeg.cpp) 和
    [`image/dng.cpp`](../rpicam-apps/image/dng.cpp)。  
    深入静态图像格式、EXIF 和 PiSP raw 解压。

14. [`meson.build`](../rpicam-apps/meson.build) 及各子目录
    `meson.build`。  
    对照已经理解的运行模块确认它们如何被链接和动态加载。

## 12. 建议的构建验证方法

当前调研环境为 `x86_64`，没有安装 Meson、Ninja、libcamera pkg-config
依赖，也没有现成 build 目录。因此本报告基于源码和构建定义的静态分析，
尚未在 Raspberry Pi 5 上实际构建或运行。

在具备依赖的 Pi 5 环境中，可先做不带 AI/OpenCV 的基础构建：

```bash
cd ~/workspace/raspi5/rpicam-apps

meson setup build \
  -Denable_libav=enabled \
  -Denable_opencv=disabled \
  -Denable_tflite=disabled \
  -Denable_hailo=disabled \
  -Denable_imx500=false

meson configure build
meson introspect build --targets
ninja -C build
```

Pi 5 建议明确启用 libav，否则默认 `--codec h264` 可能没有可用 encoder。

查看动态模块目标：

```bash
ninja -C build -t targets | \
  grep -E 'rpicam|preview|encoder|postproc'
```

安装到临时目录并核对布局：

```bash
DESTDIR=/tmp/rpicam-install meson install -C build

find /tmp/rpicam-install -type f | sort
```

重点确认：

```text
librpicam_app.so
rpicam-hello/still/vid/raw/jpeg
rpicam-apps-preview/*.so
rpicam-apps-encoder/*.so
rpicam-apps-postproc/*.so
share/rpi-camera-assets/*.json
```

项目自带的运行测试入口是：

- [`utils/test.py`](../rpicam-apps/utils/test.py)

它覆盖 hello、ROI、controls、preview backends、多相机、still/video/raw、
metadata、timestamps 及可选 Hailo/IMX500，但注释也明确说明并非穷尽测试。

## 13. 建议的运行时验证方法

枚举相机、模式和 controls：

```bash
rpicam-hello --list-cameras -v 2
```

验证最短 headless Request 循环：

```bash
rpicam-hello -t 5000 --nopreview -v 2
```

Pi 5 验证 libav/libx264 H.264 路径：

```bash
rpicam-vid -t 5000 --codec h264 \
  --nopreview -o /tmp/test.h264 -v 2
```

验证 stream、后处理和 metadata：

```bash
rpicam-vid -t 5000 --codec yuv420 \
  --lores-width 320 --lores-height 240 \
  --post-process-file assets/motion_detect.json \
  --metadata /tmp/metadata.json \
  --nopreview -o /tmp/test.yuv -v 2
```

验证 ZSL 和 raw/DNG：

```bash
rpicam-still --zsl -t 3000 \
  --raw -o /tmp/test.jpg -v 2
```

结合 libcamera 日志：

```bash
LIBCAMERA_LOG_LEVELS='Camera:DEBUG,RPI:DEBUG' \
rpicam-hello -t 5000 --nopreview -v 2
```

建议优先设置断点或增加日志的位置：

```text
Options::Parse
OptsInternal::Parse
RPiCamApp::OpenCamera
RPiCamApp::ConfigureVideo
RPiCamApp::setupCapture
RPiCamApp::makeRequests
RPiCamApp::StartCamera
RPiCamApp::requestComplete
PostProcessor::Process
PostProcessor::outputThread
RPiCamEncoder::EncodeBuffer
RPiCamEncoder::encodeBufferDone
RPiCamApp::ShowPreview
RPiCamApp::previewDoneCallback
RPiCamApp::queueRequest
Output::OutputReady
```

每帧日志建议记录：

```text
CompletedRequest sequence
Request pointer
buffer fd
shared_ptr use_count
SensorTimestamp / FrameWallClock
postprocess 开始和结束时间
preview Show/done
encoder input queued/done
encoder output timestamp/keyframe
queueRequest 时刻
```

这样可以直接观察哪一个消费者在持有 buffer，以及背压来自后处理、预览、
编码还是输出。

还可以用系统调用跟踪验证 DMA 和 codec 路径：

```bash
strace -f \
  -e trace=openat,ioctl,mmap,munmap,poll \
  rpicam-vid -t 2000 --nopreview -o /tmp/test.h264
```

重点寻找：

```text
/dev/dma_heap/vidbuf_cached
DMA_HEAP_IOCTL_ALLOC
DMA_BUF_IOCTL_SYNC
/dev/video11（仅 VC4 H264Encoder）
V4L2 QBUF/DQBUF
```

## 14. 最终掌握目标

完成第一轮阅读后，应能够沿代码回答以下问题：

1. 哪些源文件进入 `librpicam_app`，哪些能力以 `.so` 插件提供？
2. 为什么 `rpicam-detect` 只有启用 TFLite 时才会构建？
3. rpicam-apps 为什么过滤 USB camera，它怎样判断 VC4 和 PiSP？
4. `ConfigureViewfinder/Still/Video/Zsl` 分别创建哪些 streams？
5. 为什么 rpicam-apps 自己从 DMA heap 分配 buffer，而不是使用
   `FrameBufferAllocator`？
6. 多条 stream 的 buffers 怎样组合成一个同步 Request？
7. `CompletedRequest` 构造时为什么立即调用 `Request::reuse()`？
8. 为什么最后一个 `CompletedRequestPtr` 释放才会重新 queue Request？
9. preview、postprocess 和 encoder 谁会持有同一帧，谁负责释放？
10. 消费者变慢时，引用计数如何形成相机背压？
11. StopCamera 后晚到的 shared pointer deleter 为什么不会重提旧 Request？
12. `SetControls()` 的值为什么未必作用于紧邻的下一 sensor frame？
13. Pi 4 和 Pi 5 的 `--codec h264` 为什么会选择不同编码器？
14. elementary H.264 和 libav 容器输出为什么走不同的 Output 路径？
15. 后处理 stage 怎样通过 `post_process_metadata` 建立生产者/消费者关系？
16. 后处理为什么允许跨帧并行，却仍保持向应用投递的帧顺序？
17. CLI config、后处理 JSON、IPA tuning JSON 和 Pipeline YAML 分别控制什么？
18. 普通 still mode switch 和 ZSL 在 buffers、时延和 temporal denoise 上有
    什么差别？

如果这些问题都能沿着源码给出答案，就已经掌握了 `rpicam-apps` 最核心的
结构和运行流程。剩余内容主要是某个具体 preview backend、图像编码格式、
AI accelerator 或后处理算法的实现细节。
