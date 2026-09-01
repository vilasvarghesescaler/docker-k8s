#!/usr/bin/env bash
#
# deploy_lattice_lab.sh
# End-to-end setup: EKS + AWS Gateway API Controller (Pod Identity) + VPC Lattice
# + two microservices + Bedrock metrics analysis + HPA (normal CPU) then HPA v2
# (KEDA, scaled on a VPC Lattice business metric) with a load-generator demo.
#
# Intended to run on an EC2 instance that already has an ADMIN IAM role attached.
# It installs kubectl, eksctl, helm, jq, and python3/boto3 if missing, then runs
# every step of the lab with polling on the async reconciliation points.
#
# Tested against Amazon Linux 2023 (x86_64). Adjust the installer block for other OSes.
#
# Usage:
#   chmod +x deploy_lattice_lab.sh
#   ./deploy_lattice_lab.sh            # full build + test + HPA/KEDA demo + bedrock analysis
#   ./deploy_lattice_lab.sh -y         # same, but auto-approve every prompt (non-interactive)
#   ./deploy_lattice_lab.sh cleanup    # tear everything down
#
# Interactive consent (build path only):
#   On the create/build run, every RESOURCE-CREATING or MUTATING command is printed
#   verbatim and must be confirmed with 'y' or 'Y' before it executes. Read-only
#   describe/list/wait/poll calls and local tool installs run without prompting.
#   The 'cleanup' path is NEVER gated.
#   Pass -y / --yes (or set ASSUME_YES=true) to auto-approve every prompt:
#     ./deploy_lattice_lab.sh -y
#     ASSUME_YES=true ./deploy_lattice_lab.sh
#
# Override defaults via env vars, e.g.:
#   AWS_REGION=us-west-2 CLUSTER_NAME=my-demo BEDROCK_MODEL_ID=us.anthropic.claude-sonnet-4-6 ./deploy_lattice_lab.sh
#   KEDA_TARGET_VALUE=5 HPA_MAX=10 LOADGEN_WORKERS=40 ./deploy_lattice_lab.sh -y
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
export AWS_REGION="${AWS_REGION:-us-east-1}"
export CLUSTER_NAME="${CLUSTER_NAME:-lattice-demo}"
export EKS_VERSION="${EKS_VERSION:-1.35}"
export NODE_TYPE="${NODE_TYPE:-t3.medium}"
export CONTROLLER_CHART_VERSION="${CONTROLLER_CHART_VERSION:-v2.1.1}"
export GATEWAY_API_CRD_VERSION="${GATEWAY_API_CRD_VERSION:-v1.6.0}"
export BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:-us.anthropic.claude-sonnet-4-6}"

CONTROLLER_NS="aws-application-networking-system"
SERVICE_NETWORK_NAME="lattice-demo-network"   # MUST match the Gateway name
GATEWAY_NAME="lattice-demo-network"           # MUST match the service network name
SG_NAME="lattice-traffic-sg"
POLICY_NAME="VPCLatticeControllerIAMPolicy"
ROLE_NAME="VPCLatticeControllerIAMRole"
SA_NAME="gateway-api-controller"
WORKDIR="${WORKDIR:-$HOME/lattice-lab}"

# --- Autoscaling (HPA + KEDA) configuration ---------------------------------
export KEDA_CHART_VERSION="${KEDA_CHART_VERSION:-}"   # empty = latest chart
KEDA_NAMESPACE="keda"
KEDA_POLICY_NAME="KEDACloudWatchReadPolicy"
KEDA_ROLE_NAME="KEDACloudWatchReadRole"
SCALEDOBJECT_NAME="backend-scaledobject"             # KEDA HPA => keda-hpa-${SCALEDOBJECT_NAME}
NORMAL_HPA_NAME="backend-cpu-hpa"                     # the classic autoscaling/v1 HPA
LOADGEN_NAME="lattice-loadgen"

export HPA_MIN="${HPA_MIN:-2}"                        # keep min == backend's current replicas
export HPA_MAX="${HPA_MAX:-10}"
export NORMAL_HPA_CPU_PCT="${NORMAL_HPA_CPU_PCT:-50}" # target CPU% for the normal HPA
# ActiveConnectionCount (Sum, across AZs) *per replica* that triggers scale-out.
# Kept intentionally low so the demo scales reliably; tune for your own load.
export KEDA_TARGET_VALUE="${KEDA_TARGET_VALUE:-5}"
export LOADGEN_WORKERS="${LOADGEN_WORKERS:-40}"        # concurrent held-open connections
export LOADGEN_SCALEOUT_WAIT="${LOADGEN_SCALEOUT_WAIT:-420}"  # seconds to watch for scale-out
export LOADGEN_SCALEIN_WAIT="${LOADGEN_SCALEIN_WAIT:-300}"    # seconds to watch for scale-in

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1; }

print_usage() {
  cat <<USAGE
Usage: $0 [-y|--yes] [cleanup]

  (no args)      Full build + test + HPA/KEDA demo + Bedrock analysis (interactive consent).
  -y, --yes      Auto-approve every consent prompt on the build path (same as ASSUME_YES=true).
  cleanup        Tear everything down (never gated).
  -h, --help     Show this help.
USAGE
}

# Poll until a command's stdout matches expected, or timeout.
#   wait_for <timeout_sec> <interval_sec> <expected> <cmd...>
wait_for() {
  local timeout=$1 interval=$2 expected=$3; shift 3
  local elapsed=0 out
  while (( elapsed < timeout )); do
    out="$("$@" 2>/dev/null || true)"
    if [[ "$out" == *"$expected"* ]]; then
      return 0
    fi
    sleep "$interval"; elapsed=$((elapsed + interval))
    info "…waiting (${elapsed}s/${timeout}s) for '$expected'"
  done
  return 1
}

# ----------------------------------------------------------------------------
# Interactive consent (create/build path ONLY — cleanup is never gated)
# ----------------------------------------------------------------------------
# Every RESOURCE-CREATING / MUTATING command on the build path is echoed exactly
# and must be approved with 'y' / 'Y' before it runs. Prompts and echoes are
# written to the controlling terminal (/dev/tty), so they survive command
# substitution ( VAR=$(...) ) and stderr/stdout redirection ( 2>/dev/null ).
# Pass -y/--yes on the command line (or ASSUME_YES=true) to auto-approve all.
ASSUME_YES="${ASSUME_YES:-false}"

C_CMD=$'\033[1;35m'
C_OFF=$'\033[0m'

# Write a message to the controlling terminal (falls back to stderr if no tty).
_msg_tty() {
  if [[ -w /dev/tty ]]; then
    printf '%s' "$1" >/dev/tty
  else
    printf '%s' "$1" >&2
  fi
}

# Render an argv as a readable, copy-pasteable command line. Any argument that
# is empty or contains shell-special characters is wrapped in single quotes.
# (No argument in this script contains a literal single quote.)
_render_cmd() {
  local a out=""
  for a in "$@"; do
    case "$a" in
      ''|*[!A-Za-z0-9_./:=@%+,-]*) out+="'$a' " ;;
      *)                           out+="$a "   ;;
    esac
  done
  printf '%s' "${out% }"
}

# Ask the user to approve the already-printed command. Returns 0 to proceed.
_consent() {
  if [[ "$ASSUME_YES" == "true" ]]; then
    _msg_tty "    (auto-approved via ASSUME_YES=true)"$'\n'
    return 0
  fi
  if [[ ! -r /dev/tty ]]; then
    warn "No TTY available to read consent and ASSUME_YES!=true — refusing to continue."
    return 1
  fi
  local reply=""
  _msg_tty "    Proceed with the above command? [y/N] "
  read -r reply </dev/tty || true
  [[ "$reply" == "y" || "$reply" == "Y" ]]
}

# confirm_run <argv...> : print the exact command, ask y/Y, then execute it.
# Redirections/pipes attached by the caller apply to the command, not to the
# prompt (which goes to /dev/tty). Declining aborts the run.
confirm_run() {
  _msg_tty $'\n'"${C_CMD}\$ $(_render_cmd "$@")${C_OFF}"$'\n'
  _consent || die "Aborted by user (declined the command above)."
  "$@"
}

# confirm_apply "<label>" "<manifest>" : show `kubectl apply -f -` plus the full
# manifest, ask y/Y, then pipe the manifest into kubectl. Declining aborts.
confirm_apply() {
  local label="$1" manifest="$2"
  _msg_tty $'\n'"${C_CMD}\$ kubectl apply -f -   # ${label}${C_OFF}"$'\n'
  _msg_tty "$(printf '%s\n' "$manifest" | sed 's/^/      /')"$'\n'
  _consent || die "Aborted by user (declined to apply: ${label})."
  printf '%s\n' "$manifest" | kubectl apply -f -
}

# ----------------------------------------------------------------------------
# Tool installation
# ----------------------------------------------------------------------------
install_tools() {
  log "Checking / installing prerequisites"
  mkdir -p "$WORKDIR"; cd "$WORKDIR"

  # Package basics — apt (Ubuntu/Debian) first, then dnf/yum (Amazon Linux/RHEL)
  install_base_packages() {
    if require_cmd apt-get; then
      sudo apt-get update -y >/dev/null 2>&1 || true
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        unzip jq tar gzip curl python3 python3-pip >/dev/null 2>&1 || true
    elif require_cmd dnf; then
      sudo dnf install -y unzip jq tar gzip curl python3 python3-pip >/dev/null 2>&1 || true
    elif require_cmd yum; then
      sudo yum install -y unzip jq tar gzip curl python3 python3-pip >/dev/null 2>&1 || true
    else
      warn "No supported package manager (apt/dnf/yum) found; ensure unzip, jq, curl, tar, python3, python3-pip are installed."
    fi
  }
  install_base_packages

  # AWS CLI v2
  if ! require_cmd aws; then
    info "Installing AWS CLI v2"
    curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o awscliv2.zip
    require_cmd unzip || { warn "unzip missing; attempting install"; install_base_packages; }
    unzip -q awscliv2.zip; sudo ./aws/install --update; rm -rf aws awscliv2.zip
  fi
  info "aws: $(aws --version 2>&1 | head -1)"

  # kubectl (match EKS minor where possible; latest stable is fine)
  if ! require_cmd kubectl; then
    info "Installing kubectl"
    local kver; kver="$(curl -sSL https://dl.k8s.io/release/stable.txt)"
    curl -sSLo kubectl "https://dl.k8s.io/release/${kver}/bin/linux/$(dpkg --print-architecture 2>/dev/null || echo amd64)/kubectl" 2>/dev/null \
      || curl -sSLo kubectl "https://dl.k8s.io/release/${kver}/bin/linux/amd64/kubectl"
    chmod +x kubectl; sudo mv kubectl /usr/local/bin/
  fi
  info "kubectl: $(kubectl version --client 2>/dev/null | head -1)"

  # eksctl
  if ! require_cmd eksctl; then
    info "Installing eksctl"
    local arch; arch="$(uname -m)"; [[ "$arch" == "x86_64" ]] && arch="amd64"; [[ "$arch" == "aarch64" ]] && arch="arm64"
    curl -sSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_${arch}.tar.gz" \
      | tar xz -C /tmp
    sudo mv /tmp/eksctl /usr/local/bin/
  fi
  info "eksctl: $(eksctl version 2>/dev/null)"

  # helm
  if ! require_cmd helm; then
    info "Installing helm"
    curl -sSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
  info "helm: $(helm version --short 2>/dev/null)"

  # boto3 for the analysis script.
  # On newer Ubuntu, pip refuses to touch the system env without --break-system-packages,
  # so prefer the apt package, then fall back through pip variants.
  if ! python3 -c "import boto3" >/dev/null 2>&1; then
    info "Installing boto3"
    if require_cmd apt-get; then
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-boto3 >/dev/null 2>&1 || true
    fi
    python3 -c "import boto3" >/dev/null 2>&1 \
      || pip3 install --quiet --break-system-packages boto3 >/dev/null 2>&1 \
      || pip3 install --quiet --user boto3 >/dev/null 2>&1 \
      || python3 -m pip install --quiet --user boto3 >/dev/null 2>&1 \
      || warn "Could not install boto3 automatically; run 'pip3 install --break-system-packages boto3' before the analysis step."
  fi

  export ACCOUNT_ID; ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  info "Account: $ACCOUNT_ID   Region: $AWS_REGION"
}

# ----------------------------------------------------------------------------
# Step 2 — Cluster
# ----------------------------------------------------------------------------

# Robustly remove a (possibly broken / DELETE_FAILED) eksctl CloudFormation stack.
# Tries: eksctl delete (only if the EKS cluster still exists) -> plain CFN delete
# -> CFN delete retaining whatever resources are stuck.
# NOTE: these destructive recovery steps run on the BUILD path, so they are gated.
force_delete_stack() {
  local stack="$1"

  # If EKS still knows the cluster, let eksctl do the orderly teardown first.
  if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    info "EKS cluster still present — using eksctl delete"
    confirm_run eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --wait || true
  fi

  # Re-read stack status; eksctl may have already cleared it.
  local st
  st="$(aws cloudformation describe-stacks --stack-name "$stack" --region "$AWS_REGION" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE)"
  [[ "$st" == "NONE" ]] && { info "Stack $stack is gone"; return 0; }

  # Plain delete attempt.
  info "Requesting CloudFormation delete of $stack"
  confirm_run aws cloudformation delete-stack --stack-name "$stack" --region "$AWS_REGION" || true
  if aws cloudformation wait stack-delete-complete --stack-name "$stack" --region "$AWS_REGION" 2>/dev/null; then
    info "Stack deleted"
    return 0
  fi

  # Still stuck: find the resources that refuse to delete and retain them.
  warn "Stack still not deleted; identifying stuck resources to retain"
  local stuck
  stuck="$(aws cloudformation describe-stack-events --stack-name "$stack" --region "$AWS_REGION" \
    --query "StackEvents[?ResourceStatus=='DELETE_FAILED'].LogicalResourceId" --output text 2>/dev/null \
    | tr '\t' '\n' | sort -u | tr '\n' ' ')"
  if [[ -n "${stuck// }" ]]; then
    warn "Retaining stuck resources and deleting the rest: $stuck"
    # shellcheck disable=SC2086
    confirm_run aws cloudformation delete-stack --stack-name "$stack" --region "$AWS_REGION" \
      --retain-resources $stuck || true
    aws cloudformation wait stack-delete-complete --stack-name "$stack" --region "$AWS_REGION" 2>/dev/null || true
    warn "Stack removed, but these resources were RETAINED and may still exist / incur cost: $stuck"
    warn "Inspect and clean them manually (often a VPC, subnet, or security group pinned by leftover"
    warn "VPC Lattice associations or ENIs). See: aws cloudformation describe-stack-events --stack-name $stack"
  else
    die "Stack $stack is stuck in a failed state and no DELETE_FAILED resource was identified. Inspect it manually in the CloudFormation console, then re-run."
  fi
}

create_cluster() {
  local stack="eksctl-${CLUSTER_NAME}-cluster"

  # Source of truth #1: does EKS itself report an ACTIVE cluster?
  local eks_status
  eks_status="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'cluster.status' --output text 2>/dev/null || echo NONE)"

  # Source of truth #2: CloudFormation stack state (eksctl builds via CFN).
  local cfn_status
  cfn_status="$(aws cloudformation describe-stacks --stack-name "$stack" --region "$AWS_REGION" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo NONE)"

  info "EKS status: $eks_status | CFN stack status: $cfn_status"

  if [[ "$eks_status" == "ACTIVE" ]]; then
    log "Cluster $CLUSTER_NAME is ACTIVE — skipping creation"
  elif [[ "$eks_status" == "CREATING" ]]; then
    log "Cluster $CLUSTER_NAME is still CREATING — waiting for it to become ACTIVE"
    aws eks wait cluster-active --name "$CLUSTER_NAME" --region "$AWS_REGION"
  else
    # No active cluster. Deal with any leftover stack before (re)creating.
    case "$cfn_status" in
      NONE)
        : # clean slate, proceed to create
        ;;
      CREATE_COMPLETE)
        # Stack is complete but EKS didn't report ACTIVE above — unusual; trust CFN and continue.
        warn "CFN stack is CREATE_COMPLETE but EKS did not report ACTIVE; continuing and will verify below."
        ;;
      CREATE_IN_PROGRESS)
        log "CFN stack creation already in progress — waiting for it to complete"
        aws cloudformation wait stack-create-complete --stack-name "$stack" --region "$AWS_REGION" || true
        ;;
      ROLLBACK_COMPLETE|ROLLBACK_FAILED|CREATE_FAILED|DELETE_FAILED)
        warn "Found a broken CFN stack ($cfn_status). Attempting to remove it before recreating."
        force_delete_stack "$stack"
        ;;
      DELETE_IN_PROGRESS)
        log "CFN stack is being deleted — waiting before recreating"
        aws cloudformation wait stack-delete-complete --stack-name "$stack" --region "$AWS_REGION" 2>/dev/null || true
        ;;
      *)
        warn "Unexpected CFN stack status '$cfn_status'. Attempting to remove it before recreating."
        force_delete_stack "$stack"
        ;;
    esac

    # Re-check whether a usable cluster now exists (e.g. CREATE_COMPLETE branch).
    eks_status="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
      --query 'cluster.status' --output text 2>/dev/null || echo NONE)"
    if [[ "$eks_status" != "ACTIVE" ]]; then
      log "Creating EKS cluster $CLUSTER_NAME (~15-20 min)"
      confirm_run eksctl create cluster \
        --name "$CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --version "$EKS_VERSION" \
        --nodegroup-name standard-nodes \
        --node-type "$NODE_TYPE" \
        --nodes 2 --nodes-min 1 --nodes-max 3 \
        --managed
    fi
  fi

  aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"
  export VPC_ID; VPC_ID="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text)"
  info "VPC: $VPC_ID"
  kubectl get nodes
}

# ----------------------------------------------------------------------------
# Step 2b — Pod Identity Agent
# ----------------------------------------------------------------------------
ensure_pod_identity_agent() {
  log "Ensuring EKS Pod Identity Agent addon"
  if aws eks list-addons --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
      --query 'addons' --output text | grep -qw eks-pod-identity-agent; then
    info "Already installed"
  else
    confirm_run aws eks create-addon --cluster-name "$CLUSTER_NAME" \
      --addon-name eks-pod-identity-agent --region "$AWS_REGION"
    aws eks wait addon-active --cluster-name "$CLUSTER_NAME" \
      --addon-name eks-pod-identity-agent --region "$AWS_REGION"
    info "Installed and active"
  fi
}

# ----------------------------------------------------------------------------
# Step 3 / 3b — Security groups
# ----------------------------------------------------------------------------
setup_security_groups() {
  log "Configuring security groups"

  export LATTICE_PREFIX_LIST; LATTICE_PREFIX_LIST="$(aws ec2 describe-managed-prefix-lists --region "$AWS_REGION" \
    --filters "Name=prefix-list-name,Values=com.amazonaws.$AWS_REGION.vpc-lattice" \
    --query 'PrefixLists[0].PrefixListId' --output text)"
  info "Lattice prefix list: $LATTICE_PREFIX_LIST"

  # Reuse SG if present
  LATTICE_SG_ID="$(aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$SG_NAME" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)"
  if [[ "$LATTICE_SG_ID" == "None" || -z "$LATTICE_SG_ID" ]]; then
    LATTICE_SG_ID="$(confirm_run aws ec2 create-security-group \
      --group-name "$SG_NAME" --description "Allow inbound from VPC Lattice" \
      --vpc-id "$VPC_ID" --region "$AWS_REGION" --query GroupId --output text)"
    info "Created SG $LATTICE_SG_ID"
  else
    info "Reusing SG $LATTICE_SG_ID"
  fi
  export LATTICE_SG_ID

  export VPC_CIDR; VPC_CIDR="$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$AWS_REGION" \
    --query 'Vpcs[0].CidrBlock' --output text)"

  # Ingress rules on the Lattice SG (ignore duplicates)
  confirm_run aws ec2 authorize-security-group-ingress --group-id "$LATTICE_SG_ID" \
    --ip-permissions "IpProtocol=-1,PrefixListIds=[{PrefixListId=$LATTICE_PREFIX_LIST}]" \
    --region "$AWS_REGION" 2>/dev/null || info "prefix-list ingress already present"
  confirm_run aws ec2 authorize-security-group-ingress --group-id "$LATTICE_SG_ID" \
    --ip-permissions "IpProtocol=-1,IpRanges=[{CidrIp=$VPC_CIDR}]" \
    --region "$AWS_REGION" 2>/dev/null || info "VPC-CIDR ingress already present"

  # Health checks reach pods via the cluster SG
  export CLUSTER_SG; CLUSTER_SG="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)"
  confirm_run aws ec2 authorize-security-group-ingress --group-id "$CLUSTER_SG" \
    --ip-permissions "IpProtocol=-1,PrefixListIds=[{PrefixListId=$LATTICE_PREFIX_LIST}]" \
    --region "$AWS_REGION" 2>/dev/null || info "cluster-SG prefix-list ingress already present"
  info "Cluster SG: $CLUSTER_SG"
}

# ----------------------------------------------------------------------------
# Step 4 — IAM + Pod Identity + controller
# ----------------------------------------------------------------------------
setup_iam_and_controller() {
  log "IAM policy, role, and Pod Identity association"
  cd "$WORKDIR"

  export POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
  if ! aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
    curl -sSL -o recommended-inline-policy.json \
      https://raw.githubusercontent.com/aws/aws-application-networking-k8s/main/files/controller-installation/recommended-inline-policy.json
    confirm_run aws iam create-policy --policy-name "$POLICY_NAME" \
      --policy-document file://recommended-inline-policy.json --region "$AWS_REGION" >/dev/null
    info "Created policy"
  else
    info "Policy already exists"
  fi

  if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    cat > eks-pod-identity-trust-relationship.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Principal": { "Service": "pods.eks.amazonaws.com" },
      "Action": ["sts:AssumeRole", "sts:TagSession"] }
  ]
}
JSON
    confirm_run aws iam create-role --role-name "$ROLE_NAME" \
      --assume-role-policy-document file://eks-pod-identity-trust-relationship.json \
      --description "IAM Role for AWS Gateway API Controller for VPC Lattice" >/dev/null
    confirm_run aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"
    info "Created role and attached policy"
  else
    info "Role already exists"
  fi
  export ROLE_ARN; ROLE_ARN="$(aws iam list-roles \
    --query "Roles[?RoleName=='${ROLE_NAME}'].Arn" --output text)"

  # Pod Identity association (idempotent-ish: skip if one exists for the SA)
  if aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
       --query "associations[?serviceAccount=='${SA_NAME}'].associationId" --output text | grep -q .; then
    info "Pod Identity association already present"
  else
    confirm_run aws eks create-pod-identity-association --cluster-name "$CLUSTER_NAME" \
      --role-arn "$ROLE_ARN" --namespace "$CONTROLLER_NS" \
      --service-account "$SA_NAME" --region "$AWS_REGION" >/dev/null
    info "Created Pod Identity association"
  fi

  log "Installing AWS Gateway API Controller (Helm)"
  aws ecr-public get-login-password --region us-east-1 \
    | helm registry login --username AWS --password-stdin public.ecr.aws >/dev/null

  if helm status aws-gateway-api-controller -n "$CONTROLLER_NS" >/dev/null 2>&1; then
    info "Controller release already installed"
  else
    confirm_run helm install aws-gateway-api-controller \
      oci://public.ecr.aws/aws-application-networking-k8s/aws-gateway-controller-chart \
      --version "$CONTROLLER_CHART_VERSION" \
      --namespace "$CONTROLLER_NS" --create-namespace \
      --set serviceAccount.create=true \
      --set serviceAccount.name="$SA_NAME" \
      --set awsRegion="$AWS_REGION" --set clusterName="$CLUSTER_NAME"
  fi

  confirm_run kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_CRD_VERSION}/standard-install.yaml"

  log "Waiting for controller pod to be Ready"
  kubectl rollout status deployment -n "$CONTROLLER_NS" --timeout=180s || true
  # Restart once so Pod Identity creds are definitely picked up
  confirm_run kubectl rollout restart deployment -n "$CONTROLLER_NS"
  kubectl rollout status deployment -n "$CONTROLLER_NS" --timeout=180s
  kubectl get pods -n "$CONTROLLER_NS"
}

# ----------------------------------------------------------------------------
# Step 5 — Service network + association
# ----------------------------------------------------------------------------
create_service_network() {
  log "Creating VPC Lattice service network + VPC association"
  export SERVICE_NETWORK_ID
  SERVICE_NETWORK_ID="$(aws vpc-lattice list-service-networks --region "$AWS_REGION" \
    --query "items[?name=='${SERVICE_NETWORK_NAME}'].id | [0]" --output text 2>/dev/null || echo None)"
  if [[ "$SERVICE_NETWORK_ID" == "None" || -z "$SERVICE_NETWORK_ID" ]]; then
    SERVICE_NETWORK_ID="$(confirm_run aws vpc-lattice create-service-network \
      --name "$SERVICE_NETWORK_NAME" --auth-type NONE --region "$AWS_REGION" \
      --query id --output text)"
    info "Created service network $SERVICE_NETWORK_ID"
  else
    info "Reusing service network $SERVICE_NETWORK_ID"
  fi

  # Associate VPC if not already associated
  if aws vpc-lattice list-service-network-vpc-associations --vpc-id "$VPC_ID" --region "$AWS_REGION" \
       --query "items[?serviceNetworkId=='${SERVICE_NETWORK_ID}'].id" --output text | grep -q .; then
    info "VPC already associated"
  else
    confirm_run aws vpc-lattice create-service-network-vpc-association \
      --service-network-identifier "$SERVICE_NETWORK_ID" \
      --vpc-identifier "$VPC_ID" --security-group-ids "$LATTICE_SG_ID" \
      --region "$AWS_REGION" >/dev/null
    info "Associated VPC"
  fi
}

# ----------------------------------------------------------------------------
# Step 6 / 6b — GatewayClass, Gateway, VpcAssociationPolicy
# ----------------------------------------------------------------------------
create_gateway() {
  log "Creating GatewayClass and Gateway"

  local gatewayclass_manifest
  gatewayclass_manifest="$(cat <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: amazon-vpc-lattice
spec:
  controllerName: application-networking.k8s.aws/gateway-api-controller
EOF
)"
  confirm_apply "GatewayClass amazon-vpc-lattice" "$gatewayclass_manifest"

  local gateway_manifest
  gateway_manifest="$(cat <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
  namespace: default
  annotations:
    application-networking.k8s.aws/lattice-vpc-association: "true"
spec:
  gatewayClassName: amazon-vpc-lattice
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: Same
EOF
)"
  confirm_apply "Gateway ${GATEWAY_NAME} (namespace default)" "$gateway_manifest"

  log "Attaching security group to the Lattice association (VpcAssociationPolicy)"
  local vpcassoc_manifest
  vpcassoc_manifest="$(cat <<EOF
apiVersion: application-networking.k8s.aws/v1alpha1
kind: VpcAssociationPolicy
metadata:
  name: lattice-vpc-assoc-policy
  namespace: default
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: ${GATEWAY_NAME}
  securityGroupIds:
  - ${LATTICE_SG_ID}
  associateWithVpc: true
EOF
)"
  confirm_apply "VpcAssociationPolicy lattice-vpc-assoc-policy" "$vpcassoc_manifest"

  log "Waiting for Gateway to be Accepted"
  wait_for 180 10 "True" \
    kubectl get gateway "$GATEWAY_NAME" -n default \
      -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' \
    || warn "Gateway not Accepted within timeout; continuing (check: kubectl describe gateway $GATEWAY_NAME -n default)"

  log "Waiting for the association to carry the security group"
  local snva
  snva="$(aws vpc-lattice list-service-network-vpc-associations --vpc-id "$VPC_ID" --region "$AWS_REGION" \
          --query 'items[0].id' --output text)"
  wait_for 120 10 "$LATTICE_SG_ID" \
    aws vpc-lattice get-service-network-vpc-association \
      --service-network-vpc-association-identifier "$snva" --region "$AWS_REGION" \
      --query 'securityGroupIds' --output text \
    || warn "SG not yet on association; continuing"
}

# ----------------------------------------------------------------------------
# Step 7 / 8 / 8b — Workloads + health-check policy
# ----------------------------------------------------------------------------
deploy_workloads() {
  log "Deploying backend (httpbin) and frontend (nginx)"
  # NOTE: the backend container declares CPU/memory requests+limits. HPA needs a
  # CPU request to compute utilization for the normal (autoscaling/v1) HPA below.
  local workloads_manifest
  workloads_manifest="$(cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      containers:
      - name: httpbin
        image: kennethreitz/httpbin
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 250m
            memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: backend-svc
  namespace: default
spec:
  selector:
    app: backend
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: frontend-svc
  namespace: default
spec:
  selector:
    app: frontend
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
EOF
)"
  confirm_apply "Deployments + Services (backend/httpbin, frontend/nginx)" "$workloads_manifest"

  log "Applying TargetGroupPolicy (health check tuned for httpbin)"
  local tgp_manifest
  tgp_manifest="$(cat <<EOF
apiVersion: application-networking.k8s.aws/v1alpha1
kind: TargetGroupPolicy
metadata:
  name: backend-tgp
  namespace: default
spec:
  targetRef:
    group: ""
    kind: Service
    name: backend-svc
  protocol: HTTP
  protocolVersion: HTTP1
  healthCheck:
    enabled: true
    protocol: HTTP
    protocolVersion: HTTP1
    port: 80
    path: /get
    healthyThresholdCount: 2
    unhealthyThresholdCount: 2
    intervalSeconds: 10
    timeoutSeconds: 5
    statusMatch: "200"
EOF
)"
  confirm_apply "TargetGroupPolicy backend-tgp" "$tgp_manifest"

  kubectl rollout status deployment/backend -n default --timeout=120s
  kubectl rollout status deployment/frontend -n default --timeout=120s
}

# ----------------------------------------------------------------------------
# Step 9 / 9b — HTTPRoute + wait for healthy targets
# ----------------------------------------------------------------------------
create_route() {
  log "Creating HTTPRoute"
  local route_manifest
  route_manifest="$(cat <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: backend-route
  namespace: default
spec:
  parentRefs:
  - name: ${GATEWAY_NAME}
    namespace: default
    sectionName: http
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: backend-svc
      namespace: default
      port: 80
      weight: 100
EOF
)"
  confirm_apply "HTTPRoute backend-route" "$route_manifest"

  log "Waiting for the Lattice service + DNS to be created"
  local dns=""
  local elapsed=0
  while (( elapsed < 240 )); do
    dns="$(aws vpc-lattice list-services --region "$AWS_REGION" \
      --query "items[?contains(name,'backend')].dnsEntry.domainName | [0]" --output text 2>/dev/null || echo None)"
    [[ -n "$dns" && "$dns" != "None" ]] && break
    sleep 10; elapsed=$((elapsed+10)); info "…waiting for Lattice service DNS (${elapsed}s)"
  done
  [[ -n "$dns" && "$dns" != "None" ]] || die "Lattice service DNS never appeared. Check: kubectl describe httproute backend-route -n default"
  export BACKEND_DNS="$dns"
  info "BACKEND_DNS=$BACKEND_DNS"

  export TG_ARN; TG_ARN="$(aws vpc-lattice list-target-groups --region "$AWS_REGION" \
    --query "items[?contains(name,'backend')] | [0].arn" --output text)"

  log "Waiting for target group to report HEALTHY"
  elapsed=0
  while (( elapsed < 300 )); do
    local statuses
    statuses="$(aws vpc-lattice list-targets --target-group-identifier "$TG_ARN" --region "$AWS_REGION" \
      --query 'items[].status' --output text 2>/dev/null || echo)"
    if [[ -n "$statuses" ]] && ! grep -qv HEALTHY <<<"$(tr '\t' '\n' <<<"$statuses")"; then
      info "All targets HEALTHY"
      break
    fi
    sleep 15; elapsed=$((elapsed+15)); info "…targets not all healthy yet (${elapsed}s): ${statuses:-none}"
  done
  aws vpc-lattice list-targets --target-group-identifier "$TG_ARN" --region "$AWS_REGION" \
    --query 'items[].{id:id,status:status,reason:reasonCode}' --output table || true
}

# ----------------------------------------------------------------------------
# Step 10 — Connectivity test + traffic
# ----------------------------------------------------------------------------
test_and_traffic() {
  log "Testing connectivity through VPC Lattice"
  export FRONTEND_POD; FRONTEND_POD="$(kubectl get pod -l app=frontend -n default \
    -o jsonpath='{.items[0].metadata.name}')"

  local code
  code="$(kubectl exec "$FRONTEND_POD" -n default -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${BACKEND_DNS}/get" || echo 000)"
  info "First request HTTP $code"
  [[ "$code" == "200" ]] || warn "Expected 200 but got $code — check target health / SGs before trusting metrics"

  # Traffic generation is optional; declining here just skips it (no abort).
  _msg_tty $'\n'"${C_CMD}\$ for i in 1..40; do kubectl exec ${FRONTEND_POD} -n default -- curl -s http://${BACKEND_DNS}/get; done${C_OFF}"$'\n'
  if _consent; then
    log "Generating traffic (40 requests)"
    for i in $(seq 1 40); do
      kubectl exec "$FRONTEND_POD" -n default -- \
        curl -s -o /dev/null --max-time 10 "http://${BACKEND_DNS}/get" || true
      printf '\r    request %d/40' "$i"
    done
    printf '\n'
  else
    warn "Skipped traffic generation — CloudWatch metrics may be empty for the analysis step."
  fi
}

# ----------------------------------------------------------------------------
# Step 10b — metrics-server (required for the normal CPU-based HPA)
# ----------------------------------------------------------------------------
install_metrics_server() {
  log "Installing metrics-server (required for the CPU-based 'normal' HPA)"
  if kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
    info "metrics-server already installed"
  else
    confirm_run kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
  fi
  log "Waiting for metrics-server to become available"
  kubectl rollout status deployment/metrics-server -n kube-system --timeout=180s \
    || warn "metrics-server not ready yet; CPU metrics may lag for the normal HPA"
}

# ----------------------------------------------------------------------------
# Step 10c — Normal HPA (classic autoscaling/v1, CPU-based)
# ----------------------------------------------------------------------------
# This is the "plain" HPA: it scales backend on CPU utilization only. It's shown
# first to contrast with the KEDA autoscaling/v2 HPA that follows. Because two
# HPAs can't own the same Deployment, this one is removed when KEDA takes over.
setup_normal_hpa() {
  log "Creating the 'normal' HPA (autoscaling/v1, CPU-based) on backend"
  local hpa_manifest
  hpa_manifest="$(cat <<EOF
apiVersion: autoscaling/v1
kind: HorizontalPodAutoscaler
metadata:
  name: ${NORMAL_HPA_NAME}
  namespace: default
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: backend
  minReplicas: ${HPA_MIN}
  maxReplicas: ${HPA_MAX}
  targetCPUUtilizationPercentage: ${NORMAL_HPA_CPU_PCT}
EOF
)"
  confirm_apply "Normal CPU HPA ${NORMAL_HPA_NAME} (autoscaling/v1)" "$hpa_manifest"

  # Wait until the HPA can actually read CPU (TARGETS shows "<pct>%/..") rather
  # than "<unknown>/.." while metrics-server gathers its first samples.
  wait_for 120 10 "%/" \
    kubectl get hpa "$NORMAL_HPA_NAME" -n default --no-headers \
    || info "CPU target still <unknown> (metrics-server warming up); continuing"
  info "Current 'normal' HPA:"
  kubectl get hpa "$NORMAL_HPA_NAME" -n default || true
  info "This classic v1 HPA scales on CPU only. Next we hand backend over to KEDA"
  info "for an autoscaling/v2 HPA driven by a VPC Lattice business metric (no CPU)."
}

# ----------------------------------------------------------------------------
# Step 10d — KEDA install + IAM (CloudWatch read via EKS Pod Identity)
# ----------------------------------------------------------------------------
install_keda() {
  log "Installing KEDA (Helm) into namespace ${KEDA_NAMESPACE}"
  helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
  helm repo update kedacore >/dev/null 2>&1 || helm repo update >/dev/null 2>&1 || true

  if helm status keda -n "$KEDA_NAMESPACE" >/dev/null 2>&1; then
    info "KEDA release already installed"
  else
    local ver_args=()
    [[ -n "$KEDA_CHART_VERSION" ]] && ver_args=(--version "$KEDA_CHART_VERSION")
    confirm_run helm install keda kedacore/keda \
      --namespace "$KEDA_NAMESPACE" --create-namespace "${ver_args[@]}"
  fi

  log "Waiting for KEDA CRDs and operator to be ready"
  kubectl wait --for=condition=established --timeout=120s \
    crd/scaledobjects.keda.sh crd/triggerauthentications.keda.sh 2>/dev/null || true
  kubectl rollout status deployment -n "$KEDA_NAMESPACE" --timeout=180s || true

  # --- IAM: let the KEDA operator read CloudWatch via EKS Pod Identity ---------
  log "Granting the KEDA operator CloudWatch read access (IAM + Pod Identity)"
  export KEDA_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${KEDA_POLICY_NAME}"
  if ! aws iam get-policy --policy-arn "$KEDA_POLICY_ARN" >/dev/null 2>&1; then
    cat > keda-cloudwatch-policy.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["cloudwatch:GetMetricData", "cloudwatch:ListMetrics", "cloudwatch:GetMetricStatistics"],
      "Resource": "*" }
  ]
}
JSON
    confirm_run aws iam create-policy --policy-name "$KEDA_POLICY_NAME" \
      --policy-document file://keda-cloudwatch-policy.json --region "$AWS_REGION" >/dev/null
    info "Created KEDA CloudWatch policy"
  else
    info "KEDA CloudWatch policy already exists"
  fi

  if ! aws iam get-role --role-name "$KEDA_ROLE_NAME" >/dev/null 2>&1; then
    cat > keda-pod-identity-trust.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Principal": { "Service": "pods.eks.amazonaws.com" },
      "Action": ["sts:AssumeRole", "sts:TagSession"] }
  ]
}
JSON
    confirm_run aws iam create-role --role-name "$KEDA_ROLE_NAME" \
      --assume-role-policy-document file://keda-pod-identity-trust.json \
      --description "CloudWatch read role for the KEDA operator (VPC Lattice autoscaling)" >/dev/null
    confirm_run aws iam attach-role-policy --role-name "$KEDA_ROLE_NAME" --policy-arn "$KEDA_POLICY_ARN"
    info "Created KEDA role and attached policy"
  else
    info "KEDA role already exists"
  fi
  export KEDA_ROLE_ARN; KEDA_ROLE_ARN="$(aws iam list-roles \
    --query "Roles[?RoleName=='${KEDA_ROLE_NAME}'].Arn" --output text)"

  # KEDA runs its scalers in the operator (and, on some versions, the metrics
  # apiserver). Associate the role with every service account the KEDA
  # deployments actually use, so whichever pod queries CloudWatch has creds.
  local sas sa
  sas="$(kubectl get deploy -n "$KEDA_NAMESPACE" \
        -o jsonpath='{range .items[*]}{.spec.template.spec.serviceAccountName}{"\n"}{end}' \
        2>/dev/null | sort -u | grep -v '^$' || true)"
  [[ -z "$sas" ]] && sas="keda-operator"
  while IFS= read -r sa; do
    [[ -z "$sa" ]] && continue
    if aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
         --query "associations[?serviceAccount=='${sa}' && namespace=='${KEDA_NAMESPACE}'].associationId" \
         --output text | grep -q .; then
      info "Pod Identity association already present for SA '$sa'"
    else
      confirm_run aws eks create-pod-identity-association --cluster-name "$CLUSTER_NAME" \
        --role-arn "$KEDA_ROLE_ARN" --namespace "$KEDA_NAMESPACE" \
        --service-account "$sa" --region "$AWS_REGION" >/dev/null
      info "Created Pod Identity association for SA '$sa'"
    fi
  done <<< "$sas"

  # Restart so the Pod Identity credentials are injected into the running pods.
  confirm_run kubectl rollout restart deployment -n "$KEDA_NAMESPACE"
  kubectl rollout status deployment -n "$KEDA_NAMESPACE" --timeout=180s || true
  kubectl get pods -n "$KEDA_NAMESPACE"
}

# ----------------------------------------------------------------------------
# Step 10e — HPA v2 via KEDA (VPC Lattice ActiveConnectionCount, no CPU)
# ----------------------------------------------------------------------------
setup_keda_scaledobject() {
  log "Switching backend to an autoscaling/v2 HPA via KEDA (VPC Lattice ActiveConnectionCount)"

  # Two HPAs cannot target one Deployment. Remove the normal CPU HPA so KEDA can
  # own the scaling with its own autoscaling/v2 HPA (keda-hpa-${SCALEDOBJECT_NAME}).
  if kubectl get hpa "$NORMAL_HPA_NAME" -n default >/dev/null 2>&1; then
    info "Removing the normal CPU HPA so KEDA can take over backend"
    confirm_run kubectl delete hpa "$NORMAL_HPA_NAME" -n default
  fi

  # Resolve the target group ID — the value of the CloudWatch TargetGroup dimension.
  local tg_id
  tg_id="$(aws vpc-lattice list-target-groups --region "$AWS_REGION" \
    --query "items[?contains(name,'backend')] | [0].id" --output text 2>/dev/null || echo None)"
  [[ -n "$tg_id" && "$tg_id" != "None" ]] || die "Could not resolve backend target group ID for the KEDA metric."
  info "TargetGroup dimension value: $tg_id"

  # VPC Lattice publishes ActiveConnectionCount per-AZ (dimensions
  # AvailabilityZone + TargetGroup), so a plain single-dimension query returns
  # nothing. We use a CloudWatch Metrics Insights expression that SUMs across AZs
  # for this target group — the same aggregation the analysis script performs.
  local so_manifest
  so_manifest="$(cat <<EOF
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: ${SCALEDOBJECT_NAME}
  namespace: default
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: backend
  minReplicaCount: ${HPA_MIN}
  maxReplicaCount: ${HPA_MAX}
  pollingInterval: 30
  cooldownPeriod: 60
  advanced:
    restoreToOriginalReplicaCount: true
    horizontalPodAutoscalerConfig:
      behavior:
        scaleUp:
          stabilizationWindowSeconds: 0
        scaleDown:
          stabilizationWindowSeconds: 30
          policies:
          - type: Percent
            value: 100
            periodSeconds: 15
  triggers:
  - type: aws-cloudwatch
    metadata:
      namespace: AWS/VpcLattice
      expression: >-
        SELECT SUM(ActiveConnectionCount)
        FROM SCHEMA("AWS/VpcLattice", AvailabilityZone, TargetGroup)
        WHERE TargetGroup = '${tg_id}'
      targetMetricValue: "${KEDA_TARGET_VALUE}"
      minMetricValue: "0"
      metricStat: "Sum"
      metricStatPeriod: "60"
      metricCollectionTime: "300"
      metricUnit: "Count"
      awsRegion: "${AWS_REGION}"
      # identityOwner: operator -> KEDA uses the operator's own (Pod Identity)
      # credentials. Deprecated in KEDA 2.13+ but still functional; the modern
      # alternative is a TriggerAuthentication with podIdentity.provider: aws.
      identityOwner: operator
EOF
)"
  confirm_apply "ScaledObject ${SCALEDOBJECT_NAME} (ActiveConnectionCount, no CPU trigger)" "$so_manifest"

  log "Waiting for KEDA to create the autoscaling/v2 HPA"
  wait_for 120 10 "keda-hpa-${SCALEDOBJECT_NAME}" \
    kubectl get hpa -n default -o name \
    || warn "KEDA HPA not visible yet; check: kubectl describe scaledobject ${SCALEDOBJECT_NAME} -n default"

  info "ScaledObject + KEDA HPA:"
  kubectl get scaledobject "$SCALEDOBJECT_NAME" -n default || true
  kubectl get hpa "keda-hpa-${SCALEDOBJECT_NAME}" -n default || true
  info "HPA apiVersion + metric (should be autoscaling/v2 with a single External metric):"
  kubectl get hpa "keda-hpa-${SCALEDOBJECT_NAME}" -n default \
    -o jsonpath='{"      "}{.apiVersion}{"  metrics="}{range .spec.metrics[*]}{.type}/{.external.metric.name}{" "}{end}{"\n"}' 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# Step 10f — HPA v2 demo: drive the business metric and watch scaling
# ----------------------------------------------------------------------------
# Holds many connections open against httpbin's /delay endpoint to inflate the
# VPC Lattice ActiveConnectionCount, which KEDA feeds to the autoscaling/v2 HPA.
run_hpa_demo() {
  log "HPA v2 demo: drive VPC Lattice ActiveConnectionCount and watch backend scale"

  local hpa="keda-hpa-${SCALEDOBJECT_NAME}"

  # Single consent gate for the whole (optional, load-generating) demo.
  _msg_tty $'\n'"${C_CMD}\$ # HPA demo: run load generator (${LOADGEN_WORKERS} held-open conns via /delay/10), watch ${hpa} scale ${HPA_MIN} -> up -> ${HPA_MIN}${C_OFF}"$'\n'
  if ! _consent; then
    warn "Skipped HPA demo. Run it later by driving load at http://${BACKEND_DNS:-<dns>}/delay/10 and watching: kubectl get hpa ${hpa} -n default -w"
    return 0
  fi

  [[ -n "${BACKEND_DNS:-}" ]] || die "BACKEND_DNS is unset; cannot run the load demo."

  log "Starting in-cluster load generator (${LOADGEN_WORKERS} workers holding connections open)"
  # Unquoted heredoc: \${LOADGEN_WORKERS} and \${BACKEND_DNS} expand here; the
  # container-side loop variable \$n is escaped so it stays literal for /bin/sh.
  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${LOADGEN_NAME}
  namespace: default
  labels:
    app: ${LOADGEN_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${LOADGEN_NAME}
  template:
    metadata:
      labels:
        app: ${LOADGEN_NAME}
    spec:
      containers:
      - name: loadgen
        image: curlimages/curl:latest
        command: ["/bin/sh","-c"]
        args:
        - |
          echo "loadgen: ${LOADGEN_WORKERS} workers -> http://${BACKEND_DNS}/delay/10";
          n=0;
          while [ \$n -lt ${LOADGEN_WORKERS} ]; do
            ( while true; do curl -s -o /dev/null --max-time 20 "http://${BACKEND_DNS}/delay/10" || true; done ) &
            n=\$((n+1));
          done;
          wait
EOF
  kubectl rollout status deployment/"$LOADGEN_NAME" -n default --timeout=120s || true

  log "Watching for scale-OUT (up to ${LOADGEN_SCALEOUT_WAIT}s; CloudWatch has ~1-2 min lag)"
  local elapsed=0 reps
  while (( elapsed < LOADGEN_SCALEOUT_WAIT )); do
    reps="$(kubectl get deployment backend -n default -o jsonpath='{.status.replicas}' 2>/dev/null || echo '?')"
    printf '\r    t=%3ds  backend replicas=%s   ' "$elapsed" "$reps"
    kubectl get hpa "$hpa" -n default --no-headers 2>/dev/null \
      | awk '{printf "hpa targets=%s replicas=%s", $3, $6}' || true
    if [[ "$reps" =~ ^[0-9]+$ ]] && (( reps > HPA_MIN )); then
      printf '\n'; info "Scaled OUT to ${reps} replicas"; break
    fi
    sleep 15; elapsed=$((elapsed+15))
  done
  printf '\n'
  kubectl get hpa "$hpa" -n default || true
  kubectl get pods -l app=backend -n default || true
  kubectl top pods -l app=backend -n default || true

  log "Stopping load (scaling the generator to 0)"
  kubectl scale deployment "$LOADGEN_NAME" -n default --replicas=0 || true

  log "Watching for scale-IN back toward ${HPA_MIN} (up to ${LOADGEN_SCALEIN_WAIT}s)"
  elapsed=0
  while (( elapsed < LOADGEN_SCALEIN_WAIT )); do
    reps="$(kubectl get deployment backend -n default -o jsonpath='{.status.replicas}' 2>/dev/null || echo '?')"
    printf '\r    t=%3ds  backend replicas=%s   ' "$elapsed" "$reps"
    if [[ "$reps" =~ ^[0-9]+$ ]] && (( reps <= HPA_MIN )); then
      printf '\n'; info "Scaled IN to ${reps} replicas"; break
    fi
    sleep 15; elapsed=$((elapsed+15))
  done
  printf '\n'
  kubectl get hpa "$hpa" -n default || true
  info "Demo complete. Load generator left at 0 replicas (removed by cleanup)."
}

# ----------------------------------------------------------------------------
# Step 11 — Bedrock model check
# ----------------------------------------------------------------------------
check_bedrock() {
  log "Checking Bedrock inference-profile availability"
  local avail
  avail="$(aws bedrock list-inference-profiles --region "$AWS_REGION" \
    --query "inferenceProfileSummaries[?inferenceProfileId=='${BEDROCK_MODEL_ID}'].inferenceProfileId | [0]" \
    --output text 2>/dev/null || echo None)"
  if [[ "$avail" == "None" || -z "$avail" ]]; then
    warn "Model '$BEDROCK_MODEL_ID' not found among your inference profiles."
    warn "Available anthropic profiles:"
    aws bedrock list-inference-profiles --region "$AWS_REGION" \
      --query "inferenceProfileSummaries[?contains(inferenceProfileId,'anthropic')].inferenceProfileId" \
      --output table 2>/dev/null || true
    warn "If empty, grant access in the Bedrock console (Model catalog -> Anthropic model -> submit use-case form),"
    warn "then re-run with:  BEDROCK_MODEL_ID=<a listed us.* profile> $0"
  else
    info "Model available: $avail"
  fi
}

# ----------------------------------------------------------------------------
# Step 12 / 13 — Analysis script + run
# ----------------------------------------------------------------------------
write_and_run_analysis() {
  log "Writing analyze_lattice_metrics.py"
  cd "$WORKDIR"
  cat > analyze_lattice_metrics.py <<PYEOF
import boto3
import json
from datetime import datetime, timedelta, timezone

REGION = "${AWS_REGION}"
METRICS_NAMESPACE = "AWS/VpcLattice"
LOOKBACK_MINUTES = 30
MODEL_ID = "${BEDROCK_MODEL_ID}"

cloudwatch = boto3.client("cloudwatch", region_name=REGION)
bedrock = boto3.client("bedrock-runtime", region_name=REGION)

def get_target_groups():
    lattice = boto3.client("vpc-lattice", region_name=REGION)
    tgs = lattice.list_target_groups().get("items", [])
    return [(tg["name"], tg["id"]) for tg in tgs]

def collect_metrics_for_tg(tg_id):
    end_time = datetime.now(timezone.utc)
    start_time = end_time - timedelta(minutes=LOOKBACK_MINUTES)
    specs = {
        "TotalRequestCount": ("TotalRequestCount", "Sum", "SUM"),
        "2xx_Count":         ("HTTPCode_2XX_Count", "Sum", "SUM"),
        "4xx_Count":         ("HTTPCode_4XX_Count", "Sum", "SUM"),
        "5xx_Count":         ("HTTPCode_5XX_Count", "Sum", "SUM"),
        "RequestTime_ms":    ("RequestTime", "Average", "AVG"),
        "ConnectionTimeoutCount": ("ConnectionTimeoutCount", "Sum", "SUM"),
    }
    queries, label_map = [], {}
    for i, (key, (mname, stat, agg)) in enumerate(specs.items()):
        sid, eid = f"s{i}", f"e{i}"
        label_map[eid] = key
        expr = (f"SEARCH('{{{METRICS_NAMESPACE},AvailabilityZone,TargetGroup}} "
                f"MetricName=\"{mname}\" TargetGroup=\"{tg_id}\"', '{stat}', 300)")
        queries.append({"Id": sid, "Expression": expr, "ReturnData": False})
        queries.append({"Id": eid, "Expression": f"{agg}({sid})", "ReturnData": True})
    resp = cloudwatch.get_metric_data(
        MetricDataQueries=queries, StartTime=start_time, EndTime=end_time,
        ScanBy="TimestampAscending")
    result = {}
    for r in resp["MetricDataResults"]:
        key = label_map.get(r["Id"])
        if key is None:
            continue
        vals = r.get("Values", [])
        if not vals:
            result[key] = None
        elif key == "RequestTime_ms":
            result[key] = round(sum(vals) / len(vals), 3)
        else:
            result[key] = round(sum(vals), 3)
    return result

def collect_metrics():
    return {name: collect_metrics_for_tg(tg_id) for name, tg_id in get_target_groups()}

def format_metrics_for_prompt(metrics):
    lines = ["VPC Lattice CloudWatch Metrics Report",
             f"Time window: last {LOOKBACK_MINUTES} minutes", ""]
    for name, data in metrics.items():
        lines.append(f"Target Group: {name}")
        for k, v in data.items():
            lines.append(f"  {k}: {'no data' if v is None else v}")
        lines.append("")
    return "\n".join(lines)

def analyze_with_bedrock(metrics_text):
    prompt = f"""You are a cloud infrastructure reliability engineer.
Below are CloudWatch metrics from an AWS VPC Lattice service mesh deployment.

Analyze the metrics and provide:
1. A brief summary of the current health of the services
2. Any anomalies or concerns (high error rates, elevated latency, zero traffic)
3. Recommendations for the operations team

{metrics_text}

Provide a clear, concise analysis suitable for a daily ops standup."""
    body = json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 1024,
        "messages": [{"role": "user", "content": prompt}],
    })
    response = bedrock.invoke_model(
        modelId=MODEL_ID, contentType="application/json",
        accept="application/json", body=body)
    return json.loads(response["body"].read())["content"][0]["text"]

def main():
    print("Collecting VPC Lattice metrics from CloudWatch...")
    metrics = collect_metrics()
    if not metrics:
        print("No target groups found.")
        return
    text = format_metrics_for_prompt(metrics)
    print("\n--- Raw Metrics Collected ---")
    print(text)
    print("\n--- Sending to Amazon Bedrock for Analysis ---")
    print("\n--- Bedrock Analysis ---")
    print(analyze_with_bedrock(text))

if __name__ == "__main__":
    main()
PYEOF

  # Running the analysis invokes Bedrock (incurs cost), so gate it. Declining
  # skips the wait + run entirely; the script file is still written for later.
  _msg_tty $'\n'"${C_CMD}\$ sleep 120 && python3 ${WORKDIR}/analyze_lattice_metrics.py   # wait for metrics, then invoke Bedrock${C_OFF}"$'\n'
  if _consent; then
    log "Waiting 120s for VPC Lattice metrics to land in CloudWatch"
    sleep 120
    log "Running analysis"
    python3 analyze_lattice_metrics.py || warn "Analysis failed — see error above (common causes: Bedrock model access, or metrics still populating; re-run: python3 $WORKDIR/analyze_lattice_metrics.py)"
  else
    warn "Skipped analysis run. Re-run any time: python3 $WORKDIR/analyze_lattice_metrics.py"
  fi
}

# ----------------------------------------------------------------------------
# Cleanup  (NEVER gated — runs unattended by design)
# ----------------------------------------------------------------------------
cleanup() {
  log "Tearing down (best-effort; ignores 'not found' errors)"
  install_tools
  aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" 2>/dev/null || true
  VPC_ID="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || echo None)"

  # --- Autoscaling / KEDA demo teardown ---------------------------------------
  kubectl delete deployment "$LOADGEN_NAME" -n default --ignore-not-found
  kubectl delete scaledobject "$SCALEDOBJECT_NAME" -n default --ignore-not-found
  kubectl delete hpa "$NORMAL_HPA_NAME" -n default --ignore-not-found
  helm uninstall keda -n "$KEDA_NAMESPACE" 2>/dev/null || true
  kubectl delete namespace "$KEDA_NAMESPACE" --ignore-not-found 2>/dev/null || true
  kubectl delete -f "https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml" \
    --ignore-not-found 2>/dev/null || true

  # KEDA IAM: pod identity associations (by namespace), role, policy
  aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query "associations[?namespace=='${KEDA_NAMESPACE}'].associationId" --output text 2>/dev/null \
    | tr '\t' '\n' | while read -r aid; do
        [[ -n "$aid" ]] && aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" \
          --association-id "$aid" --region "$AWS_REGION" 2>/dev/null || true
      done
  KEDA_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${KEDA_POLICY_NAME}"
  aws iam detach-role-policy --role-name "$KEDA_ROLE_NAME" --policy-arn "$KEDA_POLICY_ARN" 2>/dev/null || true
  aws iam delete-role --role-name "$KEDA_ROLE_NAME" 2>/dev/null || true
  aws iam delete-policy --policy-arn "$KEDA_POLICY_ARN" 2>/dev/null || true

  kubectl delete targetgrouppolicy backend-tgp -n default --ignore-not-found
  kubectl delete vpcassociationpolicy lattice-vpc-assoc-policy -n default --ignore-not-found
  kubectl delete httproute backend-route -n default --ignore-not-found
  kubectl delete gateway "$GATEWAY_NAME" -n default --ignore-not-found
  kubectl delete gatewayclass amazon-vpc-lattice --ignore-not-found
  kubectl delete deployment frontend backend -n default --ignore-not-found
  kubectl delete svc frontend-svc backend-svc -n default --ignore-not-found
  info "Waiting 30s for controller to release Lattice resources"; sleep 30

  SERVICE_NETWORK_ID="$(aws vpc-lattice list-service-networks --region "$AWS_REGION" \
    --query "items[?name=='${SERVICE_NETWORK_NAME}'].id | [0]" --output text 2>/dev/null || echo None)"
  if [[ "$SERVICE_NETWORK_ID" != "None" && -n "$SERVICE_NETWORK_ID" ]]; then
    aws vpc-lattice list-service-network-vpc-associations \
      --service-network-identifier "$SERVICE_NETWORK_ID" --region "$AWS_REGION" \
      --query 'items[].id' --output text 2>/dev/null | tr '\t' '\n' | while read -r a; do
        [[ -n "$a" ]] && aws vpc-lattice delete-service-network-vpc-association \
          --service-network-vpc-association-identifier "$a" --region "$AWS_REGION" 2>/dev/null || true
      done
    sleep 20
    aws vpc-lattice delete-service-network \
      --service-network-identifier "$SERVICE_NETWORK_ID" --region "$AWS_REGION" 2>/dev/null || true
  fi

  ASSOC_ID="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query "associations[?serviceAccount=='${SA_NAME}'].associationId" --output text 2>/dev/null || echo)"
  [[ -n "$ASSOC_ID" ]] && aws eks delete-pod-identity-association \
    --cluster-name "$CLUSTER_NAME" --association-id "$ASSOC_ID" --region "$AWS_REGION" 2>/dev/null || true

  POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
  aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true
  aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null || true

  log "Deleting EKS cluster (this also removes node group and the pod-identity-agent addon)"
  eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" || true
  log "Cleanup complete"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
  install_tools
  create_cluster
  ensure_pod_identity_agent
  setup_security_groups
  setup_iam_and_controller
  create_service_network
  create_gateway
  deploy_workloads
  create_route
  test_and_traffic
  install_metrics_server
  setup_normal_hpa
  install_keda
  setup_keda_scaledobject
  run_hpa_demo
  check_bedrock
  write_and_run_analysis

  log "DONE"
  cat <<SUMMARY

  Backend DNS : ${BACKEND_DNS:-<unknown>}
  Analysis    : python3 ${WORKDIR}/analyze_lattice_metrics.py   (re-run any time)

  Autoscaling:
    Normal HPA : ${NORMAL_HPA_NAME} (autoscaling/v1, CPU) — created for the demo, then replaced by KEDA
    HPA v2     : keda-hpa-${SCALEDOBJECT_NAME} (autoscaling/v2) scales backend on
                 VPC Lattice ActiveConnectionCount (min ${HPA_MIN}, max ${HPA_MAX}, target ${KEDA_TARGET_VALUE}/replica)
    Watch      : kubectl get hpa keda-hpa-${SCALEDOBJECT_NAME} -n default -w
    Re-run demo: kubectl scale deployment ${LOADGEN_NAME} -n default --replicas=1   # then watch the HPA
                 kubectl scale deployment ${LOADGEN_NAME} -n default --replicas=0   # stop the load

  Manual test:
    FRONTEND_POD=\$(kubectl get pod -l app=frontend -n default -o jsonpath='{.items[0].metadata.name}')
    kubectl exec -it \$FRONTEND_POD -n default -- curl -s http://${BACKEND_DNS:-<dns>}/get

  Tear everything down with:
    $0 cleanup

SUMMARY
}

# ----------------------------------------------------------------------------
# Argument parsing / dispatch
#   -y | --yes : auto-approve every build-path consent prompt
#   cleanup    : tear everything down (never gated)
# ----------------------------------------------------------------------------
SUBCOMMAND="main"
while (($#)); do
  case "$1" in
    -y|--yes)  ASSUME_YES=true ;;
    cleanup)   SUBCOMMAND="cleanup" ;;
    -h|--help) print_usage; exit 0 ;;
    *)         die "Unknown argument: $1 (use -h for help)" ;;
  esac
  shift
done

case "$SUBCOMMAND" in
  cleanup) cleanup ;;
  main)    main ;;
esac
