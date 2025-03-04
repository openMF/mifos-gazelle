#!/bin/bash

# Get the memory usage of all pods in all namespaces
kubectl top pods --all-namespaces --sort-by=memory | tail -n +3 | awk '{print $1, $3}'

# Sort the output by memory usage, descending
kubectl top pods --all-namespaces --sort-by=memory | tail -n +3 | awk '{print $1, $3}' | sort -nr -k 2