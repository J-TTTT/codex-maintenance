# Codex Maintenance

Linux 上的 Codex CLI 更新与模型目录刷新工具。停止旧进程、更新 CLI、备份缓存，并分别检查内置目录和实际缓存；保留聊天历史及配置。

## 使用

将仓库克隆到服务器后，进入仓库目录：

```bash
bash refresh-codex.sh --dry-run
bash refresh-codex.sh
```

从普通 SSH 终端执行。执行前保存任务并退出桌面 App/IDE 的远程连接。脚本经确认后会中断当前 Linux 用户的 Codex 进程，包括使用其他配置目录的实例。

```bash
# 不升级 CLI，只刷新后台与模型缓存
bash refresh-codex.sh --skip-update

# 指定要检查的模型
bash refresh-codex.sh --model gpt-6-astra
```

兼容 npm 和官方 standalone 两种 Codex 安装。只有 standalone 安装会执行 `app-server daemon stop/start`；npm 安装会跳过该命令，避免出现 `managed standalone Codex install not found`。依赖：Linux、Bash、Python 3、Codex CLI、flock、timeout。无需 Node.js、rg 或 jq。

详细流程、回滚和故障分析见 [完整攻略](refresh-codex_README.md)。攻略中的绝对路径是原部署示例，请替换为你自己的克隆目录。

脚本清理的是旧运行进程和模型缓存，不删除聊天历史。更新结果不保证账号权限或界面模型列表已经同步。
