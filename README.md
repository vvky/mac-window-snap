# mac-window-snap


基于本 Skill，可构建一个轻量级 macOS 原生后台应用，内存占用约 15 MB。它会监听指定应用，按当前屏幕可用区域自动调整窗口大小并居中吸附；新窗口出现时即吸附，跨屏拖动则在松手后触发。

- 宽、高默认各占屏幕可用区域的 **75%**。
- 同屏自由移动，跳过全屏、最小化和特殊窗口。
- 按应用 Bundle ID 配置，应用名单与比例均支持热更新。
- 原生 Swift、单个后台进程、事件驱动，无持续轮询。
- 只管理窗口，不修改应用字体、主题或内容。

## 实现原理

窗口助手使用 **Swift** 编写，是一个轻量的 macOS 原生后台应用，直接调用系统接口管理窗口。安装与配置由 Bash 脚本完成。

安装后，助手在后台运行，并通过 macOS 的 LaunchAgent 在当前用户登录 macOS 时自动启动。

1. **按应用监听**：根据配置中的 Bundle ID，通过 `NSWorkspace` 感知应用启动与退出，再用辅助功能接口 `AXObserver` 监听目标应用的窗口事件，无需循环扫描。
2. **识别所在屏幕**：以窗口与各显示器的重叠面积确定目标屏幕，按扣除菜单栏和 Dock 后的可用区域计算窗口尺寸。
3. **松手后居中**：拖拽期间暂缓调整，收到鼠标松开事件后再处理跨屏窗口。通过辅助功能接口设置大小，并按应用实际接受的尺寸计算居中位置；同屏手动移动不触发吸附。
4. **配置热更新**：`configure` 保存配置并发送一次 `SIGHUP`，助手随即更新应用监听和窗口比例，无需重启。目标应用全部退出后解除窗口与鼠标监听，助手保持空闲等待应用事件。

## 使用

将仓库交给具备本机执行能力的 Agent：

> （示例）请读取 `mac-window-snap/SKILL.md`，帮我安装窗口助手，让 Terminal 和 Ghostty 的窗口自动居中吸附。

需要 macOS 13+、Apple Command Line Tools 和辅助功能权限。新安装默认不管理任何应用。

也可在 Skill 目录手动执行：

```bash
bash scripts/window-snap.sh install
bash scripts/window-snap.sh permissions
bash scripts/window-snap.sh configure --apps com.apple.Safari,com.apple.finder
bash scripts/window-snap.sh status
```

```bash
# 调整宽、高比例
bash scripts/window-snap.sh configure --fraction 0.75
# 暂停所有应用的窗口管理
bash scripts/window-snap.sh configure --apps none
# 卸载到回收站
bash scripts/window-snap.sh uninstall
```

`configure` 写入配置后立即重载，无需重启；手动编辑配置后执行 `reload`。

支持提供标准 macOS 辅助功能窗口接口的应用，特殊窗口可能不适用。升级后可能需要重新授权。系统中的应用名称为 **Mac Window Snap**。

[MIT License](LICENSE)
