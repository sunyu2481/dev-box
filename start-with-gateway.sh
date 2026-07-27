#!/usr/bin/env bash
set -u

# ---------------------------------------------------------------------------
# 统一日志：所有子系统的输出都汇聚到本脚本（即容器主进程）的 stdout，
# 因此 `docker logs` 能看到全部日志。每行前缀 `<时间戳> [来源]` 以区分应用：
#   [init]    本启动脚本自身
#   [sshd]    OpenSSH 服务（含认证成功/失败，用于发现爆破）
#   [gateway] Hermes gateway
#
# 时间戳用 bash 内建 printf '%(...)T'（bash 4.2+），避免每行 fork 一次 date。
# 注意 tag_stream 中不能用 `while read | printf` 之外的重量级方案：sshd 在被
# 爆破时日志量很大，逐行 fork 子进程会拖垮容器。
# ---------------------------------------------------------------------------
log_ts() { printf '%(%Y-%m-%dT%H:%M:%S%z)T' -1; }

# 认证失败累计计数写在 /tmp（容器生命周期内有效，重启归零即可）。
# 必须初始化为 0 而非空文件：空内容会让后续 $(( ))算术展开拿到空串。
AUTHFAIL_COUNTER="${TMPDIR:-/tmp}/.devbox-sshd-authfail"
printf '0' > "$AUTHFAIL_COUNTER" 2>/dev/null || true

# 供本脚本自己输出结构化日志
log() { printf '%s [init] %s\n' "$(log_ts)" "$*"; }

# 从 stdin 逐行读取，加上时间戳与来源标签后写到 stdout。
# IFS= 与 -r 保证原始行内容不被改写；末行无换行时 [ -n "$line" ] 兜底输出。
tag_stream() {
  local tag="$1" line
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s [%s] %s\n' "$(log_ts)" "$tag" "$line"
  done
}

# 与 tag_stream 相同，但顺带累计"认证失败"次数到 $AUTHFAIL_COUNTER 文件，
# 供健康汇报读取。计数只在 sshd 流上做，避免给 gateway 流增加无谓开销。
#
# 模式经过去重：一次失败连接会产生多行日志（例如 "Invalid user X" 紧跟
# "Connection closed by invalid user X"），若两者都计数会使统计翻倍。故只匹配
# 每类失败中出现一次的那行：
#   Invalid user          用户名不存在
#   not allowed because   用户名存在但被 AllowUsers/账户锁定拒绝
#   Failed publickey      用户名合法但公钥不被接受
# 用文件而非变量传递：本函数跑在子 shell（进程替换）里，变量无法回传父进程。
tag_stream_sshd() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s [sshd] %s\n' "$(log_ts)" "$line"
    case "$line" in
      *"Invalid user"*|*"not allowed because"*|*"Failed publickey"*)
        # 读-加-写非原子，但这里只有单一写者（本函数），不存在竞争
        printf '%s' "$(( $(cat "$AUTHFAIL_COUNTER" 2>/dev/null || echo 0) + 1 ))" \
          > "$AUTHFAIL_COUNTER" 2>/dev/null || true
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# SSH 服务：仅公钥认证，host key 持久化在 /home/vscode（命名卷/绑定挂载保留）
# 通过环境变量 SSH_PUBLIC_KEY 注入公钥，或直接挂载 ~/.ssh/authorized_keys
# ---------------------------------------------------------------------------
SSH_DIR="$HOME/.ssh"
HOST_KEY_DIR="$SSH_DIR/host_keys"
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$HOST_KEY_DIR"
# StrictModes 会检查家目录本身：绑定挂载常带 group/other 可写位，必须收紧，
# 否则 sshd 拒绝该用户的所有公钥（表现为 "Server refused our key"）。
chmod g-w,o-w "$HOME" 2>/dev/null || true
chmod 700 "$SSH_DIR"

# 首次启动生成持久化 host key，后续复用以保持客户端指纹稳定
[ -f "$HOST_KEY_DIR/ssh_host_ed25519_key" ] \
  || ssh-keygen -q -t ed25519 -f "$HOST_KEY_DIR/ssh_host_ed25519_key" -N ''
[ -f "$HOST_KEY_DIR/ssh_host_rsa_key" ] \
  || ssh-keygen -q -t rsa -b 4096 -f "$HOST_KEY_DIR/ssh_host_rsa_key" -N ''

# 收集公钥来源：环境变量 SSH_PUBLIC_KEY + 挂载到 ~/.ssh 下的任意 *.pub 文件，
# 去重合并进 authorized_keys。三种用法任选其一：
#   1) 启动时设置 SSH_PUBLIC_KEY 环境变量
#   2) 把公钥文件（如 id_ed25519.pub）放到宿主机挂载的 ~/.ssh 目录
#   3) 直接编辑/挂载 ~/.ssh/authorized_keys
collect_keys() {
  [ -n "${SSH_PUBLIC_KEY:-}" ] && printf '%s\n' "$SSH_PUBLIC_KEY"
  cat "$SSH_DIR"/*.pub 2>/dev/null || true
}

new_keys="$(collect_keys)"
if [ -n "$new_keys" ]; then
  touch "$AUTH_KEYS"
  chmod 600 "$AUTH_KEYS" 2>/dev/null || true
  while IFS= read -r key; do
    key="${key%$'\r'}"          # 剥除 CRLF 行尾，避免 Windows 生成的公钥匹配失败
    [ -z "$key" ] && continue
    grep -qxF "$key" "$AUTH_KEYS" || echo "$key" >> "$AUTH_KEYS"
  done <<< "$new_keys"
fi

# 兜底：authorized_keys 可能由用户直接挂载，统一剥除 CRLF 与多余权限
if [ -f "$AUTH_KEYS" ]; then
  sed -i 's/\r$//' "$AUTH_KEYS" 2>/dev/null || true
  chmod 600 "$AUTH_KEYS" 2>/dev/null || true
fi

# 仅在存在已授权公钥时启动 sshd（sshd 需 root，vscode 具备 NOPASSWD sudo）
if [ -s "$AUTH_KEYS" ]; then
  sudo mkdir -p /run/sshd
  # 先做配置自检，失败时打印明确原因而非静默。
  # 注意不能写成 `sshd -t ... | tag_stream`：管道的退出码取自最后一个命令
  # （tag_stream 恒为 0），会把自检失败吞掉。故先捕获输出再判断退出码。
  if ! selftest_out="$(sudo /usr/sbin/sshd -t -f /etc/ssh/sshd_config_devbox 2>&1)"; then
    [ -n "$selftest_out" ] && printf '%s\n' "$selftest_out" | tag_stream sshd
    log "sshd 配置自检失败，见上方 [sshd] 输出"
  else
    # -D 前台运行（不 daemonize，否则 stdio 被重定向到 /dev/null，日志全丢）
    # -e 日志写 stderr 而非 syslog（容器内没有 syslog 守护进程接收）
    #
    # 用进程替换 `> >(tag_stream ...)` 而非管道 `| tag_stream`：管道场景下 `$!`
    # 是管道最后一个命令（tag_stream）的 PID，而 sshd 崩溃后只要仍有子进程持有
    # 写端，tag_stream 就不退出，`kill -0` 会把已死的服务误判为健康。进程替换让
    # `$!` 指向 sshd 自身（此处为 sudo，但 sudo 会随 sshd 一同退出，等效）。
    sudo /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config_devbox > >(tag_stream_sshd) 2>&1 &
    sshd_pid=$!
    sleep 1
    if kill -0 "$sshd_pid" 2>/dev/null; then
      log "sshd 已启动，监听容器内 22 端口（用户 vscode，仅公钥认证，已授权 $(grep -c . "$AUTH_KEYS") 个公钥）"
    else
      log "sshd 启动失败，见上方 [sshd] 输出"
    fi
  fi
else
  log "未配置 SSH 公钥（设置 SSH_PUBLIC_KEY、挂载 ~/.ssh/*.pub 或 ~/.ssh/authorized_keys），跳过 sshd 启动"
fi

# ---------------------------------------------------------------------------
# Hermes gateway：后台启动，最多重试 3 次
#
# 注意：本脚本不是 PID 1，镜像 ENTRYPOINT 为 tini，孤儿进程由 tini 回收。
# sshd 这里以 -D 前台运行（见上），但其 pre-auth 子进程仍可能被 reparent 到 PID 1，
# 因此 PID 1 必须会调用 wait()。不要把本脚本设为 ENTRYPOINT 绕过 tini。
# ---------------------------------------------------------------------------
for attempt in 1 2 3; do
  # stdbuf -oL：gateway 是 Python 进程，stdout 非 tty 时默认块缓冲，
  # 会导致日志延迟数 KB 才出现在 docker logs 中；强制行缓冲以便实时可见。
  # 进程替换而非管道，理由同上（$! 需指向服务自身以便健康检查）。
  # -v 把 stderr 日志级别提到 INFO（默认仅 WARNING 以上，看不到连接/收发状态）。
  # gateway 另有文件日志在 $HERMES_HOME/logs/ 下，内容与 stderr 大量重叠，
  # 故不再 tail 进 stdout，避免 docker logs 里出现双份记录。
  stdbuf -oL -eL hermes gateway run -v --accept-hooks > >(tag_stream gateway) 2>&1 &
  gateway_pid=$!

  sleep 5

  if kill -0 "$gateway_pid" 2>/dev/null; then
    log "hermes gateway 已启动（第 ${attempt} 次尝试）"
    break
  fi

  wait "$gateway_pid" 2>/dev/null || true
  log "hermes gateway 启动失败（第 ${attempt}/3 次尝试），见上方 [gateway] 输出"
done

log "初始化完成，容器进入常驻状态；应用日志以 [sshd] / [gateway] 前缀区分"

# ---------------------------------------------------------------------------
# 常驻 + 周期健康汇报
#
# 原实现是 `exec sleep infinity`，纯粹占位。改为循环后多了一件事：把「僵尸进程
# 数」和「sshd 认证失败次数」定期打进 docker logs，异常无需进容器排查即可发现。
# 这正是此前爆破无人察觉的根因——没有任何东西主动汇报状态。
#
# 注意这里不能再用 exec：进程替换 >(tag_stream) 的写端由本 shell 持有，exec 替换
# 掉 shell 后虽然 FD 被继承（已验证日志不断流），但 shell 一走就没人做汇报了。
# 循环本身开销极低（默认 5 分钟一次，无变化时不输出）。
#
# HEALTH_REPORT_INTERVAL=0 可关闭汇报，此时退化为纯 sleep 常驻。
# ---------------------------------------------------------------------------
report_interval="${HEALTH_REPORT_INTERVAL:-300}"

if [ "$report_interval" -le 0 ] 2>/dev/null; then
  log "健康汇报已关闭（HEALTH_REPORT_INTERVAL=$report_interval）"
  while :; do sleep 3600; done
fi

prev_zombies=0
prev_authfail=0

count_zombies() { ps -eo stat= 2>/dev/null | grep -c '^Z' || true; }
read_authfail() {
  local n
  n="$(cat "$AUTHFAIL_COUNTER" 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$n" ;; esac
}

while :; do
  sleep "$report_interval"

  zombies="$(count_zombies)"
  zombies="${zombies:-0}"
  authfail="$(read_authfail)"

  # sshd 已死则明确告警——否则容器看着在跑，SSH 却连不上
  if [ -n "${sshd_pid:-}" ] && ! kill -0 "$sshd_pid" 2>/dev/null; then
    log "警告：sshd 进程已退出，SSH 将无法连入（可 docker compose restart 恢复）"
    sshd_pid=""
  fi

  if [ -n "${gateway_pid:-}" ] && ! kill -0 "$gateway_pid" 2>/dev/null; then
    log "警告：hermes gateway 进程已退出"
    gateway_pid=""
  fi

  # 认证失败增量即本轮爆破强度。逐条失败在 [sshd] 日志里已有原始记录，
  # 这里给的是聚合视图：扫一眼 [init] 行就能判断是否正在被爆破。
  if [ "$authfail" -gt "$prev_authfail" ]; then
    log "SSH 认证失败 $(( authfail - prev_authfail )) 次（最近 ${report_interval}s，累计 ${authfail} 次）；若非本人操作则为爆破尝试，详见 [sshd] 日志中的来源 IP"
  fi
  prev_authfail="$authfail"

  # 僵尸数增长说明 PID 1 没在回收，属于必须暴露的异常（正常应恒为 0）
  if [ "$zombies" -gt 0 ] && [ "$zombies" -ne "$prev_zombies" ]; then
    log "警告：检测到 $zombies 个僵尸进程（正常应为 0，说明 PID 1 未回收子进程）"
  fi
  prev_zombies="$zombies"
done
