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
for dependency in codex node flock timeout; do
  command -v "$dependency" >/dev/null || { echo "缺少命令: $dependency"; exit 2; }
done
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
task_codex_dir=${CODEX_HOME:-"$HOME/.codex"}
[[ -d "$task_codex_dir" ]] || { echo "目录不存在: $task_codex_dir"; exit 2; }
task_codex_dir=$(cd -- "$task_codex_dir" && pwd -P)
[[ "$task_codex_dir" != / && "$task_codex_dir" != "$HOME" ]] || exit 2
task_cache="$task_codex_dir/models_cache.json"
[[ ! -L "$task_cache" ]] || { echo '缓存是符号链接，请人工检查。'; exit 2; }

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
restore_on_error() {
  local result=$?
  if ((result != 0)); then
    if ((cache_moved)) && [[ ! -e "$task_cache" ]]; then
      cp -p -- "$task_backup/models_cache.json" "$task_cache"
      echo '刷新失败，已恢复原缓存。'
    fi
    echo "未完成；请查看 $task_backup。后台可能处于停止状态，可运行 codex app-server daemon start。"
  fi
}
trap restore_on_error EXIT
timeout 20s codex app-server daemon version >"$task_backup/versions-before.json" 2>"$task_backup/versions-before.err" || true
timeout 30s codex app-server daemon stop >"$task_backup/stop.log" 2>&1 || echo '后台停止命令未成功，继续检查实际进程。'
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
  codex update
  hash -r
fi
codex --version
# An app may reconnect during the update. Do not alter its active cache.
[[ -z $(scan_processes) ]] || { echo '更新期间客户端重新连接，请退出该客户端后重试。'; exit 1; }
if [[ -f "$task_cache" ]]; then
  mv -- "$task_cache" "$task_backup/models_cache.json"
  cache_moved=1
fi
timeout 60s codex debug models --bundled >"$task_backup/bundled.json" 2>"$task_backup/bundled.err"
timeout 90s codex debug models >"$task_backup/refreshed.json" 2>"$task_backup/refreshed.err"
timeout 30s codex app-server daemon start >"$task_backup/start.log" 2>&1
timeout 20s codex app-server daemon version >"$task_backup/versions-after.json" 2>"$task_backup/versions-after.err" || true
node "$script_dir/report-models.cjs" "$target_model" "$task_backup/bundled.json" "$task_backup/refreshed.json" "$task_cache"
echo "诊断已完成，以上结果不代表 UI 或账号调用权限验证通过。日志: $task_backup"
echo '现在可恢复原会话：codex resume（选择对应会话），并用 /model 检查列表。'
