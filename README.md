# FlipPanel Companion / FlipPanel Bridge

这是一个面向折叠屏桌搭场景的双端项目仓库。

- `FlipPanel Companion`
  Android 端控制与展示 App，适配折叠态使用
- `FlipPanel Bridge`
  Windows 端常驻 Agent，负责播放器状态采集、控制转发、局域网广播与封面代理

当前仓库采用 **单仓库（monorepo）** 组织，两端代码、协议、构建脚本和分发流程放在同一个项目里统一维护。

## 项目定位

这个项目的目标不是通用远控，也不是桌面镜像，而是一个围绕音乐播放场景构建的折叠屏陪伴控制台：

- 手机半折叠放在桌面上，作为信息展示与快捷控制终端
- PC 端提供播放状态、控制能力和局域网发现
- 两端通过局域网自动发现与 WebSocket 长连接协作

## 仓库结构

```text
.
├─ FlipPanelFlutter/        Android Flutter 客户端
├─ ReuseDisplay.Agent/      Windows Agent、托盘功能、安装器脚本
├─ docs/archive/            历史文档归档
├─ 可分发安装包/             最终分发产物输出目录
├─ build-distributables.ps1 一键构建全部分发物
├─ KIOSK_SETUP.md           当前 Android kiosk 相关说明
└─ prepare-device-owner.ps1 对失效旧链路的提示脚本
```

## 当前能力

### Android 端

- 折叠态 / 全屏态界面
- 局域网自动发现与自动连接
- WebSocket 状态同步与控制指令发送
- 封面、歌词、播放状态展示
- 常亮、前台服务、开机恢复相关能力

### Windows 端

- 托盘常驻
- 播放/暂停、上一首、下一首、喜欢等控制
- 局域网 UDP 广播发现
- WebSocket 状态推送
- 网易云封面代理
- 单文件 exe、zip 便携包、安装器分发

## 开发环境

当前构建链路默认面向 Windows 开发机：

- Windows
- .NET SDK
- Flutter SDK
- Android SDK
- PowerShell

Android 构建脚本会将工程同步到 ASCII 临时目录，以规避 Windows 下中文路径对 Flutter AOT 构建的影响。

## 构建方式

### 一键构建全部分发物

```powershell
.\build-distributables.ps1
```

### 仅构建 Windows 端

```powershell
.\ReuseDisplay.Agent\installer\build-installer.ps1
```

### 仅构建 Android 端

```powershell
.\FlipPanelFlutter\build-apk.ps1
```

## GitHub Actions

仓库内置了自动构建工作流：

- push 到 `main`
- 提交 Pull Request
- 手动触发 `workflow_dispatch`

工作流会分别构建：

- `FlipPanel Bridge`
- `FlipPanel Companion`

并在 Actions 中上传三个 artifact：

- `flip-panel-bridge`
- `flip-panel-companion`
- `flip-panel-distributables`

## 分发产物

构建完成后，最终产物只会出现在 `可分发安装包` 目录：

- `FlipPanel-Bridge.exe`
- `FlipPanel-Bridge-win-x64.zip`
- `FlipPanelBridgeSetup.exe`
- `FlipPanel-Companion.apk`

这个目录被视为 **唯一最终分发出口**。  
源码仓库内部不再长期保留中间发布目录，中间产物会在临时目录中生成。

## 仓库约定

- `.dotnet-home`、`.gradle-home`
  本地 SDK/CLI 缓存，不属于源码
- `FlipPanelFlutter/build`、`FlipPanelFlutter/.dart_tool`
  Flutter 构建缓存
- `ReuseDisplay.Agent/bin`、`ReuseDisplay.Agent/obj`
  .NET 构建输出
- `docs/archive/`
  历史方案和过时规划，只保留作背景参考，不代表当前实现状态

## Kiosk 相关说明

当前仓库只保留仍然真实存在的 Android kiosk 相关能力，例如：

- `HOME` 候选启动器
- `BootReceiver`
- 前台服务常驻

旧的 `device-owner / DeviceAdminReceiver` 链路已经不再属于当前实现范围。  
详细说明见 [KIOSK_SETUP.md](./KIOSK_SETUP.md)。

## 当前边界

这个项目当前仍有一些明确边界：

- 不以多播放器兼容为目标
- 不提供远程桌面或通用远控能力
- 不包含仍可直接使用的 device-owner 深度锁定方案
- Windows 端分发物当前未做数字签名

## 文档说明

- 根目录文档只描述当前真实状态
- 历史规划文档已移动到 `docs/archive/`
- 如果文档与代码冲突，应以代码和当前构建链路为准
