## 安装依赖包

```bash
yum install net-snmp net-snmp-utils net-snmp-libs net-snmp-deve
```

## 安装snmp exporter

```bash
wget https://github.com/prometheus/snmp_exporter/releases/download/v0.20.0/snmp_exporter-0.20.0.linux-amd64.tar.gz
tar -xf snmp_exporter-0.20.0.linux-amd64.tar.gz   -C /opt/
cd /opt/snmp_exporter-0.20.0.linux-amd64/
```

## 编辑配置文件
对于 SNMP Exporter 的使用来说， 配置文件比较重要，配置文件中根据硬件的 MIB 文件生成了 OID 的映射关系。以 Cisco 交换机为例，在官方 GitHub 上下载最新的 snmp.yml 文件，由于 Cisco 交换机使用的是 if_mib 模块，在 if_mib 下新增 auth ，用来在请求交换机的时候做验证使用，这个值是配置在交换机上的。

关于采集的监控项是在 walk 字段下，如果要新增监控项，写在 walk 项下。我新增了交换机的 CPU 和内存信息。
```bash
cat snmp.yml
if_mib:
  auth:
    community: xxxx
  walk:
  - 1.3.6.1.2.1.2
  - 1.3.6.1.2.1.31.1.1
  - 1.3.6.1.4.1.9.2.1  # 交换机 CPU 相关信息
  - 1.3.6.1.4.1.9.9.48  # 交换机内存相关信息
  get:
  - 1.3.6.1.2.1.1.3.0
  metrics:
  - name: busyPer
    oid: 1.3.6.1.4.1.9.2.1.56.0
    type: gauge
    help: CPU utilization
  - name: avgBusy1
    oid: 1.3.6.1.4.1.9.2.1.57.0
    type: gauge
    help: CPU utilization in the past 1 minute
  - name: avgBusy2
    oid: 1.3.6.1.4.1.9.2.1.58.0
    type: gauge
    help: CPU utilization in the past 5 minute
  - name: MemoryPoolFree
    oid: 1.3.6.1.4.1.9.9.48.1.1.1.6.1
    type: gauge
    help: ciscoMemoryPoolFree
  - name: MemoryPoolUsed
    oid: 1.3.6.1.4.1.9.9.48.1.1.1.5.1
    type: gauge
    help: ciscoMemoryPoolUsed
```

## 添加systemctl 服务

```bash
cat /lib/systemd/system/snmp_exporter.service
[Unit]
Description=snmp_exporter service

[Service]
User=root
ExecStart=/opt/snmp_exporter-0.20.0.linux-amd64/snmp_exporter --config.file=/opt/snmp_exporter-0.20.0.linux-amd64/snmp.yml

TimeoutStopSec=10
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## 启动服务

```bash
systemctl daemon-reload 
systemctl enable snmp_exporter.service
systemctl start snmp_exporter.service
systemctl status snmp_exporter.service
```

## prometheus添加targets

```yaml
 - job_name: NET-SW
    static_configs:
      - targets: 
          - 192.168.10.10  # 交换机的 IP 地址
    metrics_path: /snmp
    params:
      module: 
        - if_mib  # 如果是其他设备，请更换其他模块。
      community:
        - xxxxxx  #  指定 community，当 snmp_exporter snmp.yml 配置文件没有指定 community，此处定义的 community 生效。
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: 192.168.1.2:9116
```

获取 MIB 可以在下面的 GitHub 里面找。这个里面有很多基础的 MIB
https://github.com/librenms/librenms/tree/master/mibs
