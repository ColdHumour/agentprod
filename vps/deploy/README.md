# Ubuntu 22.04 VPS 部署 Xray

本方案支持全新 Ubuntu 22.04 VPS，也支持已经运行 Nginx 和 Docker 的服务器。安装器不会停止、重载或改写 Nginx，也不会重启 Docker、修改容器或改写 Docker 配置；它会记录现有公网监听和容器发布端口并在 UFW 中保留。若 TCP 443 已占用，REALITY 自动改用一个未占用的随机高位 TCP 端口。

| 节点 | VPS 端口 |
|---|---|
| VMess AEAD + KCP + DTLS | 安装时随机生成的高位 UDP 端口 |
| VLESS + TCP/RAW + REALITY + Vision | TCP 443；已占用时随机高位 TCP 端口 |

KCP 端口从 `20000..59999` 中使用系统安全随机数选择，同时避开脚本列出的常用高位端口、SSH 端口、REALITY 端口和已经占用的 UDP 端口。UUID、KCP seed、REALITY 密钥和 shortId 也只在 VPS 上生成。

Docker 发布到宿主机的端口可能绕过 UFW。脚本会避免与这些端口冲突并保持现有映射，但不会替你判断每个容器端口是否应该公开；不需要公网访问的容器端口应绑定到 `127.0.0.1`，或在 Docker Compose 中取消 `ports` 发布。

SSH 登录用户名不要求是 `root`，但必须能使用 `sudo` 获得 root 权限。下面用 `YOUR_SSH_USER` 表示 PuTTY 登录时填写的用户名，例如 `ubuntu`、`debian` 或 `root`。Windows 命令会明确要求输入这个用户名。

## 第 1 步：云控制台保留现有规则

这一步在 VPS 厂商的网站管理后台操作，不是在 PuTTY 中输入命令。不同厂商的菜单名称可能是“安全组”“云防火墙”“Firewall”或“Networking”。一般操作路径是：

1. 登录 VPS 厂商网站，进入这台 VPS 的详情页面。
2. 找到“网络”“安全组”或“防火墙”。
3. 打开“入站规则（Inbound rules）”。
4. 保留当前 SSH、网站和确实需要公网访问的容器端口规则，不要删除或修改 Nginx 正在使用的 TCP 80/443 等规则。
5. 保存或应用规则。

需要确认的规则如下：

| 协议 | 端口 | 用途 |
|---|---:|---|
| TCP | 当前 PuTTY 使用的 SSH 端口，通常为 22 | SSH |
| TCP | Nginx 当前使用的端口，例如 80/443 | 保留现有网站 |

SSH 规则已经能用时不要删除或修改。如果需要新建，协议选 TCP，端口填写 PuTTY 当前连接使用的端口。来源地址优先填写你当前公网 IP 加 `/32`；如果公网 IP 会变化或不确定，可以先用 `0.0.0.0/0`，部署完成后再收紧。不要把 SSH 端口误填成 UDP。

如果不确定当前 SSH 端口，可在现有 PuTTY 会话运行：

```bash
echo "$SSH_CONNECTION"
```

输出共有四项，最后一项就是 VPS 的 SSH 端口。例如最后一项是 `22`，云防火墙就必须允许 TCP 22。也可以运行：

```bash
sudo sshd -T | awk '$1 == "port" {print $2}'
```

此时还不知道最终 REALITY 和 KCP 端口，不要预先开放整个高位端口范围。安装完成后，脚本会显示具体的 REALITY TCP 端口和 KCP UDP 端口，再分别添加单端口规则。如果 REALITY 最终使用 443 且网站原本已经开放 443，无需重复添加。

“确认厂商提供网页终端、串口或救援控制台”只需要在 VPS 详情页确认能找到类似入口，暂时不用打开。它用于防火墙误配导致 PuTTY 无法登录时恢复服务器。保存规则后继续保持当前 PuTTY 窗口打开。

## 第 2 步：把部署脚本放到 VPS

下面两种方式任选一种。GitHub 方式不需要从 Windows 上传文件；PSCP 方式适合 GitHub 暂时不可达的情况。

### 方式 A：VPS 从 GitHub 获取

在当前 PuTTY 会话运行。系统询问 sudo 密码时，输入当前 SSH 用户的密码：

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends ca-certificates curl

curl --fail --show-error --location \
  --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/ColdHumour/agentprod/main/vps/deploy/bootstrap.sh \
  -o "$HOME/bootstrap.sh"

sudo bash "$HOME/bootstrap.sh"
```

脚本从 `ColdHumour/agentprod` 的 `main` 分支下载一次完整仓库快照，只取其中的 `/vps/deploy`，拒绝符号链接，检查所需文件与 Bash 语法，然后放到 `/root/xray-vps-kit`。下载归档的 SHA256 和来源记录在 `/root/xray-vps-kit/SOURCE.txt`。

如果需要部署某个确定的 tag 或 commit，可把两条命令中的版本同时固定。例如先把 raw URL 中的 `main` 换成 commit SHA，再运行：

```bash
sudo bash "$HOME/bootstrap.sh" --ref 'COMMIT_SHA'
```

### 方式 B：Windows 使用 PSCP 上传

先在 Windows 下载或克隆仓库，然后打开 PowerShell，进入仓库的部署目录：

```powershell
Set-Location -LiteralPath 'C:\path\to\agentprod\vps\deploy'
```

使用 SSH 密码：

```powershell
.\upload-kit.ps1 -VpsAddress 'YOUR_VPS_IP' -User 'YOUR_SSH_USER' -SshPort 22
```

使用 PuTTY `.ppk` 私钥：

```powershell
.\upload-kit.ps1 -VpsAddress 'YOUR_VPS_IP' -User 'YOUR_SSH_USER' -SshPort 22 -PrivateKey 'C:\path\to\your-key.ppk'
```

脚本会从明确的源码文件清单现场生成临时 ZIP 和 SHA256，调用 `pscp.exe` 上传，并在结束时删除本地临时包。它不会打包 Xray 核心、本地配置、密钥或客户端凭据。

脚本把三个文件上传到当前 SSH 用户的主目录。上传完成后，在 PuTTY 会话运行：

```bash
sudo bash "$HOME/bootstrap.sh" --source-dir "$HOME" --replace
```

两种方式成功时都会显示：

```text
SCRIPT KIT READY: /root/xray-vps-kit
```

## 第 3 步：运行安装前检查

在当前 PuTTY 会话运行：

```bash
sudo env SSH_CONNECTION="$SSH_CONNECTION" bash /root/xray-vps-kit/deploy.sh preflight
```

它会检查 sudo/root 权限、SSH 会话、Ubuntu 22.04、systemd、架构、现有 TCP 监听、Nginx、Docker、UFW、旧代理服务、磁盘空间和 GitHub 连通性。此步骤不会安装 Xray，也不会修改防火墙。输出会说明 TCP 443 是否可供 REALITY 使用。

```text
PREFLIGHT PASSED
Planned proxy ports: REALITY TCP 443; KCP a random high UDP port.
```

出现 `[FAIL]` 时按提示修复后重新运行，不要跳过。

如果检测到 `/root/xray-vps`、`/etc/xray-vps` 等旧部署路径，并且确认要用本部署包替换以前由本部署包管理的 Xray，先执行：

```bash
sudo bash /root/xray-vps-kit/deploy.sh replace-existing --confirm
```

该命令会停止旧 Xray 和旧防火墙回退计时器，把配置、凭据、核心和服务文件移动到 root 私有备份目录，并移除带有本部署包标记的旧 Xray UFW 规则。它不会停止或修改 Nginx、Docker、SSH。检测到非本部署包管理的 Xray/V2Ray、异常系统账户或不明确的 UFW 规则时会拒绝操作。完成后重新运行本节的 `preflight`，通过后再安装。

## 第 4 步：安装并配置 Xray

运行：

```bash
sudo env SSH_CONNECTION="$SSH_CONNECTION" bash /root/xray-vps-kit/deploy.sh install
```

脚本会自动：

1. 再次执行环境检查并安装必要的 Ubuntu 软件包。
2. 记录现有公网监听、Docker 的 TCP/UDP 发布端口，并确认 Nginx 和 Docker 状态。
3. TCP 443 空闲时用于 REALITY；被 Nginx、Docker 或其他服务占用时选择随机高位 TCP 端口。
4. 选择可用的随机 KCP UDP 端口。
5. 探测 VPS 公网地址并验证 REALITY 目标。
6. 从 XTLS/Xray-core 官方 GitHub 获取执行时最新稳定 Release。
7. 校验官方资产 SHA256，并用下载到的核心检查生成配置。
8. 在 VPS 上生成全部 UUID、seed 和密钥。
9. 安装 systemd 服务，保留 Nginx、Docker 端口和现有活动 UFW，再配置 Xray、Fail2ban 和防火墙回退。
10. 在 root 私有目录生成客户端参数和导入链接。

成功时会看到类似输出：

```text
Deployment staged successfully. Keep this SSH window OPEN.
REALITY TCP PORT (add this exact TCP port to the cloud security group): 4xxxx
KCP UDP PORT (add this exact UDP port to the cloud security group): 4xxxx
Open a SECOND PuTTY session within 10 minutes and run the sudo confirmation command.
```

记下实际显示的 REALITY TCP 和 KCP UDP 端口。如果 443 被 Nginx 占用，REALITY 会显示另一个随机端口；每台服务器的数字可能不同。

默认 REALITY 目标是 `www.cloudflare.com`。如果验证失败，并且尚未创建 `/root/xray-vps`，可以换成经过确认支持 TLS 1.3、HTTP/2 且证书名称匹配的其他公网域名：

```bash
sudo env SSH_CONNECTION="$SSH_CONNECTION" bash /root/xray-vps-kit/deploy.sh install --reality-target YOUR_TARGET_HOST
```

通常不要手动指定 KCP 端口。如确有需要，可加 `--kcp-port PORT`；端口仍必须位于允许范围内、不是常用端口并且未被占用。

## 第 5 步：从第二个 SSH 会话确认防火墙

保持原 PuTTY 窗口打开，再新建一个 PuTTY 会话并登录同一台 VPS。在新窗口运行：

```bash
sudo env SSH_CONNECTION="$SSH_CONNECTION" /usr/local/sbin/xray-vps confirm
```

成功标志：

```text
SERVER CONFIRMATION PASSED
```

这里必须使用第二个会话，因为原会话是在 UFW 启用前建立的：即使防火墙已经错误地阻止所有新 SSH 连接，原有 TCP 连接仍可能继续工作。只有成功建立第二条连接，才能证明 SSH 入站规则正确。

如果新窗口无法登录，不要关闭原窗口，也不要确认。等待 10 分钟后，自动回退会恢复部署前的防火墙状态并停止 Xray：原来已启用 UFW 时只移除本次新增的 Xray 规则；原来未启用且没有规则时清空本次规则并重新禁用 UFW。第二个窗口只用于这次防火墙确认；确认成功后，后续操作可以继续在任意一个窗口完成。

## 第 6 步：开放安装输出中的代理端口

回到云厂商安全组，添加以下入站规则（已经存在的规则无需重复添加）：

| 协议 | 端口 | 用途 |
|---|---:|---|
| TCP | 安装输出中的 REALITY 端口 | REALITY |
| UDP | 安装输出中的 KCP 端口 | KCP |

如果没有记下端口，可在 VPS 上运行：

```bash
sudo xray-vps show-client
```

只开放脚本显示的两个单端口，不要开放整个 `20000..59999` 范围。不要删除或替换原有 Nginx 网站规则。

## 第 7 步：显示并复制 v2rayN 分享链接

在 VPS 的 PuTTY 会话中运行：

```bash
sudo xray-vps show-links
```

命令只输出两行：一条 `vmess://...` 和一条 `vless://...`。这是两个不同节点，所以标准格式需要两条 URI；不需要下载文件。先单独复制第一行并在 v2rayN 中导入，再单独复制第二行并导入。服务端 REALITY 私钥不会出现在分享链接中。

## 第 8 步：导入并分别测试两个节点

每复制一行，就在 v2rayN 中执行一次“从剪贴板导入分享链接”。两次导入后应出现：

- `VPS-KCP-DTLS`
- `VPS-REALITY`

先选中其中一个节点并设为活动服务器，使用 v2rayN 的“测试服务器真连接延迟”和网页访问测试。确认后切换到另一个节点再测试一次。

## 日常管理

VPS 常用命令：

```bash
sudo xray-vps status
sudo xray-vps check
sudo xray-vps show-client
sudo journalctl -u xray -n 100 --no-pager
```

怀疑客户端链接泄露时：

```bash
sudo xray-vps rotate-credentials
```

轮换后重新执行 `sudo xray-vps show-links` 并导入新链接；旧节点会立即失效。

## 精简后的文件

| 文件 | 用途 |
|---|---|
| `README.md` | 完整操作说明、设计与验证范围 |
| `bootstrap.sh` | 从 GitHub 或 Windows 上传包取得部署文件 |
| `deploy.sh` | 环境检查、安装、确认、回退和日常管理 |
| `xray_vps.py` | 配置生成、Release 校验、端口选择和监听识别 |
| `upload-kit.ps1` | Windows 生成最小部署包并通过 PSCP 上传 |
| `tests/` | 本地开发验证；不会进入 VPS 部署包 |

## 发布到公开仓库前

只提交 `vps/deploy` 中的源码、文档和测试。不要提交以下内容：

- `client-info.txt`、`links.txt`、`state.json`、实际 `config.json`
- 私钥、`.ppk`、`.pem`、`.env`
- VPS IP、个人 Windows 路径、SSH 主机信息
- 下载的 Xray 二进制、Release ZIP、测试输出和 `__pycache__`

目录中的 `.gitignore` 已覆盖常见敏感输出，但提交前仍应运行：

```bash
git diff --cached
```

逐项检查即将公开的内容。脚本源码中的 GitHub 仓库地址、示例地址和合成测试凭据不具备服务器访问权限。

## 常见失败

- GitHub 获取失败：检查 VPS DNS/HTTPS；也可以改用 Windows PSCP 方式。
- `upload-kit.ps1` 找不到 pscp：确认 PuTTY 已安装，或把 `pscp.exe` 放入 PATH。
- ZIP 提示 `appears to use backslashes as path separators`：这是旧版 Windows 打包方式产生的警告；当前脚本已固定使用 `/`。没有看到 `SCRIPT KIT READY` 时，重新上传后运行 `sudo bash "$HOME/bootstrap.sh" --source-dir "$HOME" --replace`。脚本会临时备份旧目录，新包校验失败时自动恢复。
- `Existing Xray deployment paths`：脚本包的 `--replace` 只更新 `/root/xray-vps-kit`，不会删除已安装状态。确认要重装时使用 `deploy.sh replace-existing --confirm`，然后重新执行 preflight。
- 最新 Xray 与配置不兼容：安装器会在永久安装前停止，不要绕过 `run -test`。
- REALITY 可用而 KCP 不通：核对云安全组开放的是客户端文件中显示的单个 **UDP** 端口。
- KCP 可用而 REALITY 不通：检查安装输出中的实际 REALITY TCP 端口、安全组、VPS 时间以及客户端 SNI、公钥和 shortId。
- 两者都不通：运行 `sudo xray-vps check`，然后检查云安全组和 v2rayN 本地代理端口。

## 验证范围

本地单元测试覆盖配置生成、KCP FinalMask 顺序、客户端链接、私钥隔离、官方 Release 资产校验、TCP/UDP 随机端口和公网监听识别。Windows PowerShell 5.1 会检查上传脚本语法，上传包也会核对文件清单。

`bootstrap.sh` 会在 VPS 上先运行 `bash -n deploy.sh` 和 Python 编译检查。仍需在真实 VPS 上验证 Ubuntu apt、systemd、UFW、Fail2ban、Nginx 网站、Docker 容器服务的外部访问、云安全组和客户端网络的 UDP 可达性。必须保留原 PuTTY 会话，并从第二个会话完成防火墙确认。
