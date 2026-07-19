有，而且比AOV更适合树莓派的项目不少。筛选标准应该是：

> 树莓派的开放Linux栈、可插桩性和可编程性不可替代，而不是依靠它去和专用SoC比功耗、成本。

我最推荐以下五个方向。

## 1. 可编程隐私智能摄像头——最推荐

把树莓派做成一个插到电脑上就能使用的标准USB摄像头：

```text
Camera Module
 → libcamera
 → NEON图像处理
 → 隐私/构图算法
 → USB UVC Gadget
 → Windows/macOS/Linux会议软件
```

同时接一个小屏，显示“电脑实际收到的最终画面”，而不是未经处理的原始画面。

功能可以包括：

- 人员自动居中和裁剪
- 背景模糊
- 固定区域隐私遮挡
- 人脸马赛克，但不做身份识别
- 亮度、逆光和肤色区域优化
- 物理静音/隐私按键
- 摄像头工作指示灯
- USB断开、休眠、恢复
- 相机卡死自动恢复
- 本地预览与USB输出完全一致

技术栈非常完整：

- CMOS Sensor、libcamera、V4L2
- YUV/NV12、RGB和stride
- NEON resize、色彩转换、模糊、锐化
- DMA-BUF和缓冲区生命周期
- Linux USB Gadget/configfs
- UVC格式、分辨率、帧间隔和控制请求
- USB suspend/resume
- DRM/KMS本地预览
- usbmon、perf、ftrace
- Camera-to-PC端到端延迟
- USB带宽、温度和功耗

Linux官方 UVC Gadget驱动允许Linux设备作为标准USB摄像头被主机识别；树莓派官方也提供了从 `libcamera` 输出到 UVC Gadget的教程。[Linux UVC Gadget](https://www.kernel.org/doc/html/latest/usb/gadget_uvc.html)、[树莓派USB摄像头教程](https://www.raspberrypi.com/tutorials/plug-and-play-raspberry-pi-usb-webcam/)

当前 Raspberry Pi OS 已支持在 Pi 4、Pi 5和Zero系列上使用USB Gadget模式，但 Pi 4/5通过USB-C同时传输数据和供电时需要注意供电能力。[树莓派USB Gadget模式](https://www.raspberrypi.com/news/usb-gadget-mode-in-raspberry-pi-os-ssh-over-usb/)

它的差异化不是“画质比商业摄像头好”，而是：

> 可编程处理流水线、可验证隐私、最终输出可信预览、完整USB与Camera链路追踪。

这是系统开发和图像处理结合最自然的项目。

---

## 2. 超低延迟电子放大镜/维修显微屏

生活场景可以是：

- 老年人阅读辅助
- 电子维修和焊接
- 印章、票据、小零件观察
- 模型制作

流水线：

```text
Camera
 → ISP
 → NEON实时增强
 → DRM/KMS
 → LCD
```

功能包括：

- 2×～8×数字放大
- 高对比度黑白模式
- 反色
- 伪彩色
- 局部对比度增强
- 锐化和降噪
- 冻结画面
- 画面平移
- 自动或手动曝光
- 焦点辅助与边缘高亮

可以深入：

- Camera-to-display photon-to-photon延迟
- 双缓冲与三缓冲
- page flip和VSync
- NEON卷积、LUT、YUV处理
- DRM plane与atomic commit
- 背光控制
- 按键/input驱动
- CPU调频、温度和电池续航
- 不同滤镜的单帧能量

这个项目的优势是**显示栈占比非常高**，而且不需要先解决复杂AI模型问题。

应把它定位为“开放式低延迟成像终端”，不是医疗设备。

---

## 3. 摄像头健康诊断与自动恢复系统

不是分析画面中有什么，而是判断摄像头本身是否工作正常：

- 画面冻结
- 重复帧
- 丢帧
- 黑屏
- 过曝、欠曝
- 镜头被遮挡
- 严重失焦
- 镜头污渍或水滴
- Sensor坏点增加
- CSI传输错误
- 曝光或增益异常
- 帧时间戳跳变
- 内存缓冲区耗尽
- Camera进程卡死
- 过热降频
- 自动重启相机或重新加载流水线

系统不仅报告“摄像头坏了”，还要区分：

```text
Sensor无输出
CSI/V4L2异常
libcamera请求超时
用户算法阻塞
显示链路异常
存储写入阻塞
```

关键技术：

- V4L2/Media Controller
- I²C和Sensor寄存器
- libcamera request状态
- 内核tracepoint和dynamic debug
- ftrace、perf、调度时间线
- watchdog
- systemd服务恢复
- 图像质量统计的NEON加速
- 故障注入

差异化是：

> 面向不同Sensor和Linux平台的开放摄像头可观测性工具。

它特别适合应聘Camera系统、嵌入式Linux、驱动调试和稳定性相关岗位。

---

## 4. 双摄同步测距与桌面尺寸测量

树莓派 5有两个MIPI连接器，可以同时连接两路摄像头；树莓派相机栈也提供软件同步机制。[树莓派多摄像头和同步](https://www.raspberrypi.com/documentation/computers/camera_software.html)

生活场景可以是：

- 快递包裹尺寸估计
- 桌面物体测量
- 模型零件测量
- 双摄景深预览
- 非安全用途的盲区观察实验

技术链：

```text
双Camera
 → 时间同步
 → 双目标定
 → 畸变矫正
 → 图像校正
 → 立体匹配
 → 深度/尺寸
 → DRM/KMS可视化
```

可以深入：

- 两路Sensor曝光同步
- 软件同步与外部同步比较
- 帧时间戳偏差
- 双路CSI带宽
- 多路DMA-BUF
- NEON图像矫正和匹配代价
- cache与内存带宽
- 双摄掉帧后的重同步
- 深度结果与真实尺寸误差
- 温度、功耗和帧率权衡

差异化不是“做一个普通双目相机”，而是：

> 可测量、可追踪的多Camera同步和带宽优化平台。

---

## 5. Camera—Display图像链路校准仪

这是偏工程工具的方向，用摄像头拍摄屏幕上的测试图案，自动分析：

- 显示延迟
- VSync和画面撕裂
- 刷新率
- 丢帧、重复帧
- 显示Gamma
- 灰阶响应
- 白平衡和色偏
- 局部亮度
- Camera rolling shutter
- Camera曝光与显示PWM的干扰
- HDR映射
- 不同KMS显示模式的差异

工作方式：

```text
DRM/KMS生成测试图案
 → LCD显示
 → Camera拍摄
 → NEON统计与分析
 → 自动生成测试报告
```

可以增加LED或光敏二极管，获得更准确的端到端延迟基准。

该项目自然覆盖：

- Sensor曝光与rolling shutter
- ISP颜色处理
- RAW/RGB/YUV
- NEON统计
- DRM/KMS、EDID、VSync、page flip
- 显示PWM
- perf/ftrace
- 自动化测试

它不是消费品，而是一个**成像与显示验证工具**，因此不会面临“为什么不用量产摄像头”的质疑：量产摄像头反而是被测试对象。

# 如何选择

| 主要目标 | 最合适项目 |
|---|---|
| Camera + Linux系统 + USB | 可编程UVC智能摄像头 |
| ARM NEON + 显示栈 | 低延迟电子放大镜 |
| 内核调试、追踪、稳定性 | 摄像头健康诊断 |
| 多摄、算法、带宽 | 双摄同步测距 |
| ISP、显示、测试工程 | Camera—Display校准仪 |

综合你的目标——图像处理、NEON、内核、系统、调试追踪、显示栈、功耗性能——**首选可编程UVC智能摄像头，次选低延迟电子放大镜**。

其中可编程UVC摄像头的完整链路最漂亮：

```text
CMOS Sensor
 → MIPI CSI-2
 → V4L2/libcamera
 → DMA-BUF
 → NEON图像处理
 → 一路进入DRM/KMS本地可信预览
 → 一路进入UVC Gadget输出给电脑
 → perf/ftrace/usbmon贯穿追踪
```

它既是日常真正能使用的东西，又能一路深入到Camera驱动、USB内核栈、显示栈和性能功耗分析，比普通AOV门铃更能体现树莓派的开放平台价值。


------

对。**“相机连续跑72小时”只是测试指标，不是完整的项目背景。**如果相机只是对着测试卡或窗外拍摄，这只能算相机驱动压测工具，应用层、AI和项目意义都会显得牵强。

完整背景应该是：**相机在长时间无人值守测试中承担“视觉判定仪”的职责，同时系统还要证明这台判定仪自身没有失效。**

## 推荐的完整场景

项目改成：

**VisionHIL BlackBox——面向嵌入式设备无人值守耐久测试的视觉观测与故障追溯系统**

具体测试对象可以是一台带屏幕、LED、风扇、电机或继电器的嵌入式终端，例如：

- 工业HMI/控制面板；
- Android/Linux嵌入式显示终端；
- 智能家居控制器；
- 带状态灯和执行器的开发板；
- 需要反复开关机、升级、休眠唤醒的边缘设备。

相机不是拍风景，而是始终对着：

- DUT屏幕；
- 状态LED；
- 风扇、舵机、继电器或其他执行机构；
- 测试夹具上的独立心跳灯/计数屏。

## 一次自动化测试具体怎么运行

假设测试对象是一台Linux嵌入式显示终端，目标是验证它能否稳定完成500次开关机和休眠唤醒。

每个测试循环包括：

1. ESP32控制继电器给DUT上电；
2. 测试程序等待UART启动日志；
3. 相机确认屏幕出现Boot Logo；
4. 等待主界面出现；
5. DUT启动动画或视频播放；
6. 测试程序执行suspend/resume；
7. 相机确认屏幕恢复、动画仍在运动；
8. 关闭DUT并开始下一轮。

系统同时采集三类证据：

```text
测试控制器
  ├─ 当前测试步骤、循环次数、命令结果
  └─ 继电器、GPIO、预期状态

被测设备
  ├─ UART/ADB日志
  ├─ 温度、电流、CPU负载
  └─ 应用运行状态

IMX219相机
  ├─ 屏幕显示状态
  ├─ LED颜色和闪烁状态
  ├─ 风扇/舵机/继电器是否真实动作
  └─ 故障前后视频
```

## 它能发现哪些普通日志发现不了的问题

### 情况一：日志成功，但物理结果失败

```text
UART：系统启动完成
systemd：应用服务启动成功
实际画面：屏幕仍然全黑
```

单看日志会判定成功；视觉系统会判定“软件状态与物理状态不一致”。

### 情况二：程序还活着，但画面冻结

```text
进程：仍在运行
心跳线程：正常打印日志
屏幕：动画停留在同一画面超过10秒
```

相机通过帧差和屏幕ROI判断UI已冻结。

### 情况三：命令执行了，但机构没有动作

```text
测试程序：已发送舵机转动命令
MCU：返回执行成功
相机：执行机构没有移动或只移动了一半
```

这可以区分软件命令成功和真实机械动作成功。

### 情况四：不是DUT冻结，而是监控相机自己冻结

这是项目最重要、也最有技术含量的问题：

> 如果画面不动，究竟是被测设备的屏幕冻结，还是相机pipeline卡死？

解决办法是在画面角落放一个由ESP32独立控制的心跳LED或小OLED计数器，例如每500ms翻转一次。

判断逻辑变成：

| DUT画面 | 独立心跳 | 相机帧序号 | 结论 |
|---|---|---|---|
| 不动 | 正常变化 | 正常 | DUT屏幕冻结 |
| 不动 | 也不变化 | 重复帧 | 相机pipeline冻结 |
| 不动 | 看不到新帧 | DQBUF超时 | Sensor/CSI/VI/Argus链路异常 |
| 正常变化 | 正常变化 | 正常 | 系统正常 |
| 画面异常 | 心跳正常 | 正常 | DUT显示或执行机构异常 |

这样相机不再只是“拍摄设备”，而是一个有自检能力的视觉测试仪。

## AI、NEON和GPU分别为什么存在

### ARM NEON：始终运行的轻量判定

处理低分辨率Luma ROI：

- 独立心跳灯是否变化；
- 屏幕是否冻结；
- 画面是否全黑、过亮或被遮挡；
- 风扇/舵机区域是否发生运动；
- 连续帧是否完全重复。

这些任务计算简单、需要持续运行，适合NEON，不值得一直占用GPU。

### CUDA/TensorRT：复杂视觉状态

只在特定测试步骤或NEON发现异常时运行：

- Boot Logo、主界面、错误弹窗分类；
- 屏幕文字OCR；
- LED颜色及组合状态识别；
- 执行机构位置检测；
- 轻度花屏、局部显示异常、失焦或遮挡分类。

例如测试步骤要求“20秒内进入主界面”，TensorRT模型输出：

```json
{
  "screen_state": "boot_logo",
  "confidence": 0.97,
  "expected_state": "main_ui",
  "timeout_ms": 20432
}
```

### 端侧LLM：事故复盘

LLM在故障发生后读取：

- 当前测试步骤；
- UART和systemd日志；
- OCR识别结果；
- 屏幕状态变化；
- 相机链路错误；
- 功耗、温度和恢复结果。

输出事故摘要，而不是参与实时控制。

## 故障发生后保存什么

例如第387次suspend/resume失败：

```text
Cycle 387
10:31:02  发出resume命令
10:31:03  UART恢复输出
10:31:05  systemd报告应用运行
10:31:10  屏幕仍为黑色
10:31:10  独立心跳LED正常变化，确认相机没有冻结
10:31:11  判定DUT显示恢复失败
```

系统保存：

```text
incident-cycle-387/
├─ test-step.json
├─ pre-event-20s.mp4
├─ post-event-20s.mp4
├─ screen-keyframes/
├─ uart.log
├─ power.csv
├─ camera-health.json
├─ vi-trace.log
├─ gstreamer-trace.log
└─ incident-report.md
```

这就是完整的应用闭环：**运行真实测试、发现状态不一致、排除监控相机自身故障、保留证据、辅助定位原因。**

## 项目的现实意义

对测试工程师而言，它减少的是：

- 人工守着测试台看屏幕和LED；
- 第二天面对“第387次失败”却没有现场证据；
- 在几小时视频中手工寻找故障时刻；
- 分不清设备冻结、相机冻结还是测试程序冻结；
- 偶发问题修复后无法自动做回归验证。

对你的求职而言，底层技术也不再是硬塞：

- 因为相机是测试判定仪，所以MIPI、驱动和采集稳定性是基础；
- 因为需要区分DUT冻结和相机冻结，所以时间戳、帧序号、SOF/EOF、DQBUF和pipeline tracing有实际意义；
- 因为测试持续数天，所以功耗、温度、内存泄漏和自动恢复有实际意义；
- 因为简单检测必须低功耗持续运行，所以使用NEON；
- 因为复杂视觉判断不需要每帧执行，所以按需使用CUDA/TensorRT；
- 因为故障涉及多份日志，所以LLM用于事后归纳，而不是实时控制。

## 修订后的项目背景

**项目名称：VisionHIL BlackBox——嵌入式设备无人值守耐久测试的视觉观测与故障追溯系统**

面向嵌入式终端在数百次开关机、应用启动、suspend/resume及执行器耐久测试中，软件日志只能反映内部状态、无法确认屏幕显示和机械动作是否真实完成，以及偶发故障发生后缺少现场证据的问题，设计基于Jetson Orin NX和IMX219的端侧视觉测试系统。

系统以相机持续观测DUT屏幕、状态LED及执行机构，并与测试步骤、UART日志、功耗和温度数据统一到单调时钟时间线；通过独立心跳LED区分DUT冻结与相机pipeline冻结，在状态不一致、丢帧或采集超时时自动保存故障前后视频和跨层trace、恢复相机链路并生成可回归验证的事故报告。

这时“相机为什么长时间运行”就有了完整答案：**因为它在连续数百次无人值守测试中充当视觉判定仪，而不是为了做72小时压测而随便对着风景拍。**


完全可以。建议你现在做一个不会被丢弃的前置项目：

**VisionHIL-Pi——基于 Raspberry Pi 5 的视觉链路健康检测与故障黑匣子**

它可以先完成未来Jetson项目约七成的通用能力：Linux相机栈、V4L2/Media Controller、GStreamer、NEON、时间戳、故障注入、自动恢复、长稳测试和端侧LLM资源隔离。以后主要替换平台后端。

树莓派5本身有四核Cortex-A76、VideoCore VII/Vulkan 1.3和双MIPI接口，很适合练ARM优化和Linux相机系统。[Raspberry Pi 5规格](https://www.raspberrypi.com/products/raspberry-pi-5/)

## 现在没有摄像头也能开始

### 第1个小项目：虚拟相机故障黑匣子

先用GStreamer `videotestsrc`、本地视频或Linux VIMC虚拟相机代替真实Sensor。

VIMC可以模拟Sensor、Debayer、Scaler和Capture节点，用`media-ctl`配置拓扑、用`v4l2-ctl`采集，很适合学习Media Controller。[Linux VIMC文档](https://docs.kernel.org/admin-guide/media/vimc.html)

实现下面的C++数据流：

```text
synthetic source / VIMC / file
          ↓
     有界帧队列
          ↓
   图像健康检测
          ↓
  事件前后环形缓存
          ↓
    incident bundle
```

每帧记录：

```text
sequence
source_timestamp
receive_monotonic_ns
process_begin_ns
process_end_ns
queue_depth
health_flags
```

模拟至少这些故障：

- 整帧重复；
- 帧序号跳变；
- 黑屏、白屏；
- DUT区域冻结，但心跳区域继续变化；
- 视频源停止输出；
- 消费线程故意变慢，造成队列反压；
- 进程异常退出。

故障发生后生成：

```text
incident/
├─ metadata.json
├─ pre-event/
├─ post-event/
├─ pipeline.log
└─ performance.csv
```

这一阶段的验收不是“画面能显示”，而是：

- 队列容量固定，不会无限占用内存；
- 慢支路不会阻塞采集主路径；
- 每种故障都能稳定生成事故包；
- 能统计P50/P95/P99延迟、最大队列深度和丢帧数量。

## 第2个小项目：ARM NEON图像内核库

树莓派5的Cortex-A76正好适合练NEON。

选择四个真正会用于相机健康检测的算法：

- NV12 Y平面均值、过曝和欠曝比例；
- 相邻帧SAD和变化像素数；
- 2×/4×下采样；
- 边缘能量或简单清晰度指标。

每个算法实现三版：

1. 标量reference；
2. 编译器自动向量化；
3. 显式AArch64 NEON intrinsics。

在以下尺寸测试：

```text
160×90
640×360
1920×1080
```

报告：

- ns/frame；
- cycles/pixel；
- P50/P95；
- instructions、cache miss；
- CPU频率、温度和是否降频；
- NEON与reference结果是否一致。

不要预先写“NEON加速4倍”。真正有价值的结论可能是：

> 160×90数据太小，函数调用和缓存行为占主要开销；640×360以上显式NEON才稳定优于自动向量化。

这比只给一个最大加速比更像性能工程。

## 添置摄像头后的学习顺序

如果只买一样东西，建议：

- Camera Module 2/IMX219；
- 配套的15-pin转Pi 5 mini 22-pin排线；
- 如果还没有，补主动散热。

Pi 5使用mini 22-pin接口，Camera Module 2使用15-pin接口，需要对应的standard-to-mini排线。[官方相机排线](https://www.raspberrypi.com/products/camera-cable/?variant=camera-cable-std-mini-200)

IMX219已经被当前Raspberry Pi `libcamera`栈正式支持，适合学习已有驱动、曝光增益控制、RAW/ISP路径和长稳验证。[Raspberry Pi相机软件栈](https://www.raspberrypi.com/documentation/computers/camera_software.html)

### 第3阶段：理解真实相机链路

先完成：

- `rpicam-hello --list-cameras`识别Sensor；
- `media-ctl -p`导出真实media graph；
- 枚举`/dev/video*`和`/dev/v4l-subdev*`，但程序不硬编码节点编号；
- 采集RAW Bayer与ISP输出，比较格式、stride和metadata；
- 修改曝光、增益、帧周期，验证实际metadata；
- 阅读主线`drivers/media/i2c/imx219.c`中的probe、controls、runtime PM、stream start/stop。

应用主路径使用C++ `libcamera` Request API，Picamera2只用于快速实验。`libcamera`的基本模型是配置Stream、分配buffer、建立Request、异步完成并重新排队，这些概念以后迁移到Argus仍然有价值。[libcamera C++指南](https://libcamera.org/guides/application-developer.html)

此时不要修改驱动。先确认你真的理解：

```text
IMX219 Sensor
  ↓
MIPI CSI / CFE
  ↓
PiSP
  ↓
libcamera pipeline handler + 3A
  ↓
rpicam-apps / libcamerasrc / C++ application
```

只有发现真实缺陷、缺失control或错误路径问题，才进入内核修改。

## 第4阶段：做一个廉价但真实的视觉场景

不需要马上购买第二台开发板。让IMX219对着旧手机、平板或电脑屏幕，屏幕运行一个“DUT模拟器”网页：

- `BOOTING`、`RUNNING`、`ERROR`、`BLACK_SCREEN`状态；
- 动态计数器；
- 移动动画；
- 可手动注入冻结、崩溃和错误弹窗。

同时在视野角落放一颗由Pi GPIO控制的闪烁LED：

- DUT画面不动、LED继续变化：DUT模拟器冻结；
- 整幅画面和LED全部重复：相机或采集pipeline冻结；
- 画面全黑但LED可见：DUT黑屏；
- DUT和LED都看不见，但仍有新帧：遮挡、照明或曝光异常。

由于LED仍由同一台Pi控制，它不是独立硬件基准。以后再增加便宜的RP2040/ESP32，才能检测整台Pi的Linux冻结。README里应主动说明这个边界。

## 第5阶段：采集服务与稳定性

把虚拟源替换为真实`libcamerasrc`：

```text
IMX219 / libcamera
  ├─ 640×360 Luma → NEON健康检测
  ├─ 事件JPEG/低帧率视频
  └─ telemetry + watchdog
```

实现：

- GStreamer ERROR、EOS、state change处理；
- no-frame watchdog；
- 有界队列和丢弃策略；
- 10秒故障前缓存；
- systemd自动拉起；
- capture timestamp到decision的逐帧关联；
- 先1小时，再24小时，最后72小时长稳。

树莓派5没有H.264硬件编码器，`rpicam-vid`使用CPU软件编码。官方测试表明它可以实时编码1080p30，但会消耗明显CPU资源；因此你的第一版建议保存JPEG关键帧或720p低帧率事件视频，并把x264带来的CPU、温度、功耗和P99延迟变化做成实验。[Raspberry Pi 5 H.264编码白皮书](https://pip-assets.raspberrypi.com/categories/685-app-notes-guides-whitepapers/documents/RP-010033-WP-1-H.264%20encoding%20performance%20on%20Raspberry%20Pi%205_series%20computers.pdf)

故障注入可以包括：

- kill/SIGSTOP采集进程；
- 故意让处理线程sleep；
- CPU、内存和I/O压力；
- 反复stream start/stop；
- 分辨率和曝光切换；
- 软件编码与NEON检测并行；
- 有边界地模拟存储不足。

不要通电热插拔CSI，也不要真的写满根分区。

## 第6阶段：AI和端侧LLM

AI只处理规则难描述的状态，例如：

- Boot Logo、主界面、错误弹窗分类；
- 局部花屏或显示异常；
- 轻度遮挡和失焦；
- 执行机构位置。

先使用小型INT8分类模型，以224×224 ROI、低帧率CPU推理；只有NEON门控触发或测试步骤要求时才运行。官方`rpicam-apps`可以编译TFLite/OpenCV后处理阶段，适合作为参考。[rpicam-apps构建说明](https://www.raspberrypi.com/documentation/computers/camera_software.html)

LLM使用`llama.cpp`运行小型Q4文本模型：

- 4GB内存：优先0.5B～1B；
- 8GB以上：可尝试1B～3B；
- 只读取incident JSON、日志和故障手册；
- 只在事件后运行；
- 用nice/cgroup限制资源；
- 测量LLM运行前后相机drop和P99延迟。

[llama.cpp](https://github.com/ggml-org/llama.cpp)支持量化和本地C/C++推理，但不要让它处理每一帧或进入恢复控制闭环。

## GPU现在怎么学

Pi 5的VideoCore VII支持Vulkan 1.3。可以额外实现一个Vulkan compute版本的SAD、灰度缩放或ROI统计，用来学习：

- buffer和内存布局；
- workgroup；
- dispatch；
- barrier与同步；
- CPU/GPU传输成本。

但简历只能写“Vulkan Compute”，不能写CUDA。以后把接口替换为CUDA：

```cpp
IHealthKernel
├─ ScalarBackend
├─ NeonBackend
├─ VulkanBackend   // Pi 5
└─ CudaBackend     // 后续Jetson
```

相机DMA-BUF直接导入Vulkan属于进阶项；第一版允许一次明确记录的CPU map/copy，不要先承诺零拷贝。

## 推荐的8周顺序

| 时间 | 交付物 |
|---|---|
| 第1周 | 虚拟视频源、有界队列、时间戳、事故包 |
| 第2周 | scalar/auto-vector/NEON基准报告 |
| 第3周 | IMX219 bring-up、media graph、RAW/ISP对照 |
| 第4周 | C++ libcamera/GStreamer真实采集服务 |
| 第5周 | DUT模拟器、心跳检测、事件缓存 |
| 第6周 | 故障注入、systemd恢复、24小时报告 |
| 第7周 | 轻量分类模型、LLM资源隔离实验 |
| 第8周 | 48/72小时压测、文档、演示视频、v1.0 release |

## 为以后迁移Jetson预留结构

```text
visionhil/
├─ src/capture/
│  ├─ synthetic/
│  ├─ libcamera_pi/
│  └─ argus_jetson/       # 后续
├─ src/health/
│  ├─ scalar/
│  ├─ neon/
│  ├─ vulkan/
│  └─ cuda/               # 后续
├─ src/inference/
│  ├─ tflite/
│  └─ tensorrt/           # 后续
├─ src/supervisor/
├─ src/incident/
├─ tools/dut-simulator/
├─ tests/faults/
└─ reports/
```

可以直接迁移的包括：NEON、GStreamer设计、帧Schema、时间戳、故障状态机、incident bundle、systemd、长稳测试和LLM隔离。

以后需要替换的是：

| Raspberry Pi 5 | Jetson |
|---|---|
| CFE/PiSP/libcamera | CSI/VI/Argus |
| 普通DMA-BUF/系统内存 | NVMM/DMA-BUF |
| x264软件编码 | NVENC |
| TFLite CPU | TensorRT/CUDA |
| Vulkan compute | CUDA |
| Pi温控工具 | tegrastats/板载功耗轨 |

最重要的是：**先完成到第6周。**那时它已经是一个合格的小型简历项目；AI、LLM和Vulkan都是增强项，不能反过来拖延相机链路、NEON和稳定性主线。