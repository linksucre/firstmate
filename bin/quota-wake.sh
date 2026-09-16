#!/usr/bin/env bash
# quota-wake: 429/限额自动唤醒器 —— 解析限额错误里的重置时间，到点自动向目标
# tmux 窗口（agent 会话）发送唤醒消息，无需人工提醒。
#
# 用法:
#   quota-wake <目标窗口> '<含重置时间的错误消息>'      # 从错误消息自动提取时间
#   quota-wake <目标窗口> '2026-09-14 11:50:19'        # 直接给重置时间
#   quota-wake <目标窗口> '+90s'                       # 相对时间（+秒）
#   quota-wake <目标窗口> '<时间>' '自定义唤醒消息'
#   quota-wake --list                                   # 查看已设置的唤醒
#   quota-wake --cancel <编号>                          # 取消
#
# 目标窗口格式: <session>:<window>（如 firstmate:fm-tsrc-assets-01、firstmate:zsh）
# 时间按本机时区。唤醒动作 = tmux send-keys "<消息>" Enter（pi/omp 会话收到即继续）。
# 自定义消息中的单引号会被剥除（唤醒消息用不到）；含双引号/中文/括号安全。
set -u

STATE="${FM_HOME:-$HOME/firstmate}/state"
REG="$STATE/quota-wakes.tsv"
SESSION="firstmate"
TIMER_PREFIX="qw-"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
die() { echo "error: $*" >&2; exit 1; }

parse_when() {  # stdout: epoch
  local input="$1" m ep
  if [[ "$input" =~ ^\+([0-9]+)s?$ ]]; then
    echo "$(( $(date +%s) + ${BASH_REMATCH[1]} ))"; return 0
  fi
  m=$(printf '%s' "$input" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1)
  [ -n "$m" ] && input="$m"
  ep=$(date -j -f "%Y-%m-%d %H:%M:%S" "$input" "+%s" 2>/dev/null)
  [ -n "$ep" ] || { echo "无法解析时间: $input" >&2; return 1; }
  echo "$ep"
}

cmd_list() {
  echo "== 已登记唤醒（${REG}）=="; [ -f "$REG" ] && cat "$REG" || echo "（空）"
  echo; echo "== 存活定时器（tmux ${TIMER_PREFIX}*）=="
  tmux list-windows -t "$SESSION" 2>/dev/null | grep "$TIMER_PREFIX" || echo "（无）"
}

cmd_cancel() {
  local id="$1"
  tmux kill-window -t "$SESSION:$TIMER_PREFIX$id" 2>/dev/null && echo "定时器 $id 已杀" || echo "定时器 $id 不存在（可能已触发）"
  if [ -f "$REG" ]; then grep -v "^$id	" "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"; fi
  echo "登记已清理"
}

set_wake() {
  local target="$1" when="$2" msg="${3:-}"
  local epoch; epoch=$(parse_when "$when") || exit 1
  local now diff; now=$(date +%s); diff=$(( epoch - now ))
  [ "$diff" -lt 0 ] && die "重置时间已过（$diff 秒前）——限额应已重置，直接给窗口发消息即可"
  local reset_display; reset_display=$(date -r "$epoch" "+%Y-%m-%d %H:%M:%S")
  [ -n "$msg" ] || msg="限额已重置（${reset_display}），请从中断处继续之前的任务。"
  msg=${msg//\'/}   # 剥单引号（runner 用单引号包裹）
  msg=${msg//$'\n'/ }  # 剥换行
  tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qxF "$target" \
    || die "目标窗口不存在: $SESSION:${target}（tmux list-windows -t $SESSION -F \#{window_name} 查看精确名）"
  local id=$(( epoch ))
  mkdir -p "$STATE"; touch "$REG"
  grep -v "^$id	" "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
  printf '%s\t%s\t%s\t%s\n' "$id" "$reset_display" "$SESSION:$target" "$msg" >> "$REG"
  # runner 脚本（避开引号地狱：msg 已无单引号/换行）
  local runner="$STATE/quota-wake-$id.sh"
  cat > "$runner" <<EOF
#!/bin/bash
sleep $diff
tmux send-keys -t '$SESSION:$target' '$msg' Enter
grep -v '^$id	' '$REG' > '$REG.tmp'; mv '$REG.tmp' '$REG'
rm -f '$runner'
tmux kill-window -t '$SESSION:${TIMER_PREFIX}${id}' 2>/dev/null
EOF
  chmod +x "$runner"
  tmux new-window -d -t "$SESSION" -n "${TIMER_PREFIX}${id}" "bash '$runner'" \
    || die "tmux 定时窗口创建失败"
  echo "✅ 唤醒已设置：${reset_display}（${diff}秒后）→ $SESSION:$target"
  echo "   消息：$msg"
  echo "   取消：quota-wake --cancel $id"
}

case "${1:-}" in
  --list) cmd_list ;;
  --cancel) [ -n "${2:-}" ] || die "--cancel 需要编号"; cmd_cancel "$2" ;;
  -h|--help|'') usage ;;
  *) [ $# -ge 2 ] || usage; set_wake "$1" "$2" "${3:-}" ;;
esac
