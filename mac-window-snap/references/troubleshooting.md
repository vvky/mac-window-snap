# 故障排查

## 安装与授权

需要 macOS 13+、Apple Command Line Tools 和已登录的 macOS 桌面会话。没有安装凭据时，脚本拒绝覆盖现有安装；先核对归属，再单独制定备份迁移方案。

系统应用名称为 Mac Window Snap。升级会改变临时签名，可能需要在系统设置的辅助功能列表中移除旧条目，再添加 `~/Applications/Mac Window Snap.app` 并开启。身份验证由用户完成。授权后 reload；若旧进程缓存授权状态，可只重启该助手后再检查 status。

已知限制：首次安装在注册后台任务阶段失败时，可能残留无凭据的支持目录而阻止重试。保留失败产物，检查日志和精确路径后再进行可恢复迁移，不删除用户数据。

## 配置与监听

配置位于 `~/Library/Application Support/MacWindowSnap/settings.plist`：

- `fraction`：0.30–0.95，默认 0.75。
- `applications`：Bundle ID 数组，默认空数组。例如 `com.apple.Safari`。

`configure` 替换指定字段并发送 SIGHUP；直接改文件需调用 reload。无效配置不会覆盖运行中的有效配置，status 会报告 invalid_settings。检查重复标识、非法格式或比例。旧 terminal、ghostty、termius 别名仅在加载旧配置时转换。

status 中 pid 为 0 表示目标未运行；observerActive 表示监听已建立，不表示真实窗口行为已经验证。错误字段包含权限、监听注册、移动或尺寸设置失败原因。日志位于同目录 helper.log。

应用必须公开标准 AXWindow / AXStandardWindow 接口，并允许修改位置与大小。部分程序限制最小尺寸或延迟应用尺寸，最终使用实际大小居中。特殊窗口、弹窗、游戏或自绘界面可能不支持。Ghostty Quick Terminal 通过标识额外排除。

## 恢复

安装备份位于支持目录的 backups 下，包含旧程序、启动项和凭据。升级失败时脚本尝试恢复旧版。手动恢复前先核对当前服务和备份内容，停止助手后恢复对应文件；不要启动第二个窗口管理进程。

卸载会打印原路径与回收站路径。恢复时先确保原路径没有冲突，再移动回原位置并按脚本输出重新注册启动项。旧版本产生的偏好备份仅保留，不自动恢复。本工具不修改字体或主题。

## 旧名称迁移

旧版使用 `Terminal Window Helper.app`、启动项 `local.terminal.windowhelper` 和支持目录 `TerminalWindowHelper`；新版分别为 `Mac Window Snap.app`、`local.mac-window-snap` 和 `MacWindowSnap`。名称变化需要为新应用重新授予辅助功能权限。

在用户授权升级本机后，Agent 按以下顺序迁移：

1. 核对旧应用、启动项和支持目录的绝对路径，检查旧凭据的 label 为 `local.terminal.windowhelper`，启动项指向旧应用。无凭据或路径不符时停止，不覆盖未托管安装。
2. 读取并保留旧 `settings.plist`。先编译新版，确认编译成功；若新名称的目标已经存在，先核对归属和配置，不能覆盖。
3. 停止旧启动项，将旧应用、启动项 plist 和支持目录移入同一个唯一命名的备份目录。使用精确路径，不删除任何文件；报告原路径和备份路径。旧 plist 必须移出 LaunchAgents，避免下次登录 macOS 时重复启动。
4. 执行新版 install，再将保留的 settings.plist 复制到新支持目录并 reload。旧应用别名仍可读取，比例与管理对象保持原值。不要复制旧 receipt.plist，使用新版安装生成的凭据。
5. 为 Mac Window Snap 授权并检查 status。若安装失败，停止新版助手，将新版产物可恢复地移出目标路径，再恢复旧三项并重新注册旧启动项。不要同时运行两版。

迁移只改助手自身文件，不恢复或修改任何应用的字体、主题或其他偏好。
