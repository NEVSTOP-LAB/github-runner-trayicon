# GitHub Runner Tray Icon

本目录包含一个基于 PowerShell + Windows 托盘的 GitHub Actions runner 管理程序。

## 文件

- [runner-tray.ps1](C:/actions-runner/runner-tray.ps1)：主程序（托盘、启动停止、日志窗口、单实例）
- [runner-tray.cmd](C:/actions-runner/runner-tray.cmd)：双击启动入口
- [README.md](C:/actions-runner/README.md)：使用说明

## 功能

1. 托盘菜单可启动 / 停止本机 GitHub Actions runner
2. 可勾选 **Run on Windows startup** 设置当前用户开机自启动
3. 托盘图标按 runner 状态显示不同标记：
   - 红色斜线：已停止
   - 绿色圆点：Idle（仅 `Runner.Listener.exe` 存在）
   - 橙色圆环：Busy（检测到 `Runner.Worker.exe`）
   - 灰色圆点：Unknown（存在同名 runner 进程但无法验证目录，通常该进程以其他账号运行，需要以管理员身份运行本工具）
4. 支持查看 **run.cmd 实时输出**（不修改 [run.cmd](C:/actions-runner/run.cmd) 本体）
5. 托盘程序和 runner 宿主都限制为单实例运行

> 状态判断逻辑是基于当前目录下的 [Runner.Listener.exe](C:/actions-runner/bin/Runner.Listener.exe) / [Runner.Worker.exe](C:/actions-runner/bin/Runner.Worker.exe) 进程。

## 启动方式

### 图形界面

双击 [runner-tray.cmd](C:/actions-runner/runner-tray.cmd)，启动后会在系统托盘区出现图标。

### 命令行

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File .\runner-tray.ps1
```

## 托盘菜单

- **Start runner**：启动 runner
- **Stop runner**：停止 runner
- **Run on Windows startup**：切换开机自启动
- **Open latest runner log**：打开最新 runner 诊断日志（`_diag/Runner_*.log`）
- **Live view latest runner log**：打开实时日志窗口（自动刷新最新日志尾部）
- **Live view run.cmd output**：打开 run.cmd 实时输出窗口（自动刷新）
- **Open run.cmd output file**：打开 run.cmd 输出文件（`\.trayicon/run-cmd-live.log`）
- **Open tray host log**：打开托盘宿主日志（`\.trayicon/runner-host.log`）
- **Open README.md**：打开本文档
- **Open runner folder**：打开当前目录
- **Exit tray icon**：退出托盘程序（不会自动停止 runner）

## 命令行辅助参数

```powershell
.\runner-tray.ps1 -Status
.\runner-tray.ps1 -StartRunner
.\runner-tray.ps1 -StopRunner
.\runner-tray.ps1 -LogPath
.\runner-tray.ps1 -SelfTest
```

## 运行细节

- runner 宿主状态文件保存在 [\.trayicon/](C:/actions-runner/.trayicon)
- 宿主日志文件为 [runner-host.log](C:/actions-runner/.trayicon/runner-host.log)
- run.cmd 输出缓存文件为 [run-cmd-live.log](C:/actions-runner/.trayicon/run-cmd-live.log)
- 自启动通过注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 写入，仅影响当前用户

## 注意事项

- **Stop runner** 会结束当前 runner 进程；如果正有任务执行，会一并停止该任务
- **Exit tray icon** 只关闭托盘界面，不会停止已运行的 runner
