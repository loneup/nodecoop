# UPGRADE-FROM-0.4.2 — v0.4.2 内部测试样本迁移指南（外部审计记录）

> **S8.5 处置**：v0.4.2 从未正式发布，没有普通用户或外部部署实例。本文档保留作为**外部审计记录**，说明 v0.4.2 用于验证旧签名失败行为和迁移边界。正式产品支持从 v0.4.4 开始，不提供双密钥兼容或 v0.4.2 长期支持。

**摘要**：公开 GitHub Release v0.4.2 agent 二进制嵌入 **OLD** Ed25519 公钥 `XYJvxWTMCb7MxSegm6ntxqHVXKs8/tumDX1mh8p0KjE=`，但 `.sig` 用 **NEW** 私钥签名（NEW pubkey `iJXuE0DFCGjctXaH0w5s69Bqg9cGDDgHzgcHeINlkr4=`）。因此内置自升级 `__verify-update` 必然失败——**仅在内部迁移/审计验证时需要**一次性手动替换到 ≥v0.4.4 后才能恢复自动升级。

**适用对象（内部审计）**：从 GitHub Release v0.4.2 (`loneup/nodecoop`) 安装 nodecoop-agent 的**内部测试部署**。**不影响**生产 URL-fixed v0.4.2（已嵌入 NEW pubkey，可正常自升级）。

---

## 前置条件

- root 或 sudo 权限（Agent 安装在 `/usr/local/bin/`）
- 能访问 GitHub Releases：<https://github.com/loneup/nodecoop/releases>
- 以下工具之一可用：`python3` + `cryptography` 库，或 `openssl pkeyutl`（OpenSSH ≥7.3 需 `libcrypto` Ed25519 支持）

---

## 步骤

### 1. 下载最新 Agent 资产

```bash
VER=v0.4.3        # 替换为最新 Release 版本
ARCH=linux-amd64   # 或 linux-arm64
WORK=/tmp/agent-upgrade-$(date +%s)
mkdir -p "$WORK" && cd "$WORK"

curl -fLO "https://github.com/loneup/nodecoop/releases/download/$VER/nodecoop-agent-${ARCH}.tar.gz"
curl -fLO "https://github.com/loneup/nodecoop/releases/download/$VER/nodecoop-agent-${ARCH}.sig"
curl -fLO "https://github.com/loneup/nodecoop/releases/download/$VER/SHA256SUMS"
```

### 2. SHA256 校验

```bash
# 对照 SHA256SUMS
grep "nodecoop-agent-${ARCH}.tar.gz" SHA256SUMS | shasum -a 256 -c

# 或对照 agent-latest.json（如果有）
curl -fsL "https://github.com/loneup/nodecoop/releases/download/$VER/agent-latest.json" | \
  python3 -c "import json,sys; d=json.load(sys.stdin); a=d['artifacts'][sys.argv[1]]; print(a['sha256'], ' ', a['url'].split('/')[-1])" "$ARCH" | \
  shasum -a 256 -c
```

校验通过输出 `nodecoop-agent-${ARCH}.tar.gz: OK`。

### 3. 解压

```bash
tar -xzf "nodecoop-agent-${ARCH}.tar.gz"
# 得到 nodecoop-agent-linux-amd64（或 arm64）
```

### 4. Ed25519 验签（用 NEW pubkey）

**NEW Ed25519 公钥（base64）**：
```
iJXuE0DFCGjctXaH0w5s69Bqg9cGDDgHzgcHeINlkr4=
```

选以下任一方式：

#### 方式 A：用新版 Agent 自验（推荐——无需外部密钥）

```bash
# 新版 agent 已嵌入 NEW pubkey，可用 __verify-update 自检
chmod +x "nodecoop-agent-${ARCH}"
"./nodecoop-agent-${ARCH}" __verify-update \
  "nodecoop-agent-${ARCH}" \
  "nodecoop-agent-${ARCH}.sig"
# 无输出 + 退出码 0 = 验签通过
```

> `__verify-update <binary-path> <sig-path>` 使用编译期内嵌公钥（NEW pubkey）验签。验签失败则退出码非 0 并输出错误。

#### 方式 B：Python + cryptography（离线验签）

```bash
python3 - << 'PYEOF'
import base64, sys

NEW_PUB_B64 = "iJXuE0DFCGjctXaH0w5s69Bqg9cGDDgHzgcHeINlkr4="

from cryptography.hazmat.primitives.asymmetric import ed25519
pub = ed25519.Ed25519PublicKey.from_public_bytes(base64.b64decode(NEW_PUB_B64))

with open(sys.argv[1], "rb") as f:
    binary = f.read()
with open(sys.argv[2], "rb") as f:
    sig = f.read()

pub.verify(sig, binary)
print("Ed25519 验签通过 (NEW pubkey)")
PYEOF "nodecoop-agent-${ARCH}" "nodecoop-agent-${ARCH}.sig"
```

> 如果未安装 `cryptography`，先执行：`pip3 install cryptography`

#### 方式 C：OpenSSH / OpenSSL（系统工具）

```bash
# OpenSSH ≥7.3: 用 ssh-keygen 转公钥为 PKCS8 DER 后装成 PEM
# 或直接用 openssl pkeyutl（需要 OpenSSL ≥1.1.1）
openssl pkeyutl -verify -pubin -inkey <(echo "-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAiJXuE0DFCGjctXaH0w5s69Bqg9cGDDgHzgcHeINlkr4=
-----END PUBLIC KEY-----") \
  -rawin -in "nodecoop-agent-${ARCH}" -sigfile "nodecoop-agent-${ARCH}.sig" 2>&1
# 输出 "Signature Verified Successfully" 即通过
```

> Ed25519 公钥 PEM 是固定不变的：直接复制上面的 `MCowBQYDK2VwAyEAiJXuE0DFCGjctXaH0w5s69Bqg9cGDDgHzgcHeINlkr4=` 即可。

### 5. 停止服务 + 原子替换

```bash
# 停止 Agent 服务
sudo systemctl stop nodecoop-agent     # systemd 托管
# 或
sudo supervisorctl stop nodecoop-agent # supervisor 托管

# 原子替换（硬链接 + mv，确保不残留部分写入文件）
sudo install -o root -g root -m 0755 "nodecoop-agent-${ARCH}" /usr/local/bin/nodecoop-agent

# 重启
sudo systemctl start nodecoop-agent
# 或
sudo supervisorctl start nodecoop-agent
```

### 6. 验证升级成功

```bash
# 检查运行版本
/usr/local/bin/nodecoop-agent -version
# 预期输出: nodecoop-agent v0.4.3 (或更高)

# 验证自升级链路已恢复（可选——Control 端发起升级，或直接调用）
/usr/local/bin/nodecoop-agent __verify-update \
  /usr/local/bin/nodecoop-agent \
  <新下载的 .sig 文件>
# 退出码 0 = NEW pubkey 验签通过 → 自升级能力已恢复
```

### 7. 清理

```bash
rm -rf "$WORK"
```

---

## 常见问题

**Q: 为什么不直接下载 v0.4.3 二进制跳过验签？**
A: 不验证 Ed25519 签名的升级等同于信任任何中间人。SHA256 + Ed25519 双重校验是唯一确保二进制未被篡改的路径。

**Q: 为什么不能用旧版 agent 的 `__verify-update` ？**
A: 旧版 agent（v0.4.2 GitHub Release）内嵌 OLD pubkey。NEW sig 无法通过 OLD pubkey 的 Ed25519 验证——这正是本问题的根源。

**Q: 生产节点需要这个步骤吗？**
A: **不需要。** 生产 shelf-6 节点部署的是 URL-fixed v0.4.2（嵌入 NEW pubkey），可以正常自升级。本指南仅针对 GitHub Release 公开 v0.4.2。

**Q: 新公钥的安全性如何保证？**
A: NEW pubkey 已编入 `loneup/nodecoop-src` 仓库 `agent/internal/selfupdate/verify.go`（公开可见），对应私钥离线保管于 `~/.nodecoop-audit/agent-update-private-key.txt`。SHA256 校验从 `agent-latest.json` 和 `SHA256SUMS` 中获取，与 `verify.go` 公钥形成双层防护。

---

## 公钥指纹（快速对照）

| 角色 | 公钥 base64（前 16 字符） | 完整 base64 |
|------|--------------------------|-------------|
| OLD（**弃用**） | `XYJvxWTMCb7MxSeg` | `XYJvxWTMCb7MxSegm6ntxqHVXKs8/tumDX1mh8p0KjE=` |
| NEW（**当前**） | `iJXuE0DFCGjctXaH` | `iJXuE0DFCGjctXaH0w5s69Bqg9cGDDgHzgcHeINlkr4=` |

---

*文档日期：2026-09-18 · 关联 ISSUE #9（nodecoop-src/KNOWN_ISSUES.md）*