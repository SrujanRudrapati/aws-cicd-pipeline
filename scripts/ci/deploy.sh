#!/usr/bin/env bash
# Deploy one image tag to one environment: plan -> apply -> smoke test.
#
#   IMAGE_TAG=<git-sha> scripts/ci/deploy.sh <dev|prod>
#   PLAN_ONLY=1 IMAGE_TAG=<git-sha> scripts/ci/deploy.sh prod     # review only
#
# The image tag is the only input that changes between releases. It lands in
# the launch template's user data, so a new tag = a new launch template version
# = a rolling instance refresh (see terraform/modules/compute). Terraform fails
# at plan time if the tag was never pushed to ECR.
set -euo pipefail

env="${1:?usage: deploy.sh <dev|prod>}"
case "$env" in
  dev | prod) ;;
  *)
    echo "deploy.sh: unknown environment '$env' (expected dev or prod)" >&2
    exit 64
    ;;
esac
: "${IMAGE_TAG:?IMAGE_TAG must be set to the image tag (git SHA) to deploy}"
if ! [[ "$IMAGE_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
  echo "deploy.sh: '$IMAGE_TAG' is not a valid image tag" >&2
  exit 64
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
reports="$root/reports"
mkdir -p "$reports"

tf() { bash "$here/tf.sh" "$env" "$@"; }
summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$*" >>"$GITHUB_STEP_SUMMARY"; fi; }

export TF_VAR_image_tag="$IMAGE_TAG"
export TF_IN_AUTOMATION=1

echo "==> [$env] plan for image $IMAGE_TAG"
set +e
tf plan -input=false -no-color -var-file="env/$env.tfvars" -out=tfplan -detailed-exitcode |
  tee "$reports/plan-$env.log"
plan_rc=${PIPESTATUS[0]}
set -e

case "$plan_rc" in
  0) changes=false ;;
  2) changes=true ;;
  *)
    echo "deploy.sh: terraform plan failed (exit $plan_rc)" >&2
    exit "$plan_rc"
    ;;
esac

plan_line="$(grep -E '^(Plan:|No changes\.)' "$reports/plan-$env.log" | tail -1 || true)"
summary "### $env: \`${IMAGE_TAG}\`"
summary ""
summary "- Terraform: ${plan_line:-see plan log}"

if [ "${PLAN_ONLY:-0}" = "1" ]; then
  echo "==> [$env] PLAN_ONLY=1, stopping before apply"
  exit 0
fi

export TF_SKIP_INIT=1
if [ "$changes" = true ]; then
  echo "==> [$env] apply"
  tf apply -input=false -no-color tfplan
else
  echo "==> [$env] no infrastructure changes; verifying what is already running"
fi

app_url="$(tf output -raw app_url)"
asg_name="$(tf output -raw asg_name)"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "app_url=$app_url" >>"$GITHUB_OUTPUT"
fi
tf output -json environment_summary >"$reports/environment-$env.json"

echo "==> [$env] smoke test $app_url"
APP_URL="$app_url" ASG_NAME="$asg_name" EXPECTED_VERSION="$IMAGE_TAG" \
  bash "$here/smoke_test.sh"

summary "- Live at: $app_url"
echo "==> [$env] deployed $IMAGE_TAG to $app_url"
