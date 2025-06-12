# 网络代理工具集

这个仓库包含多种网络代理和端口转发工具的一键安装脚本，方便快速部署各类网络服务。

## 使用方法

### Snell

Snell 是一个简单高效的代理工具，支持与 Shadow-TLS 配合使用。

```bash
bash <(curl -Ls https://github.com/lucking7/snells/raw/main/snells.sh)
```

### Brook

Brook 是一个跨平台的强加密无特征的网络工具，支持 TCP/UDP 端口转发。

```bash
bash <(curl -Ls https://github.com/lucking7/snells/raw/main/brook.sh)
```

### GOST

GOST 是一个功能强大的网络代理和端口转发工具，支持多种协议和转发模式。

```bash
bash <(curl -Ls https://github.com/lucking7/snells/raw/main/gost.sh)
```

### Socat

Socat 是一个多功能的网络工具，用于建立双向数据流通道。

```bash
bash <(curl -Ls https://github.com/lucking7/snells/raw/main/socat.sh)
```

### Realm

Realm 是一个轻量级的网络代理工具。

```bash
bash <(curl -Ls https://github.com/lucking7/snells/raw/main/realm.sh)
```

### NFTables

NFTables 配置脚本，用于网络流量控制和防火墙规则管理。

```bash
bash <(curl -Ls https://github.com/lucking7/snells/raw/main/nftables.sh)
```

## 注意事项

- 所有脚本均需要 root 权限运行
- 请在使用前了解相关工具的功能和用途
- 脚本会自动安装所需依赖并配置系统服务
