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
    argocd login $ARGOCD_SERVER --username $ARGOCD_USER --password $ARGOCD_PASSWORD
  else
    echo "[INFO] ArgoCD authentication is valid!"
  fi
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

# Identify old color
OLD_COLOR=$(if [ "$TARGET_COLOR" == "blue" ]; then echo "green"; else echo "blue"; fi)

TARGET_STS="nginx-app-$TARGET_COLOR"
OLD_STS="nginx-app-$OLD_COLOR"

echo "[INFO] Scaling up StatefulSet $TARGET_STS to $NEW_REPLICAS replicas..."
kubectl scale statefulset/$TARGET_STS -n $NAMESPACE --replicas=$NEW_REPLICAS || exit 3

echo "[INFO] Waiting for $TARGET_STS to be ready..."
kubectl rollout status statefulset/$TARGET_STS -n $NAMESPACE --timeout=${WAIT_TIMEOUT}s || exit 4

echo "[INFO] Patching service selector to switch traffic to $TARGET_COLOR..."
kubectl patch service $FRONT_SERVICE -n $NAMESPACE --type='json' -p="[{\"op\": \"replace\", \"path\": \"/spec/selector/color\", \"value\": \"$TARGET_COLOR\"}]" || exit 5

echo "[SUCCESS] Traffic switched to $TARGET_COLOR!"

# Authenticate to ArgoCD before updating
check_argocd_auth

# Update ArgoCD application path dynamically
echo "[INFO] Updating ArgoCD application to $TARGET_COLOR overlay..."
kubectl patch application $ARGOCD_APP -n $ARGO_NAMESPACE --type='json' -p="[{\"op\": \"replace\", \"path\": \"/spec/source/path\", \"value\": \"overlays/$TARGET_COLOR\"}]" || exit 6

echo "[INFO] Syncing ArgoCD application..."
argocd app sync $ARGOCD_APP || exit 7

echo "[INFO] Scaling down old StatefulSet $OLD_STS to 1 replica..."
kubectl scale statefulset/$OLD_STS -n $NAMESPACE --replicas=1 || exit 8

echo "[SUCCESS] Blue-Green deployment switch to $TARGET_COLOR completed successfully!"
exit 0

