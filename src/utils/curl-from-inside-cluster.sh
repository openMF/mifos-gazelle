#!/bin/bash

POD_NAME=$1
NAMESPACE=$2
URL=$3

if [[ -z "$POD_NAME" || -z "$NAMESPACE" || -z "$URL" ]]; then
  echo "Usage: $0 <pod_name> <namespace> <url>"
  exit 1
fi

# Pull and run the curl container from Docker Hub inside the pod
#kubectl run curl-pod --rm -i --tty --image=curlimages/curl:latest --restart=Never -n "$NAMESPACE" -- curl -s "$URL"
kubectl run curl-pod --rm -i --tty --image=curlimages/curl:latest --restart=Never -n "$NAMESPACE" -- sleep 3600
