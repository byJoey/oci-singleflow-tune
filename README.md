# OCI Single-Flow Tune 一键脚本

相关链接：

- 完整排查记录：[docs/oci-singapore-arm-single-flow-tuning.md](docs/oci-singapore-arm-single-flow-tuning.md)
- BBRv3 内核构建仓库：<https://github.com/byJoey/Actions-bbr-v3/tree/main>

这个脚本用于复用这组实测参数：

```text
MTU 1500
BBR + fq
tcp_wmem max 32MB
tcp_rmem max 32MB
fq quantum 18028
fq initial_quantum 90140
```

适合先在 OCI / Ubuntu 服务器上测试，尤其是遇到公网单线程下载重传高、速度低的场景。

## 运行

一键运行：

```bash
curl -fsSL https://raw.githubusercontent.com/byJoey/oci-singleflow-tune/main/oci-singleflow-tune.sh | sudo bash
```

如果想先下载再执行：

```bash
sudo bash oci-singleflow-tune.sh
```

如果自动识别网卡不准，手动指定：

```bash
IFACE=enp0s6 sudo -E bash oci-singleflow-tune.sh
```

如果 netplan 文件不是默认第一个，手动指定：

```bash
NETPLAN_FILE=/etc/netplan/50-cloud-init.yaml sudo -E bash oci-singleflow-tune.sh
```

## 自定义参数

```bash
MTU=1500 \
FQ_QUANTUM=18028 \
FQ_INITIAL_QUANTUM=90140 \
TCP_WMEM_MAX=33554432 \
TCP_RMEM_MAX=33554432 \
sudo -E bash oci-singleflow-tune.sh
```

## 脚本会做什么

1. 自动识别默认出站网卡。
2. 备份 netplan 文件。
3. 把网卡 MTU 持久化为 1500。
4. 写入 sysctl TCP 参数。
5. 创建并启用 `singleflow-fq-quantum.service`。
6. 立即应用 `fq quantum 18028 initial_quantum 90140`。

## 验证

```bash
ip link show dev enp0s6
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.ipv4.tcp_wmem net.ipv4.tcp_rmem
tc qdisc show dev enp0s6
systemctl status singleflow-fq-quantum.service --no-pager
```

测试单线程下载：

服务器：

```bash
sudo ufw allow 5201/tcp
iperf3 -s -p 5201
```

本地：

```bash
iperf3 -4 -c SERVER_IP -p 5201 -R -t 20 -O 3
```

测完清理：

```bash
sudo ufw delete allow 5201/tcp
pkill iperf3
```

## 回滚

恢复 netplan 备份：

```bash
sudo cp /etc/netplan/50-cloud-init.yaml.bak.singleflow.YYYYMMDDHHMMSS /etc/netplan/50-cloud-init.yaml
sudo netplan apply
```

删除 sysctl 和 systemd 服务：

```bash
sudo rm -f /etc/sysctl.d/99-singleflow-tcp-optimization.conf
sudo systemctl disable --now singleflow-fq-quantum.service
sudo rm -f /etc/systemd/system/singleflow-fq-quantum.service
sudo systemctl daemon-reload
sudo sysctl --system
```
