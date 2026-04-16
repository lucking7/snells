# 网络代理工具集

一键安装脚本，快速部署网络代理和端口转发服务。

## 使用方法

### Snell + Shadow-TLS

```bash
bash <(curl -Ls https://github.com/lucking7/snells/raw/main/snells.sh)
```

### 端口转发 (Realm / GOST / Brook / Socat)

统一管理四种转发工具，支持安装/卸载、规则增删改、TCP/UDP 分流。

```bash
bash <(curl -Ls https://github.com/lucking7/snells/raw/main/fwrd.sh)
```

### NFTables

```bash
bash <(curl -Ls https://github.com/lucking7/snells/raw/main/nftables.sh)
```

## 注意事项

- 所有脚本均需要 root 权限运行
- 请在使用前了解相关工具的功能和用途
- 脚本会自动安装所需依赖并配置系统服务
