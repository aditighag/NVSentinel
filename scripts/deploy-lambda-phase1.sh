#!/usr/bin/env bash
# Deploy the full NVSentinel Lambda stack to the Supernova cluster:
#   - nvsentinel parent chart (mongodb-store + platform-connector DaemonSet + fault-quarantine)
#   - csp-health-monitor + maintenance-notifier (images pulled from the Lambda
#     internal registry lambdapublic.jfrog.io/lambda-mk8s-images/*).
#
# Images are built and pushed by .github/workflows/release-lambda.yml. Trigger
# the workflow_dispatch with your desired tag first, then update the `image.tag`
# field in the corresponding values-lambda-*.yaml file before running this script.
#
# Usage: ./scripts/deploy-lambda-phase1.sh [--phase2|--prod] [--dry-run] [--completion]
#
#   (no flag)      Phase 1: mock file events SCHEDULED → tests quarantine path (node gets tainted).
#   --phase2       Phase 2: real Lambda staging API. Seed events first via simulate API, then deploy.
#                  Requires LAMBDA_STG_API_KEY env var to be set.
#   --prod         Production Lambda API (cloud.lambda.ai). Requires LAMBDA_PROD_API_KEY env var.
#   --completion   Phase 1 only. Mock events COMPLETED → tests de-quarantine path (taint removed).
#                  Only updates the mock-events ConfigMap and restarts.
#   --dry-run      Render manifests only, no deploy.
#
# Prerequisites:
#   - SSH key at ~/.ssh/aditig with access to CONTROL_PLANE
#   - Phase 2: LAMBDA_STG_API_KEY env var must be set
#   - Prod:    LAMBDA_PROD_API_KEY env var must be set

set -euo pipefail

CONTROL_PLANE="ubuntu@10.252.9.160"
WORKER_NODE="static-m4wh5-pfg62"

SSH_KEY="$HOME/.ssh/aditig"
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no"
REMOTE_DIR="/tmp/nvsentinel-deploy"
NAMESPACE="nvsentinel"
RELEASE_NAME="csp-health-monitor"
NVSENTINEL_RELEASE="nvsentinel"
CHART_DIR="distros/kubernetes/nvsentinel/charts/csp-health-monitor"
NVSENTINEL_CHART_DIR="distros/kubernetes/nvsentinel"
NVSENTINEL_VALUES_FILE="${NVSENTINEL_CHART_DIR}/values-lambda-fullstack.yaml"

# Parse flags
DRY_RUN=""
COMPLETION=""
PHASE2=""
PROD=""
for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY_RUN="--dry-run" ;;
    --completion) COMPLETION="--completion" ;;
    --phase2)     PHASE2="--phase2" ;;
    --prod)       PROD="--prod" ;;
  esac
done

if [[ -n "${PHASE2}" && -n "${PROD}" ]]; then
  echo "Error: --phase2 and --prod are mutually exclusive."
  exit 1
fi

if [[ -n "${COMPLETION}" && ( -n "${PHASE2}" || -n "${PROD}" ) ]]; then
  echo "Error: --completion is only supported with phase 1 (no --phase2 or --prod)."
  echo "       To test de-quarantine in phase2/prod, update the event status via the API."
  exit 1
fi

# Set values file based on phase/mode
if [[ -n "${PROD}" ]]; then
  VALUES_FILE="${CHART_DIR}/values-lambda-prod.yaml"
  echo "==> Prod: real Lambda prod API (cloud.lambda.ai) on ${WORKER_NODE}"
elif [[ -n "${PHASE2}" ]]; then
  VALUES_FILE="${CHART_DIR}/values-lambda-phase2.yaml"
  echo "==> Phase 2: real Lambda staging API on ${WORKER_NODE}"
elif [[ -n "${COMPLETION}" ]]; then
  VALUES_FILE="${CHART_DIR}/values-lambda-phase1-completion.yaml"
  echo "==> Phase 1 completion mode: mock events COMPLETED (de-quarantine path)"
else
  VALUES_FILE="${CHART_DIR}/values-lambda-phase1.yaml"
  echo "==> Phase 1 quarantine mode: mock events SCHEDULED (quarantine path)"
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SETUP_KUBECONFIG="sudo cp /etc/rancher/rke2/rke2.yaml /tmp/kubeconfig && sudo chmod 644 /tmp/kubeconfig && export KUBECONFIG=/tmp/kubeconfig"

# ── Copy csp-health-monitor chart + values to control plane ──────────────────
echo "==> Copying csp-health-monitor chart and values to control plane..."
ssh ${SSH_OPTS} "${CONTROL_PLANE}" "rm -rf ${REMOTE_DIR}/chart && mkdir -p ${REMOTE_DIR}"
scp ${SSH_OPTS} -r \
  "${REPO_ROOT}/${CHART_DIR}" \
  "${CONTROL_PLANE}:${REMOTE_DIR}/chart"
scp ${SSH_OPTS} \
  "${REPO_ROOT}/${VALUES_FILE}" \
  "${CONTROL_PLANE}:${REMOTE_DIR}/values-csp-health-monitor.yaml"

if [[ -z "${COMPLETION}" ]]; then
  # ── Full deploy: copy nvsentinel chart to control plane ─────────────────────
  # Images (csp-health-monitor + maintenance-notifier) are pulled from the
  # Lambda internal registry (lambdapublic.jfrog.io/lambda-mk8s-images/...).
  # Build+push is handled by .github/workflows/release-lambda.yml — trigger
  # the workflow_dispatch with your tag before running this script, then set
  # `image.tag` in values-lambda-{prod,phase2}.yaml accordingly.
  echo "==> Copying nvsentinel chart to control plane..."
  ssh ${SSH_OPTS} "${CONTROL_PLANE}" "rm -rf ${REMOTE_DIR}/nvsentinel-chart"
  scp ${SSH_OPTS} -r \
    "${REPO_ROOT}/${NVSENTINEL_CHART_DIR}" \
    "${CONTROL_PLANE}:${REMOTE_DIR}/nvsentinel-chart"
  scp ${SSH_OPTS} \
    "${REPO_ROOT}/${NVSENTINEL_VALUES_FILE}" \
    "${CONTROL_PLANE}:${REMOTE_DIR}/values-lambda-fullstack.yaml"
fi

# ── 3. Check helm on control plane ───────────────────────────────────────────
echo "==> Checking helm on control plane..."
ssh ${SSH_OPTS} "${CONTROL_PLANE}" bash <<'REMOTE'
  if ! command -v helm &>/dev/null; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  else
    echo "helm $(helm version --short) already installed"
  fi
REMOTE

if [[ "${DRY_RUN}" == "--dry-run" ]]; then
  echo "==> Dry-run: rendering csp-health-monitor manifests..."
  ssh ${SSH_OPTS} "${CONTROL_PLANE}" bash <<REMOTE
    ${SETUP_KUBECONFIG}
    helm template ${RELEASE_NAME} ${REMOTE_DIR}/chart \
      --namespace ${NAMESPACE} \
      -f ${REMOTE_DIR}/values-csp-health-monitor.yaml
REMOTE

  if [[ -z "${COMPLETION}" ]]; then
    echo "==> Dry-run: rendering nvsentinel manifests..."
    ssh ${SSH_OPTS} "${CONTROL_PLANE}" bash <<REMOTE
      ${SETUP_KUBECONFIG}
      helm template ${NVSENTINEL_RELEASE} ${REMOTE_DIR}/nvsentinel-chart \
        --namespace ${NAMESPACE} \
        -f ${REMOTE_DIR}/values-lambda-fullstack.yaml
REMOTE
  fi
  exit 0
fi

if [[ -z "${COMPLETION}" ]]; then
  # ── Create lambda-api-key Secret (phase2/prod only) ─────────────────────────
  if [[ -n "${PHASE2}" || -n "${PROD}" ]]; then
    if [[ -n "${PROD}" ]]; then
      if [[ -z "${LAMBDA_PROD_API_KEY:-}" ]]; then
        echo "Error: LAMBDA_PROD_API_KEY env var must be set for prod deploy"
        exit 1
      fi
      _API_KEY="${LAMBDA_PROD_API_KEY}"
    else
      if [[ -z "${LAMBDA_STG_API_KEY:-}" ]]; then
        echo "Error: LAMBDA_STG_API_KEY env var must be set for phase2 deploy"
        exit 1
      fi
      _API_KEY="${LAMBDA_STG_API_KEY}"
    fi
    echo "==> Creating lambda-api-key Secret..."
    # Pipe a generated manifest over SSH so the key never appears in remote process args.
    {
      printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: lambda-api-key\n  namespace: %s\ntype: Opaque\ndata:\n  LAMBDA_API_KEY: %s\n' \
        "${NAMESPACE}" "${NAMESPACE}" "$(printf '%s' "${_API_KEY}" | base64)"
    } | ssh ${SSH_OPTS} "${CONTROL_PLANE}" \
        "${SETUP_KUBECONFIG} && export PATH=\$PATH:/var/lib/rancher/rke2/bin && kubectl apply -f -"
    echo "Secret lambda-api-key created/updated."
  fi

  # ── 6. Deploy nvsentinel parent chart (platform-connector + fault-quarantine + mongodb-store) ─
  echo "==> Installing/upgrading ${NVSENTINEL_RELEASE} (platform-connector + fault-quarantine)..."
  ssh ${SSH_OPTS} "${CONTROL_PLANE}" bash <<REMOTE
    ${SETUP_KUBECONFIG}
    export PATH=\$PATH:/var/lib/rancher/rke2/bin

    helm upgrade --install ${NVSENTINEL_RELEASE} ${REMOTE_DIR}/nvsentinel-chart \
      --namespace ${NAMESPACE} \
      --create-namespace \
      -f ${REMOTE_DIR}/values-lambda-fullstack.yaml \
      --wait --timeout 5m
    echo "${NVSENTINEL_RELEASE} deployed."

    # Restart to pick up any ConfigMap changes on re-runs
    kubectl -n ${NAMESPACE} rollout restart daemonset/${NVSENTINEL_RELEASE} || true
    kubectl -n ${NAMESPACE} rollout restart deployment/fault-quarantine || true
    kubectl -n ${NAMESPACE} rollout status daemonset/${NVSENTINEL_RELEASE} --timeout=3m || true
    kubectl -n ${NAMESPACE} rollout status deployment/fault-quarantine --timeout=3m || true
REMOTE
fi

if [[ -n "${COMPLETION}" ]]; then
  # ── Completion (phase1 only): patch ConfigMaps only, then restart ─────────────
  echo "==> Patching ConfigMaps for completion scenario..."
  ssh ${SSH_OPTS} "${CONTROL_PLANE}" bash <<REMOTE
    ${SETUP_KUBECONFIG}
    export PATH=\$PATH:/var/lib/rancher/rke2/bin

    helm template ${RELEASE_NAME} ${REMOTE_DIR}/chart \
      --namespace ${NAMESPACE} \
      -f ${REMOTE_DIR}/values-csp-health-monitor.yaml \
      -s templates/configmap.yaml \
      -s templates/configmap-lambda-mock-events.yaml \
    | kubectl apply -f -

    kubectl -n ${NAMESPACE} rollout restart deployment/${RELEASE_NAME}
    kubectl -n ${NAMESPACE} rollout status deployment/${RELEASE_NAME} --timeout=3m
REMOTE
else
  # ── 7. Full deploy: helm upgrade csp-health-monitor ───────────────────────────
  echo "==> Installing/upgrading ${RELEASE_NAME}..."
  ssh ${SSH_OPTS} "${CONTROL_PLANE}" bash <<REMOTE
    ${SETUP_KUBECONFIG}
    export PATH=\$PATH:/var/lib/rancher/rke2/bin
    helm upgrade --install ${RELEASE_NAME} ${REMOTE_DIR}/chart \
      --namespace ${NAMESPACE} \
      --create-namespace \
      -f ${REMOTE_DIR}/values-csp-health-monitor.yaml \
      --wait --timeout 3m

    kubectl -n ${NAMESPACE} rollout restart deployment/${RELEASE_NAME}
    kubectl -n ${NAMESPACE} rollout status deployment/${RELEASE_NAME} --timeout=3m
REMOTE
fi

echo "==> Pod status:"
ssh ${SSH_OPTS} "${CONTROL_PLANE}" bash <<REMOTE
  export KUBECONFIG=/tmp/kubeconfig
  export PATH=\$PATH:/var/lib/rancher/rke2/bin
  kubectl -n ${NAMESPACE} get pods
REMOTE

echo ""
echo "==> Done. To tail logs:"
echo "    ssh -i ${SSH_KEY} ${CONTROL_PLANE}"
echo "    export KUBECONFIG=/tmp/kubeconfig"
echo "    kubectl -n ${NAMESPACE} logs -l app.kubernetes.io/name=csp-health-monitor -c csp-health-monitor -f"
echo "    kubectl -n ${NAMESPACE} logs -l app.kubernetes.io/name=csp-health-monitor -c maintenance-notifier -f"
echo ""
echo "==> To check quarantine (taint) on ${WORKER_NODE}:"
echo "    kubectl describe node ${WORKER_NODE} | grep -A5 Taints"
if [[ -n "${PHASE2}" || -n "${PROD}" ]]; then
  if [[ -n "${PHASE2}" ]]; then
    _flag="--staging"
    _host="https://cloud.lambdastaging.com"
    _key='$LAMBDA_STG_API_KEY'
  else
    _flag=""
    _host="https://cloud.lambda.ai"
    _key='$LAMBDA_PROD_API_KEY'
  fi
  echo ""
  echo "==> Fast e2e test flow (uses the simulate API — defaults to PROD):"
  echo "    ./scripts/simulate-lambda-events.sh cycle ${_flag}"
  echo ""
  echo "    Or manually:"
  echo "      # 1. Create emergency event (fires on next poll — no time-window check)"
  echo "      ./scripts/simulate-lambda-events.sh create ${_flag}"
  echo ""
  echo "      # 2. After the taint appears, transition to completed:"
  echo "      ./scripts/simulate-lambda-events.sh complete <event-id> ${_flag}"
  echo ""
  echo "    Raw curl equivalent (create):"
  echo "      curl -sS -X POST ${_host}/api/v1/maintenance_events/simulate \\"
  echo "        -H \"Authorization: Bearer ${_key}\" -H 'Content-Type: application/json' \\"
  echo "        -d '{\"entity_lrns\":[\"lrn:cloud:instance:06c1e2f8a20042be8d4617c83fa18b39\"],\"urgency\":\"emergency\",\"detail\":\"e2e test\"}'"
  echo ""
  echo "    Raw curl equivalent (transition):"
  echo "      curl -sS -X POST ${_host}/api/v1/maintenance_events/simulate/<event-id>/transition \\"
  echo "        -H \"Authorization: Bearer ${_key}\" -H 'Content-Type: application/json' \\"
  echo "        -d '{\"status\":\"completed\"}'"
  if [[ -n "${PROD}" ]]; then
    echo ""
    echo "    NOTE: prod defaults postMaintenanceHealthyDelayMinutes=15."
    echo "          HEALTHY won't fire until 15 min after actualEndTime — backdate in Mongo to test fast."
  fi
fi
