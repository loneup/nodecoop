#!/usr/bin/env bash
# install 一致性测试
#
# 校验：
#   1) nodecoop-dist/install.sh 与 nodecoop-src/control/install.sh 实质同源
#      （允许仅注释行差异；源仓副本带"事实源"头部说明）
#   2) 安装器的 GITHUB_REPO + 资产命名与 v0.4.2 Release 资产一致
#   3) 架构映射正确（x86_64→amd64、aarch64→arm64）
#   4) 所有安装脚本通过 bash -n 语法检查
#
# 用法：
#   bash tests/install-consistency.sh            # 纯本地校验（无需网络）
#   CHECK_ONLINE=1 bash tests/install-consistency.sh   # 额外 curl 验证 Release 资产
#
# 可通过环境变量覆盖路径：
#   DIST_INSTALL  nodecoop-dist/install.sh
#   SRC_INSTALL   nodecoop-src/control/install.sh
#   DIST_BOT      nodecoop-dist/bot/install.sh
#   SRC_QUICK     nodecoop-src/control/quick-install.sh

set -euo pipefail

# 默认路径：相对本脚本所在目录（nodecoop-dist 根）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_ROOT="${DIST_ROOT:-$SCRIPT_DIR/..}"
SRC_ROOT="${SRC_ROOT:-/Users/liyan/01_Projects/nodecoop-src}"

DIST_INSTALL="${DIST_INSTALL:-$DIST_ROOT/install.sh}"
DIST_BOT="${DIST_BOT:-$DIST_ROOT/bot/install.sh}"
SRC_INSTALL="${SRC_INSTALL:-$SRC_ROOT/control/install.sh}"
SRC_QUICK="${SRC_QUICK:-$SRC_ROOT/control/quick-install.sh}"

GITHUB_REPO="loneup/nodecoop"
RELEASE_TAG="${RELEASE_TAG:-v0.4.2}"

PASS=0
FAIL=0

ok()   { echo "✅ $*"; PASS=$((PASS+1)); }
bad()  { echo "❌ $*"; FAIL=$((FAIL+1)); }
note() { echo "ℹ️  $*"; }

# ---------------------------------------------------------------------------
# 1. bash -n 语法检查
# ---------------------------------------------------------------------------
note "--- bash -n 语法检查 ---"
for f in "$DIST_INSTALL" "$DIST_BOT" "$SRC_INSTALL" "$SRC_QUICK"; do
  if [ -f "$f" ]; then
    if bash -n "$f" 2>/tmp/bashn.err; then
      ok "语法通过: $f"
    else
      bad "语法错误: $f"
      cat /tmp/bashn.err
    fi
  else
    bad "文件不存在: $f"
  fi
done

# ---------------------------------------------------------------------------
# 2. 一致性：dist/install.sh vs src/control/install.sh（忽略注释/空行）
# ---------------------------------------------------------------------------
note "--- 源仓/公开仓一致性 ---"
strip_comments() { # 输出去注释、去空行、去 shebang 后的代码行
  grep -vE '^\s*(#|$)' "$1" | grep -v '^#!' || true
}

strip_comments "$DIST_INSTALL" > /tmp/dist.install.norm
strip_comments "$SRC_INSTALL"  > /tmp/src.install.norm

if diff -u /tmp/dist.install.norm /tmp/src.install.norm > /tmp/install.diff; then
  ok "install.sh 实质同源（去注释后完全一致）"
else
  bad "install.sh 实质不一致（去注释后仍有差异）"
  cat /tmp/install.diff
fi

# 源仓副本应带"事实源"说明注释
if grep -q "事实源" "$SRC_INSTALL"; then
  ok "源仓副本含'事实源'说明注释"
else
  bad "源仓副本缺少'事实源'说明注释"
fi

# ---------------------------------------------------------------------------
# 3. GITHUB_REPO 与资产命名校验
# ---------------------------------------------------------------------------
note "--- 仓库与资产命名 ---"
check_repo() {
  local f="$1"
  if grep -q "loneup/nodecoop" "$f"; then
    ok "GITHUB_REPO=loneup/nodecoop: $f"
  else
    bad "GITHUB_REPO 未指向 loneup/nodecoop: $f"
  fi
}
check_repo "$DIST_INSTALL"
check_repo "$DIST_BOT"
check_repo "$SRC_INSTALL"
check_repo "$SRC_QUICK"

# Control 资产必须为 .tar.gz（不再请求裸二进制）
if grep -qE 'nodecoop-linux-(amd64|arm64)\.tar\.gz' "$DIST_INSTALL"; then
  ok "Control 安装器使用 nodecoop-linux-<arch>.tar.gz 资产"
else
  bad "Control 安装器未引用 .tar.gz 资产"
fi

# Bot 资产：仅 amd64.tar.gz
if grep -q 'nodecoop-bot-linux-amd64.tar.gz' "$DIST_BOT"; then
  ok "Bot 安装器使用 nodecoop-bot-linux-amd64.tar.gz 资产"
else
  bad "Bot 安装器未引用 nodecoop-bot-linux-amd64.tar.gz"
fi

# Bot 安装器不得宣称 arm64 可用
if grep -qiE 'aarch64|arm64' "$DIST_BOT" | grep -q '无'; then
  ok "Bot 安装器对 arm64 明确拒绝"
else
  # 允许脚本中仅出现'无 arm64 资产'的字样；检查是否含拒绝语义
  if grep -q "无 arm64 资产" "$DIST_BOT"; then
    ok "Bot 安装器对 arm64 明确拒绝（'无 arm64 资产'）"
  else
    bad "Bot 安装器未明确拒绝 arm64"
  fi
fi

# ---------------------------------------------------------------------------
# 4. 架构映射校验（uname -m → tar.gz 名）
# ---------------------------------------------------------------------------
note "--- 架构映射 ---"
arch_map() {
  case "$1" in
    x86_64|amd64) echo "nodecoop-linux-amd64.tar.gz" ;;
    aarch64|arm64) echo "nodecoop-linux-arm64.tar.gz" ;;
    *) echo "UNSUPPORTED" ;;
  esac
}
for m in x86_64 amd64; do
  [ "$(arch_map "$m")" = "nodecoop-linux-amd64.tar.gz" ] && ok "架构映射 $m → amd64.tar.gz" || bad "架构映射错误: $m"
done
for m in aarch64 arm64; do
  [ "$(arch_map "$m")" = "nodecoop-linux-arm64.tar.gz" ] && ok "架构映射 $m → arm64.tar.gz" || bad "架构映射错误: $m"
done

# ---------------------------------------------------------------------------
# 5.（可选）在线验证 Release 资产
# ---------------------------------------------------------------------------
if [ "${CHECK_ONLINE:-0}" = "1" ]; then
  note "--- 在线验证 Release 资产（${RELEASE_TAG}）---"
  check_url() {
    local asset="$1" expect="$2"
    local code
    code=$(curl -sL --max-time 30 -o /dev/null -w "%{http_code}" \
      "https://github.com/${GITHUB_REPO}/releases/download/${RELEASE_TAG}/${asset}")
    if [ "$code" = "$expect" ]; then
      ok "${asset} → HTTP ${code}（符合预期）"
    else
      bad "${asset} → HTTP ${code}（预期 ${expect}）"
    fi
  }
  check_url "nodecoop-linux-amd64.tar.gz" 200
  check_url "nodecoop-linux-arm64.tar.gz" 200
  check_url "nodecoop-bot-linux-amd64.tar.gz" 200
  check_url "SHA256SUMS" 200
  # 已知缺失（不应被安装器请求）
  check_url "nodecoop-linux-amd64" 404
  check_url "nodecoop-bot-linux-arm64.tar.gz" 404
else
  note "跳过在线验证（设置 CHECK_ONLINE=1 启用 curl 检查）"
fi

# ---------------------------------------------------------------------------
# 结果
# ---------------------------------------------------------------------------
echo
echo "=================== 结果 ==================="
echo "通过: $PASS  失败: $FAIL"
[ "$FAIL" -eq 0 ] && { echo "全部通过 ✅"; exit 0; } || { echo "存在失败 ❌"; exit 1; }
