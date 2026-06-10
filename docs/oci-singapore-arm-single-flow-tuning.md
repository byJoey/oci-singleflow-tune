# OCI 新加坡 ARM 单线程下载优化记录：MTU 9000 不是总是更快

相关仓库：

- 一键脚本：<https://github.com/byJoey/oci-singleflow-tune>
- 内核构建：<https://github.com/byJoey/Actions-bbr-v3/tree/main>

最近在 Oracle Cloud 新加坡区开了两台 ARM 机器，配置是常见的 A1.Flex，系统为 Ubuntu 24.04。机器本身性能和多线程测速都没问题，但在从服务器单线程下载到本地 Mac 时，表现非常不稳定：有时只有几 Mbps 到几十 Mbps，并且 `iperf3` 里能看到大量重传。

这篇记录一下完整排查过程，以及最后比较有效的一组参数。它不是通用“神仙参数”，更适合作为同类场景的复现实验参考。

## 环境

服务器：

```text
Oracle Cloud Infrastructure
Region: ap-singapore-2
Shape: VM.Standard.A1.Flex
OS: Ubuntu 24.04
Kernel: 7.0.12 with BBRv3，内核来自 Actions-bbr-v3
NIC: enp0s6
```

本地测试点：

```text
macOS
iperf3 client
无代理/VPN
到新加坡 OCI RTT 约 76 ms
```

服务器初始 TCP 状态：

```bash
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
sysctl net.ipv4.tcp_wmem
sysctl net.ipv4.tcp_rmem
ip link show dev enp0s6
tc qdisc show dev enp0s6
```

初始值大致是：

```text
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_wmem = 4096 16384 4194304
net.ipv4.tcp_rmem = 4096 131072 33554432
enp0s6 mtu 9000
qdisc fq quantum 18028b initial_quantum 90140b
```

也就是说，BBR 和 fq 本来就已经开了，问题不在“有没有开 BBR”。

## 现象

从 Mac 到服务器方向：

```bash
iperf3 -c SERVER_IP -p 5201
```

结果大约几十 Mbps，并且重传很多。

从服务器到 Mac 方向：

```bash
iperf3 -c SERVER_IP -p 5201 -R
```

初始表现更差，曾经出现几 Mbps、几十 Mbps，甚至某些轮次接近 0 的情况。重点是 `Retr` 很高，说明不是单纯的应用层限速。

RTT 大约：

```text
76 ms
```

如果要跑 500 Mbps 到 1 Gbps 的单 TCP 流，BDP 已经不小。粗略估算：

```text
500 Mbps * 0.076s / 8 = 4.75 MB
1 Gbps * 0.076s / 8 = 9.5 MB
```

所以 4MB 的发送窗口上限偏紧，但单纯调大窗口并不能解决所有问题。

## 排查思路

参考了一些基于 `iperf3` 的 TCP 调优思路，核心不是盲目堆参数，而是看三个指标：

```text
吞吐
Retr 重传
RTT / BDP
```

如果吞吐低但重传很高，继续加大发送窗口往往没有意义，可能会让突发更严重。

测试时主要做了这些组合：

```text
BBR vs CUBIC
tcp_wmem 16MB / 32MB / 64MB
fq quantum 1514 / 3028 / 12000 / 18028 / 24000 / 36000
tc 限速
MTU 9000 vs MTU 1500
tcp_limit_output_bytes / tcp_notsent_lowat
```

## 关键发现：MTU 1500 比 9000 稳定很多

OCI 内网/虚拟网卡默认 MTU 是 9000，这对云内通信可能有好处，但跨公网到家宽时未必合适。

临时把服务器网卡 MTU 从 9000 改为 1500：

```bash
sudo ip link set dev enp0s6 mtu 1500
```

然后再测服务器到 Mac 的单线程：

```bash
iperf3 -4 -c SERVER_IP -p 5201 -R -t 20
```

结果直接从几 Mbps 到几十 Mbps，提升到：

```text
384.6 Mbps, Retr=0
```

后续继续调参数，最好一轮达到：

```text
534.3 Mbps, Retr=0
```

重复测试也有波动：

```text
451.2 Mbps, Retr=0
442.4 Mbps, Retr=0
```

偶尔也会出现低值，比如 155 Mbps，甚至单轮异常到 0.x Mbps。这说明公网路径本身仍然有波动，但优化后的关键区别是：正常轮次重传能压到 0，速度上限明显提高。

## 为什么不是把 fq quantum 改成 1500？

一个容易踩坑的点是：既然 MTU 降到了 1500，是不是 fq 的 `quantum` 也应该降到 1514 左右？

实测不是。

在这台 OCI ARM 上，保留原来 MTU 9000 时生成的：

```text
quantum 18028
initial_quantum 90140
```

反而最好。

测试结果里，小 quantum 会直接把单线程打废：

```text
bbr-q18028-w16m   404.3 Mbps, Retr=0
bbr-q1514-w16m      2.0 Mbps, Retr=316
bbr-q3028-w16m      1.3 Mbps, Retr=258
```

后续用 32MB 发送窗口时：

```text
bbr-q18028-w32m   534.3 Mbps, Retr=0
bbr-q15000-w32m   453.9 Mbps, Retr=0
bbr-q12000-w32m   有时能到 511 Mbps，但不如 18028 稳
```

所以最终保留：

```text
fq quantum 18028 initial_quantum 90140
```

## 最终配置

### 1. netplan 持久化 MTU 1500

编辑：

```bash
sudo nano /etc/netplan/50-cloud-init.yaml
```

示例：

```yaml
network:
  version: 2
  ethernets:
    enp0s6:
      dhcp4: true
      dhcp4-overrides:
        use-dns: false
      nameservers:
        addresses:
          - 1.1.1.1
          - 2606:4700:4700::1111
      mtu: 1500
```

应用：

```bash
sudo netplan generate
sudo netplan apply
```

如果你的网卡不是 `enp0s6`，先用下面命令确认：

```bash
ip link
```

### 2. sysctl TCP 参数

创建文件：

```bash
sudo nano /etc/sysctl.d/99-tcp-optimization.conf
```

写入：

```conf
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_wmem = 4096 16384 33554432
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_limit_output_bytes = 4194304
```

应用：

```bash
sudo sysctl --system
```

### 3. 持久化 fq quantum

只设置 `net.core.default_qdisc=fq` 不一定够。重启或网络重载后，系统可能按当前 MTU 重新生成较小的 quantum，而我们实测较小 quantum 表现很差。

创建 systemd 服务：

```bash
sudo nano /etc/systemd/system/fq-quantum.service
```

写入：

```ini
[Unit]
Description=Set fq qdisc quantum for single-flow throughput
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=-/usr/sbin/tc qdisc del dev enp0s6 root
ExecStart=/usr/sbin/tc qdisc add dev enp0s6 root fq quantum 18028 initial_quantum 90140
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

启用：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now fq-quantum.service
```

检查：

```bash
tc qdisc show dev enp0s6
systemctl status fq-quantum.service --no-pager
```

应该看到类似：

```text
qdisc fq ... quantum 18028b initial_quantum 90140b
```

## 测试方法

服务器端临时启动 iperf3：

```bash
sudo ufw allow 5201/tcp
iperf3 -s -p 5201
```

Mac 本地测服务器到本地的单线程下载：

```bash
iperf3 -4 -c SERVER_IP -p 5201 -R -t 20 -O 3
```

参数说明：

```text
-R   反向测试，服务器发，客户端收
-O 3 跳过前 3 秒启动期，更接近稳态
-4   强制 IPv4，避免 IPv6 干扰测试
```

测完记得清理：

```bash
sudo ufw delete allow 5201/tcp
pkill iperf3
```

## 实测数据摘要

优化前：

```text
MTU 9000
服务器到 Mac 单线程：几 Mbps 到几十 Mbps
Retr 高
```

只改 MTU 1500 + 16MB 发送窗口：

```text
384.6 Mbps, Retr=0
```

最终较优组合：

```text
MTU 1500
BBR
fq quantum 18028
tcp_wmem max 32MB
```

表现：

```text
534.3 Mbps, Retr=0
451.2 Mbps, Retr=0
442.4 Mbps, Retr=0
```

低值也会出现：

```text
155 Mbps, Retr=0
0.x Mbps, Retr 高
```

这类低值更像公网路径短时波动，不是单个参数能完全消除。

## 结论

这次最有价值的结论不是“把某个参数调大”，而是：

```text
OCI 的 9000 MTU 在公网单线程场景下不一定更好。
```

在这条“OCI 新加坡 ARM -> 本地 Mac/家宽”的路径上，MTU 1500 明显降低了重传，并把单线程下载从不可用级别提升到 400-500 Mbps 区间。

另外，`fq quantum` 不要机械地跟着 MTU 变小。至少在这台机器上，保留 `quantum 18028` 比 `1514` 或 `3028` 好得多。

如果你要复用这组参数，建议按这个顺序验证：

1. 先确认已经是 `bbr + fq`。
2. 记录原始 `iperf3 -R` 单线程结果和 `Retr`。
3. 临时把 MTU 改成 1500 测一次。
4. 再试 `tcp_wmem max 32MB`。
5. 最后固定 `fq quantum 18028`。
6. 不要只看一次结果，至少重复 3 轮。

如果你的目标是多线程测速跑满带宽，这组参数不一定是重点；如果你的问题是跨境/跨运营商单 TCP 流慢、重传高，那么 MTU 和 fq pacing 的组合值得优先排查。
