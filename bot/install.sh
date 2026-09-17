#!/usr/bin/env bash
# nodecoop-bot 一键安装 / 更新脚本
#
#   # BLOCKED external: 下面 URL 指向待发布的 NodeCoop org,暂不改写为不存在的地址;发布后替换。
#   安装(交互):curl -fsSL https://raw.githubusercontent.com/loneup/bot-installer/main/install.sh | sudo bash
#   更新(复用现有配置):curl -fsSL https://raw.githubusercontent.com/loneup/bot-installer/main/install.sh | sudo bash -s update
#   # 下载后:sudo bash install.sh        # 安装
#   #         sudo bash install.sh update # 更新
set -euo pipefail

# BLOCKED external: GitHub org 待 NodeCoop 发布后替换此地址。
REPO="loneup/bot-installer"
BIN_PATH="/usr/local/bin/nodecoop-bot"
CONFIG_DIR="/etc/nodecoop-bot"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
SERVICE="nodecoop-bot"
SERVICE_FILE="/etc/systemd/system/$SERVICE.service"

# ---- 颜色 ----
if [[ -t 1 ]]; then
  R=$'\e[0m'; B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; RED=$'\e[31m'
else R=; B=; G=; Y=; C=; RED=; fi
info(){ echo "${C}▶${R} $*"; }
ok(){ echo "${G}✅${R} $*"; }
warn(){ echo "${Y}⚠${R}  $*"; }
err(){ echo "${RED}✖${R} $*" >&2; }

[[ $EUID -eq 0 ]] || { err "请用 root 运行:sudo bash install.sh"; exit 1; }

# ---- 下载工具 ----
if command -v curl >/dev/null 2>&1; then DLO(){ curl -fsSL -o "$1" "$2"; }
elif command -v wget >/dev/null 2>&1; then DLO(){ wget -qO "$1" "$2"; }
else err "需要 curl 或 wget"; exit 1; fi

# ---- 架构检测 ----
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) err "不支持的架构:$(uname -m)"; exit 1 ;;
esac
[[ "$OS" == "linux" ]] || warn "当前系统 $OS 非 linux,systemd 步骤可能不适用"
ASSET="nodecoop-bot-${OS}-${ARCH}"
URL="https://github.com/$REPO/releases/latest/download/$ASSET"

# ---- 公共:下载二进制 ----
download_binary() {
  info "下载最新版 $ASSET ..."
  local tmp; tmp=$(mktemp)
  if ! DLO "$tmp" "$URL"; then
    err "下载失败:$URL"
    err "确认该 Release 资产已发布(仓库需先打 tag 触发 CI 发版)。"
    rm -f "$tmp"; exit 1
  fi
  install -m 0755 "$tmp" "$BIN_PATH"; rm -f "$tmp"
  ok "二进制已安装:$BIN_PATH ($($BIN_PATH -v 2>/dev/null || echo unknown))"
}

# ---- 公共:写 systemd 服务(幂等)----
write_service() {
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=NodeCoop Telegram bot
After=network.target

[Service]
Type=simple
ExecStart=$BIN_PATH -c $CONFIG_FILE
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
}

# ---- 公共:重启并检查 ----
restart_and_check() {
  systemctl restart "$SERVICE"
  sleep 2
  if systemctl is-active --quiet "$SERVICE"; then
    ok "$SERVICE 运行中($($BIN_PATH -v 2>/dev/null || echo ''))"
  else
    err "$SERVICE 启动失败,最近日志:"
    journalctl -u "$SERVICE" --no-pager -n 20 || true
    exit 1
  fi
}

MODE="${1:-install}"

case "$MODE" in
  # ============ 更新 ============
  update|--update|-u|up)
    echo
    echo "${B}========== nodecoop-bot 更新 ==========${R}"
    [[ -f "$CONFIG_FILE" ]] || warn "未找到 $CONFIG_FILE(仍会更新二进制,但服务可能起不来)"
    download_binary
    [[ -f "$SERVICE_FILE" ]] || write_service   # 老版手动装的没有 unit 时补上
    restart_and_check
    echo
    ok "更新完成!(配置沿用 $CONFIG_FILE)"
    echo "  查看日志:journalctl -u $SERVICE -f"
    ;;

  # ============ 安装(交互)============
  install|"")
    # 交互输入从 /dev/tty 读,兼容 `curl ... | sudo bash` 管道
    TTY=/dev/tty
    ask(){ # ask VAR "提示" "默认值" "必填(1/0)"
      local _var=$1 _prompt=$2 _def=${3:-} _req=${4:-0} _val
      while :; do
        if [[ -n "$_def" ]]; then read -rp "  $_prompt [$_def]: " _val <"$TTY"; _val=${_val:-$_def}
        else read -rp "  $_prompt: " _val <"$TTY"; fi
        [[ -z "$_val" && "$_req" == "1" ]] && { warn "不能为空"; continue; }
        break
      done
      printf -v "$_var" '%s' "$_val"
    }

    echo
    echo "${B}========== nodecoop-bot 一键安装 ==========${R}"
    echo
    info "请输入配置(方括号内为示例,回车采用):"
    ask NODECOOP_URL "主控地址 nodecoop_url"                    "https://control.example.com" 1
    NODECOOP_URL=${NODECOOP_URL%/}
    ask API_TOKEN  "主控 admin API token (nodecoop_api_token)" ""              1
    ask BOT_TOKEN  "Telegram bot token (tg_bot_token)"         ""                   1
    ask ADMIN_IDS  "管理员 TG ID,多个用逗号隔开 (admin_tg_ids)" ""                   1
    ask WEBAPP_URL "Mini App 公网地址 webapp_url(需自配 nginx,可留空)" ""           0

    # admin_tg_ids → YAML 流式列表 [a, b]
    _yaml_ids=""
    IFS=',' read -ra _ids <<<"$ADMIN_IDS"
    for id in "${_ids[@]}"; do
      id="${id//[[:space:]]/}"; [[ -z "$id" ]] && continue
      [[ "$id" =~ ^[0-9]+$ ]] || { err "管理员 ID 必须为数字:$id"; exit 1; }
      _yaml_ids+="${_yaml_ids:+, }$id"
    done
    [[ -n "$_yaml_ids" ]] || { err "至少需要一个管理员 ID"; exit 1; }

    echo
    download_binary

    # 写配置
    mkdir -p "$CONFIG_DIR"
    write_cfg=1
    if [[ -f "$CONFIG_FILE" ]]; then
      read -rp "  $CONFIG_FILE 已存在,覆盖?(y/N): " yn <"$TTY"
      [[ "${yn,,}" == "y" ]] || { warn "保留现有配置,不覆盖"; write_cfg=0; }
    fi
    if [[ "$write_cfg" == "1" ]]; then
      cat >"$CONFIG_FILE" <<EOF
nodecoop_url: $NODECOOP_URL
nodecoop_api_token: $API_TOKEN
tg_bot_token: $BOT_TOKEN
admin_tg_ids: [$_yaml_ids]

# Mini App(默认只听本机回环,由 nginx 反代到公网 HTTPS)
webapp_listen: "127.0.0.1:23088"
webapp_url: "${WEBAPP_URL}"
EOF
      chmod 600 "$CONFIG_FILE"
      ok "配置已写入:$CONFIG_FILE"
    fi

    write_service
    restart_and_check

    echo
    echo "${B}========== 安装完成 ==========${R}"
    echo "  配置文件:$CONFIG_FILE"
    echo "  查看日志:journalctl -u $SERVICE -f"
    echo "  更新版本:curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sudo bash -s update"
    if [[ -n "$WEBAPP_URL" ]]; then
      echo
      warn "Mini App 还需在 nginx 给该域名加反代到 127.0.0.1:23088(location /app 与 /api/tg-webapp/),见 README《Mini App 的 nginx 反代》。"
    fi
    ;;

  *)
    err "未知参数:$MODE(用 install 或 update)"; exit 1
    ;;
esac
