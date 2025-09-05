#!/bin/bash

set -e

# Configuration
NAMESPACE=nginx
FRONT_SERVICE=nginx-service
ARGOCD_APP="nginx-bluegreen"
ARGO_NAMESPACE="argocd"
WAIT_TIMEOUT=300
NEW_REPLICAS=2
ARGOCD_SERVER="<ARGOCD_SERVER>"  # Replace with your ArgoCD server address
ARGOCD_USER="admin"
ARGOCD_PASSWORD="<PASSWORD>"  # Replace with your ArgoCD password

# Function to check ArgoCD authentication
check_argocd_auth() {
  echo "[INFO] Checking ArgoCD authentication..."
  if ! argocd app list >/dev/null 2>&1; then
    echo "[INFO] Logging into ArgoCD..."
    argocd login $ARGOCD_SERVER --username $ARGOCD_USER --password $ARGOCD_PASSWORD --insecure
  else
    echo "[INFO] ArgoCD authentication is valid!"
  fi
}

# Function to check readiness of all pods in a StatefulSet
wait_for_sts_ready() {
  local sts_name=$1
  local expected_replicas=$2
  echo "[INFO] Verifying all $expected_replicas pods in $sts_name are READY..."

  local ready=0
  local retries=60

  for ((i=1; i<=retries; i++)); do
    ready=$(kubectl get pods -n $NAMESPACE -l statefulset.kubernetes.io/pod-name -o json | \
      jq "[.items[] | select(.metadata.name | startswith(\"$sts_name\")) | select(.status.containerStatuses[0].ready == true)] | length")
    
    echo "[INFO] Ready Pods: $ready/$expected_replicas"
    if [[ "$ready" -eq "$expected_replicas" ]]; then
      echo "[INFO] All $sts_name pods are ready!"
      return 0
    fi

    sleep 5
  done

  echo "[ERROR] Pods in $sts_name not ready within timeout."
  exit 4
}

usage() {
  echo "Usage: $0 [blue|green]"
  exit 1
}

if [ $# -ne 1 ]; then
  usage
fi

TARGET_COLOR=$1
if [[ "$TARGET_COLOR" != "blue" && "$TARGET_COLOR" != "green" ]]; then
  echo "Error: argument must be 'blue' or 'green'"
  exit 2
fi

OLD_COLOR=$(if [ "$TARGET_COLOR" == "blue" ]; then echo "green"; else echo "blue"; fi)

TARGET_STS="nginx-app-$TARGET_COLOR"
OLD_STS="nginx-app-$OLD_COLOR"

echo "[STEP 1] Scaling up StatefulSet $TARGET_STS to $NEW_REPLICAS replicas..."
kubectl scale statefulset/$TARGET_STS -n $NAMESPACE --replicas=$NEW_REPLICAS || exit 3

echo "[STEP 2] Waiting for rollout to complete..."
kubectl rollout status statefulset/$TARGET_STS -n $NAMESPACE --timeout=${WAIT_TIMEOUT}s || exit 4

echo "[STEP 3] Ensuring all pods are ready before switching traffic..."
wait_for_sts_ready $TARGET_STS $NEW_REPLICAS

echo "[STEP 4] Patching service selector to switch traffic to $TARGET_COLOR..."
kubectl patch service $FRONT_SERVICE -n $NAMESPACE --type='json' \
  -p="[{\"op\": \"replace\", \"path\": \"/spec/selector/color\", \"value\": \"$TARGET_COLOR\"}]" || exit 5

echo "[STEP 5] Traffic successfully switched to $TARGET_COLOR!"

check_argocd_auth

echo "[STEP 6] Updating ArgoCD application path to overlays/$TARGET_COLOR..."
argocd app set $ARGOCD_APP --path overlays/$TARGET_COLOR || exit 6

echo "[STEP 7] Syncing ArgoCD application..."
argocd app sync $ARGOCD_APP || exit 7

echo "[STEP 8] Scaling down old StatefulSet $OLD_STS to 1 replica..."
kubectl scale statefulset/$OLD_STS -n $NAMESPACE --replicas=1 || exit 8

echo "[✅ SUCCESS] Blue-Green deployment switched to $TARGET_COLOR with near-zero downtime!"
exit 0

