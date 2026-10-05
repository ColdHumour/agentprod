# GitKraken SOCKS5 启动脚本

1. 把 `start-proxy.cmd` 和 `start-proxy.ps1` 放到 **GitKraken 实际 exe 所在的文件夹**，与 `gitkraken.exe` 同级。不要单独搬走 GitKraken 的 exe，它还需要安装目录里的其他文件。
2. 编辑 `start-proxy.ps1` 开头的 `ExeName`、`ProxyHost` 和 `ProxyPort`。默认是 `gitkraken.exe`、`127.0.0.1:1080`；端口只是示例，必须改成实际 SOCKS5 端口。
3. 先运行你的代理服务，并完全退出已有 GitKraken（包括托盘中的进程）。
4. 双击 `start-proxy.cmd`。脚本从自身所在目录启动 exe，并将该目录设为程序工作目录。启动失败会保留窗口显示错误；成功创建进程后窗口关闭，不等待 GitKraken 退出。

PS1 请保存为 **UTF-8 带 BOM**，兼容 Windows PowerShell 5.1 的中文注释。CMD 使用系统自带 Windows PowerShell，不需要安装 Python 或额外模块。`ExecutionPolicy Bypass` 只作用于这次 PowerShell 启动，不持久修改执行策略。

## 代理覆盖范围

- 启动时传递 `--proxy-server="socks5://地址:端口"`，用于支持该参数的 GitKraken Chromium/Electron 网络请求。
- 给新进程设置 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`，值为 `socks5h://地址:端口`，并通过 `GIT_CONFIG_COUNT/KEY/VALUE` 给支持这些变量的 Git 子进程提供临时 `http.proxy`。这些设置不会写入系统环境或 Git 配置文件。
- 本机回环地址保持直连，兼容登录回调。脚本不会启动代理服务，也不会检测出口 IP；“Started”只代表已创建进程。
- **这不是强制流量代理。** GitKraken 不同版本、内置 Git 后端、插件或其他网络模块可能不读取这些参数/变量，不能保证每条连接都走 SOCKS5。仓库已有的 URL 专用代理、remote 代理或 Git 命令行参数也可能覆盖这里的配置。
- Git 的这部分代理配置针对 **HTTP/HTTPS 仓库**；`git@github.com:...`、`ssh://...` 等 **SSH 连接不受它控制**。若必须覆盖 SSH 或全部连接，需要额外配置相应的 SSH 代理或使用进程级代理/TUN 工具。
- Chromium 的 SOCKS5 不支持用户名/密码认证，因此本脚本面向无认证的 SOCKS5 端点（通常是本机代理客户端提供的端口）。

## 验证方法

在代理客户端打开连接日志，然后通过本脚本启动 GitKraken，分别测试登录/集成功能，以及 HTTPS 仓库的 fetch/pull。应能在日志中看到对应目标连接；只看到窗口启动，不能证明联网经过代理。也可以临时停止代理后重试，检查相关请求是否失败，但这不能单独证明所有流量均受控。

未针对你的 GitKraken 版本和代理端点进行实际联网验证。

参考：[GitKraken 代理说明](https://support.gitkraken.com/getting-started/authentication)、[Electron 启动参数](https://www.electronjs.org/docs/latest/api/command-line-switches)、[Git 临时配置环境变量](https://git-scm.com/docs/git-config#_environment)、[Chromium SOCKS5 限制](https://chromium.googlesource.com/chromium/src/+/HEAD/net/docs/proxy.md#socks-v5-proxy-scheme)。
