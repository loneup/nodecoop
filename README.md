# NodeCoop

Xray 多服务器管理面板 — 公开分发仓。

## 安装

### Control 主控面板

```bash
curl -fsSL https://raw.githubusercontent.com/loneup/nodecoop/main/install.sh | sudo bash
```

### Bot Telegram 机器人

```bash
curl -fsSL https://raw.githubusercontent.com/loneup/nodecoop/main/bot/install.sh | sudo bash
```

### Nginx 反代（可选）

```bash
curl -fsSL https://raw.githubusercontent.com/loneup/nodecoop/main/install-nginx.sh | sudo bash
```

## 目录

| 目录 | 说明 |
|------|------|
| `install.sh` | Control 主控安装器 |
| `install-nginx.sh` | Nginx 反代安装器 |
| `uninstall-nginx.sh` | Nginx 卸载脚本 |
| `bot/` | Bot 安装器 |
| `proxy-groups/` | Clash 代理分组配置 |
| `speedtest/` | 节点测速部署 |
| `docs/` | 文档 |

## 下载

Release 二进制：<https://github.com/loneup/nodecoop/releases>

## 源码

开发仓：`loneup/nodecoop-src`（私有）

## 许可证

Control/Agent/Bot 组件为专有许可。Xray-core 组件遵循其上游许可证（MPL 2.0）。
