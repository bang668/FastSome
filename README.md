# FastSome

轻量的 macOS 菜单栏启动器，用来打开常用的 App、文件和文件夹。

从**菜单栏**、**程序坞**或**全局快捷键**打开同一块面板。快捷方式按分组整理，在设置里选择布局，点击或按 `⌘` + 数字即可打开。

## 下载

当前版本是 **1.0**，需要 macOS 14 或更高版本。

- [FastSome-1.0.dmg](https://github.com/bang668/FastSome/releases/download/v1.0/FastSome-1.0.dmg)：打开后把 FastSome.app 拖进「应用程序」
- [FastSome-1.0.zip](https://github.com/bang668/FastSome/releases/download/v1.0/FastSome-1.0.zip)：解压后把 FastSome.app 放进「应用程序」

这个包没有经过 Apple 公证。第一次打开时，在 Finder 里按住 Control 点按应用，选择「打开」。

发布页面：[1.0](https://github.com/bang668/FastSome/releases/tag/v1.0)

## 环境

- macOS 14 或更高版本
- 从源码编译需要 Xcode 15 或更高版本

## 编译

```bash
open FastSome.xcodeproj
```

选择 **FastSome** 这个 scheme，然后运行（⌘R）。也可以在终端执行：

```bash
xcodebuild -project FastSome.xcodeproj -scheme FastSome -configuration Debug -destination 'platform=macOS' build
xcodebuild -project FastSome.xcodeproj -scheme FastSome -destination 'platform=macOS' test
```

Debug 编译完成后，用 Xcode 直接运行，或到 DerivedData 里找到生成的应用。

## 功能（v1）

- 菜单栏图标和全局快捷键用来显示或隐藏面板。面板出现在菜单栏图标下方
- App、文件、文件夹快捷方式，按分组存放
- 三种布局：顶部分组加图标网格、左侧分组栏、列表
- 编辑模式：添加和删除、调整顺序、拖到分组名称上即可移动、用对话框重命名分组
- 设置：布局、全局快捷键、登录时打开、是否在程序坞显示图标
- 按住 `⌘` 显示数字提示；`⌘1`–`⌘9` 和 `⌘0` 打开前 10 项
- 打开一项后关闭面板

## 许可证

尚未选择许可证。
