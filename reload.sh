#!/bin/bash
kubectl apply -f /opt/k8s/thanos-minIO/prometheus-config.yaml
kubectl apply -f /opt/k8s/thanos-minIO/prometheus-rule.yaml
kubectl delete -f /opt/k8s/thanos-minIO/thanos-rule.yaml
kubectl apply -f /opt/k8s/thanos-minIO/thanos-rule.yaml
ip=`kubectl get pod -o wide -n thanos | grep prometheus | awk '{ print $6 }'`
for j in $ip
do
    echo $j;
    curl -s -X POST "$j":9090/-/reload
done
echo 'reload success'