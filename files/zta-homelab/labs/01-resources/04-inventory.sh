#!/usr/bin/env bash
set -euo pipefail
CTX=docker-desktop
kubectl --context $CTX get deploy,statefulset,daemonset,svc,pvc -A \
  -l zta.resource=true \
  -o custom-columns='\
NAMESPACE:.metadata.namespace,\
KIND:.kind,\
NAME:.metadata.name,\
DATA-CLASS:.metadata.labels.zta\.data-class,\
TIER:.metadata.labels.zta\.tier-role,\
OWNER:.metadata.labels.zta\.owner,\
EXPOSURE:.metadata.labels.zta\.exposure'

