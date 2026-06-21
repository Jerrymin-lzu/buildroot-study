# 1. 如何添加软件包

本文说明如何通过 `make menuconfig` 启用 Buildroot 中**已存在但未配置**的软件包。

---

## 背景

Buildroot 自带大量软件包（位于 `package/` 目录下，共 2800+ 个），默认编译时只有基础工具链和系统组件被选中，绝大多数软件包处于**未勾选**状态。添加软件包的本质就是在 menuconfig 中找到它并勾选启用。

---

## 完整步骤

### 步骤 1：进入 menuconfig

```bash
cd buildroot-2023.11.1
make menuconfig
```

出现基于 ncurses 的图形配置界面：

```
 ┌────────────────── Buildroot 2023.11.1 Configuration ──────────────────┐
 │  Arrow keys navigate the menu.  <Enter> selects submenus ---> (or     │
 │  empty submenus ----).  Highlighted letters are hotkeys.  Pressing    │
 │  <Y> includes, <N> excludes, <M> modularizes features.  Press         │
 │  <Esc><Esc> to exit, <?> for Help, </> for Search.  Legend: [*]      │
 │  built-in  [ ] excluded  <M> module  < > module capable               │
 │                                                                       │
 │ ┌───────────────────────────────────────────────────────────────────┐ │
 │ │              Target options  --->                                 │ │
 │ │              Build options  --->                                  │ │
 │ │              Toolchain  --->                                      │ │
 │ │              System configuration  --->                           │ │
 │ │              Kernel  --->                                         │ │
 │ │              Target packages  --->                                │ │
 │ │              Filesystem images  --->                              │ │
 │ │              Bootloaders  --->                                    │ │
 │ │              Host utilities  --->                                 │ │
 │ │              Legacy config options  --->                          │ │
 │ │                                                                   │ │
 │ └───────────────────────────────────────────────────────────────────┘ │
 ├───────────────────────────────────────────────────────────────────────┤
 │              <Select>    < Exit >     < Help >     < Save >           │
 └───────────────────────────────────────────────────────────────────────┘
```

---

### 步骤 2：定位目标软件包

有三种方式找到你需要的软件包。

#### 方式 A：搜索（最快速、推荐）

在 menuconfig 界面中按 `/` 键，输入关键词搜索：

```
按 /
输入: 关键词（如 ssh、python、wifi）
按 Enter 执行搜索
```

搜索结果会列出匹配的配置项及其路径，例如搜索 `openssh`：

```
Symbol: BR2_PACKAGE_OPENSSH [=n]
Type  : bool
Prompt: openssh
  Location:
    -> Target packages
      -> Networking applications
```

其中：
- `Symbol: BR2_PACKAGE_XXX` — 该包的唯一标识符
- `[=n]` — 当前状态：`n` 未启用 / `y` 已启用 / `m` 编译为模块
- `Location:` — 在菜单中的位置路径

#### 方式 B：手动浏览菜单

大多数软件包位于 `Target packages` 下，按类别分组：

```
Target packages
├── Audio and video applications    # 音视频应用
├── Compressors and decompressors   # 压缩/解压工具
├── Debugging, profiling and benchmark  # 调试与性能分析
├── Development tools               # 开发工具
├── Filesystem and flash utilities  # 文件系统工具
├── Fonts, cursors, icons, sounds   # 字体、光标、图标
├── Games                           # 游戏
├── Graphic libraries and applications  # 图形库及应用
├── Hardware handling               # 硬件处理
├── Interpreter languages and scripting  # 脚本语言（Python/Lua/Node.js 等）
├── Libraries                       # 库文件
│   ├── Crypto                      # 加密库
│   ├── Database                    # 数据库
│   ├── Graphics                    # 图形库
│   ├── JSON/XML                    # 数据格式
│   ├── Networking                  # 网络库
│   └── ...
├── Mail                            # 邮件
├── Miscellaneous                   # 杂项
├── Networking applications         # 网络应用
├── Package managers                # 包管理器
├── Shell and utilities             # Shell 与工具
├── System tools                    # 系统工具
└── Text and documents              # 文本与文档
```

#### 方式 C：命令行搜索

在 menuconfig 外直接用 grep 搜索：

```bash
# 搜索包名
grep -r "openssh" package/Config.in

# 搜索结果示例：
# package/Config.in:  source "package/openssh/Config.in"

# 查看包的详细描述
cat package/openssh/Config.in
```

---

### 步骤 3：勾选启用

找到目标包后：

| 操作 | 按键 | 效果 |
|------|------|------|
| 勾选 | `Space` 或 `Y` | `[ ]` → `[*]` |
| 取消勾选 | `Space` 或 `N` | `[*]` → `[ ]` |
| 进入子菜单 | `Enter` | 展开子菜单 |
| 返回上级 | `Esc` `Esc` | 退回上一级 |
| 查看帮助 | `?` 或 `H` | 显示该包说明 |

**注意**：如果某个包前面显示 `-*-` 而非 `[ ]`，说明它被其他已启用的包强制依赖选中，无法取消。

**依赖提示**：勾选某个包时，其所依赖的包（通过 `select` 定义）会自动被勾选。如果缺少必要条件（通过 `depends on` 定义），该选项会隐藏——需要先满足条件依赖才能看到。

---

### 步骤 4：保存配置

```
按 ← → 键选择底部的 <Save> → 按 Enter
确认文件名为 .config → 选择 <Ok> → 按 Enter
选择 <Exit> → 按 Enter 退出
```

---

### 步骤 5：编译

```bash
cd buildroot-2023.11.1
make
```

Buildroot 会自动完成：下载源码 → 解压 → 交叉编译 → 安装到根文件系统。

---

### 步骤 6：验证

```bash
# 确认配置已保存
grep BR2_PACKAGE_OPENSSH .config
# 输出: BR2_PACKAGE_OPENSSH=y

# 检查编译产物是否已安装
ls output/target/usr/bin/   # 二进制程序
ls output/target/usr/lib/   # 库文件
```

---

## 操作速查卡

```
cd buildroot-2023.11.1
make menuconfig         # 打开配置界面
    / 输入关键词        # 搜索软件包
    Space               # 勾选
    Esc Esc             # 返回
    → → <Save>          # 保存
    → → <Exit>          # 退出
make                    # 编译
```

---

## 常见场景

| 场景 | 搜索关键词 | 典型包名 |
|------|-----------|---------|
| SSH 远程登录 | `ssh` | `openssh` / `dropbear` |
| Python 脚本支持 | `python` | `python3` |
| 网络调试工具 | `iperf` / `ping` | `iperf3` / `iputils` |
| Wi-Fi 支持 | `wpa` / `wifi` | `wpa_supplicant` / `iw` / `hostapd` |
| Web 服务器 | `http` / `lighttpd` | `lighttpd` / `nginx` |
| 数据库 | `sqlite` / `mysql` | `sqlite` / `mariadb` |
| 音频播放 | `alsa` / `mpg` | `alsa-utils` / `mpg123` |
| GPIO 控制 | `gpio` | `libgpiod` |
| 文件传输 | `scp` / `rsync` | `openssh` / `rsync` |
| 固件升级 | `mtd` / `swupdate` | `mtd` / `swupdate` |

---

## 常见问题

**Q: 搜不到我想要的包怎么办？**

可能是包名拼写不同，尝试：
```bash
# 在 Buildroot package 目录中模糊搜索
ls package/ | grep -i "<关键词>"
```
如果确实不存在，则需要自行创建软件包（参见"方式二：编写新的 .mk 文件"相关文档）。

**Q: 某个选项灰掉了（`---`），无法勾选？**

说明该包的 `depends on` 条件不满足。按 `?` 查看帮助，其中列出了所有依赖条件。你需要先回到对应菜单启用缺失的依赖。

**Q: 勾选后编译报错？**

先单独编译该包以定位问题：
```bash
make <包名>-rebuild
```
常见的错误原因：工具链缺少该包需要的库（如 C++ 支持、线程支持等）。

**Q: 如何查看当前所有已启用的包？**

```bash
grep "^BR2_PACKAGE_.*=y" .config | sort
```
