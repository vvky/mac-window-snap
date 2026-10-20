---
name: mac-window-snap
description: 为本机 macOS 应用配置多屏自适应窗口居中吸附，按 Bundle ID 选择管理对象，支持新窗口居中、跨屏拖拽松手后居中及配置热更新。用于安装、配置、诊断或卸载窗口助手；不修改应用字体、主题或内容，不管理远程桌面。
---

# Mac 窗口居中吸附

使用随附 Swift 源码和管理脚本。一个事件驱动的后台进程管理指定应用，无持续轮询。默认宽、高各占屏幕可用区域的 75%；新窗口居中，跨屏拖拽松手后调整大小并居中，同屏手动移动不干预。

## 范围

- 需要本机 macOS 13+、已登录的 macOS 桌面会话、Apple Command Line Tools 和本机命令执行能力。
- 新安装默认不管理应用。根据用户指定的应用，从实际 `.app/Contents/Info.plist` 读取 `CFBundleIdentifier`，不要猜测标识、模糊匹配进程或枚举全部应用后批量接管。用户未指定目标时先询问。
- `applications` 为 Bundle ID 字符串数组，支持任意符合格式的标识。数组为空时暂停管理。未启动的应用保持空闲，不主动启动。
- 仅处理普通窗口。跳过全屏、最小化、浮动和对话框，保留 Ghostty Quick Terminal 排除规则。部分应用将设置窗口暴露为普通窗口，无法仅凭窗口角色准确区分；不要承诺适配所有 App。
- 不读取应用内容，不修改字号、主题、Shell、连接或应用偏好设置。
- 同一应用的不同进程各自监听；退出或禁用目标后解除相关监听和待执行动作。所有目标退出后解除窗口与鼠标监听。
- 当前用户安装，无 sudo，不自动安装开发工具。辅助功能授权与身份验证由用户完成，不修改 TCC 数据库或绕过系统安全机制。

## 操作

以本文件所在目录解析脚本绝对路径，不依赖调用者的工作目录。以下命令在 Skill 目录执行：

```bash
bash scripts/window-snap.sh install --dry-run
bash scripts/window-snap.sh install
bash scripts/window-snap.sh permissions
bash scripts/window-snap.sh configure --apps com.apple.Safari,com.apple.finder
bash scripts/window-snap.sh configure --fraction 0.75
bash scripts/window-snap.sh reload
bash scripts/window-snap.sh status
bash scripts/window-snap.sh configure --apps none
bash scripts/window-snap.sh stop
bash scripts/window-snap.sh uninstall
```

`--apps` 替换完整名单。增加或移除单个应用时，先读取现有配置，保留其他管理对象，再写入完整名单。比例范围 0.30–0.95。`configure` 自动发送一次 SIGHUP 并重新调整现有合格窗口；手动编辑配置后需执行 `reload`，没有文件轮询。拖动中仍等待松手。

安装或配置请求授权完成相应本机步骤，不反复询问。先说明一个后台项目与辅助功能权限，再执行 dry-run 和安装。脚本保留现有设置并备份升级前的程序；相同版本复用二进制。无安装凭据或路径冲突时停止并报告，不能覆盖未托管文件。

系统应用名为 **Mac Window Snap**，支持目录为 `~/Library/Application Support/MacWindowSnap/`，启动项为 `local.mac-window-snap`。配置中的应用一律使用 Bundle ID。

安装后检查 `status`：退出码 0 表示就绪或空闲，2 表示缺少辅助功能权限，3 表示配置、进程或监听异常。核对实际 `pid`、`observerActive` 和 `error`；应用未运行时 pid 为 0。权限缺失时执行 `permissions`，由用户添加已安装应用；授权后 reload，必要时只重启助手以刷新权限，再检查状态。不通过反复编译、重装解决授权。

验证新窗口、跨屏松手居中、同屏自由移动、全屏与最小化排除，以及移除应用后停止管理。不能把监听成功当成真实拖拽验证；无法操作界面时请用户验证，不向用户正在使用的会话输入命令。

`stop` 停止当前 macOS 用户会话中的助手，`install` 可恢复。`uninstall` 将明确属于本安装的应用、启动项和支持目录移入回收站，报告原路径、回收站路径和恢复方式。回收站不可用时停止，不永久删除。

交付时说明管理对象、比例、运行与权限状态、已验证行为和未验证部分。不要发布偏好备份、日志、安装凭据或构建产物。
