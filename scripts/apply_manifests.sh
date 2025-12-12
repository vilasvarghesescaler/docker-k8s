#!/bin/bash
kubectl run test --image=nginx
kubectl apply -f deploy-tomcat.yaml
