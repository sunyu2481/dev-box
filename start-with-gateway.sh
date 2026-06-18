#!/usr/bin/env bash
set -u

# ---------------------------------------------------------------------------
# SSH 服务：仅公钥认证，host key 持久化在 /home/vscode（命名卷/绑定挂载保留）
# 通过环境变量 SSH_PUBLIC_KEY 注入公钥，或直接挂载 ~/.ssh/authorized_keys
# ---------------------------------------------------------------------------
SSH_DIR="$HOME/.ssh"
HOST_KEY_DIR="$SSH_DIR/host_keys"
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$HOST_KEY_DIR"
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
    [ -z "$key" ] && continue
    grep -qxF "$key" "$AUTH_KEYS" || echo "$key" >> "$AUTH_KEYS"
  done <<< "$new_keys"
fi

# 仅在存在已授权公钥时启动 sshd（sshd 需 root，vscode 具备 NOPASSWD sudo）
if [ -s "$AUTH_KEYS" ]; then
  sudo mkdir -p /run/sshd
  if sudo /usr/sbin/sshd -f /etc/ssh/sshd_config_devbox; then
    echo "sshd 已启动，监听容器内 22 端口（用户 vscode，仅公钥认证）"
  else
    echo "sshd 启动失败" >&2
  fi
else
  echo "未配置 SSH 公钥（设置 SSH_PUBLIC_KEY 或挂载 ~/.ssh/authorized_keys），跳过 sshd 启动" >&2
fi

# ---------------------------------------------------------------------------
# Hermes gateway：后台启动，最多重试 3 次
# ---------------------------------------------------------------------------
for _ in 1 2 3; do
  hermes gateway run --accept-hooks &
  gateway_pid=$!

  sleep 5

  if kill -0 "$gateway_pid" 2>/dev/null; then
    break
  fi

  wait "$gateway_pid" 2>/dev/null || true
done

exec sleep infinity
