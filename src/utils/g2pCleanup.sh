#!/usr/bin/env bash 

kubectl get clusterroles -n paymenthub | grep '^ph-ee-' | awk '{print $1}' | xargs kubectl delete clusterrole
kubectl delete -n paymenthub clusterrole message-gateway-c-role 

kubectl delete -n paymenthub clusterrolebinding message-gateway-c-role-binding 
kubectl get clusterrolebindings -n paymenthub | grep '^ph-ee-' | awk '{print $1}' | xargs kubectl delete clusterrolebinding

k delete pvc --all -n paymenthub