PyAppRelease — 操作说明（简明）

简介
- PyAppRelease 是一个基于 PowerShell 的发布流水线，用于将 Python 桌面应用打包为可执行文件并制作 Windows 安装包（使用 PyInstaller + Inno Setup）。

先决条件
- Windows 10/11。
- PowerShell 5.1（脚本头部有 `#Requires -Version 5.1`）。
- Python 3.8+ 已安装，或项目内配置了虚拟环境（推荐使用 `.venv`）。
- Inno Setup（ISCC.exe）用于生成安装程序（可选，如果不需要安装包可跳过）。
- Windows SDK 的 `signtool.exe`（可选，用于代码签名）。

快速启动 — GUI
1. 双击运行 `PyAppRelease-GUI.bat`，或运行：

```powershell
Start-Process powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "F:\MyCode\PyAppRelease\PyAppRelease-GUI.ps1"
```

2. 在 GUI 中：
- 选择包含 `release.config.psd1` 的项目根目录。
- 检查输出目录（默认 `release/`）、版本、签名设置。
- 选择版本 bump（Patch/Minor/Major/Custom），点击 `> Start Release`。

快速启动 — 命令行（批量 / CI）
```powershell
Import-Module .\PyAppRelease.psm1 -Force
# 默认 patch bump
Invoke-PyAppRelease -ConfigFile 'release.config.psd1' -BumpPatch
# 或指定版本
Invoke-PyAppRelease -ConfigFile 'release.config.psd1' -VersionOverride '1.2.3'
```

如何准备 Python 环境
```powershell
cd C:\path\to\project
python -m venv .venv
.venv\Scripts\python.exe -m pip install --upgrade pip
.venv\Scripts\pip.exe install -r requirements.txt
```
如不使用 `.venv`，可在 `release.config.psd1` 中设置 `VenvPython` 指向你的 python 可执行文件。

release.config.psd1 关键字段
- `AppName`：应用名（必须）。
- `EntryScript`：应用入口脚本（如 `main.py`）。
- `VenvPython`：相对于项目根的 python 路径，默认 `.venv\Scripts\python.exe`（工具已实现自动探测 `.venv|venv|.env|env` 或系统 `python`）。
- `OutputDir`：生成物目录，默认 `release`（所有中间/产出文件都放这里）。
- `OneFile`/`Windowed`：PyInstaller 选项。
- `InnoScript` / `InnoDefines`：Inno Setup 模板与变量。
- 签名：通过 GUI 传递环境变量 `PYAPP_SIGN_PFX` / `PYAPP_SIGN_PASSWORD` 或 `PYAPP_SIGN_THUMBPRINT` 给子进程，避免明文写入磁盘。

日志与故障排查
- GUI 跟踪文件：`PyAppRelease_GUI_trace.txt`（脚本目录）。
- GUI 错误文件：`PyAppRelease_GUI_error.txt`（脚本目录）。
- 打包运行时输出会写入临时 `.log` 并在结束后删除；若需要保留输出，可使用 `-DryRun` 或在 Invoke-PyAppRelease 中临时修改行为。

常见问题与解决
- "Python not found": 创建虚拟环境或在 `VenvPython` 指向正确的 python 可执行文件。
- PyInstaller 脚本提示安装在 `%APPDATA%\Python\..\Scripts` 且不在 PATH：这通常是 `pip install --user` 的提示，属于警告（不会中断流程）。可将对应 Scripts 路径加入 PATH 或使用 `.venv`。
- Git 报错 `ignored by .gitignore`: 确保 `release/VERSION` 未被 .gitignore 忽略，或在 release 完成后手动提交，或使用 GUI 中的 SkipGitTag 选项。

改进建议（优先级建议）
1. CI 集成（高）：添加 GitHub Actions（Windows runner）执行 `Invoke-PyAppRelease -DryRun` 或构建打包流程，自动产出构建工件并在合并时触发发布。
2. 单元/集成测试（中高）：使用 Pester 为 PowerShell 模块函数（版本管理、配置解析）添加测试；为示例项目添加简单集成测试。
3. 可复现/确定性构建（中）：锁定 Python 依赖版本（requirements.txt/pip-tools 或 poetry），记录依赖哈希以便可复现构建。
4. 签名凭据安全（中）：将签名证书改用证书存储或云机密（如 Azure Key Vault / GitHub Secrets），在 CI 中安全注入而非明文或临时文件。
5. 提供 headless/CI 模式（中）：增强 `Invoke-PyAppRelease` 的非交互模式（参数化全部确认提示、把输出写到持久文件夹），便于 CI 使用。
6. 文档与样例（低）: 添加 `examples/` 目录下的最小示例项目，包含 `release.config.psd1` 模板和步骤说明。

如何贡献
- 修改 `release.config.psd1` 模板或 `PyAppRelease.psm1`，运行本地 `Invoke-PyAppRelease -DryRun` 验证。
- 建议新功能时，请提交 Issue 并附上复现步骤。

---
文件位置：`OPERATING.md`（已创建在仓库根目录）

如需要，我可以：
- 把这份文档合并到 `README.md` 或 `docs/` 子目录；
- 继续按优先级添加 CI 工作流（我可以为 GitHub Actions 撰写初始工作流文件并推送）；
- 或现在把这份文档提交并推送到远程（我将继续执行）。
