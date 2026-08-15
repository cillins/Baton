# Baton

Baton 是一款 macOS 菜单栏应用，把 Apple Siri Remote 变成可自定义的鼠标、键盘、演示器和 Claude Code 控制器。

通过遥控器的实体按键、触控板手势与陀螺仪，你可以移动光标、滚动、拖拽、发送快捷键、输入文本或执行 Claude Code 斜杠命令。所有映射都在原生 SwiftUI 设置窗口中完成，不再通过菜单栏子菜单配置。

> 安装包可从 [GitHub Releases](https://github.com/cillins/Baton/releases) 下载。当前公开构建尚未使用 Developer ID 公证；首次打开时如被 Gatekeeper 拦截，请在“系统设置 → 隐私与安全性”中选择“仍要打开”。项目暂不提供自动更新或应用内更新检查。

## 支持的遥控器

- 已实际适配：Siri Remote A1513、A1962
- 已纳入 HID 识别：A1969、A2179、A2540 等后续型号
- 不同固件的 HID 报告可能存在差异；未实际验证的型号仍属于实验性支持

### 实验性 A1962 遥控器麦克风

Baton 已能从 A1962 的蓝牙 HCI 数据中提取并解码 16 kHz 单声道 Opus 音频，并通过 `Baton Remote Microphone` 虚拟输入设备提供给录音和会议应用。此功能是完全可选的实验功能：未配置时不会注册采集组件，也不影响按键、触控板、陀螺仪或其他功能。它要求 macOS 13 或更高版本，并需要用户另行从 Apple 官方安装 **Bluetooth Logging for macOS / PacketLogger** 及其 **Bluetooth Logging 配置描述文件**。

Apple 的配置文件内明确标注为机密资料并禁止分发，因此 Baton 不会把该 `.mobileconfig` 提交到公开仓库或放进公开 DMG。设置页提供“选择并安装”入口；Baton 会读取用户自行取得的配置并确认其确实是 `Bluetooth Logging for macOS`，避免误装 iOS 配置，然后再交给系统设置确认安装。该配置会在安装 3 天后自动移除，届时需要用户再次安装。

在“设置 → 遥控器麦克风”中需要分别：

1. 查看 PacketLogger 状态；未安装时通过设置页进入 Apple 官方下载页面；
2. 通过“选择并安装”打开 Apple Bluetooth Logging 配置，并在系统设置中确认；
3. 启用受限的 HCI 采集组件，并在“系统设置 → 通用 → 登录项”中批准；
4. 安装 `Baton Remote Microphone` CoreAudio 驱动（需要管理员密码）；
5. 在目标应用中选择 `Baton Remote Microphone` 作为输入设备，按住遥控器 Siri 键讲话。

如果目标应用要求按住键盘快捷键才能讲话，可在“设置 → 遥控器麦克风 → 同时按住快捷键”中录制按键或组合键。Baton 支持普通键、单独的 Command/Option/Control/Shift/Fn、带修饰键的组合以及系统功能键；Caps Lock 是切换状态键，不作为持续按住键。Baton 会先启动麦克风，再按下该快捷键；松开遥控器时先释放快捷键，并为麦克风保留短暂的音频尾部。

特权组件只会启动经过 Apple 签名验证的 PacketLogger，并只向 Baton 转发 A1962 ATT `0x0023` 中经过格式校验的 Opus 帧，不会转发完整 HCI 抓包。

## 主要功能

### 按键与手势映射

- 七个遥控器按键可分别配置
- 支持普通按键、带修饰键组合及媒体/系统功能键
- 支持录制新按键和输入任意自定义文本
- 触控板提供“鼠标”和“手势”两种模式
- 手势模式支持上、下、左、右滑动映射
- 鼠标模式下不显示无效的滑动配置
- 支持单指移动、双指滚动、轻点单击与按住拖拽

### 陀螺仪光标

支持带运动数据的 A1513/A1962：按住触控板后转动遥控器即可拖动窗口或对象。设置页可调整拖动灵敏度和防抖强度。

Baton 会等待遥控器的 vendor HID 接口完成打开和调度后再启用运动数据，避免首次授权或刚连接时过早写入启用指令。如果启用后持续没有收到运动报告，应用会自动重新初始化陀螺仪，正常情况下不需要退出或重启 Baton。

### 配置与应用预设

Baton 内置以下配置：

- 默认配置：鼠标与常用导航
- Vibe Coding：Claude Code 命令与模式切换
- 演示模式：翻页、黑屏/白屏及全屏演示
- 媒体播放：播放、上一首、下一首、静音和系统音量

你也可以新建、重命名和编辑自己的配置，并按前台应用自动切换配置。新配置会复制当前配置作为起点，但按键映射、滑动映射、自定义文本、自定义快捷键、触控板模式和滚动速度都会独立保存，后续修改不会影响默认配置或其他配置。

### 通用设置

- 登录时启动
- 关闭主窗口后继续在菜单栏运行，或直接退出
- 菜单栏显示遥控器电量百分比
- 跟随系统、浅色、深色三种整体外观
- A1962 实验性虚拟麦克风组件安装与状态检查

### 稳定性处理

- HID 与 AVRCP 双通道去重，避免一次按键触发两次
- 只拦截能够与遥控器 HID 对应的媒体键事件，不影响 Mac 键盘或其他外设
- 按触控表面尺寸识别 Siri Remote，避免误接管 Magic Trackpad
- 多个 HID 接口分批抢占，降低蓝牙 HID 栈在连接瞬间的压力
- 陀螺仪只在 vendor HID 接口就绪后启用，无运动数据时自动重试
- 遥控器断开时自动释放仍按住的虚拟按键
- 睡眠唤醒和输入停顿后自动恢复事件监听与触控板连接
- 对遥控器导致的系统音量变化进行保护，同时允许媒体配置正常调节音量

## 构建

### 环境要求

- macOS 12 或更高版本
- Xcode Command Line Tools：`xcode-select --install`
- 遥控器麦克风：macOS 13+、Bluetooth Logging for macOS / PacketLogger、Apple Bluetooth Logging 配置描述文件、`libopus`

### 编译并打包

```bash
./build.sh
./create_app_bundle.sh
./create_dmg.sh
open Baton.app
```

`build.sh` 是唯一的正式构建入口。项目使用一次 `swiftc` 调用，并链接系统私有的 `MultitouchSupport` 框架；`Package.swift` 仅用于 IDE 索引，不能替代 `build.sh`。

`create_app_bundle.sh` 会生成 `Baton.app`、复制图标、虚拟麦克风驱动、采集辅助程序和 Opus 库，并使用 `Baton.entitlements` 进行签名。

`create_dmg.sh` 会在 `dist/` 下生成包含 `Baton.app` 和“应用程序”快捷方式的安装镜像。公开发布包不包含 Apple 的受限配置文件。

发布时可显式传入版本号和构建号，确保应用版本、DMG 文件名和 Git 标签一致：

```bash
BATON_VERSION="1.0.0" BATON_BUILD_NUMBER="3" ./create_app_bundle.sh
./create_dmg.sh
```

仅在有权使用该文件的本地测试环境中，可显式传入 Apple macOS 配置；脚本会校验其 Payload，配置只放在本地 DMG 根目录，不会进入应用包。不要公开分发由此生成的镜像：

```bash
BATON_BLUETOOTH_PROFILE="/path/to/BluetoothLogging.mobileconfig" ./create_dmg.sh
```

本地开发者可设置稳定签名身份，让辅助功能和输入监控授权在重新构建后继续有效：

```bash
BATON_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./create_app_bundle.sh
```

不设置 `BATON_SIGN_IDENTITY` 时仍使用临时签名，行为与之前一致。

## 权限与首次运行

首次启动时需要在“系统设置 → 隐私与安全性”中允许：

- 辅助功能：发送键盘和鼠标事件
- 输入监控：读取并拦截遥控器输入
- 蓝牙：连接 Siri Remote 并读取电量

建议将 `Baton.app` 移到 `/Applications` 后再授权。临时签名会随二进制变化，重新构建后 macOS 可能要求重新授权。

如果“输入监控”中没有自动出现 Baton，请点击 `+` 手动添加 `Baton.app`。缺少该权限时，音量键或播放键可能仍被系统或音乐应用处理。

完成首次授权后，Baton 会在当前进程中启动遥控器检测并等待 HID 接口就绪，通常不需要手动重启。如果 macOS 自身明确提示必须退出并重新打开应用，请按系统提示操作。

诊断日志写入 `/tmp/baton.log`。

排查陀螺仪时可在日志中搜索 `motion enable sent`。如果蓝牙接口暂时没有开始发送运动数据，还会看到 `motion enable (no motion reports)`；Baton 会继续自动恢复，无需反复重启应用。

开发时可以运行独立检查：

```bash
./Tests/run-tests.sh                 # 触控表面识别单元测试
./Tests/run-touch-surface-probe.sh   # 枚举本机 Multitouch 设备及尺寸
./script/build_and_run.sh --verify   # 构建、打包、启动并确认进程
```

## 项目结构

- `SiriRemoteApp.swift`：应用启动、权限流程和组件装配
- `RemoteDetector.swift` / `RemoteInputHandler.swift`：遥控器发现、HID 抢占和按键解析
- `TouchHandler.swift`：触控板输入、滚动和滑动识别
- `RemoteTouchSurface.swift`：区分 Siri Remote 与 Magic Trackpad
- `MotionCapture.swift`：等待 vendor HID 就绪、启用运动数据、保活与无数据自动恢复
- `MenuBarManager.swift`：配置、映射持久化和动作执行
- `SettingsUI/`：生产使用的原生 SwiftUI 设置界面
- `ble_probe.swift`、`MotionProbe.swift`、`AudioProbe.swift`：硬件研究工具
- `mic-spike/`：A1962 麦克风验证工具，可从 PacketLogger 抓包提取 Opus 帧并解码为 WAV
- `RemoteMicrophoneController.swift` / `RemoteMicrophoneAudio.swift`：HCI 采集控制、Opus 解码和 CoreAudio 定向输出
- `MicCaptureHelper/`：经过调用方与 PacketLogger 签名校验的特权采集组件
- `VirtualMicrophoneDriver/`：基于 Apple 官方示例的 CoreAudio HAL 虚拟输入设备

## 技术说明与限制

Baton 依赖 Apple 私有的 `MultitouchSupport` 框架，并使用未公开的 `NX_SYSDEFINED` 媒体键事件格式，因此不适合提交 Mac App Store，也可能受未来 macOS 更新影响。

虚拟麦克风驱动派生自 Apple 宽松许可的 Audio Server Driver 示例。BlackHole 仅用于研究设备时钟和环形缓冲架构；项目没有复制或嵌入 BlackHole 的 GPL 源码。

同一次物理按键可能同时从 HID 和 AVRCP 到达。Baton 在 HID 层抢占设备，并通过 200 ms 去重窗口把两条路径汇合到同一映射，避免重复触发。媒体键的按下和抬起之间保留必要延迟，防止 macOS 合并或丢弃事件。

用户设置保存在 `UserDefaults` 中，包括按键/滑动映射、按配置隔离的自定义文本与快捷键、配置、应用预设、灵敏度和外观。

## 致谢

Baton 是从 [HyperVibe](https://github.com/machinarii/hypervibe)（[@machinarii](https://github.com/machinarii)）fork 后继续开发的项目。HyperVibe 提供了通过 Apple TV Remote 进行按键与手势自定义、Claude Code 工作流控制等核心基础；感谢原作者的开源工作。

HyperVibe 本身基于 [Remotastic](https://github.com/lauschue/Remotastic)（[@lauschue](https://github.com/lauschue)），后者提供了 Siri Remote HID、`MultitouchSupport` 接入和菜单栏应用的基础实现。

部分图标来自 [The Noun Project](https://thenounproject.com/)：

- [Arrow Up by Dayeong Kim](https://thenounproject.com/icon/arrow-up-6066125/)
- [Microphone by Alvida](https://thenounproject.com/icon/microphone-8162320/)
- [Radio by Kiran Shastry](https://thenounproject.com/icon/radio-2338991/)

## License

详见 [LICENSE](LICENSE)。
