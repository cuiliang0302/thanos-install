## 整体架构
![](https://oss.cuiliangblog.cn/markdown/2022_07_19_19_26_11_467-1658229971562.jpg)

## 参考文章
[https://www.cuiliangblog.cn/detail/article/45](https://www.cuiliangblog.cn/detail/article/45)

## 修改内容
### 1. 镜像仓库地址
```yaml
containers:
  - name: prometheus
    image: harbor.com/prometheus/prometheus:v2.36.0
```
### 2, ingress域名
```yaml
spec:
  routes:
    - match: Host(`prometheus.com`)
      kind: Rule
      services:
        - name: prometheus-headless 
          port: 9090
```
### 3.exporter.yaml
修改各种exporter的资源地址，例如es地址，mysql地址，网络探针ip地址域名等
```yaml
- --es.uri=https://elastic:password@192.168.10.10:31000
```

## 部署顺序
### 1. 部署k8s监控组件
apply metrics-server.yaml 和 kube-state-metrics.yaml（注意k8s集群版本差异）
### 2. 创建文件顺序
rbac.yaml——>thanos-storage-minio.yaml——>其他yaml
只需要在其中一个集群部署Alertmanager和thanos-query-global即可

## 不同集群修改文件内容
### 1. thanos-storage-minio.yaml
修改bucket的access_key和secret_key还有地址
```yaml
bucket: thanos-tj-test
endpoint: 192.168.10.20:40000
access_key: access_key
secret_key: secret_key
```
### 2. prometheus.yaml
修改Prometheus额外标签，标注集群名称
```yaml
- name: CLUSTER
  value: "shanghai"
```
### 3.*-ingress.yaml
修改ingress资源访问域名
```yaml
spec:
  routes:
    - match: Host(`prometheus.shanghai.com`)
```
