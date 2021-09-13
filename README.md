## 一、prometheus痛点
prometheus的单机痛点简单来说就是存在性能瓶颈，不得不降低采集频率，丢弃部分指标，缩小数据过去时间。想要实现水平扩容只能按服务进行拆分，或者服务分片。为了解决数据分散问题，可以指定远程集中存储，但抛弃了强大的promQL。上述方案虽然解决了prometheus的痛点，但是极大的提高了运维使用难度。针对这些问题上述问题，最好的方式办法是采用Thanos 的架构解决。
详细内容可参见[https://cloud.tencent.com/developer/article/1605915?from=10680](https://cloud.tencent.com/developer/article/1605915?from=10680)，总结的非常到位。在面试中也经常会问到prometheus监控上千台节点时如何进行优化，避免单点故障。
## 二、thanos简介
### 1. thanos架构
Sidecar模式：绑定部署在Prometheus 实例上，当进行查询时，由thanos sidecar返回监控数据给Thanos QueryT对数据进行聚合与去重。最新的监控数据存放于Prometheus 本机（适用于Sidecar数量少，prometheus集群查询响应快的场景）
![image.png](https://cdn.nlark.com/yuque/0/2021/png/2308212/1631445619847-de01db26-ef6e-491b-9a54-a6340003478f.png#clientId=u004fdf9d-2a04-4&from=paste&height=720&id=ubfe5e3ce&margin=%5Bobject%20Object%5D&name=image.png&originHeight=720&originWidth=960&originalType=binary&ratio=1&size=85056&status=done&style=none&taskId=u47d9ee5e-c3ef-407c-8ce8-9a14810e952&width=960)
Receive模式:Prometheus 实例实时将数据 push 到 Thanos Receiver，最新数据也得以集中起来，然后 Thanos Query 也不用去所有 Sidecar 查最新数据了，直接查 Thanos Receiver 即可（适用于集群规模大，prometheus节点较多，集群查询响应慢的场景）
![image.png](https://cdn.nlark.com/yuque/0/2021/png/2308212/1631445821424-ac66334d-eb62-4b07-8b2e-195fe3e1c23c.png#clientId=u004fdf9d-2a04-4&from=paste&height=720&id=u803aa3f1&margin=%5Bobject%20Object%5D&name=image.png&originHeight=720&originWidth=960&originalType=binary&ratio=1&size=88899&status=done&style=none&taskId=u62ec58da-e460-4431-b5ab-20dbcaadf87&width=960)
### 2. thanos组件
Thanos Query: 实现了 Prometheus API，将来自下游组件提供的数据进行聚合最终返回给查询数据的 client (如 grafana)，类似数据库中间件。
Thanos Sidecar: 连接 Prometheus，将其数据提供给 Thanos Query 查询，并且/或者将其上传到对象存储，以供长期存储。
Thanos Store Gateway: 将对象存储的数据暴露给 Thanos Query 去查询。
Thanos Ruler: 对监控数据进行评估和告警，还可以计算出新的监控数据，将这些新数据提供给 Thanos Query 查询并且/或者上传到对象存储，以供长期存储。
Thanos Compact: 将对象存储中的数据进行压缩和降低采样率，加速大时间区间监控数据查询的速度。
## 三、thanos部署（基础组件）
### 1. 环境与版本
> 虽然网上有很多部署文档，官网也有demo示例。但在实际部署过程中仍然发现不少问题，以下部署过程本人是参考最新文档示例部署后总结的，如果和本人使用同样的环境，理论上部署不会存在任何问题。

```bash
[root@tiaoban ~]# kubectl get node
NAME         STATUS   ROLES    AGE    VERSION
k8s-master   Ready    master   233d   v1.18.14
k8s-work1    Ready    <none>   233d   v1.18.14
k8s-work2    Ready    <none>   233d   v1.18.14
k8s-work3    Ready    <none>   233d   v1.18.14
```
prometheus：v0.23.0
alertmanager：v0.23.0
node-exporter：v1.2.2
grafana：8.1.3
thanos：0.23.0-rc.0
### 2. 准备工作
> thanos推荐使用对象存储服务实现数据持久化，如果是公有云推荐腾讯云 COS 或者阿里云 OSS ，如果是私有云推荐使用minIO或者ceph的RGW。此处为了便于演示，直接使用local pv。

- 宿主机创建目录（或挂载并格式化一个可用的磁盘）用于存储。
```bash
# 提前在所有work节点创建如下三个目录，用于存放数据。
mkdir -p /tmp/{prometheus,grafana,thanos-store}
```

- 创建StorageClass
```yaml
[root@tiaoban thanos]# cat storageClass.yaml 
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
[root@tiaoban thanos]# kubectl apply -f storageClass.yaml 
storageclass.storage.k8s.io/local-storage created
[root@tiaoban thanos]# kubectl get sc
NAME            PROVISIONER                    RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
local-storage   kubernetes.io/no-provisioner   Delete          WaitForFirstConsumer   false                  3s
```
volumeBindingMode 字段定义为 WaitForFirstConsumer，即：延迟绑定。当在我们提交 PVC 文件时，StorageClass 为我们延迟绑定 PV 与 PVC 的对应关系。避免pod因pv资源而调度失败。

- 创建namespace

`kubectl create ns thanos`
### 3. 创建ServiceAccount
> 创建Prometheus账号，并为其绑定足够的 RBAC 权限，以便后续配置使用 k8s 的服务发现 (kubernetes_sd_configs) 时能够正常工作。

```yaml
[root@tiaoban thanos]# cat rbac.yaml 
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus
  namespace: thanos

---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRole
metadata:
  name: prometheus
  namespace: thanos
rules:
- apiGroups: [""]
  resources:
  - nodes
  - nodes/proxy
  - nodes/metrics
  - services
  - endpoints
  - pods
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get"]
- nonResourceURLs: ["/metrics"]
  verbs: ["get"]

---
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: prometheus
subjects:
  - kind: ServiceAccount
    name: prometheus
    namespace: thanos
roleRef:
  kind: ClusterRole
  name: prometheus
  apiGroup: rbac.authorization.k8s.io
[root@tiaoban thanos]# kubectl apply -f rbac.yaml 
serviceaccount/prometheus created
clusterrole.rbac.authorization.k8s.io/prometheus unchanged
clusterrolebinding.rbac.authorization.k8s.io/prometheus unchanged
[root@tiaoban thanos]# kubectl get sa -n thanos 
NAME         SECRETS   AGE
default      1         2m35s
prometheus   1         12s
```
### 4. 部署prometheus和Sidecar

- 创建pv资源，供Prometheus 使用 StatefulSet使用
> 此处部署三个 Prometheus StatefulSet，用于实现高可用，模拟实际生产环境多个prometheus集群情况。

```yaml
[root@tiaoban thanos]# cat prometheus-pv.yaml 
apiVersion: v1
kind: PersistentVolume
metadata:
  name: prometheus-pv1
spec:
  capacity:
    storage: 10Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: local-storage
  local:
    path: /data/prometheus
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - k8s-work1
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: prometheus-pv2
spec:
  capacity:
    storage: 10Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: local-storage
  local:
    path: /data/prometheus
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - k8s-work2
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: prometheus-pv3
spec:
  capacity:
    storage: 10Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: local-storage
  local:
    path: /data/prometheus
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - k8s-work3
[root@tiaoban thanos]# kubectl apply -f prometheus-pv.yaml 
persistentvolume/prometheus-pv1 created
persistentvolume/prometheus-pv2 created
persistentvolume/prometheus-pv3 created
[root@tiaoban thanos]# kubectl get pv
NAME             CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM   STORAGECLASS    REASON   AGE
prometheus-pv1   10Gi       RWO            Delete           Available           local-storage            4s
prometheus-pv2   10Gi       RWO            Delete           Available           local-storage            4s
prometheus-pv3   10Gi       RWO            Delete           Available           local-storage            4s
```

- 创建prometheus配置文件和roles告警规则文件
> - Prometheus 使用 --storage.tsdb.retention.time 指定数据保留时长，默认15天，可以根据数据增长速度和数据盘大小做适当调整(数据增长取决于采集的指标和目标端点的数量和采集频率)。
> - 通常会给 Prometheus 附带一个 quay.io/coreos/prometheus-config-reloader 来监听配置变更并动态加载，但 thanos sidecar 也为我们提供了这个功能，所以可以直接用 thanos sidecar 来实现此功能，也支持配置文件根据模板动态生成：--reloader.config-file 指定 Prometheus 配置文件模板--reloader.config-envsubst-file 指定生成配置文件的存放路径，假设是 /etc/prometheus/config_out/prometheus.yaml ，那么 /etc/prometheus/config_out 这个路径使用 emptyDir 让 Prometheus 与 Sidecar 实现配置文件共享挂载，Prometheus 再通过 --config.file 指定生成出来的配置文件，当配置有更新时，挂载的配置文件也会同步更新，Sidecar 也会通知 Prometheus 重新加载配置。另外，Sidecar 与 Prometheus 也挂载同一份 rules 配置文件，配置更新后 Sidecar 仅通知 Prometheus 加载配置，不支持模板，因为 rules 配置不需要模板来动态生成。
> - Prometheus 实例采集的所有指标数据里都会额外加上 external_labels 里指定的 label，通常用 cluster 区分当前 Prometheus 所在集群的名称，我们再加了个 prometheus_replica，用于区分相同 Prometheus 副本（这些副本所采集的数据除了 prometheus_replica 的值不一样，其它几乎一致，这个值会被 Thanos Sidecar 替换成 Pod 副本的名称，用于 Thanos 实现 Prometheus 高可用）

```yaml
[root@tiaoban thanos]# cat prometheus-config.yaml 
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config-tmpl
  namespace: thanos
data:
  prometheus.yaml.tmpl: |-
    global:
      scrape_interval: 5s
      evaluation_interval: 5s
      external_labels:
        cluster: prometheus-ha
        prometheus_replica: $(POD_NAME)
    rule_files:
    - /etc/prometheus/rules/*.yaml
    scrape_configs:
    - job_name: node_exporter
      kubernetes_sd_configs:
      - role: node
      relabel_configs:
      - source_labels: [__address__]
        regex: '(.*):10250'
        replacement: '${1}:9100'
        target_label: __address__
        action: replace
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
    - job_name: kubelet
      metrics_path: /metrics/cadvisor
      scrape_interval: 10s
      scrape_timeout: 10s
      scheme: https
      tls_config:
        insecure_skip_verify: true
      bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      kubernetes_sd_configs:
      - role: node
      relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
    - job_name: 'kube-state-metrics'
      kubernetes_sd_configs:
      - role: pod
      relabel_configs:
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: pod
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
      - source_labels: [__meta_kubernetes_pod_ip]
        regex: (.+)
        target_label: __address__
        replacement: ${1}:8080
      - source_labels:  ["__meta_kubernetes_pod_container_name"]
        regex: "^kube-state-metrics.*"
        action: keep
    - job_name: prometheus
      honor_labels: false
      kubernetes_sd_configs:
      - role: endpoints
      scrape_interval: 30s
      relabel_configs:
      - source_labels:
          - __meta_kubernetes_service_label_name
        regex: k8s-prometheus
        action: keep
      - source_labels: [__meta_kubernetes_pod_ip]
        regex: (.+)
        target_label: __address__
        replacement: ${1}:9090
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-rules
  labels:
    name: prometheus-rules
  namespace: thanos
data:
  alert-rules.yaml: |-
    groups:
    - name: k8s.rules
      rules:
      - expr: |
          sum(rate(container_cpu_usage_seconds_total{job="cadvisor", image!="", container!=""}[5m])) by (namespace)
        record: namespace:container_cpu_usage_seconds_total:sum_rate
      - expr: |
          sum(container_memory_usage_bytes{job="cadvisor", image!="", container!=""}) by (namespace)
        record: namespace:container_memory_usage_bytes:sum
      - expr: |
          sum by (namespace, pod, container) (
            rate(container_cpu_usage_seconds_total{job="cadvisor", image!="", container!=""}[5m])
          )
        record: namespace_pod_container:container_cpu_usage_seconds_total:sum_rate
[root@tiaoban thanos]# kubectl apply -f prometheus-config.yaml 
configmap/prometheus-config-tmpl created
configmap/prometheus-rules created
[root@tiaoban thanos]# kubectl get configmaps -n thanos 
NAME                     DATA   AGE
prometheus-config-tmpl   1      8s
prometheus-rules         1      8s
```

- 部署prometheus和sidecar
> - Prometheus 使用 StatefulSet 方式部署，挂载数据盘以便存储最新监控数据。
> - 由于 Prometheus 副本之间没有启动顺序的依赖，所以 podManagementPolicy 指定为 Parallel，加快启动速度。
> - 为 Prometheus 创建 headless 类型 service，为后续 Thanos Query 通过 DNS SRV 记录来动态发现 Sidecar 的 gRPC 端点做准备 (使用 headless service 才能让 DNS SRV 正确返回所有端点)。
> - 使用硬反亲和，避免 Prometheus 部署在同一节点，既可以分散压力也可以避免单点故障。

```yaml
[root@tiaoban thanos]# cat prometheus.yaml 
kind: Service
apiVersion: v1
metadata:
  name: prometheus-headless
  namespace: thanos
  labels:
    app.kubernetes.io/name: prometheus
    name: k8s-prometheus
spec:
  type: ClusterIP
  clusterIP: None
  selector:
    app.kubernetes.io/name: prometheus
  ports:
  - name: web
    protocol: TCP
    port: 9090
    targetPort: web
  - name: grpc
    port: 10901
    targetPort: grpc
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: prometheus
  namespace: thanos
  labels:
    app.kubernetes.io/name: thanos-query
spec:
  serviceName: prometheus-headless
  podManagementPolicy: Parallel
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: prometheus
  template:
    metadata:
      labels:
        app.kubernetes.io/name: prometheus
    spec:
      serviceAccountName: prometheus
      securityContext:
        fsGroup: 2000
        runAsNonRoot: true
        runAsUser: 1000
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
              - key: app.kubernetes.io/name
                operator: In
                values:
                - prometheus
            topologyKey: kubernetes.io/hostname
      containers:
      - name: prometheus
        image: prom/prometheus:v2.30.0
        imagePullPolicy: IfNotPresent
        args:
        - --config.file=/etc/prometheus/config_out/prometheus.yaml
        - --storage.tsdb.path=/prometheus
        - --storage.tsdb.retention.time=10d
        - --web.route-prefix=/
        - --web.enable-lifecycle
        - --storage.tsdb.no-lockfile
        - --storage.tsdb.min-block-duration=2h
        - --storage.tsdb.max-block-duration=2h
        - --log.level=debug
        ports:
        - containerPort: 9090
          name: web
          protocol: TCP
        livenessProbe:
          failureThreshold: 6
          httpGet:
            path: /-/healthy
            port: web
            scheme: HTTP
          periodSeconds: 5
          successThreshold: 1
          timeoutSeconds: 3
        readinessProbe:
          failureThreshold: 120
          httpGet:
            path: /-/ready
            port: web
            scheme: HTTP
          periodSeconds: 5
          successThreshold: 1
          timeoutSeconds: 3
        volumeMounts:
        - mountPath: /etc/prometheus/config_out
          name: prometheus-config-out
          readOnly: true
        - mountPath: /prometheus
          name: data
        - mountPath: /etc/prometheus/rules
          name: prometheus-rules
      - name: thanos
        image: thanosio/thanos:v0.23.0-rc.0
        imagePullPolicy: IfNotPresent
        args:
        - sidecar
        - --log.level=debug
        - --tsdb.path=/prometheus
        - --prometheus.url=http://127.0.0.1:9090
        - --reloader.config-file=/etc/prometheus/config/prometheus.yaml.tmpl
        - --reloader.config-envsubst-file=/etc/prometheus/config_out/prometheus.yaml
        - --reloader.rule-dir=/etc/prometheus/rules/
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        ports:
        - name: http-sidecar
          containerPort: 10902
        - name: grpc
          containerPort: 10901
        livenessProbe:
            httpGet:
              port: 10902
              path: /-/healthy
        readinessProbe:
          httpGet:
            port: 10902
            path: /-/ready
        volumeMounts:
        - name: prometheus-config-tmpl
          mountPath: /etc/prometheus/config
        - name: prometheus-config-out
          mountPath: /etc/prometheus/config_out
        - name: prometheus-rules
          mountPath: /etc/prometheus/rules
        - name: data
          mountPath: /prometheus
      volumes:
      - name: prometheus-config-tmpl
        configMap:
          defaultMode: 420
          name: prometheus-config-tmpl
      - name: prometheus-config-out
        emptyDir: {}
      - name: prometheus-rules
        configMap:
          name: prometheus-rules
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes:
      - ReadWriteOnce
      storageClassName: local-storage
      resources:
        requests:
          storage: 5Gi
[root@tiaoban thanos]# kubectl apply -f prometheus.yaml 
service/prometheus-headless created
statefulset.apps/prometheus created
[root@tiaoban thanos]# kubectl get pod -n thanos 
NAME           READY   STATUS    RESTARTS   AGE
prometheus-0   2/2     Running   1          2m46s
prometheus-1   2/2     Running   1          2m37s
prometheus-2   2/2     Running   1          3m22s
[root@tiaoban thanos]# kubectl get pv
NAME             CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                      STORAGECLASS    REASON   AGE
prometheus-pv1   10Gi       RWO            Delete           Bound    thanos/data-prometheus-0   local-storage            58m
prometheus-pv2   10Gi       RWO            Delete           Bound    thanos/data-prometheus-1   local-storage            58m
prometheus-pv3   10Gi       RWO            Delete           Bound    thanos/data-prometheus-2   local-storage            58m
```
### 5. 部署Thanos Querier
> - 因为 Query 是无状态的，使用 Deployment 部署，也不需要 headless service，直接创建普通的 service。
> - 使用软反亲和，尽量不让 Query 调度到同一节点。
> - 部署多个副本，实现 Query 的高可用。
> - --query.partial-response 启用 [Partial Response](https://thanos.io/components/query.md/#partial-response)，这样可以在部分后端 Store API 返回错误或超时的情况下也能看到正确的监控数据(如果后端 Store API 做了高可用，挂掉一个副本，Query 访问挂掉的副本超时，但由于还有没挂掉的副本，还是能正确返回结果；如果挂掉的某个后端本身就不存在我们需要的数据，挂掉也不影响结果的正确性；总之如果各个组件都做了高可用，想获得错误的结果都难，所以我们有信心启用 Partial Response 这个功能)。
> - --query.auto-downsampling 查询时自动降采样，提升查询效率。
> - --query.replica-label 指定我们刚刚给 Prometheus 配置的 prometheus_replica 这个 external label，Query 向 Sidecar 拉取 Prometheus 数据时会识别这个 label 并自动去重，这样即使挂掉一个副本，只要至少有一个副本正常也不会影响查询结果，也就是可以实现 Prometheus 的高可用。同理，再指定一个 rule_replica 用于给 Ruler 做高可用。
> - --store 指定实现了 Store API 的地址(Sidecar, Ruler, Store Gateway, Receiver)，通常不建议写静态地址，而是使用服务发现机制自动发现 Store API 地址，如果是部署在同一个集群，可以用 DNS SRV 记录来做服务发现，比如 dnssrv+_grpc._tcp.prometheus-headless.thanos.svc.cluster.local，也就是我们刚刚为包含 Sidecar 的 Prometheus 创建的 headless service (使用 headless service 才能正确实现服务发现)，并且指定了名为 grpc 的 tcp 端口，同理，其它组件也可以按照这样加到 --store 参数里；如果是其它有些组件部署在集群外，无法通过集群 dns 解析 DNS SRV 记录，可以使用配置文件来做服务发现，也就是指定 --store.sd-files 参数，将其它 Store API 地址写在配置文件里 (挂载 ConfigMap)，需要增加地址时直接更新 ConfigMap (不需要重启 Query)。

- 部署Thanos Querier
```yaml
[root@tiaoban thanos]# cat thanos-query.yaml 
apiVersion: v1
kind: Service
metadata:
  name: thanos-query
  namespace: thanos
  labels:
    app.kubernetes.io/name: thanos-query
spec:
  ports:
  - name: grpc
    port: 10901
    targetPort: grpc
  - name: http
    port: 9090
    targetPort: http
  selector:
    app.kubernetes.io/name: thanos-query
---

apiVersion: apps/v1
kind: Deployment
metadata:
  name: thanos-query
  namespace: thanos
  labels:
    app.kubernetes.io/name: thanos-query
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: thanos-query
  template:
    metadata:
      labels:
        app.kubernetes.io/name: thanos-query
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app.kubernetes.io/name
                  operator: In
                  values:
                  - thanos-query
              topologyKey: kubernetes.io/hostname
            weight: 100
      containers:
      - args:
        - query
        - --log.level=debug
        - --query.auto-downsampling
        - --grpc-address=0.0.0.0:10901
        - --http-address=0.0.0.0:9090
        - --query.partial-response
        - --query.replica-label=prometheus_replica
        - --query.replica-label=rule_replica
        - --store=dnssrv+_grpc._tcp.prometheus-headless.thanos.svc.cluster.local
        - --store=dnssrv+_grpc._tcp.thanos-rule.thanos.svc.cluster.local
        - --store=dnssrv+_grpc._tcp.thanos-store.thanos.svc.cluster.local
        image: thanosio/thanos:v0.23.0-rc.0
        imagePullPolicy: IfNotPresent
        resources:
          limits:
            memory: "2048Mi"
            cpu: "500m" 
          requests:
            memory: "128Mi"
            cpu: "100m" 
        livenessProbe:
          failureThreshold: 4
          httpGet:
            path: /-/healthy
            port: 9090
            scheme: HTTP
          periodSeconds: 30
        name: thanos-query
        ports:
        - containerPort: 10901
          name: grpc
        - containerPort: 9090
          name: http
        readinessProbe:
          failureThreshold: 20
          httpGet:
            path: /-/ready
            port: 9090
            scheme: HTTP
          periodSeconds: 5
        terminationMessagePolicy: FallbackToLogsOnError
      terminationGracePeriodSeconds: 120
[root@tiaoban thanos]# kubectl apply -f thanos-query.yaml 
service/thanos-query created
deployment.apps/thanos-query created
[root@tiaoban thanos]# kubectl get pod -n thanos 
NAME                           READY   STATUS    RESTARTS   AGE
prometheus-0                   2/2     Running   1          14m
prometheus-1                   2/2     Running   1          14m
prometheus-2                   2/2     Running   1          15m
thanos-query-5cd8dc8d7-rg75m   1/1     Running   0          33s
thanos-query-5cd8dc8d7-xqbjp   1/1     Running   0          32s
thanos-query-5cd8dc8d7-xth47   1/1     Running   0          32s
```
### 6. 部署Thanos Store Gateway

- 创建pv，用于store gateway数据存储
```yaml
[root@tiaoban thanos]# cat thanos-store-pv.yaml 
apiVersion: v1
kind: PersistentVolume
metadata:
  name: thanos-store-pv1
spec:
  capacity:
    storage: 5Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: local-storage
  local:
    path: /data/thanos-store
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - k8s-work1
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: thanos-store-pv2
spec:
  capacity:
    storage: 5Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: local-storage
  local:
    path: /data/thanos-store
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - k8s-work2
[root@tiaoban thanos]# kubectl apply -f thanos-store-pv.yaml 
persistentvolume/thanos-store-pv1 created
persistentvolume/thanos-store-pv2 created
[root@tiaoban thanos]# kubectl get pv
NAME               CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM                      STORAGECLASS    REASON   AGE
prometheus-pv1     10Gi       RWO            Delete           Bound       thanos/data-prometheus-0   local-storage            70m
prometheus-pv2     10Gi       RWO            Delete           Bound       thanos/data-prometheus-1   local-storage            70m
prometheus-pv3     10Gi       RWO            Delete           Bound       thanos/data-prometheus-2   local-storage            70m
thanos-store-pv1   5Gi        RWO            Delete           Available                              local-storage            5s
thanos-store-pv2   5Gi        RWO            Delete           Available                              local-storage            5s
```

- 创建Store Gateway配置文件，此处使用FILESYSTEM便于演示
```yaml
[root@tiaoban thanos]# cat thanos-store-config.yaml 
apiVersion: v1
kind: ConfigMap
metadata:
  name: thanos-storage-config
  namespace: thanos
data:
  storage.yaml: |
    type: FILESYSTEM
    config:
      directory: "/data/thanos-store/"

[root@tiaoban thanos]# kubectl apply -f thanos-store-config.yaml 
configmap/thanos-storage-config created
[root@tiaoban thanos]# kubectl get configmaps -n thanos 
NAME                     DATA   AGE
prometheus-config-tmpl   1      69m
prometheus-rules         1      69m
thanos-storage-config    1      7s
```

- 部署Store Gateway
> - Store Gateway 实际也可以做到一定程度的无状态，它会需要一点磁盘空间来对对象存储做索引以加速查询，但数据不那么重要，是可以删除的，删除后会自动去拉对象存储查数据重新建立索引。这里我们避免每次重启都重新建立索引，所以用 StatefulSet 部署 Store Gateway，挂载一块小容量的磁盘(索引占用不到多大空间)。
> - 同样创建 headless service，用于 Query 对 Store Gateway 进行服务发现。
> - 部署两个副本，实现 Store Gateway 的高可用。

```yaml
[root@tiaoban thanos]# cat thanos-store.yaml 
apiVersion: v1
kind: Service
metadata:
  name: thanos-store
  namespace: thanos
  labels:
    app.kubernetes.io/name: thanos-store
spec:
  clusterIP: None
  ports:
  - name: grpc
    port: 10901
    targetPort: 10901
  - name: http
    port: 10902
    targetPort: 10902
  selector:
    app.kubernetes.io/name: thanos-store
---

apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: thanos-store
  namespace: thanos
  labels:
    app.kubernetes.io/name: thanos-store
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: thanos-store
  serviceName: thanos-store
  podManagementPolicy: Parallel
  template:
    metadata:
      labels:
        app.kubernetes.io/name: thanos-store
    spec:
      containers:
      - args:
        - store
        - --log.level=debug
        - --data-dir=/var/thanos/store
        - --grpc-address=0.0.0.0:10901
        - --http-address=0.0.0.0:10902
        - --objstore.config-file=/etc/thanos/storage.yaml
        image: thanosio/thanos:v0.23.0-rc.0
        imagePullPolicy: IfNotPresent
        resources:
          limits:
            memory: "2048Mi"
            cpu: "500m" 
          requests:
            memory: "128Mi"
            cpu: "100m" 
        livenessProbe:
          failureThreshold: 8
          httpGet:
            path: /-/healthy
            port: 10902
            scheme: HTTP
          periodSeconds: 30
        name: thanos-store
        ports:
        - containerPort: 10901
          name: grpc
        - containerPort: 10902
          name: http
        readinessProbe:
          failureThreshold: 20
          httpGet:
            path: /-/ready
            port: 10902
            scheme: HTTP
          periodSeconds: 5
        terminationMessagePolicy: FallbackToLogsOnError
        volumeMounts:
        - mountPath: /var/thanos/store
          name: data
          readOnly: false
        - name: thanos-storage-config
          subPath: storage.yaml
          mountPath: /etc/thanos/storage.yaml
      terminationGracePeriodSeconds: 120
      volumes:
      - name: thanos-storage-config
        configMap:
          name: thanos-storage-config
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes:
      - ReadWriteOnce
      storageClassName: local-storage
      resources:
        requests:
          storage: 5Gi
[root@tiaoban thanos]# kubectl apply -f thanos-store.yaml 
service/thanos-store created
statefulset.apps/thanos-store created
[root@tiaoban thanos]# kubectl get pod -n thanos 
NAME                           READY   STATUS    RESTARTS   AGE
prometheus-0                   2/2     Running   1          33m
prometheus-1                   2/2     Running   1          33m
prometheus-2                   2/2     Running   1          34m
thanos-query-5cd8dc8d7-rg75m   1/1     Running   0          19m
thanos-query-5cd8dc8d7-xqbjp   1/1     Running   0          19m
thanos-query-5cd8dc8d7-xth47   1/1     Running   0          19m
thanos-store-0                 1/1     Running   0          45s
thanos-store-1                 1/1     Running   0          45s
[root@tiaoban thanos]# kubectl get pv
NAME               CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                        STORAGECLASS    REASON   AGE
prometheus-pv1     10Gi       RWO            Delete           Bound    thanos/data-prometheus-0     local-storage            86m
prometheus-pv2     10Gi       RWO            Delete           Bound    thanos/data-prometheus-1     local-storage            86m
prometheus-pv3     10Gi       RWO            Delete           Bound    thanos/data-prometheus-2     local-storage            86m
thanos-store-pv1   5Gi        RWO            Delete           Bound    thanos/data-thanos-store-0   local-storage            81s
thanos-store-pv2   5Gi        RWO            Delete           Bound    thanos/data-thanos-store-1   local-storage            81s
```
### 7. 部署Thanos Compact

- 创建pv，用于compact存储
```yaml
[root@tiaoban thanos]# cat thanos-compact-pv.yaml 
apiVersion: v1
kind: PersistentVolume
metadata:
  name: thanos-compact-pv
spec:
  capacity:
    storage: 10Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: local-storage
  local:
    path: /data/thanos-compact
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - k8s-work3
[root@tiaoban thanos]# kubectl apply -f thanos-compact-pv.yaml 
persistentvolume/thanos-compact-pv created
[root@tiaoban thanos]# kubectl get pv
NAME                CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM                        STORAGECLASS    REASON   AGE
prometheus-pv1      10Gi       RWO            Delete           Bound       thanos/data-prometheus-0     local-storage            88m
prometheus-pv2      10Gi       RWO            Delete           Bound       thanos/data-prometheus-1     local-storage            88m
prometheus-pv3      10Gi       RWO            Delete           Bound       thanos/data-prometheus-2     local-storage            88m
thanos-compact-pv   10Gi       RWO            Delete           Available                                local-storage            4s
thanos-store-pv1    5Gi        RWO            Delete           Bound       thanos/data-thanos-store-0   local-storage            3m29s
thanos-store-pv2    5Gi        RWO            Delete           Bound       thanos/data-thanos-store-1   local-storage            3m29s
```

- 部署thanos compact
> - Compact 只能部署单个副本，因为如果多个副本都去对对象存储的数据做压缩和降采样的话，会造成冲突。
> - 使用 StatefulSet 部署，方便自动创建和挂载磁盘。磁盘用于存放临时数据，因为 Compact 需要一些磁盘空间来存放数据处理过程中产生的中间数据。
> - --wait 让 Compact 一直运行，轮询新数据来做压缩和降采样。
> - Compact 也需要对象存储的配置，用于读取对象存储数据以及上传压缩和降采样后的数据到对象存储。
> - 创建一个普通 service，主要用于被 Prometheus 使用 kubernetes 的 endpoints 服务发现来采集指标(其它组件的 service 也一样有这个用途)。
> - --retention.resolution-raw 指定原始数据存放时长，--retention.resolution-5m 指定降采样到数据点 5 分钟间隔的数据存放时长，--retention.resolution-1h 指定降采样到数据点 1 小时间隔的数据存放时长，它们的数据精细程度递减，占用的存储空间也是递减，通常建议它们的存放时间递增配置 (一般只有比较新的数据才会放大看，久远的数据通常只会使用大时间范围查询来看个大致，所以建议将精细程度低的数据存放更长时间)

```yaml
[root@tiaoban thanos]# cat thanos-compact.yaml 
apiVersion: v1
kind: Service
metadata:
  labels:
    app.kubernetes.io/name: thanos-compact
  name: thanos-compact
  namespace: thanos
spec:
  ports:
  - name: http
    port: 10902
    targetPort: http
  selector:
    app.kubernetes.io/name: thanos-compact
---

apiVersion: apps/v1
kind: StatefulSet
metadata:
  labels:
    app.kubernetes.io/name: thanos-compact
  name: thanos-compact
  namespace: thanos
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: thanos-compact
  serviceName: thanos-compact
  template:
    metadata:
      labels:
        app.kubernetes.io/name: thanos-compact
    spec:
      containers:
      - args:
        - compact
        - --wait
        - --objstore.config-file=/etc/thanos/storage.yaml
        - --data-dir=/var/thanos/compact
        - --debug.accept-malformed-index
        - --log.level=debug
        - --retention.resolution-raw=90d
        - --retention.resolution-5m=180d
        - --retention.resolution-1h=360d
        image: thanosio/thanos:v0.23.0-rc.0
        imagePullPolicy: IfNotPresent
        resources:
          limits:
            memory: "2048Mi"
            cpu: "500m" 
          requests:
            memory: "128Mi"
            cpu: "100m" 
        livenessProbe:
          failureThreshold: 4
          httpGet:
            path: /-/healthy
            port: 10902
            scheme: HTTP
          periodSeconds: 30
        name: thanos-compact
        ports:
        - containerPort: 10902
          name: http
        readinessProbe:
          failureThreshold: 20
          httpGet:
            path: /-/ready
            port: 10902
            scheme: HTTP
          periodSeconds: 5
        terminationMessagePolicy: FallbackToLogsOnError
        volumeMounts:
        - mountPath: /var/thanos/compact
          name: data
          readOnly: false
        - name: thanos-storage-config
          subPath: storage.yaml
          mountPath: /etc/thanos/storage.yaml
      terminationGracePeriodSeconds: 120
      volumes:
      - name: thanos-storage-config
        configMap:
          name: thanos-storage-config
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes:
      - ReadWriteOnce
      storageClassName: local-storage
      resources:
        requests:
          storage: 10Gi
[root@tiaoban thanos]# kubectl apply -f thanos-compact.yaml 
service/thanos-compact created
statefulset.apps/thanos-compact created
[root@tiaoban thanos]# kubectl get pod -n thanos 
NAME                           READY   STATUS    RESTARTS   AGE
prometheus-0                   2/2     Running   1          40m
prometheus-1                   2/2     Running   1          39m
prometheus-2                   2/2     Running   1          40m
thanos-compact-0               1/1     Running   0          8s
thanos-query-5cd8dc8d7-rg75m   1/1     Running   0          26m
thanos-query-5cd8dc8d7-xqbjp   1/1     Running   0          26m
thanos-query-5cd8dc8d7-xth47   1/1     Running   0          26m
thanos-store-0                 1/1     Running   0          7m23s
thanos-store-1                 1/1     Running   0          7m23s
[root@tiaoban thanos]# kubectl get pv
NAME                CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                          STORAGECLASS    REASON   AGE
prometheus-pv1      10Gi       RWO            Delete           Bound    thanos/data-prometheus-0       local-storage            92m
prometheus-pv2      10Gi       RWO            Delete           Bound    thanos/data-prometheus-1       local-storage            92m
prometheus-pv3      10Gi       RWO            Delete           Bound    thanos/data-prometheus-2       local-storage            92m
thanos-compact-pv   10Gi       RWO            Delete           Bound    thanos/data-thanos-compact-0   local-storage            4m20s
thanos-store-pv1    5Gi        RWO            Delete           Bound    thanos/data-thanos-store-0     local-storage            7m45s
thanos-store-pv2    5Gi        RWO            Delete           Bound    thanos/data-thanos-store-1     local-storage            7m45s
```
### 8. 部署Alertmanager

- 创建alertmanager配置文件
> 此处以最简单的webhook告警基础配置为例

```yaml
[root@tiaoban thanos]# cat alertmanager-config.yaml 
kind: ConfigMap
apiVersion: v1
metadata:
  name: alertmanager-conf
  namespace: thanos
data:
  config.yaml: |-
    global:
      resolve_timeout: 5m
    route:
      group_by: ['alertname', 'cluster', 'service']
      group_wait: 30s
      group_interval: 5s
      repeat_interval: 10s  
      receiver: 'web.hook'
    receivers:
    - name: 'web.hook'
      webhook_configs:
      - url: 'http://127.0.0.1:5000'
[root@tiaoban thanos]# kubectl apply -f alertmanager-config.yaml 
configmap/alertmanager-conf created
[root@tiaoban thanos]# kubectl get configmaps -n thanos 
NAME                     DATA   AGE
alertmanager-conf        1      10s
prometheus-config-tmpl   1      94m
prometheus-rules         1      94m
thanos-storage-config    1      25m
```

- 部署alertmanager
> - 因为alertmanager是无状态的，使用 Deployment 部署，也不需要 headless service，直接创建普通的 service。
> - 使用软反亲和，尽量不让 Query 调度到同一节点。
> - 部署多个副本，实现alertmanager的高可用。

```yaml
[root@tiaoban thanos]# cat alertmanager.yaml 
apiVersion: v1
kind: Service
metadata:
  name: alertmanager
  namespace: thanos
spec:
  selector:
    app: alertmanager
  ports:
  - name: alertmanager
    protocol: TCP
    port: 9093
    targetPort: 9093
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alertmanager
  namespace: thanos
spec:
  replicas: 2
  selector:
    matchLabels:
      app: alertmanager
  template:
    metadata:
      name: alertmanager
      labels:
        app: alertmanager
    spec:
      containers:
      - name: alertmanager
        image: prom/alertmanager:v0.23.0
        imagePullPolicy: IfNotPresent
        resources:
          limits:
            memory: "512Mi"
            cpu: "1000m"
          requests:
            memory: "128Mi"
            cpu: "500m"
        args:
          - '--config.file=/etc/alertmanager/config.yaml'
          - '--storage.path=/alertmanager'
        ports:
        - name: alertmanager
          containerPort: 9093
        volumeMounts:
        - name: alertmanager-conf
          mountPath: /etc/alertmanager
        - name: alertmanager
          mountPath: /alertmanager
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
              - key: app
                operator: In
                values:
                - alertmanager
            topologyKey: "kubernetes.io/hostname"
      volumes:
      - name: alertmanager-conf
        configMap:
          name: alertmanager-conf
      - name: alertmanager
        emptyDir: {}
[root@tiaoban thanos]# kubectl apply -f alertmanager.yaml 
service/alertmanager created
deployment.apps/alertmanager created
[root@tiaoban thanos]# kubectl get pod -n thanos 
NAME                            READY   STATUS    RESTARTS   AGE
alertmanager-54d948fdf7-6gpc4   1/1     Running   0          25s
alertmanager-54d948fdf7-qqvmp   1/1     Running   0          25s
prometheus-0                    2/2     Running   1          50m
prometheus-1                    2/2     Running   1          50m
prometheus-2                    2/2     Running   1          50m
thanos-compact-0                1/1     Running   0          10m
thanos-query-5cd8dc8d7-rg75m    1/1     Running   0          36m
thanos-query-5cd8dc8d7-xqbjp    1/1     Running   0          36m
thanos-query-5cd8dc8d7-xth47    1/1     Running   0          36m
thanos-store-0                  1/1     Running   0          17m
thanos-store-1                  1/1     Running   0          17m
```
### 9. 部署Node-Exporter

- 部署node-exporter使用daemonset即可。记得挂载proc、sys、root，使用宿主机网络和pid
```yaml
[root@tiaoban thanos]# cat node-exporter.yaml 
apiVersion: apps/v1
kind: DaemonSet
metadata:
  labels:
    app: node-exporter
  name: node-exporter
  namespace: thanos
spec:
  selector:
    matchLabels:
      app: node-exporter
  template:
    metadata:
      labels:
        app: node-exporter
    spec:
      containers:
      - args:
        - --path.procfs=/host/proc
        - --path.sysfs=/host/sys
        - --path.rootfs=/host/root
        image: prom/node-exporter:v1.2.2
        name: node-exporter
        resources:
          limits:
            cpu: 250m
            memory: 180Mi
          requests:
            cpu: 100m
            memory: 100Mi
        volumeMounts:
        - mountPath: /host/proc
          name: proc
          readOnly: false
        - mountPath: /host/sys
          name: sys
          readOnly: false
        - mountPath: /host/root
          mountPropagation: HostToContainer
          name: root
          readOnly: true
        ports:
        - name: node-exporter
          hostPort: 9100
          containerPort: 9100
          protocol: TCP
      hostNetwork: true
      hostPID: true
      nodeSelector:
        kubernetes.io/os: linux
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
      tolerations:
      - operator: Exists
      volumes:
      - hostPath:
          path: /proc
        name: proc
      - hostPath:
          path: /sys
        name: sys
      - hostPath:
          path: /
        name: root
[root@tiaoban thanos]# kubectl apply -f node-exporter.yaml 
daemonset.apps/node-exporter created
[root@tiaoban thanos]# kubectl get pod -n thanos -o wide -l app=node-exporter
NAME                  READY   STATUS    RESTARTS   AGE     IP              NODE         NOMINATED NODE   READINESS GATES
node-exporter-4g577   1/1     Running   0          5m23s   192.168.10.13   k8s-work3    <none>           <none>
node-exporter-76phm   1/1     Running   0          5m23s   192.168.10.10   k8s-master   <none>           <none>
node-exporter-hb6p6   1/1     Running   0          5m23s   192.168.10.11   k8s-work1    <none>           <none>
node-exporter-hz8x9   1/1     Running   0          5m23s   192.168.10.12   k8s-work2    <none>           <none>
```
### 10. 部署kube-state-metrics
> 如果已经部署过该组件直接跳过进行下一步，记得将server允许prometheus自动发现

- 版本依赖
| **kube-state-metrics** | **Kubernetes 1.18** | **Kubernetes 1.19** | **Kubernetes 1.20** | **Kubernetes 1.21** | **Kubernetes 1.22** |
| --- | --- | --- | --- | --- | --- |
| **v1.9.8** | - | - | - | - | - |
| **v2.0.0** | -/✓ | ✓ | ✓ | -/✓ | -/✓ |
| **v2.1.1** | -/✓ | ✓ | ✓ | ✓ | -/✓ |
| **v2.2.0** | -/✓ | ✓ | ✓ | ✓ | ✓ |
| **master** | -/✓ | ✓ | ✓ | ✓ | ✓ |

- 克隆项目至本地
```yaml
git clone https://github.com/kubernetes/kube-state-metrics.git
cd kube-state-metrics/examples/standard/
```

- 修改service，允许prometheus自动发现
```yaml
vim service.yaml
apiVersion: v1
kind: Service
metadata:
  labels:
    app.kubernetes.io/name: kube-state-metrics
    app.kubernetes.io/version: 2.2.0
  name: kube-state-metrics
  namespace: kube-system
  annotations:  
    prometheus.io/scrape: "true"       ##添加此参数，允许prometheus自动发现
```

- 创建资源
```yaml
kubectl apply -f .
[root@tiaoban standard]# kubectl get pod -n kube-system -l app.kubernetes.io/name=kube-state-metrics
NAME                                 READY   STATUS    RESTARTS   AGE
kube-state-metrics-bb59558c8-cx9pz   1/1     Running   0          1m
```

- 使用kubectl top node查看结果
```yaml
[root@tiaoban  ~]# kubectl top node 
NAME         CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
k8s-master   422m         10%    1471Mi          40%
k8s-work1    268m         6%     1197Mi          33%
k8s-work2    239m         5%     1286Mi          35%
k8s-work3    320m         8%     1091Mi          30%
```
### 11. 部署grafana
> - grafana服务与数据非强关联，使用 Deployment 部署，创建普通的 service。然后挂载pvc即可
> - 部署多个副本，实现alertmanager的高可用。

- 创建pv和pvc。用于存储grafana数据
```yaml
[root@tiaoban thanos]# cat grafana-storage.yaml 
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: grafana-pvc
  namespace: thanos
spec:
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
  storageClassName: local-storage
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: grafana-pv
spec:
  capacity:
    storage: 5Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteMany
  persistentVolumeReclaimPolicy: Delete
  storageClassName: local-storage
  local:
    path: /data/grafana
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - k8s-work1
[root@tiaoban thanos]# kubectl apply -f grafana-storage.yaml 
persistentvolumeclaim/grafana-pvc created
persistentvolume/grafana-pv created
[root@tiaoban thanos]# kubectl get pvc -n thanos 
NAME                    STATUS    VOLUME              CAPACITY   ACCESS MODES   STORAGECLASS    AGE
data-prometheus-0       Bound     prometheus-pv1      10Gi       RWO            local-storage   112m
data-prometheus-1       Bound     prometheus-pv2      10Gi       RWO            local-storage   112m
data-prometheus-2       Bound     prometheus-pv3      10Gi       RWO            local-storage   112m
data-thanos-compact-0   Bound     thanos-compact-pv   10Gi       RWO            local-storage   44m
data-thanos-store-0     Bound     thanos-store-pv1    5Gi        RWO            local-storage   51m
data-thanos-store-1     Bound     thanos-store-pv2    5Gi        RWO            local-storage   51m
grafana-pvc             Pending                                                 local-storage   30s.
[root@tiaoban thanos]# kubectl get pv
NAME                CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM                          STORAGECLASS    REASON   AGE
grafana-pv          5Gi        RWX            Delete           Available                                  local-storage            41s
prometheus-pv1      10Gi       RWO            Delete           Bound       thanos/data-prometheus-0       local-storage            137m
prometheus-pv2      10Gi       RWO            Delete           Bound       thanos/data-prometheus-1       local-storage            137m
prometheus-pv3      10Gi       RWO            Delete           Bound       thanos/data-prometheus-2       local-storage            137m
thanos-compact-pv   10Gi       RWO            Delete           Bound       thanos/data-thanos-compact-0   local-storage            48m
thanos-store-pv1    5Gi        RWO            Delete           Bound       thanos/data-thanos-store-0     local-storage            52m
thanos-store-pv2    5Gi        RWO            Delete           Bound       thanos/data-thanos-store-1     local-storage            52m
```

- 部署grafana
```yaml
[root@tiaoban thanos]# cat grafana.yaml 
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: thanos
spec:
  ports:
  - port: 3000
    targetPort: 3000
  selector:
    name: grafana
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: thanos
spec:
  replicas: 2
  selector:
    matchLabels:
      name: grafana
  template:
    metadata:
      labels:
        name: grafana
    spec:
      containers:
      - name: grafana
        image: grafana/grafana:8.1.3
        resources:
          limits:
            memory: "1024Mi"
            cpu: "1000m"
          requests:
            memory: "128Mi"
            cpu: "500m"
        readinessProbe:
          failureThreshold: 10
          httpGet:
            path: /api/health
            port: 3000
            scheme: HTTP
          initialDelaySeconds: 60
          periodSeconds: 10
          successThreshold: 1
          timeoutSeconds: 30
        livenessProbe:
          failureThreshold: 3
          httpGet:
            path: /api/health
            port: 3000
            scheme: HTTP
          periodSeconds: 10
          successThreshold: 1
          timeoutSeconds: 1
        ports:
        - containerPort: 3000
          protocol: TCP
        volumeMounts:
        - mountPath: /var/lib/grafana
          name: grafana-storage
        env:
        - name: GF_SECURITY_ADMIN_USER
          value: admin
        - name: GF_SECURITY_ADMIN_PASSWORD
          value: 123.com
      volumes:
      - name: grafana-storage
        persistentVolumeClaim:
          claimName: grafana-pvc
[root@tiaoban thanos]# kubectl apply -f grafana.yaml 
service/grafana created
deployment.apps/grafana created
[root@tiaoban thanos]# kubectl get pod -n thanos -o wide -l name=grafana
NAME                      READY   STATUS    RESTARTS   AGE   IP             NODE        NOMINATED NODE   READINESS GATES
grafana-56c9c5f87-stf2q   1/1     Running   0          80s   10.244.3.132   k8s-work1   <none>           <none>
grafana-56c9c5f87-xvxzc   1/1     Running   0          80s   10.244.3.133   k8s-work1   <none>           <none>
```
### 12. 部署ingress
> 本次实验使用的ingress为traefik

- 查看thanos命名空间下的服务
```bash
[root@tiaoban thanos]# kubectl get svc -n thanos 
NAME                  TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)               AGE
alertmanager          ClusterIP   10.98.194.253    <none>        9093/TCP              43m
grafana               ClusterIP   10.107.15.87     <none>        3000/TCP              2m31s
prometheus-headless   ClusterIP   None             <none>        9090/TCP,10901/TCP    98m
thanos-compact        ClusterIP   10.106.179.2     <none>        10902/TCP             53m
thanos-query          ClusterIP   10.110.129.217   <none>        10901/TCP,9090/TCP    79m
thanos-store          ClusterIP   None             <none>        10901/TCP,10902/TCP   60m
```

- 依次对alertmanager、grafana、thanos-query、prometheus创建ingress
```yaml
[root@tiaoban thanos]# cat alertmanager-ingress.yaml 
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: alertmanager
  namespace: thanos
spec:
  routes:
    - match: Host(`alertmanager.local.com`)
      kind: Rule
      services:
        - name: alertmanager
          port: 9093
[root@tiaoban thanos]# kubectl apply -f alertmanager.yaml 
service/alertmanager unchanged
deployment.apps/alertmanager configured
[root@tiaoban thanos]# cat alertmanager-ingress.yaml 
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: alertmanager
  namespace: thanos
spec:
  routes:
    - match: Host(`alertmanager.local.com`)
      kind: Rule
      services:
        - name: alertmanager
          port: 9093
[root@tiaoban thanos]# kubectl apply -f alertmanager-ingress.yaml 
ingressroute.traefik.containo.us/alertmanager created
[root@tiaoban thanos]# cat grafana-ingress.yaml 
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: grafana
  namespace: thanos
spec:
  routes:
    - match: Host(`grafana.local.com`)
      kind: Rule
      services:
        - name: grafana
          port: 3000
[root@tiaoban thanos]# kubectl apply -f grafana-ingress.yaml 
ingressroute.traefik.containo.us/grafana created
[root@tiaoban thanos]# cat thanos-query-ingress.yaml 
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: thanos-querier
  namespace: thanos
spec:
  routes:
    - match: Host(`thanos-querier.local.com`)
      kind: Rule
      services:
        - name: thanos-query
          port: 9090
[root@tiaoban thanos]# kubectl apply -f thanos-query-ingress.yaml 
ingressroute.traefik.containo.us/thanos-querier created
[root@tiaoban thanos]# cat prometheus-ingress.yaml 
apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: prometheus
  namespace: thanos
spec:
  routes:
    - match: Host(`prometheus.local.com`)
      kind: Rule
      services:
        - name: prometheus-headless
          port: 9090
[root@tiaoban thanos]# kubectl apply -f prometheus-ingress.yaml 
ingressroute.traefik.containo.us/prometheus created
[root@tiaoban thanos]# kubectl get ingressroute -n thanos 
NAME             AGE
alertmanager     88s
grafana          71s
prometheus       7s
thanos-querier   27s
```

- 修改hosts文件，访问测试
```bash
192.168.10.10 prometheus.local.com
192.168.10.10 thanos-querier.local.com
192.168.10.10 grafana.local.com
192.168.10.10 alertmanager.local.com
```

- prometheus![image.png](https://cdn.nlark.com/yuque/0/2021/png/2308212/1631458901766-c08d2450-b59d-45ad-b012-212e3f9d5c56.png#clientId=u3ab05ffe-c464-4&from=paste&height=483&id=u02d974c0&margin=%5Bobject%20Object%5D&name=image.png&originHeight=483&originWidth=1669&originalType=binary&ratio=1&size=81614&status=done&style=none&taskId=u79a2ca92-87cb-47f8-9b74-d2b88f87612&width=1669)
- alertmanager![image.png](https://cdn.nlark.com/yuque/0/2021/png/2308212/1631458951364-13245d58-c461-438a-b0ba-9f2363fe4640.png#clientId=u3ab05ffe-c464-4&from=paste&height=659&id=u761c154e&margin=%5Bobject%20Object%5D&name=image.png&originHeight=659&originWidth=1667&originalType=binary&ratio=1&size=134891&status=done&style=none&taskId=u45ad26bd-d17c-4264-b3f4-3fefac2e5dc&width=1667)
- thanos-querier

![image.png](https://cdn.nlark.com/yuque/0/2021/png/2308212/1631459159948-f90341f7-be5a-49ee-9268-985d23c388c5.png#clientId=u3ab05ffe-c464-4&from=paste&height=511&id=u95a4c831&margin=%5Bobject%20Object%5D&name=image.png&originHeight=511&originWidth=1672&originalType=binary&ratio=1&size=154835&status=done&style=none&taskId=uda52fb27-8f64-4773-b4d2-5c4b47bc303&width=1672)

- grafana

![image.png](https://cdn.nlark.com/yuque/0/2021/png/2308212/1631459124041-5c81bb64-2b91-469e-a355-5e9fabae5a68.png#clientId=u3ab05ffe-c464-4&from=paste&height=534&id=ua728ccd8&margin=%5Bobject%20Object%5D&name=image.png&originHeight=534&originWidth=1669&originalType=binary&ratio=1&size=183681&status=done&style=none&taskId=uec3f39e6-8bbb-4f21-89f7-416d65b3ee2&width=1669)
## 四、thanos部署（可选组件）
### 1. 部署Ruler
推荐尽量使用 Prometheus 自带的 rule 功能 (生成新指标+告警)，这个功能需要一些 Prometheus 最新数据，直接使用 Prometheus 本机 rule 功能和数据，性能开销相比 Thanos Ruler 这种分布式方案小得多，并且几乎不会出错。
如果某些有关联的数据分散在多个不同 Prometheus 上，比如对某个大规模服务采集做了分片，每个 Prometheus 仅采集一部分 endpoint 的数据，对于 record 类型的 rule (生成的新指标)，还是可以使用 Prometheus 自带的 rule 功能，在查询时再聚合一下就可以(如果可以接受的话)；对于 alert 类型的 rule，就需要用 Thanos Ruler 来做了，因为有关联的数据分散在多个 Prometheus 上，用单机数据去做 alert 计算是不准确的，就可能会造成误告警或不告警。

- 创建pv资源，用于ruler存储
```yaml
[root@tiaoban other]# cat thanos-ruler-pv.yaml 
apiVersion: v1
kind: PersistentVolume
metadata:
  name: thanos-ruler-pv1
spec:
  capacity:
    storage: 5Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: local-storage
  local:
    path: /data/thanos-ruler
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - k8s-work2
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: thanos-ruler-pv2
spec:
  capacity:
    storage: 5Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: local-storage
  local:
    path: /data/thanos-ruler
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - k8s-work3
[root@tiaoban other]# kubectl apply -f thanos-ruler-pv.yaml 
persistentvolume/thanos-ruler-pv1 created
persistentvolume/thanos-ruler-pv2 created
[root@tiaoban other]# kubectl get pv
NAME                CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM                          STORAGECLASS    REASON   AGE
grafana-pv          5Gi        RWX            Delete           Bound       thanos/grafana-pvc             local-storage            9h
prometheus-pv1      10Gi       RWO            Delete           Bound       thanos/data-prometheus-0       local-storage            11h
prometheus-pv2      10Gi       RWO            Delete           Bound       thanos/data-prometheus-1       local-storage            11h
prometheus-pv3      10Gi       RWO            Delete           Bound       thanos/data-prometheus-2       local-storage            11h
thanos-compact-pv   10Gi       RWO            Delete           Bound       thanos/data-thanos-compact-0   local-storage            10h
thanos-ruler-pv1    5Gi        RWO            Delete           Available                                  local-storage            36s
thanos-ruler-pv2    5Gi        RWO            Delete           Available                                  local-storage            36s
thanos-store-pv1    5Gi        RWO            Delete           Bound       thanos/data-thanos-store-0     local-storage            10h
thanos-store-pv2    5Gi        RWO            Delete           Bound       thanos/data-thanos-store-1     local-storage            10h
```

- 创建ruler配置文件
```yaml
[root@tiaoban other]# cat thanos-ruler-config.yaml 
apiVersion: v1
kind: ConfigMap
metadata:
  name: thanos-rules
  labels:
    name: thanos-rules
  namespace: thanos
data:
  record.rules.yaml: |-
    groups:
    - name: k8s.rules
      rules:
      - expr: |
          sum(rate(container_cpu_usage_seconds_total{job="cadvisor", image!="", container!=""}[5m])) by (namespace)
        record: namespace:container_cpu_usage_seconds_total:sum_rate
      - expr: |
          sum(container_memory_usage_bytes{job="cadvisor", image!="", container!=""}) by (namespace)
        record: namespace:container_memory_usage_bytes:sum
      - expr: |
          sum by (namespace, pod, container) (
            rate(container_cpu_usage_seconds_total{job="cadvisor", image!="", container!=""}[5m])
          )
        record: namespace_pod_container:container_cpu_usage_seconds_total:sum_rate
[root@tiaoban other]# kubectl apply -f thanos-ruler-config.yaml 
configmap/thanos-rules created
[root@tiaoban other]# kubectl get configmaps -n thanos 
NAME                     DATA   AGE
alertmanager-conf        1      10h
prometheus-config-tmpl   1      12h
prometheus-rules         1      12h
thanos-rules             1      3m46s
thanos-storage-config    1      10h
```

- 部署ruler
> - Ruler 是有状态服务，使用 Statefulset 部署，挂载磁盘以便存储根据 rule 配置计算出的新数据。
> - 同样创建 headless service，用于 Query 对 Ruler 进行服务发现。
> - 部署两个副本，且使用 --label=rule_replica= 给所有数据添加 rule_replica 的 label (与 Query 配置的 replica_label 相呼应)，用于实现 Ruler 高可用。同时指定 --alert.label-drop 为 rule_replica，在触发告警发送通知给 AlertManager 时，去掉这个 label，以便让 AlertManager 自动去重 (避免重复告警)。
> - 使用 --query 指定 Query 地址，这里还是用 DNS SRV 来做服务发现，但效果跟配 dns+thanos-query.thanos.svc.cluster.local:9090 是一样的，最终都是通过 Query 的 ClusterIP (VIP) 访问，因为它是无状态的，可以直接由 K8S 来给我们做负载均衡。
> - Ruler 也需要对象存储的配置，用于上传计算出的数据到对象存储，所以要挂载对象存储的配置文件。
> - --rule-file 指定挂载的 rule 配置，Ruler 根据配置来生成数据和触发告警。

```yaml
[root@tiaoban other]# cat thanos-ruler.yaml 
apiVersion: v1
kind: Service
metadata:
  labels:
    app.kubernetes.io/name: thanos-rule
  name: thanos-rule
  namespace: thanos
spec:
  clusterIP: None
  ports:
  - name: grpc
    port: 10901
    targetPort: grpc
  - name: http
    port: 10902
    targetPort: http
  selector:
    app.kubernetes.io/name: thanos-rule
---

apiVersion: apps/v1
kind: StatefulSet
metadata:
  labels:
    app.kubernetes.io/name: thanos-rule
  name: thanos-rule
  namespace: thanos
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: thanos-rule
  serviceName: thanos-rule
  podManagementPolicy: Parallel
  template:
    metadata:
      labels:
        app.kubernetes.io/name: thanos-rule
    spec:
      containers:
      - args:
        - rule
        - --grpc-address=0.0.0.0:10901
        - --http-address=0.0.0.0:10902
        - --rule-file=/etc/thanos/rules/*rules.yaml
        - --data-dir=/var/thanos/rule
        - --label=rule_replica="$(NAME)"
        - --alert.label-drop="rule_replica"
        - --query=dnssrv+_http._tcp.thanos-query.thanos.svc.cluster.local
        env:
        - name: NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        image: thanosio/thanos:v0.23.0-rc.0
        imagePullPolicy: IfNotPresent
        resources:
          limits:
            memory: "2048Mi"
            cpu: "500m" 
          requests:
            memory: "128Mi"
            cpu: "100m" 
        livenessProbe:
          failureThreshold: 24
          httpGet:
            path: /-/healthy
            port: 10902
            scheme: HTTP
          periodSeconds: 5
        name: thanos-rule
        ports:
        - containerPort: 10901
          name: grpc
        - containerPort: 10902
          name: http
        readinessProbe:
          failureThreshold: 18
          httpGet:
            path: /-/ready
            port: 10902
            scheme: HTTP
          initialDelaySeconds: 10
          periodSeconds: 5
        terminationMessagePolicy: FallbackToLogsOnError
        volumeMounts:
        - mountPath: /var/thanos/rule
          name: data
          readOnly: false
        - name: thanos-rules
          mountPath: /etc/thanos/rules
      volumes:
      - name: thanos-rules
        configMap:
          name: thanos-rules
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes:
      - ReadWriteOnce
      storageClassName: local-storage
      resources:
        requests:
          storage: 5Gi
[root@tiaoban other]# kubectl apply -f thanos-ruler.yaml 
service/thanos-rule created
statefulset.apps/thanos-rule created
[root@tiaoban other]# kubectl get pod -n thanos -o wide -l app.kubernetes.io/name=thanos-rule
NAME            READY   STATUS    RESTARTS   AGE     IP             NODE        NOMINATED NODE   READINESS GATES
thanos-rule-0   1/1     Running   0          6m53s   10.244.1.106   k8s-work2   <none>           <none>
thanos-rule-1   1/1     Running   0          6m53s   10.244.2.100   k8s-work3   <none>           <none>
```
### 2. 部署Receiver
Receiver 是让 Prometheus 通过 remote wirte API 将数据 push 到 Receiver 集中存储 。
如果你的 Query 跟 Sidecar 离的比较远，比如 Sidecar 分布在多个数据中心，Query 向所有 Sidecar 查数据，速度会很慢，这种情况可以考虑用 Receiver，将数据集中吐到 Receiver，然后 Receiver 与 Query 部署在一起，Query 直接向 Receiver 查最新数据，提升查询性能。
Sidecar和Receiver功能相似，都是获取prometheus的数据给thanos。区别在于sidecar采用边车模式读取prometheus数据，而receiver相当于存储服务，prometheus数据。当使用了Receiver 来统一接收 Prometheus 的数据时，Prometheus 不需要部署Sidecar

- 创建pv资源，用于receiver存储
```yaml
[root@tiaoban other]# cat thanos-receiver-pv.yaml 
apiVersion: v1
kind: PersistentVolume
metadata:
  name: thanos-receiver-pv1
spec:
  capacity:
    storage: 10Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: local-storage
  local:
    path: /data/thanos-receiver
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - k8s-work1
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: thanos-receiver-pv2
spec:
  capacity:
    storage: 10Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: local-storage
  local:
    path: /data/thanos-receiver
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - k8s-work2
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: thanos-receiver-pv3
spec:
  capacity:
    storage: 10Gi
  volumeMode: Filesystem
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Delete
  storageClassName: local-storage
  local:
    path: /data/thanos-receiver
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - k8s-work3
[root@tiaoban other]# kubectl apply -f thanos-receiver-pv.yaml 
persistentvolume/thanos-receiver-pv1 created
persistentvolume/thanos-receiver-pv2 created
persistentvolume/thanos-receiver-pv3 created
[root@tiaoban other]# kubectl get pv
NAME                  CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM                          STORAGECLASS    REASON   AGE
grafana-pv            5Gi        RWX            Delete           Bound       thanos/grafana-pvc             local-storage            10h
prometheus-pv1        10Gi       RWO            Delete           Bound       thanos/data-prometheus-0       local-storage            12h
prometheus-pv2        10Gi       RWO            Delete           Bound       thanos/data-prometheus-1       local-storage            12h
prometheus-pv3        10Gi       RWO            Delete           Bound       thanos/data-prometheus-2       local-storage            12h
thanos-compact-pv     10Gi       RWO            Delete           Bound       thanos/data-thanos-compact-0   local-storage            11h
thanos-receiver-pv1   10Gi       RWO            Delete           Available                                  local-storage            4s
thanos-receiver-pv2   10Gi       RWO            Delete           Available                                  local-storage            3s
thanos-receiver-pv3   10Gi       RWO            Delete           Available                                  local-storage            3s
thanos-ruler-pv1      5Gi        RWO            Delete           Bound       thanos/data-thanos-rule-0      local-storage            45m
thanos-ruler-pv2      5Gi        RWO            Delete           Bound       thanos/data-thanos-rule-1      local-storage            45m
thanos-store-pv1      5Gi        RWO            Delete           Bound       thanos/data-thanos-store-0     local-storage            11h
thanos-store-pv2      5Gi        RWO            Delete           Bound       thanos/data-thanos-store-1     local-storage            11h
```

- 创建receiver配置文件
```yaml
[root@tiaoban other]# cat thanos-receiver-config.yaml 
apiVersion: v1
kind: ConfigMap
metadata:
  name: thanos-receive-hashrings
  namespace: thanos
data:
  thanos-receive-hashrings.json: |
    [
      {
        "hashring": "soft-tenants",
        "endpoints":
        [
          "thanos-receive-0.thanos-receive.kube-system.svc.cluster.local:10901",
          "thanos-receive-1.thanos-receive.kube-system.svc.cluster.local:10901",
          "thanos-receive-2.thanos-receive.kube-system.svc.cluster.local:10901"
        ]
      }
    ]
[root@tiaoban other]# kubectl apply -f thanos-receiver-config.yaml 
configmap/thanos-receive-hashrings created
[root@tiaoban other]# kubectl get configmaps -n thanos 
NAME                       DATA   AGE
alertmanager-conf          1      11h
prometheus-config-tmpl     1      12h
prometheus-rules           1      12h
thanos-receive-hashrings   1      13s
thanos-rules               1      38m
thanos-storage-config      1      11h
```

- 部署receiver
> - 部署 3 个副本， 配置 hashring， --label=receive_replica 为数据添加 receive_replica 这个 label (Query 的 --query.replica-label 也要加上这个) 来实现 Receiver 的高可用。
> - Query 要指定 Receiver 后端地址: --store=dnssrv+_grpc._tcp.thanos-receive.thanos.svc.cluster.local
> - request, limit 根据自身规模情况自行做适当调整。
> - --tsdb.retention 根据自身需求调整最新数据的保留时间。

```yaml
[root@tiaoban other]# cat thanos-receiver.yaml 
apiVersion: v1
kind: Service
metadata:
  name: thanos-receive
  namespace: thanos
  labels:
    kubernetes.io/name: thanos-receive
spec:
  ports:
  - name: http
    port: 10902
    protocol: TCP
    targetPort: 10902
  - name: remote-write
    port: 19291
    protocol: TCP
    targetPort: 19291
  - name: grpc
    port: 10901
    protocol: TCP
    targetPort: 10901
  selector:
    kubernetes.io/name: thanos-receive
  clusterIP: None
---

apiVersion: apps/v1
kind: StatefulSet
metadata:
  labels:
    kubernetes.io/name: thanos-receive
  name: thanos-receive
  namespace: thanos
spec:
  replicas: 3
  selector:
    matchLabels:
      kubernetes.io/name: thanos-receive
  serviceName: thanos-receive
  template:
    metadata:
      labels:
        kubernetes.io/name: thanos-receive
    spec:
      containers:
      - args:
        - receive
        - --grpc-address=0.0.0.0:10901
        - --http-address=0.0.0.0:10902
        - --remote-write.address=0.0.0.0:19291
        - --tsdb.path=/var/thanos/receive
        - --tsdb.retention=12h
        - --label=receive_replica="$(NAME)"
        - --label=receive="true"
        - --receive.hashrings-file=/etc/thanos/thanos-receive-hashrings.json
        - --receive.local-endpoint=$(NAME).thanos-receive.thanos.svc.cluster.local:10901
        env:
        - name: NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        image: thanosio/thanos:v0.23.0-rc.0
        imagePullPolicy: IfNotPresent
        resources:
          limits:
            memory: 2Gi
            cpu: "1"
          requests:
            memory: "128Mi"
            cpu: "100m" 
        livenessProbe:
          failureThreshold: 4
          httpGet:
            path: /-/healthy
            port: 10902
            scheme: HTTP
          periodSeconds: 30
        name: thanos-receive
        ports:
        - containerPort: 10901
          name: grpc
        - containerPort: 10902
          name: http
        - containerPort: 19291
          name: remote-write
        readinessProbe:
          httpGet:
            path: /-/ready
            port: 10902
            scheme: HTTP
          initialDelaySeconds: 10
          periodSeconds: 30
        volumeMounts:
        - mountPath: /var/thanos/receive
          name: data
          readOnly: false
        - mountPath: /etc/thanos/thanos-receive-hashrings.json
          name: thanos-receive-hashrings
          subPath: thanos-receive-hashrings.json
      terminationGracePeriodSeconds: 120
      volumes:
      - configMap:
          defaultMode: 420
          name: thanos-receive-hashrings
        name: thanos-receive-hashrings
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes:
      - ReadWriteOnce
      storageClassName: local-storage
      resources:
        requests:
          storage: 10Gi
[root@tiaoban other]# kubectl apply -f thanos-receiver.yaml 
service/thanos-receive created
statefulset.apps/thanos-receive created
[root@tiaoban other]# kubectl get pod -n thanos -o wide -l kubernetes.io/name=thanos-receive
NAME               READY   STATUS    RESTARTS   AGE   IP             NODE        NOMINATED NODE   READINESS GATES
thanos-receive-0   1/1     Running   0          76s   10.244.1.107   k8s-work2   <none>           <none>
thanos-receive-1   1/1     Running   0          49s   10.244.3.134   k8s-work1   <none>           <none>
thanos-receive-2   1/1     Running   0          33s   10.244.2.101   k8s-work3   <none>           <none>
```

- 部署完receiver后，sidecar就可以停用了。先修改Prometheus 配置文件里加下 remote_write，让 Prometheus 将数据 push 给 Receiver:
```yaml
# 删除先前的prometheus配置文件
[root@tiaoban other]# kubectl delete configmaps -n thanos prometheus-config-tmpl 
configmap "prometheus-config-tmpl" deleted
[root@tiaoban other]# cat prometheus-receiver-config.yaml 
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: thanos
data:
  prometheus.yaml: |-
    global:
      scrape_interval: 5s
      evaluation_interval: 5s
      external_labels:
        cluster: prometheus-ha
        prometheus_replica: $(POD_NAME)
    rule_files:
    - /etc/prometheus/rules/*.yaml
    remote_write: 
    - url: http://thanos-receive.thanos.svc.cluster.local:19291/api/v1/receive
    scrape_configs:
    - job_name: node_exporter
      kubernetes_sd_configs:
      - role: node
      relabel_configs:
      - source_labels: [__address__]
        regex: '(.*):10250'
        replacement: '${1}:9100'
        target_label: __address__
        action: replace
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
    - job_name: kubelet
      metrics_path: /metrics/cadvisor
      scrape_interval: 10s
      scrape_timeout: 10s
      scheme: https
      tls_config:
        insecure_skip_verify: true
      bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      kubernetes_sd_configs:
      - role: node
      relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
    - job_name: 'kube-state-metrics'
      kubernetes_sd_configs:
      - role: pod
      relabel_configs:
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: pod
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
      - source_labels: [__meta_kubernetes_pod_ip]
        regex: (.+)
        target_label: __address__
        replacement: ${1}:8080
      - source_labels:  ["__meta_kubernetes_pod_container_name"]
        regex: "^kube-state-metrics.*"
        action: keep
    - job_name: prometheus
      honor_labels: false
      kubernetes_sd_configs:
      - role: endpoints
      scrape_interval: 30s
      relabel_configs:
      - source_labels:
          - __meta_kubernetes_service_label_name
        regex: k8s-prometheus
        action: keep
      - source_labels: [__meta_kubernetes_pod_ip]
        regex: (.+)
        target_label: __address__
        replacement: ${1}:9090
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-rules
  labels:
    name: prometheus-rules
  namespace: thanos
data:
  alert-rules.yaml: |-
    groups:
    - name: k8s.rules
      rules:
      - expr: |
          sum(rate(container_cpu_usage_seconds_total{job="cadvisor", image!="", container!=""}[5m])) by (namespace)
        record: namespace:container_cpu_usage_seconds_total:sum_rate
      - expr: |
          sum(container_memory_usage_bytes{job="cadvisor", image!="", container!=""}) by (namespace)
        record: namespace:container_memory_usage_bytes:sum
      - expr: |
          sum by (namespace, pod, container) (
            rate(container_cpu_usage_seconds_total{job="cadvisor", image!="", container!=""}[5m])
          )
        record: namespace_pod_container:container_cpu_usage_seconds_total:sum_rate           
[root@tiaoban other]# kubectl apply -f prometheus-receiver-config.yaml 
configmap/prometheus-config-tmpl created
configmap/prometheus-rules unchanged
[root@tiaoban other]# kubectl get configmaps -n thanos 
NAME                       DATA   AGE
alertmanager-conf          1      11h
prometheus-config          1      2m47s
prometheus-rules           1      13h
thanos-receive-hashrings   1      36m
thanos-rules               1      74m
thanos-storage-config      1      12h
```

- 修改prometheus部署，删除sidecar相关部分
```yaml
# 删除先前部署的prometheus
[root@tiaoban other]# kubectl delete statefulsets.apps -n thanos prometheus 
statefulset.apps "prometheus" deleted
[root@tiaoban other]# cat prometheus-receiver.yaml 
kind: Service
apiVersion: v1
metadata:
  name: prometheus-headless
  namespace: thanos
  labels:
    app.kubernetes.io/name: prometheus
    name: k8s-prometheus
spec:
  type: ClusterIP
  clusterIP: None
  selector:
    app.kubernetes.io/name: prometheus
  ports:
  - name: web
    protocol: TCP
    port: 9090
    targetPort: web
  - name: grpc
    port: 10901
    targetPort: grpc
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: prometheus
  namespace: thanos
  labels:
    app.kubernetes.io/name: thanos-query
spec:
  serviceName: prometheus-headless
  podManagementPolicy: Parallel
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: prometheus
  template:
    metadata:
      labels:
        app.kubernetes.io/name: prometheus
    spec:
      serviceAccountName: prometheus
      securityContext:
        fsGroup: 2000
        runAsNonRoot: true
        runAsUser: 1000
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
              - key: app.kubernetes.io/name
                operator: In
                values:
                - prometheus
            topologyKey: kubernetes.io/hostname
      containers:
      - name: prometheus
        image: prom/prometheus:v2.30.0
        imagePullPolicy: IfNotPresent
        resources:
          limits:
            memory: "2048Mi"
            cpu: "500m" 
          requests:
            memory: "128Mi"
            cpu: "100m" 
        args:
        - --config.file=/etc/prometheus/config/prometheus.yaml
        - --storage.tsdb.path=/prometheus
        - --storage.tsdb.retention.time=10d
        - --web.route-prefix=/
        - --web.enable-lifecycle
        - --storage.tsdb.no-lockfile
        - --storage.tsdb.min-block-duration=2h
        - --storage.tsdb.max-block-duration=2h
        - --log.level=debug
        ports:
        - containerPort: 9090
          name: web
          protocol: TCP
        livenessProbe:
          failureThreshold: 6
          httpGet:
            path: /-/healthy
            port: web
            scheme: HTTP
          periodSeconds: 5
          successThreshold: 1
          timeoutSeconds: 3
        readinessProbe:
          failureThreshold: 120
          httpGet:
            path: /-/ready
            port: web
            scheme: HTTP
          periodSeconds: 5
          successThreshold: 1
          timeoutSeconds: 3
        volumeMounts:
        - mountPath: /etc/prometheus/config
          name: prometheus-config
          readOnly: true
        - mountPath: /prometheus
          name: data
        - mountPath: /etc/prometheus/rules
          name: prometheus-rules
      volumes:
      - name: prometheus-config
        configMap:
          name: prometheus-config
      - name: prometheus-rules
        configMap:
          name: prometheus-rules
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes:
      - ReadWriteOnce
      storageClassName: local-storage
      resources:
        requests:
          storage: 5Gi
[root@tiaoban other]# kubectl apply -f prometheus-receiver.yaml 
service/prometheus-headless unchanged
statefulset.apps/prometheus created
[root@tiaoban other]# kubectl get pod -n thanos -o wide -l app.kubernetes.io/name=prometheus
NAME           READY   STATUS    RESTARTS   AGE     IP             NODE        NOMINATED NODE   READINESS GATES
prometheus-0   1/1     Running   0          2m13s   10.244.3.136   k8s-work1   <none>           <none>
prometheus-1   1/1     Running   0          119s    10.244.1.109   k8s-work2   <none>           <none>
prometheus-2   1/1     Running   0          110s    10.244.2.104   k8s-work3   <none>           <none>
```
## 五、thanos使用
### 1. Thanos Querier
使用thanos querier调试PromQL和prometheus上调试别无二致，最主要的一点是记得选择“Use Deldupication“ 删除重复数据。
![image.png](https://cdn.nlark.com/yuque/0/2021/png/2308212/1631489829181-3ddb8c2f-6424-4f01-8801-847786f8f2b2.png#clientId=uc5388f60-2179-4&from=paste&height=461&id=u0729e53d&margin=%5Bobject%20Object%5D&name=image.png&originHeight=461&originWidth=1663&originalType=binary&ratio=1&size=171853&status=done&style=none&taskId=uf5b37116-23f3-4497-a039-f6c6a1f045c&width=1663)
### 2. Grafana

- grafana创建数据源时，由于thanos-query和grafana同属一个namespace，所以url地址填写thanos-query:9090即可。如果位于不同namespace，url地址填写为：http://(servicename).(namespace).svc.cluster.local:9090

![image.png](https://cdn.nlark.com/yuque/0/2021/png/2308212/1631448424210-7c5915bc-3766-4b9d-af49-377d638eb78c.png#clientId=u6b44cf91-efd3-4&from=paste&height=570&id=ue4a83366&margin=%5Bobject%20Object%5D&name=image.png&originHeight=570&originWidth=694&originalType=binary&ratio=1&size=85277&status=done&style=none&taskId=u7f9b7f18-c64b-4de8-adf9-740446d3e42&width=694)

- 然后从grafana官网dashboard导入对应的dashboard即可

![image.png](https://cdn.nlark.com/yuque/0/2021/png/2308212/1631412720215-09d8e12a-7a4d-4ba7-80e9-50b4be7b0dc3.png#clientId=u7efebe2d-a729-4&from=paste&height=880&id=ude977fdc&margin=%5Bobject%20Object%5D&name=image.png&originHeight=880&originWidth=1673&originalType=binary&ratio=1&size=408628&status=done&style=none&taskId=ud006b51b-6882-43ad-974e-d44fda29a13&width=1673)
![image.png](https://cdn.nlark.com/yuque/0/2021/png/2308212/1631415255360-e55aaa33-0745-4f72-ac0a-9c17cb7a1251.png#clientId=u7efebe2d-a729-4&from=paste&height=879&id=u62118d1c&margin=%5Bobject%20Object%5D&name=image.png&originHeight=879&originWidth=1673&originalType=binary&ratio=1&size=311846&status=done&style=none&taskId=u7b007e31-9c43-46c1-8597-cc542d87a5d&width=1673)
![image.png](https://cdn.nlark.com/yuque/0/2021/png/2308212/1631431649613-fc1f1bc8-f272-4973-be88-633a36bfa63d.png#clientId=u2fd58f5d-02d9-4&from=paste&height=806&id=ub56af2b2&margin=%5Bobject%20Object%5D&name=image.png&originHeight=806&originWidth=1673&originalType=binary&ratio=1&size=283429&status=done&style=none&taskId=uae4ad054-3077-4051-8ce7-f8d791a6822&width=1673)
> 参考链接
> - thanos部署
> 
[https://k8s.imroc.io/monitoring/build-cloud-native-large-scale-distributed-monitoring-system/thanos-deploy/](https://k8s.imroc.io/monitoring/build-cloud-native-large-scale-distributed-monitoring-system/thanos-deploy/)
> [https://www.kubernetes.org.cn/8308.html](https://www.kubernetes.org.cn/8308.html)

> - sidecar更多配置参见
> 
[https://github.com/thanos-io/thanos/blob/main/docs/components/sidecar.md](https://github.com/thanos-io/thanos/blob/main/docs/components/sidecar.md)
> - query更多配置项参见
> 
[https://github.com/thanos-io/thanos/blob/main/docs/components/query.md](https://github.com/thanos-io/thanos/blob/main/docs/components/query.md)
> - store更多配置项参见
> 
[https://github.com/thanos-io/thanos/blob/main/docs/components/store.md](https://github.com/thanos-io/thanos/blob/main/docs/components/store.md)
> - compact更多配置项参见
> 
[https://github.com/thanos-io/thanos/blob/main/docs/components/compact.md](https://github.com/thanos-io/thanos/blob/main/docs/components/compact.md)
> - rule更多配置项参见
> 
[https://thanos.io/components/rule.md/#configuring-rules](https://thanos.io/components/rule.md/#configuring-rules)
> ​

> - k8s服务自动发现
> 
[https://juejin.cn/post/6844903908251451406](https://juejin.cn/post/6844903908251451406)
> [https://prometheus.io/docs/prometheus/latest/configuration/configuration/#kubernetes_sd_config](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#kubernetes_sd_config)
> [https://github.com/prometheus/prometheus/blob/release-2.12/documentation/examples/prometheus-kubernetes.yml](https://github.com/prometheus/prometheus/blob/release-2.12/documentation/examples/prometheus-kubernetes.yml)
> ​

> - prometheus痛点分析
> 
[https://cloud.tencent.com/developer/article/1605915?from=10680](https://cloud.tencent.com/developer/article/1605915?from=10680)

​

​

​

​

[
](https://cloud.tencent.com/developer/article/1605915?from=10680)
​

