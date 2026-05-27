# Kiosk Setup Notes

这份说明只描述当前仓库里仍然存在的 Android 侧 kiosk 相关能力。

## 当前支持的能力

- App 可作为 `HOME` 候选启动器手动设置
- `BootReceiver` 会在开机、锁屏后启动完成、应用升级后重新拉起前台服务
- 前台服务可帮助维持常驻感知和常亮场景

## 建议的系统设置

在目标手机上建议先完成：

- 允许开机自启
- 关闭电池优化
- 允许通知
- 打开开发者选项
- 适当延长自动休眠时间
- 如需更强限制，可手动启用系统的屏幕固定能力

## 设为默认 Home

当前 `FlipPanelFlutter` 已声明为 `HOME` 候选。你可以在手机上：

- 进入默认应用设置
- 找到桌面/Launcher
- 选择 `FlipPanel Companion`

这一步不会自动完成，必须用户手动切换。

## 当前不支持的能力

当前项目 **没有** 声明 `DeviceAdminReceiver`，也 **没有** 可用的 device-owner 接入链路。

这意味着下面这些能力不应再按“现成可用”理解：

- 设备管理员授权
- `adb shell dpm set-device-owner ...`
- 基于 device owner 的深度锁定

`prepare-device-owner.ps1` 现在只保留为提示脚本，防止误以为仓库仍支持这条旧链路。

## 边界说明

即使完成当前支持的系统设置，下面这些能力仍不在现有实现范围内：

- 完全禁止退出
- 厂商 ROM 不杀后台
- 开机 100% 直接进入主界面
- 基于 device owner 的深度系统管控
