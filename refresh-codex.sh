#!/usr/bin/env bash
# Linux / Bash. Run from an ordinary SSH terminal, outside Codex.
set -Eeuo pipefail
umask 077

usage() {
  echo '用法: bash refresh-codex.sh [--yes] [--skip-update] [--dry-run] [--model MODEL]'
  echo '默认：确认后停止当前用户的 Codex 进程，更新 CLI，备份并刷新模型缓存。'
  echo '保留登录、配置、聊天历史和工作文件。--yes 跳过脚本确认，不跳过更新器提示。'
}
assume_yes=0; skip_update=0; dry_run=0; target_model=gpt-6-astra
while (($#)); do
  case "$1" in
    --yes) assume_yes=1; shift ;;
    --skip-update) skip_update=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --model) [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }; target_model=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
[[ $(uname -s) == Linux ]] || { echo '此脚本仅用于 Linux 服务器。'; exit 2; }
for dependency in codex python3 flock timeout; do
  command -v "$dependency" >/dev/null || { echo "缺少命令: $dependency"; exit 2; }
done
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
task_codex_dir=${CODEX_HOME:-"$HOME/.codex"}
[[ -d "$task_codex_dir" ]] || { echo "目录不存在: $task_codex_dir"; exit 2; }
task_codex_dir=$(cd -- "$task_codex_dir" && pwd -P)
[[ "$task_codex_dir" != / && "$task_codex_dir" != "$HOME" ]] || exit 2
task_cache="$task_codex_dir/models_cache.json"
task_standalone="$task_codex_dir/packages/standalone/current/codex"
[[ ! -L "$task_cache" ]] || { echo '缓存是符号链接，请人工检查。'; exit 2; }

codex_command=$(command -v codex)
codex_real=$(readlink -f "$codex_command" 2>/dev/null || printf '%s' "$codex_command")
standalone_real=$(readlink -f "$task_standalone" 2>/dev/null || true)
if [[ -n "$standalone_real" && "$codex_real" == "$standalone_real" ]]; then
  install_mode=standalone
elif [[ "$codex_real" == */node_modules/@openai/* || "$codex_real" == */node_modules/@openai/codex/* ]]; then
  install_mode=npm
else
  install_mode=other
fi

# Inspect only executables named codex owned by this user; never match command text.
scan_processes() {
  local entry pid exe start
  for entry in /proc/[0-9]*; do
    [[ -O "$entry" ]] || continue
    pid=${entry##*/}
    exe=$(readlink "$entry/exe" 2>/dev/null) || continue
    exe=${exe% (deleted)}
    [[ ${exe##*/} == codex ]] || continue
    start=$(awk '{print $22}' "$entry/stat" 2>/dev/null) || continue
    printf '%s\t%s\t%s\n' "$pid" "$start" "$exe"
  done
}
echo "配置目录: $task_codex_dir"
echo "安装方式: $install_mode"
echo "当前命令: $codex_command"
codex --version
echo '当前用户的 Codex 二进制进程（PID / 启动标识 / 路径）：'
scan_processes
if ((dry_run)); then
  echo '预览完成，没有更新、停止进程或修改缓存。'
  exit 0
fi
[[ -z ${CODEX_THREAD_ID:-} && -z ${CODEX_SESSION_ID:-} ]] || {
  echo '请从普通 SSH 终端运行，不能从 Codex 工具终端内运行此脚本。'; exit 2;
}
ancestor=$PPID
while [[ "$ancestor" =~ ^[0-9]+$ ]] && ((ancestor > 1)); do
  ancestor_exe=$(readlink "/proc/$ancestor/exe" 2>/dev/null || true)
  ancestor_exe=${ancestor_exe% (deleted)}
  [[ ${ancestor_exe##*/} != codex ]] || { echo '检测到 Codex 父进程，请换普通 SSH 终端。'; exit 2; }
  ancestor=$(awk '/^PPid:/ {print $2}' "/proc/$ancestor/status" 2>/dev/null || true)
done
echo '将中断当前用户的所有本地 Codex 任务（包括其他 CODEX_HOME），但不删除会话历史。'
echo '请先保存工作并退出桌面 App/IDE 远程连接，避免自动重连。'
if ((!assume_yes)); then
  read -r -p '确认执行？输入 UPDATE: ' answer
  [[ "$answer" == UPDATE ]] || { echo '已取消。'; exit 0; }
fi
exec 9>"$task_codex_dir/.refresh-codex.lock"
flock -n 9 || { echo '另一个刷新脚本正在运行。'; exit 2; }
task_backup=$(mktemp -d "$task_codex_dir/model-refresh.XXXXXXXX")
echo "备份和诊断目录: $task_backup"
cache_moved=0
failed_stage=初始化
restore_on_error() {
  local result=$?
  if ((result != 0)); then
    if ((cache_moved)) && [[ ! -e "$task_cache" ]]; then
      cp -p -- "$task_backup/models_cache.json" "$task_cache"
      echo '刷新失败，已恢复原缓存。'
    fi
    echo "失败阶段: $failed_stage"
    echo "未完成；请查看 $task_backup。"
    if [[ "$install_mode" == standalone ]]; then
      echo 'standalone 后台可能处于停止状态，可运行 codex app-server daemon start。'
    else
      echo '当前不是 standalone 安装，无需也不能运行 codex app-server daemon start；直接重新启动 codex。'
    fi
  fi
}
trap restore_on_error EXIT
show_failure() {
  local log=$1
  [[ -s "$log" ]] && { echo "错误摘要（$log）："; tail -n 30 "$log"; }
}
if [[ "$install_mode" == standalone ]]; then
  timeout 20s codex app-server daemon version >"$task_backup/versions-before.json" 2>"$task_backup/versions-before.err" || true
  if ! timeout 30s codex app-server daemon stop >"$task_backup/stop.log" 2>&1; then
    echo 'standalone 后台停止命令未成功，继续检查实际进程。'
    show_failure "$task_backup/stop.log"
  fi
else
  printf '{"install_mode":"%s","codex":"%s"}\n' "$install_mode" "$codex_command" >"$task_backup/versions-before.json"
  echo '检测到 npm/其他非 standalone 安装：跳过 daemon stop/start，改由进程检查处理。'
fi
failed_stage=停止旧进程
scan_processes >"$task_backup/processes.tsv"
while IFS=$'\t' read -r pid started exe; do
  [[ -n "$pid" ]] || continue
  current_start=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
  current_exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
  current_exe=${current_exe% (deleted)}
  if [[ "$current_start" == "$started" && "$current_exe" == "$exe" && -O /proc/$pid ]]; then
    kill -TERM "$pid" 2>/dev/null || true
  fi
done <"$task_backup/processes.tsv"
for ((attempt=0; attempt<15; attempt++)); do
  remaining=$(scan_processes)
  [[ -n "$remaining" ]] || break
  sleep 1
done
[[ -z "$remaining" ]] || { echo '仍有 Codex 进程或自动重连；请关闭对应客户端后重试。'; printf '%s\n' "$remaining"; exit 1; }
if ((!skip_update)); then
  failed_stage=更新CLI
  codex update
  hash -r
fi
failed_stage=验证更新后的CLI
codex_command=$(command -v codex)
echo "更新后命令: $codex_command"
codex --version
# An app may reconnect during the update. Do not alter its active cache.
remaining=$(scan_processes)
[[ -z "$remaining" ]] || {
  echo '更新期间客户端重新连接，请退出该客户端后重试：'
  printf '%s\n' "$remaining"
  exit 1
}
failed_stage=备份模型缓存
if [[ -f "$task_cache" ]]; then
  mv -- "$task_cache" "$task_backup/models_cache.json"
  cache_moved=1
fi
failed_stage=读取内置模型目录
if ! timeout 60s codex debug models --bundled >"$task_backup/bundled.json" 2>"$task_backup/bundled.err"; then
  show_failure "$task_backup/bundled.err"
  exit 1
fi
failed_stage=刷新服务端模型目录
if ! timeout 90s codex debug models >"$task_backup/refreshed.json" 2>"$task_backup/refreshed.err"; then
  show_failure "$task_backup/refreshed.err"
  exit 1
fi
if [[ "$install_mode" == standalone ]]; then
  failed_stage=启动standalone后台
  if ! timeout 30s codex app-server daemon start >"$task_backup/start.log" 2>&1; then
    show_failure "$task_backup/start.log"
    exit 1
  fi
  timeout 20s codex app-server daemon version >"$task_backup/versions-after.json" 2>"$task_backup/versions-after.err" || true
else
  echo '非 standalone 安装：跳过 daemon start。下一次运行 codex 时会启动所需进程。' >"$task_backup/start.log"
  printf '{"install_mode":"%s","codex":"%s"}\n' "$install_mode" "$codex_command" >"$task_backup/versions-after.json"
fi
failed_stage=核对模型目录
if ! python3 "$script_dir/report-models.py" "$target_model" "$task_backup/bundled.json" "$task_backup/refreshed.json" "$task_cache"; then
  echo '刷新命令已执行，但尚未确认目标模型进入可见磁盘缓存。'
  show_failure "$task_backup/refreshed.err"
  exit 3
fi
failed_stage=完成
echo "诊断已完成，以上结果不代表 UI 或账号调用权限验证通过。日志: $task_backup"
echo '现在可恢复原会话：codex resume（选择对应会话），并用 /model 检查列表。'
