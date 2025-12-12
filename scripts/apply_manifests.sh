#!/bin/bash
kubectl run test --image=nginx
kubectl apply -f /opt/k8s/deploy-tomcat.yaml
