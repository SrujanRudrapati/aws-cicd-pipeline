#!/usr/bin/env bash
# Push a verified local image to ECR.
#
#   scripts/ci/push_image.sh <local-image> <tag>
#
# The repository uses immutable tags, so re-running the pipeline for a commit
# that is already pushed skips the push instead of failing on it.
# Env: ECR_REPOSITORY (required), AWS_REGION.
set -euo pipefail

local_image="${1:?usage: push_image.sh <local-image> <tag>}"
tag="${2:?usage: push_image.sh <local-image> <tag>}"
: "${ECR_REPOSITORY:?set ECR_REPOSITORY to the ecr_repository_name output of terraform/bootstrap}"
region="${AWS_REGION:-us-east-1}"

repo_uri="$(aws ecr describe-repositories --region "$region" \
  --repository-names "$ECR_REPOSITORY" \
  --query 'repositories[0].repositoryUri' --output text)"

if aws ecr describe-images --region "$region" --repository-name "$ECR_REPOSITORY" \
  --image-ids imageTag="$tag" >/dev/null 2>&1; then
  echo "$repo_uri:$tag already exists; skipping push (tags are immutable)"
  exit 0
fi

aws ecr get-login-password --region "$region" |
  docker login --username AWS --password-stdin "${repo_uri%%/*}"

docker tag "$local_image" "$repo_uri:$tag"
docker push "$repo_uri:$tag"
echo "pushed $repo_uri:$tag"
