#!/usr/bin/env bash
# report on the pods using the most memory (GBs) 

kubectl get pods --all-namespaces -o=jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].resources.requests.memory}{"\n"}{end}' | 
awk '
  function human_to_bytes(human) {
    if (human ~ /Gi/) {
      return human * 1024 * 1024 * 1024;
    } else if (human ~ /Mi/) {
      return human * 1024 * 1024;
    } else if (human ~ /Ki/) {
      return human * 1024;
    } else {
      return human;
    }
  }
  {
    bytes = human_to_bytes($2);
    gb = bytes / 1024 / 1024 / 1024;
    printf "%-40s %6.2f GB\n", $1, gb;
  }
' | sort -k2 -rn