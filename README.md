# port-traffic-keeper

怎么安装/更新

### 全新机器第一次装

```bash
curl -sSL https://raw.githubusercontent.com/shangusl/port-traffic-keeper/main/ptk.sh -o /tmp/ptk.sh && bash /tmp/ptk.sh
```

跑起来会自动：
- 安装依赖（nftables、jq、curl 等）
- 把自己复制到 `/usr/local/bin/port-traffic-keeper.sh`
- 创建 `ptk` 快捷命令
- 配置每分钟 cron + `@reboot` 开机自愈
- 创建 systemd `ptk-save` 服务

然后正常进菜单配端口就行。

### 已有 ptk 的机器升级

最简单，直接一条命令：

```bash
ptk update
```

脚本会自动从 GitHub 下载最新版替换自己，保留所有配置和流量数据。

**注意：**
- `ptk update` 不会改你的 `config.json` 和 `state.json`，流量数据完全保留。
- 如果你在 GitHub 上改了什么配置相关的逻辑，更新后跑一次 `ptk --tick` 或直接 `ptk` 进菜单确认就行。
```
