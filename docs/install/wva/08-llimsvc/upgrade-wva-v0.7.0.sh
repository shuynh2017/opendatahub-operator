#!/bin/bash
set -euo pipefail

info() { echo "==> $*"; }

# Scale down the RHODS operator to prevent it from reverting changes
info "Scaling down rhods-operator to 0 replicas..."
kubectl scale deployment rhods-operator -n redhat-ods-operator --replicas=0

info "Waiting for rhods-operator to scale down..."
kubectl wait --for=delete pod -l app.kubernetes.io/name=rhods-operator -n redhat-ods-operator --timeout=60s || true

# Upgrade workload-variant-autoscaler-controller-manager to v0.7.0
info "Upgrading workload-variant-autoscaler-controller-manager to v0.7.0..."
kubectl set image deployment/workload-variant-autoscaler-controller-manager \
    -n redhat-ods-applications \
    manager=ghcr.io/llm-d/llm-d-workload-variant-autoscaler:v0.7.0

info "Waiting for rollout to complete..."
kubectl rollout status deployment/workload-variant-autoscaler-controller-manager \
    -n redhat-ods-applications \
    --timeout=180s

info "Upgrade complete!"
info "Current WVA image:"
kubectl get deployment workload-variant-autoscaler-controller-manager \
    -n redhat-ods-applications \
    -o jsonpath='{.spec.template.spec.containers[0].image}'
echo ""

info "RHODS operator status:"
kubectl get deployment rhods-operator -n redhat-ods-operator -o jsonpath='{.spec.replicas}' | xargs -I {} echo "Replicas: {}"
