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
  # 先做配置自检，失败时打印明确原因而非静默
  if ! sudo /usr/sbin/sshd -t -f /etc/ssh/sshd_config_devbox; then
    echo "sshd 配置自检失败，见上方 sshd -t 输出" >&2
  elif sudo /usr/sbin/sshd -f /etc/ssh/sshd_config_devbox; then
    echo "sshd 已启动，监听容器内 22 端口（用户 vscode，仅公钥认证，已授权 $(grep -c . "$AUTH_KEYS") 个公钥）"
  else
    echo "sshd 启动失败" >&2
  fi
else
  echo "未配置 SSH 公钥（设置 SSH_PUBLIC_KEY、挂载 ~/.ssh/*.pub 或 ~/.ssh/authorized_keys），跳过 sshd 启动" >&2
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
