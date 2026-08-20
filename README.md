# GitHub Runner Tray Icon

基于 PowerShell + Windows 托盘的 GitHub Actions runner 管理程序，可部署到任意 runner 目录（不限于 `C:\actions-runner`）。

## 文件

- `runner-tray.ps1`：主程序（托盘、启动停止、日志窗口、单实例）
- `runner-tray.cmd`：双击启动入口
- `tests/`：Pester 测试（配合 GitHub Actions CI）
- `README.md`：使用说明

## 部署

把 `runner-tray.ps1`、`runner-tray.cmd` 复制到 runner 目录（与 `run.cmd` 同级）即可使用，无需安装脚本。支持任意 runner 目录（不限于 `C:\actions-runner`）。

## 功能

1. 托盘菜单可启动 / 停止本机 GitHub Actions runner
2. 可勾选 **Run on Windows startup** 设置当前用户开机自启动（注册表值按目录哈希命名，多 runner 目录互不覆盖）
3. 托盘图标按 runner 状态显示不同标记：
   - 红色斜线：已停止
   - 绿色圆点：Idle（仅 `Runner.Listener.exe` 存在）
   - 橙色圆环：Busy（检测到 `Runner.Worker.exe`）
   - 灰色圆点：Unknown（存在同名 runner 进程但无法验证目录，通常该进程以其他账号运行，需要以管理员身份运行本工具）
4. 状态切换时弹出气泡通知（菜单 **Show state notifications** 可关闭）
5. 支持查看 **run.cmd 实时输出**（追加写入 `\.trayicon\run-cmd-live.log`，不修改 `run.cmd` 本体，stdout/stderr 均记录）
6. 托盘程序和 runner 宿主都限制为单实例运行

> 状态判断逻辑是基于当前目录下的 `bin\Runner.Listener.exe` / `bin\Runner.Worker.exe` 进程路径，多 runner 并存时互不干扰。

## 启动方式

### 图形界面

双击 `runner-tray.cmd`，启动后会在系统托盘区出现图标。双击托盘图标可打开 **run.cmd 实时输出窗口**。

### 命令行

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File .\runner-tray.ps1
```

## 托盘菜单

- **Runner directory: ...**：当前托盘管控的 runner 目录（只读信息）
- **Status: ...**：当前状态（Idle / Busy / Stopped / Unknown）
- **Start runner**：启动 runner
- **Stop runner**：停止 runner（弹出确认框，避免误中断正在执行的任务）
- **Run on Windows startup**：切换开机自启动
- **Show state notifications**：切换状态变化气泡通知
- **Open latest runner log**：打开最新 runner 诊断日志（`_diag/Runner_*.log`）
- **Live view latest runner log**：打开实时日志窗口（自动刷新最新日志尾部）
- **Live view run.cmd output**：打开 run.cmd 实时输出窗口（自动刷新）
- **Open run.cmd output file**：打开 run.cmd 输出文件（`\.trayicon\run-cmd-live.log`）
- **Open tray host log**：打开托盘宿主日志（`\.trayicon\runner-host.log`）
- **Open README.md**：打开本文档
- **Open runner folder**：打开当前目录
- **Exit tray icon**：退出托盘程序（不会自动停止 runner）

## 命令行辅助参数

```powershell
.\runner-tray.ps1 -Status      # 输出当前状态
.\runner-tray.ps1 -StartRunner # 启动 runner
.\runner-tray.ps1 -StopRunner  # 停止 runner（不弹确认）
.\runner-tray.ps1 -LogPath     # 输出最新诊断日志路径
.\runner-tray.ps1 -SelfTest    # 自检：图标生成、run.cmd/bin 存在性、状态目录可写、自启动状态等
```

## 运行细节

- runner 宿主状态文件保存在 `\.trayicon/`
- 宿主日志文件为 `\.trayicon\runner-host.log`，run.cmd 输出缓存为 `\.trayicon\run-cmd-live.log`；两者超过 5 MB 自动滚动为 `<name>.1`
- 自启动通过注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 写入，仅影响当前用户；值名为 `GitHubRunnerTrayIcon_<目录哈希>`，旧版固定名 `GitHubRunnerTrayIcon` 在关闭自启动时会被一并清理
- 宿主进程优先使用 Windows PowerShell（`powershell.exe`）；仅安装 PowerShell 7 的环境自动回退到 `pwsh`
- 托盘菜单显示 Unknown 状态且无法启动/停止时，请以管理员身份运行本工具

## 注意事项

- **Stop runner** 会结束当前 runner 进程；如果正有任务执行，会一并停止该任务（托盘菜单已加确认，命令行 `-StopRunner` 不确认）
- **Exit tray icon** 只关闭托盘界面，不会停止已运行的 runner

## 安全说明

- `runner-tray.cmd` 与自启动项使用 `-ExecutionPolicy Bypass` 启动脚本，这是本地工具常用的便捷方式；对安全性有更高要求时，建议对 `runner-tray.ps1` 进行代码签名（`Set-AuthenticodeSignature`）后改用受限策略（如 `RemoteSigned`）
- 本工具按当前用户运行。若 runner 以其他账号（如服务账号）运行，普通权限下无法读取其进程路径，托盘会显示 **Unknown** 状态——此时需以管理员身份运行本工具才能看到真实状态
- 状态判断逻辑基于当前目录下的 `Runner.Listener.exe` / `Runner.Worker.exe` 进程，无法区分其他账号同名进程时按 Unknown 处理，不会误操作

## 开发

- CI：`.github/workflows/ci.yml` 在 Windows 上运行 PSScriptAnalyzer（Error 级别）与 Pester 测试（Windows PowerShell 5.1 与 PowerShell 7）
- 本地运行测试：`Invoke-Pester -Path ./tests -Output Detailed`
