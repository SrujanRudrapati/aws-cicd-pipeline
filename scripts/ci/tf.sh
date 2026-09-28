#!/usr/bin/env bash
# Run Terraform against one environment's state.
#
#   scripts/ci/tf.sh <dev|prod> <terraform args...>
#   scripts/ci/tf.sh dev plan -var-file=env/dev.tfvars
#
# One root module (terraform/live) serves every environment; this wrapper picks
# the environment's state key (env/<env>.backend.hcl) and injects the bucket,
# which is account-specific and therefore not committed.
#
# Env: TF_STATE_BUCKET (required), AWS_REGION, ECR_REPOSITORY,
#      TERRAFORM (binary, default "terraform"), TF_SKIP_INIT=1 to reuse an init.
set -euo pipefail

env="${1:?usage: tf.sh <dev|prod> <terraform args...>}"
shift
case "$env" in
  dev | prod) ;;
  *)
    echo "tf.sh: unknown environment '$env' (expected dev or prod)" >&2
    exit 64 # not 2: `plan -detailed-exitcode` uses 2 to mean "changes present"
    ;;
esac

: "${TF_STATE_BUCKET:?set TF_STATE_BUCKET to the state_bucket output of terraform/bootstrap}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
live="$(cd "$here/../../terraform/live" && pwd)"
terraform="${TERRAFORM:-terraform}"

export AWS_REGION="${AWS_REGION:-us-east-1}"
export TF_VAR_aws_region="$AWS_REGION"
if [ -n "${ECR_REPOSITORY:-}" ]; then
  export TF_VAR_ecr_repository_name="$ECR_REPOSITORY"
fi

if [ "${TF_SKIP_INIT:-0}" != "1" ]; then
  # init output goes to stderr so `tf.sh dev output -raw x` stays clean on stdout.
  "$terraform" -chdir="$live" init -input=false -reconfigure \
    -backend-config="env/$env.backend.hcl" \
    -backend-config="bucket=$TF_STATE_BUCKET" \
    -backend-config="region=$AWS_REGION" >&2
fi

exec "$terraform" -chdir="$live" "$@"
