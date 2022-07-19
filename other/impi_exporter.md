## 安装ipmitool 并加载相应模块

```bash
yum install ipmitool freeipmi  -y
modprobe ipmi_msghandler
modprobe ipmi_devintf
modprobe ipmi_poweroff
modprobe ipmi_si
modprobe ipmi_watchdog
```

## 安装ipmi exporter

```bash
wget https://github.com/soundcloud/ipmi_exporter/releases/download/v1.5.1/ipmi_exporter-v1.5.1.linux-amd64.tar.gz  
tar -xf ipmi_exporter-v1.5.1.linux-amd64.tar.gz   -C /opt/
cd /opt/ipmi_exporter-v1.5.1.linux-amd64/
```

## 编辑配置文件

```bash
cat ipmi_remote.yml
modules:
  192.168.10.10:               #远控卡ip地址
    user: "username"  #远控卡用户
    pass: "password"  #远控卡密码
    # Available collectors are bmc, ipmi, chassis, and dcmi 
    collectors:
    - bmc
    - ipmi
    - dcmi
    - chassis
    # Got any sensors you don't care about? Add them here. 
    #exclude_sensor_ids:
    #- 2
    #- 29
    #- 32
```

## 添加systemctl 服务

```bash
cat /lib/systemd/system/ipmi_exporter.service
[Unit]
Description=ipmi_exporter service

[Service]
User=root
ExecStart=/opt/ipmi_exporter-1.5.1.linux-amd64/ipmi_exporter --config.file=/opt/ipmi_exporter-1.5.1.linux-amd64/ipmi_remote.yml

TimeoutStopSec=10
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## 启动服务

```bash
systemctl daemon-reload 
systemctl enable ipmi_exporter.service
systemctl start ipmi_exporter.service
systemctl status ipmi_exporter.service
```

## prometheus添加targets

```yaml
- job_name: 'ipmi_exporter'
      scrape_interval: 1m
      static_configs:
      - targets: ['192.168.10.71:9290']
```

