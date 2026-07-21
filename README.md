<p align="center">
  <img src="banner.png" alt="Baton — 用 Siri Remote 控制 Mac" width="100%">
</p>

# Baton

Baton 是一款 macOS 菜单栏应用，把 Apple Siri Remote 变成可自定义的鼠标、键盘、演示器和 Claude Code 控制器。

通过遥控器的实体按键、触控板手势与陀螺仪，你可以移动光标、滚动、拖拽、发送快捷键、输入文本或执行 Claude Code 斜杠命令。所有映射都在原生 SwiftUI 设置窗口中完成，不再通过菜单栏子菜单配置。

> 当前暂不提供可下载发行版、自动更新或应用内更新检查。请按照下方步骤从源码构建。

## 支持的遥控器

- 已实际适配：Siri Remote A1513、A1962
- 已纳入 HID 识别：A1969、A2179、A2540 等后续型号
- 不同固件的 HID 报告可能存在差异；未实际验证的型号仍属于实验性支持

麦克风音频目前不支持。按住 Siri 键可以映射为 macOS 或第三方听写工具的快捷键，但 Baton 不会直接读取遥控器麦克风音频。

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

### 配置与应用预设

Baton 内置以下配置：

- 默认配置：鼠标与常用导航
- Vibe Coding：Claude Code 命令与模式切换
- 演示模式：翻页、黑屏/白屏及全屏演示
- 媒体播放：播放、上一首、下一首、静音和系统音量

你也可以新建、重命名和编辑自己的配置，并按前台应用自动切换配置。

### 通用设置

- 登录时启动
- 关闭主窗口后继续在菜单栏运行，或直接退出
- 菜单栏显示遥控器电量百分比
- 跟随系统、浅色、深色三种整体外观

### 稳定性处理

- HID 与 AVRCP 双通道去重，避免一次按键触发两次
- 只拦截能够与遥控器 HID 对应的媒体键事件，不影响 Mac 键盘或其他外设
- 按触控表面尺寸识别 Siri Remote，避免误接管 Magic Trackpad
- 多个 HID 接口分批抢占，降低蓝牙 HID 栈在连接瞬间的压力
- 遥控器断开时自动释放仍按住的虚拟按键
- 睡眠唤醒和输入停顿后自动恢复事件监听与触控板连接
- 对遥控器导致的系统音量变化进行保护，同时允许媒体配置正常调节音量

## 构建

### 环境要求

- macOS 12 或更高版本
- Xcode Command Line Tools：`xcode-select --install`

### 编译并打包

```bash
./build.sh
./create_app_bundle.sh
open Baton.app
```

`build.sh` 是唯一的正式构建入口。项目使用一次 `swiftc` 调用，并链接系统私有的 `MultitouchSupport` 框架；`Package.swift` 仅用于 IDE 索引，不能替代 `build.sh`。

`create_app_bundle.sh` 会生成 `Baton.app`、复制图标与资源，并使用 `Baton.entitlements` 进行临时签名。

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

诊断日志写入 `/tmp/baton.log`。

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
- `MotionCapture.swift`：运动数据启用与保活
- `MenuBarManager.swift`：配置、映射持久化和动作执行
- `SettingsUI/`：生产使用的原生 SwiftUI 设置界面
- `web/`：旧版 React 界面的设计参考，不会打包进应用
- `ble_probe.swift`、`MotionProbe.swift`、`AudioProbe.swift`：硬件研究工具

## 技术说明与限制

Baton 依赖 Apple 私有的 `MultitouchSupport` 框架，并使用未公开的 `NX_SYSDEFINED` 媒体键事件格式，因此不适合提交 Mac App Store，也可能受未来 macOS 更新影响。

同一次物理按键可能同时从 HID 和 AVRCP 到达。Baton 在 HID 层抢占设备，并通过 200 ms 去重窗口把两条路径汇合到同一映射，避免重复触发。媒体键的按下和抬起之间保留必要延迟，防止 macOS 合并或丢弃事件。

用户设置保存在 `UserDefaults` 中，包括按键/滑动映射、自定义文本、自定义快捷键、配置、应用预设、灵敏度和外观。

## 致谢

Baton 基于 [Remotastic](https://github.com/lauschue/Remotastic)（[@lauschue](https://github.com/lauschue)）继续开发。原项目提供了 Siri Remote HID、`MultitouchSupport` 接入和菜单栏应用的基础实现。

部分图标来自 [The Noun Project](https://thenounproject.com/)：

- [Arrow Up by Dayeong Kim](https://thenounproject.com/icon/arrow-up-6066125/)
- [Microphone by Alvida](https://thenounproject.com/icon/microphone-8162320/)
- [Radio by Kiran Shastry](https://thenounproject.com/icon/radio-2338991/)

## License

详见 [LICENSE](LICENSE)。
