#!/bin/bash

# NodeCoop Control 安装脚本
# 适用于 Debian/Ubuntu Linux 系统

set -e

# 配置
# 公开安装源：loneup/nodecoop（公开分发仓）
GITHUB_REPO="loneup/nodecoop"
VERSION=""          # 将自动获取最新版本
ARCH=""             # amd64 或 arm64
ASSET_NAME=""       # nodecoop-linux-<arch>.tar.gz
EXTRACTED_NAME=""   # 解压出的二进制文件名
INSTALL_DIR="/usr/local/bin"
SERVICE_NAME="nodecoop"
DATA_DIR="/etc/nodecoop"
CONFIG_DIR="/etc/nodecoop"

# 全局：临时工作目录（下载/解压/校验在私有目录进行）
WORK_DIR=""

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ---------------------------------------------------------------------------
# 清理私有临时目录（注册在 EXIT trap，无论成功/失败都清理）
# ---------------------------------------------------------------------------
cleanup_workdir() {
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup_workdir EXIT

# ---------------------------------------------------------------------------
# 回滚：恢复旧二进制备份（若存在）；否则移除新二进制
# ---------------------------------------------------------------------------
rollback_install() {
    if [ -f "$INSTALL_DIR/${SERVICE_NAME}.bak" ]; then
        echo_warn "回滚到旧版本..."
        mv -f "$INSTALL_DIR/${SERVICE_NAME}.bak" "$INSTALL_DIR/$SERVICE_NAME"
        echo_info "已恢复旧版本"
    else
        echo_warn "无旧版本可回滚，移除新二进制..."
        rm -f "$INSTALL_DIR/$SERVICE_NAME"
    fi
}

# ---------------------------------------------------------------------------
# 校验 SHA256（从 Release 的 SHA256SUMS 获取期望值）
# ---------------------------------------------------------------------------
verify_sha256() {
    local file="$1"       # 待校验文件
    local sums="$2"        # SHA256SUMS 文件路径
    local asset_name="$3"  # 资产文件名（如 nodecoop-linux-amd64.tar.gz）

    if ! command -v sha256sum >/dev/null 2>&1; then
        echo_warn "未找到 sha256sum 命令，跳过 SHA256 校验"
        return 0
    fi

    # SHA256SUMS 格式：hash  filename
    local expected
    expected=$(awk -v n="$asset_name" '$2 == n { print $1 }' "$sums")
    if [ -z "$expected" ]; then
        echo_error "SHA256SUMS 中未找到 $asset_name 的校验值"
        exit 1
    fi

    local actual
    actual=$(sha256sum "$file" | awk '{ print $1 }')
    if [ "$actual" != "$expected" ]; then
        echo_error "SHA256 校验失败！"
        echo_error "期望: $expected"
        echo_error "实际: $actual"
        exit 1
    fi
    echo_info "SHA256 校验通过 ($asset_name)"
}

# ---------------------------------------------------------------------------
# ELF 架构校验：确认解压出的文件是 Linux 可执行文件，且机器架构匹配
# ---------------------------------------------------------------------------
verify_elf() {
    local bin="$1"
    local expect_arch="$2"

    if ! command -v file >/dev/null 2>&1; then
        echo_warn "未找到 file 命令，跳过 ELF 架构校验"
        return 0
    fi

    local desc
    desc=$(file -b "$bin" 2>/dev/null || true)

    if ! echo "$desc" | grep -qi "ELF"; then
        echo_error "下载的文件不是 ELF 可执行文件: $desc"
        return 1
    fi

    case "$expect_arch" in
        amd64)
            if ! echo "$desc" | grep -qiE "x86-?64|x86_64"; then
                echo_error "ELF 架构不匹配：期望 x86-64，实际: $desc"
                return 1
            fi
            ;;
        arm64)
            if ! echo "$desc" | grep -qiE "aarch64|ARM aarch64"; then
                echo_error "ELF 架构不匹配：期望 aarch64，实际: $desc"
                return 1
            fi
            ;;
    esac

    echo_info "ELF 架构校验通过: $desc"
    return 0
}

# ---------------------------------------------------------------------------
# 健康检查：新二进制 --version 输出非空
# ---------------------------------------------------------------------------
health_check_binary() {
    local bin="$1"
    echo_info "健康检查: $bin --version ..."
    local ver
    ver=$("$bin" --version 2>/dev/null || "$bin" -v 2>/dev/null || true)
    if [ -z "$ver" ]; then
        echo_error "健康检查失败：二进制 --version / -v 无输出"
        return 1
    fi
    echo_info "版本信息: $ver"
    return 0
}

# ---------------------------------------------------------------------------
# 检查 root 权限
# ---------------------------------------------------------------------------
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo_error "请使用 root 权限运行此脚本"
        echo_info "使用命令: sudo bash install.sh"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# 检查系统架构
# ---------------------------------------------------------------------------
check_architecture() {
    local raw_arch
    raw_arch=$(uname -m)
    echo_info "检测到系统架构: $raw_arch"

    case "$raw_arch" in
        x86_64|amd64)
            ARCH="amd64"
            ASSET_NAME="nodecoop-linux-amd64.tar.gz"
            EXTRACTED_NAME="nodecoop-linux-amd64"
            echo_info "使用 AMD64 版本"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ASSET_NAME="nodecoop-linux-arm64.tar.gz"
            EXTRACTED_NAME="nodecoop-linux-arm64"
            echo_info "使用 ARM64 版本"
            ;;
        *)
            echo_error "不支持的架构: $raw_arch"
            echo_error "支持的架构: x86_64 (amd64), aarch64 (arm64)"
            exit 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 安装依赖
# ---------------------------------------------------------------------------
install_dependencies() {
    echo_info "检查并安装依赖..."
    apt-get update -qq
    apt-get install -y wget curl jq systemd >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 获取最新版本号（通过 GitHub API）
# ---------------------------------------------------------------------------
get_latest_version() {
    if [ -z "$VERSION" ]; then
        echo_info "获取最新版本..."
        VERSION=$(curl -sL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | jq -r '.tag_name')
        if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
            echo_error "无法获取最新版本号，请检查网络连接"
            exit 1
        fi
        echo_info "最新版本: $VERSION"
    fi
}

# ---------------------------------------------------------------------------
# 下载 Release 资产（tar.gz）+ SHA256SUMS → 校验 → 解压到私有临时目录
# ---------------------------------------------------------------------------
download_binary() {
    echo_info "下载 $SERVICE_NAME $VERSION ($ARCH)..."
    local download_url="https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/${ASSET_NAME}"
    local checksum_url="https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/SHA256SUMS"

    # 创建私有临时目录（trap 保证退出时清理）
    WORK_DIR=$(mktemp -d)
    echo_info "使用临时目录: $WORK_DIR"

    # 下载 tar.gz
    if ! wget -q --show-progress "$download_url" -O "$WORK_DIR/$ASSET_NAME"; then
        echo_error "下载失败: $download_url"
        echo_error "请检查网络连接或版本号"
        exit 1
    fi
    echo_info "下载完成: $ASSET_NAME"

    # 下载 SHA256SUMS
    if ! wget -q "$checksum_url" -O "$WORK_DIR/SHA256SUMS"; then
        echo_error "下载校验文件失败: $checksum_url"
        exit 1
    fi

    # SHA256 校验
    verify_sha256 "$WORK_DIR/$ASSET_NAME" "$WORK_DIR/SHA256SUMS" "$ASSET_NAME"

    # 解压到临时目录（仅限临时目录，不触碰根文件系统）
    echo_info "解压归档..."
    if ! tar -xzf "$WORK_DIR/$ASSET_NAME" -C "$WORK_DIR"; then
        echo_error "解压失败: $ASSET_NAME"
        exit 1
    fi

    local extracted="$WORK_DIR/$EXTRACTED_NAME"
    if [ ! -f "$extracted" ]; then
        echo_error "归档中未找到预期文件: $EXTRACTED_NAME"
        echo_info  "归档实际内容:"
        tar -tzf "$WORK_DIR/$ASSET_NAME" || true
        exit 1
    fi

    # ELF 架构校验
    if ! verify_elf "$extracted" "$ARCH"; then
        exit 1
    fi

    DOWNLOADED_BIN="$extracted"
}

# ---------------------------------------------------------------------------
# 原子安装二进制文件（install 命令，reserve .bak 回滚）
# ---------------------------------------------------------------------------
install_binary() {
    echo_info "安装二进制文件..."

    # 若已有旧版本，保留备份（失败可回滚）
    if [ -f "$INSTALL_DIR/$SERVICE_NAME" ]; then
        cp -p "$INSTALL_DIR/$SERVICE_NAME" "$INSTALL_DIR/${SERVICE_NAME}.bak"
        echo_info "已备份旧版本到 $INSTALL_DIR/${SERVICE_NAME}.bak"
    fi

    # install 原子替换（拷贝到目标，0755 权限）
    install -m 0755 "$DOWNLOADED_BIN" "$INSTALL_DIR/$SERVICE_NAME"
    echo_info "已安装到 $INSTALL_DIR/$SERVICE_NAME"

    # 健康检查
    if ! health_check_binary "$INSTALL_DIR/$SERVICE_NAME"; then
        rollback_install
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# 创建数据目录
# ---------------------------------------------------------------------------
create_directories() {
    echo_info "创建数据目录..."
    mkdir -p "$DATA_DIR"
    mkdir -p "$CONFIG_DIR"
    chmod 755 "$DATA_DIR"
    chmod 755 "$CONFIG_DIR"
}

# ---------------------------------------------------------------------------
# 创建 systemd 服务
# ---------------------------------------------------------------------------
create_systemd_service() {
    echo_info "创建 systemd 服务..."

    echo ""
    if [ -t 0 ]; then
        read -p "请输入端口号（默认 28080，直接回车使用默认值）: " PORT_INPUT
        if [ -z "$PORT_INPUT" ]; then
            PORT_INPUT=28080
        fi
    else
        PORT_INPUT=${PORT:-28080}
        echo_info "使用端口: $PORT_INPUT"
    fi

    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=NodeCoop - Xray 多服务器管理面板
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$DATA_DIR
ExecStart=$INSTALL_DIR/$SERVICE_NAME
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SERVICE_NAME

# 环境变量
Environment="PORT=$PORT_INPUT"
Environment="DATABASE_PATH=$DATA_DIR/nodecoop.db"
Environment="LOG_LEVEL=info"

# 安全选项
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    echo_info "systemd 服务已创建（端口: $PORT_INPUT）"
}

# ---------------------------------------------------------------------------
# 启动服务
# ---------------------------------------------------------------------------
start_service() {
    echo_info "启动服务..."
    systemctl enable ${SERVICE_NAME}.service
    systemctl start ${SERVICE_NAME}.service
    sleep 2

    if systemctl is-active --quiet ${SERVICE_NAME}.service; then
        echo_info "服务启动成功！"
        return 0
    else
        echo_error "服务启动失败"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 显示安装状态
# ---------------------------------------------------------------------------
show_status() {
    local configured_port
    configured_port=$(grep "Environment=\"PORT=" /etc/systemd/system/${SERVICE_NAME}.service | sed 's/.*PORT=\([0-9]*\).*/\1/')
    configured_port=${configured_port:-28080}

    echo ""
    echo "======================================"
    echo_info "NodeCoop 安装完成！"
    echo "======================================"
    echo ""
    echo "📦 安装位置: $INSTALL_DIR/$SERVICE_NAME"
    echo "💾 数据目录: $DATA_DIR"
    echo "🌐 访问地址: http://$(hostname -I | awk '{print $1}'):$configured_port"
    echo ""
    echo "常用命令:"
    echo "  启动服务: systemctl start $SERVICE_NAME"
    echo "  停止服务: systemctl stop $SERVICE_NAME"
    echo "  重启服务: systemctl restart $SERVICE_NAME"
    echo "  查看状态: systemctl status $SERVICE_NAME"
    echo "  查看日志: journalctl -u $SERVICE_NAME -f"
    echo "  更新版本: curl -sL https://raw.githubusercontent.com/${GITHUB_REPO}/main/install.sh | sudo bash -s update"
    echo "  覆盖安装: curl -sL https://raw.githubusercontent.com/${GITHUB_REPO}/main/install.sh | sudo bash -s reinstall"
    echo "  卸载服务: curl -sL https://raw.githubusercontent.com/${GITHUB_REPO}/main/install.sh | sudo bash -s uninstall"
    echo ""
    echo "⚠️  首次访问需要完成初始化配置"
    echo ""
}

# ---------------------------------------------------------------------------
# 更新服务（备份由 install_binary 统一处理）
# ---------------------------------------------------------------------------
update_service() {
    echo_info "开始更新 NodeCoop..."
    echo ""

    if [ ! -f "$INSTALL_DIR/$SERVICE_NAME" ]; then
        echo_error "未检测到已安装的服务，请先使用安装模式"
        exit 1
    fi

    # 显示当前版本
    if [ -f "$DATA_DIR/.version" ]; then
        local current_version
        current_version=$(cat "$DATA_DIR/.version")
        echo_info "当前版本: $current_version"
    fi
    echo_info "目标版本: $VERSION"
    echo ""

    # 停止服务
    echo_info "停止服务..."
    systemctl stop ${SERVICE_NAME}.service || true

    # 下载并安装新版本（install_binary 内做备份+原子替换+健康检查）
    download_binary
    install_binary

    # 保存版本信息
    echo "$VERSION" > "$DATA_DIR/.version"

    # 端口处理
    local current_port
    current_port=$(grep "Environment=\"PORT=" /etc/systemd/system/${SERVICE_NAME}.service 2>/dev/null | sed 's/.*PORT=\([0-9]*\).*/\1/')
    current_port=${current_port:-28080}
    echo ""
    if [ -t 0 ]; then
        read -p "请输入端口号（默认 $current_port，直接回车使用默认值）: " PORT_INPUT
        if [ -z "$PORT_INPUT" ]; then
            PORT_INPUT=$current_port
        fi
    else
        PORT_INPUT=${PORT:-$current_port}
        echo_info "使用端口: $PORT_INPUT"
    fi

    # 更新 systemd 服务文件中的端口
    sed -i "s/Environment=\"PORT=[0-9]*\"/Environment=\"PORT=$PORT_INPUT\"/" /etc/systemd/system/${SERVICE_NAME}.service
    systemctl daemon-reload

    # 启动服务
    if start_service; then
        echo ""
        echo "======================================"
        echo_info "更新完成！"
        echo "======================================"
        echo ""
        echo "📦 版本: $VERSION"
        echo "🌐 访问地址: http://$(hostname -I | awk '{print $1}'):$PORT_INPUT"
        echo ""
        echo "如遇问题可回滚到备份版本:"
        echo "  sudo systemctl stop $SERVICE_NAME"
        echo "  sudo mv $INSTALL_DIR/${SERVICE_NAME}.bak $INSTALL_DIR/$SERVICE_NAME"
        echo "  sudo systemctl start $SERVICE_NAME"
        echo ""
    else
        echo_error "更新后服务启动失败，正在回滚..."
        if [ -f "$INSTALL_DIR/${SERVICE_NAME}.bak" ]; then
            mv -f "$INSTALL_DIR/${SERVICE_NAME}.bak" "$INSTALL_DIR/$SERVICE_NAME"
            systemctl start ${SERVICE_NAME}.service || true
            echo_error "已回滚到之前版本"
        fi
        echo_error "请查看日志: journalctl -u $SERVICE_NAME -n 50"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# 卸载服务
# ---------------------------------------------------------------------------
uninstall_service() {
    echo_info "开始卸载 NodeCoop..."
    echo ""

    if [ ! -f "$INSTALL_DIR/$SERVICE_NAME" ]; then
        echo_error "未检测到已安装的服务"
        exit 1
    fi

    if [ -f "$DATA_DIR/.version" ]; then
        local current_version
        current_version=$(cat "$DATA_DIR/.version")
        echo_info "当前版本: $current_version"
        echo ""
    fi

    # 停止并禁用服务
    echo_info "停止并禁用服务..."
    systemctl stop ${SERVICE_NAME}.service || true
    systemctl disable ${SERVICE_NAME}.service || true
    echo_info "✓ 服务已停止"
    echo ""

    # 询问是否保留配置和数据
    KEEP_DATA=false
    if [ -t 0 ]; then
        echo "是否保留配置和数据？"
        echo "  1) 完全删除（删除所有文件和数据）"
        echo "  2) 保留数据（保留 $DATA_DIR 和 $CONFIG_DIR 目录）"
        read -p "请选择 (1/2，默认 2): " CHOICE
        if [ "$CHOICE" = "1" ]; then
            KEEP_DATA=false
        else
            KEEP_DATA=true
        fi
    else
        if [ "$KEEP_DATA" != "false" ]; then
            KEEP_DATA=true
        fi
        if [ "$KEEP_DATA" = "true" ]; then
            echo_info "保留数据模式"
        else
            echo_info "完全删除模式"
        fi
    fi
    echo ""

    # 删除 systemd 服务文件
    echo_info "删除 systemd 服务..."
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    systemctl daemon-reload
    echo_info "✓ systemd 服务已删除"
    echo ""

    # 删除二进制文件
    echo_info "删除程序文件..."
    rm -f "$INSTALL_DIR/$SERVICE_NAME" "$INSTALL_DIR/${SERVICE_NAME}.bak"
    echo_info "✓ 程序文件已删除"
    echo ""

    # 根据选择删除或保留数据
    if [ "$KEEP_DATA" = "false" ]; then
        echo_info "删除数据和配置..."
        rm -rf "$DATA_DIR" "$CONFIG_DIR"
        echo_info "✓ 数据和配置已删除"
        echo ""
        echo "======================================"
        echo_info "卸载完成！所有文件已删除"
        echo "======================================"
    else
        echo_info "保留数据目录: $DATA_DIR"
        echo_info "保留配置目录: $CONFIG_DIR"
        echo ""
        echo "======================================"
        echo_info "卸载完成！配置和数据已保留"
        echo "======================================"
        echo ""
        echo "如需重新安装:"
        echo "  curl -sL https://raw.githubusercontent.com/${GITHUB_REPO}/main/install.sh | sudo bash"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# 覆盖安装（全量重装，保留数据）
# ---------------------------------------------------------------------------
reinstall_service() {
    echo_info "开始覆盖安装 NodeCoop..."
    echo ""

    # 停止已有服务
    if systemctl is-active --quiet ${SERVICE_NAME}.service 2>/dev/null; then
        echo_info "停止现有服务..."
        systemctl stop ${SERVICE_NAME}.service || true
    fi

    # 下载安装（install_binary 内做备份+原子替换+健康检查）
    download_binary
    install_binary
    create_directories
    create_systemd_service

    # 保存版本信息
    echo "$VERSION" > "$DATA_DIR/.version"

    if start_service; then
        show_status
        echo_info "覆盖安装完成！数据已保留。"
        echo ""
        echo "如遇问题可回滚到备份版本:"
        echo "  sudo systemctl stop $SERVICE_NAME"
        echo "  sudo mv $INSTALL_DIR/${SERVICE_NAME}.bak $INSTALL_DIR/$SERVICE_NAME"
        echo "  sudo systemctl start $SERVICE_NAME"
        echo ""
    else
        echo_error "覆盖安装后服务启动失败，正在回滚..."
        if [ -f "$INSTALL_DIR/${SERVICE_NAME}.bak" ]; then
            mv -f "$INSTALL_DIR/${SERVICE_NAME}.bak" "$INSTALL_DIR/$SERVICE_NAME"
            systemctl start ${SERVICE_NAME}.service || true
            echo_error "已回滚到之前版本"
        fi
        echo_error "请查看日志: journalctl -u $SERVICE_NAME -n 50"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# 主入口
# ---------------------------------------------------------------------------
main() {
    if [ "$1" = "update" ]; then
        echo_info "进入更新模式..."
        check_root
        check_architecture
        install_dependencies
        get_latest_version
        update_service
    elif [ "$1" = "reinstall" ]; then
        echo_info "进入覆盖安装模式..."
        check_root
        check_architecture
        install_dependencies
        get_latest_version
        reinstall_service
    elif [ "$1" = "uninstall" ]; then
        echo_info "进入卸载模式..."
        check_root
        uninstall_service
    else
        echo_info "开始安装 NodeCoop..."
        echo ""

        check_root
        check_architecture
        install_dependencies
        get_latest_version
        download_binary
        install_binary
        create_directories
        create_systemd_service

        # 保存版本信息
        echo "$VERSION" > "$DATA_DIR/.version"

        if start_service; then
            show_status
        else
            echo_error "安装过程中出现错误，请查看日志: journalctl -u $SERVICE_NAME -n 50"
            exit 1
        fi
    fi
}

main "$@"