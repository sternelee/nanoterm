# nanoterm 移动端打包指南

本文档说明如何为 macOS 和 Android 打包 nanoterm 移动端应用。

## 快速开始

打包两个平台：
```sh
cd mobile
VERSION=0.1.0 sh package.sh
```

这会生成：
- `zig-out/package/nanoterm-phone-macos-arm64.dmg` - macOS 桌面版本（用于测试）
- `zig-out/android/nanoterm.apk` - Android 安装包

## 单独打包

### macOS DMG

打包 macOS 桌面版本（方便在电脑上测试，无需模拟器）：

```sh
cd mobile
VERSION=0.1.0 sh package-macos.sh
```

输出：
- `zig-out/package/nanoterm-phone.app` - 应用程序包
- `zig-out/package/nanoterm-phone-macos-arm64.dmg` - 磁盘镜像
- `zig-out/package/nanoterm-phone-macos-arm64.dmg.sha256` - 校验和

**代码签名**（可选）：
```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name" sh package-macos.sh
```

### Android APK

打包 Android 版本：

```sh
cd mobile
VERSION=0.1.0 sh package-android.sh
```

输出：
- `zig-out/android/nanoterm.apk` - Android 安装包
- `zig-out/android/nanoterm.apk.sha256` - 校验和

**要求**：
- Android SDK 已安装
- `ANDROID_HOME` 环境变量已设置（脚本会自动检测常见位置）
- NDK 已安装（通过 Android Studio 的 SDK Manager）

## 安装和运行

### macOS

1. 双击 `nanoterm-phone-macos-arm64.dmg` 打开磁盘镜像
2. 将 `nanoterm-phone.app` 拖到 Applications 文件夹
3. 从 Launchpad 或 Applications 启动应用

### Android

通过 adb 安装到设备：

```sh
# 确保设备已连接并启用 USB 调试
adb install zig-out/android/nanoterm.apk

# 启动应用（需要传入连接参数）
adb shell am start -n com.justrach.nanoterm/android.app.NativeActivity \
  --es nanoui.arg.0 --host --es nanoui.arg.1 127.0.0.1 \
  --es nanoui.arg.2 --port --es nanoui.arg.3 4789 \
  --es nanoui.arg.4 --token --es nanoui.arg.5 YOUR-32-CHAR-TOKEN
```

或者通过 Tailscale/USB 连接：

```sh
# USB 连接（adb reverse）
adb reverse tcp:4789 tcp:4789
# 然后使用 host=127.0.0.1, port=4789

# Tailscale 连接
# 使用工作站的 Tailscale IP 地址
```

## 环境变量

- `VERSION` - 版本号（默认从 git tag 读取）
- `ANDROID_HOME` - Android SDK 路径（自动检测）
- `CODESIGN_IDENTITY` - macOS 代码签名身份（可选）
- `TARGET` - Android 目标架构（默认 `aarch64-linux-android`）

## 故障排除

### Android 构建失败

错误：`unable to provide libc for target`

解决：确保 `ANDROID_HOME` 已设置且 NDK 已安装：
```sh
export ANDROID_HOME=$HOME/Library/Android/sdk
# 或通过 Android Studio 安装 NDK
```

### macOS 构建失败

错误：`zig-out/bin/nanoterm not found`

解决：确保 Zig 0.17.0 已安装：
```sh
zig version
# 应该显示 0.17.0 或更高版本
```

### 代码签名问题

错误：`codesign: errSecInternalComponent`

解决：确保签名身份已安装到钥匙串：
```sh
security find-identity -v -p codesigning
# 应该列出可用的签名身份
```

## 文件结构

```
mobile/
├── package.sh              # 打包两个平台
├── package-macos.sh        # 打包 macOS DMG
├── package-android.sh      # 打包 Android APK
├── zig-out/
│   ├── package/
│   │   ├── nanoterm-phone.app
│   │   ├── nanoterm-phone-macos-arm64.dmg
│   │   └── nanoterm-phone-macos-arm64.dmg.sha256
│   └── android/
│       ├── nanoterm.apk
│       └── nanoterm.apk.sha256
```

## 注意事项

1. **macOS DMG** 是桌面版本，用于在没有 iOS 模拟器时测试 UI/UX
2. **Android APK** 是真正的移动端版本，需要在真机或模拟器上运行
3. iOS 真机打包（IPA）需要 Xcode 和 Apple 开发者账号，当前未配置
4. 所有脚本都支持 ad-hoc 签名（无需开发者账号即可测试）
5. 发布到 App Store 或 Google Play 需要正式的代码签名和公证
