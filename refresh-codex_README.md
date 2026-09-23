# Codex 更新后模型列表不刷新的处理攻略

适用环境：Linux 服务器上的 Codex CLI；以本机 0.154.0 的命令帮助为依据。

## 一键使用

先保存正在执行的任务，退出桌面 Codex App、IDE 的远程连接，然后从**普通 SSH 终端**运行：

```bash
bash /home/tangjh/codex-maintenance/refresh-codex.sh
```

脚本列出进程并要求输入 `UPDATE`。会停止当前 Linux 用户名下的 Codex 二进制进程，包括其他配置目录中的实例；只在可以中断这些任务时执行。不会终止其他用户的任务，不使用 `kill -9`。

可选用法：

```bash
# 只预览版本与进程，不做更改
bash /home/tangjh/codex-maintenance/refresh-codex.sh --dry-run

# 已升级 CLI，只处理旧进程和模型缓存
bash /home/tangjh/codex-maintenance/refresh-codex.sh --skip-update

# 跳过脚本确认（更新器本身可能仍需交互）
bash /home/tangjh/codex-maintenance/refresh-codex.sh --yes

# 以后换成其他需要检查的模型 ID
bash /home/tangjh/codex-maintenance/refresh-codex.sh --model gpt-6-astra
```

依赖：Bash、Python 3、Codex、flock、timeout 和常见 Linux 工具。不需要 Node.js、rg 或 jq。

## 脚本做什么

1. 检查环境，防止从 Codex 自己的工具终端执行并中断自身。
2. 根据 PATH 中实际执行的 Codex 路径检测安装方式。官方 standalone 安装使用 `codex app-server daemon stop`；npm 或其他安装跳过这个专用命令。即使磁盘上残留另一种安装，也以当前命令为准。随后对剩余的当前用户 Codex 二进制进程发送 SIGTERM；若进程不退出或自动重连，停止操作并报告。
3. 执行 `codex update`，除非指定 `--skip-update`。
4. 把唯一目标 `models_cache.json` 移入一个新的私有备份目录，不覆盖以往备份。
5. 分别获取内置目录和刷新命令结果。仅 standalone 安装重新启动托管后台；npm 安装由用户下次运行 `codex` 时启动所需进程。最后检查实际磁盘缓存。
6. 单独报告目标模型是否存在、可见性、推理强度，以及缓存版本。失败时显示具体阶段和相关日志尾部。未确认进入可见缓存时退出码为 3；其他错误非零，完成检查为 0。

“清除旧会话”在这里指**结束旧的运行进程**。聊天记录、会话数据库、登录、配置、项目文件全部保留。正在执行的工具可能被中断，恢复会话后应核对其执行结果。删除聊天历史并不能修复模型目录，因此脚本不提供批量删除历史功能。

## 为什么旧攻略里的判断需要修正

当时检查到：CLI 为 0.154.0，磁盘缓存标记 0.152.1 且没有 Astra；新版内置目录包含 Astra。这提示存在版本或目录来源不一致，但**仅凭缓存版本不能证明桌面 App 就是原因**。

`codex debug models` 的输出可能使用内置目录回退；输出包含 Astra，不等于成功从服务器刷新，也不等于 `/model` 已更新。启动时能显示模型名称，也不等于已成功完成该模型的请求。脚本不会把这些结果混为一谈。

桌面 App 可能保持旧后台连接或自动重连，服务器 CLI 的升级也不代表桌面 App 已升级。脚本只处理这台 Linux 服务器，桌面端需要单独退出并检查更新。不要为刷新列表重启整台服务器。

## 更新后恢复原会话

```bash
codex resume
```

选择原会话，再运行 `/model`。多个会话并行时，优先使用选择器或明确的会话 ID，避免 `--last` 恢复到其他会话。

若列表仍未出现目标模型，可临时恢复原会话并覆盖模型、强度：

```bash
codex resume SESSION_ID -m gpt-6-astra -c 'model_reasoning_effort="high"'
```

这只是恢复时的绕行方法，不代表已经解决当前界面的热切换问题。支持的强度以实际客户端模型目录为准。

## 失败时检查什么

每次运行会输出 `model-refresh.XXXXXXXX` 目录，保留旧缓存、停止/启动日志、刷新错误输出及更新前后后台版本。目录权限仅当前用户可访问；分享诊断时只分享版本及错误摘要，不要公开完整目录或登录文件。

- 后台仍旧或自动重连：关闭桌面 App/IDE 连接，查看 `versions-after.json`，核实到底运行的是哪个安装路径。
- 内置目录有模型但缓存没有：检查 `refreshed.err`；可能是请求失败、服务端目录差异或另一个客户端写入。不要据此断言一定是账号灰度。
- 缓存有且可见但 UI 没有：检查 UI 实际连接的服务器、用户和配置目录，重连后再次验证。
- `rg: command not found`：只表示普通终端没有该工具；Codex 的工具环境 PATH 可能不同。脚本不依赖它。

如需回滚缓存，先退出相关客户端并停止后台，再把脚本输出目录里的 `models_cache.json` 复制回原配置目录。脚本失败且没有生成替代缓存时会自动恢复旧缓存；不会覆盖失败过程中已生成的新缓存。standalone 后台若保持停止，可运行 `codex app-server daemon start`；npm 安装不要运行该命令，直接重新启动 `codex`。

## npm 安装的特殊说明

如果 `codex app-server daemon start` 报错：

```text
managed standalone Codex install not found
```

说明当前 `codex` 来自 npm、nvm 或其他非 standalone 安装。这个命令只管理 `~/.codex/packages/standalone/current/codex`，不应作为 npm 安装的恢复步骤。新版脚本会自动识别并跳过。`codex update` 显示更新成功但版本号不变，通常表示 npm registry 当前版本与已安装版本相同。

不要手工把内置条目写进服务端缓存，不要改缓存版本号伪装刷新成功，也不要通过删除整个 `.codex` 目录来解决模型问题。
