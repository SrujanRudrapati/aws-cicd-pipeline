# One entry point for local work and for BOTH CI systems: GitHub Actions and
# the Jenkinsfile call the same targets, so a green `make` locally means the
# same thing as a green pipeline.
#
#   make help

SHELL        := /bin/bash
.SHELLFLAGS  := -euo pipefail -c
.DEFAULT_GOAL := help

PY             ?= python3
TERRAFORM      ?= terraform
ENV            ?= dev
AWS_REGION     ?= us-east-1
IMAGE_NAME     ?= aws-cicd-pipeline-app
IMAGE_TAG      ?= $(shell git rev-parse HEAD 2>/dev/null || echo local)
ECR_REPOSITORY ?= aws-cicd-pipeline-app
# TF_STATE_BUCKET: output of terraform/bootstrap (make bootstrap-env prints it)

export AWS_REGION ECR_REPOSITORY TERRAFORM

TF_LIVE := terraform/live

.PHONY: help
help: ## List targets
	@grep -hE '^[a-z][a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------- setup

.PHONY: install install-lint
install: ## Install app + test dependencies
	$(PY) -m pip install -r app/requirements-dev.txt

install-lint: ## Install ansible-lint and shellcheck
	$(PY) -m pip install -r requirements-lint.txt

# ----------------------------------------------------------- lint & test

.PHONY: lint lint-python lint-ansible lint-shell test
lint: lint-python lint-ansible lint-shell ## All linters

lint-python: ## ruff format check + lint
	$(PY) -m ruff format --check app scripts
	$(PY) -m ruff check app scripts

lint-ansible: ## ansible-lint (production profile) + playbook syntax check
	cd ansible && ansible-lint
	cd ansible && ansible-playbook site.yml -i localhost, --syntax-check

lint-shell: ## shellcheck the CI scripts and the EC2 user-data template
	shellcheck -x scripts/ci/*.sh
	shellcheck --shell=bash terraform/modules/compute/templates/user_data.sh.tftpl

test: ## Unit tests for the app, sysdiag and loadtest (coverage + JUnit in reports/)
	@mkdir -p reports
	$(PY) -m pytest

# ------------------------------------------------------------ terraform

.PHONY: tf-fmt tf-validate
tf-fmt: ## Rewrite Terraform files into canonical format
	$(TERRAFORM) fmt -recursive terraform

tf-validate: ## fmt check, validate, and offline plan tests for dev + prod (no AWS needed)
	$(TERRAFORM) fmt -recursive -check -diff terraform
	$(TERRAFORM) -chdir=terraform/bootstrap init -backend=false -input=false >/dev/null
	$(TERRAFORM) -chdir=terraform/bootstrap validate
	$(TERRAFORM) -chdir=terraform/modules/network init -backend=false -input=false >/dev/null
	$(TERRAFORM) -chdir=terraform/modules/network test
	$(TERRAFORM) -chdir=$(TF_LIVE) init -backend=false -input=false >/dev/null
	$(TERRAFORM) -chdir=$(TF_LIVE) validate
	$(TERRAFORM) -chdir=$(TF_LIVE) test -var-file=env/dev.tfvars
	$(TERRAFORM) -chdir=$(TF_LIVE) test -var-file=env/prod.tfvars

# ---------------------------------------------------------- image

.PHONY: image verify push
image: ## Build the app image, tagged with the git SHA
	docker build -f app/Dockerfile --build-arg APP_VERSION=$(IMAGE_TAG) -t $(IMAGE_NAME):$(IMAGE_TAG) .

verify: ## Run the image, load test it, and check for leaks / regressions
	EXPECTED_VERSION=$(IMAGE_TAG) bash scripts/ci/verify_image.sh $(IMAGE_NAME):$(IMAGE_TAG)

push: ## Push the verified image to ECR (skips tags that already exist)
	bash scripts/ci/push_image.sh $(IMAGE_NAME):$(IMAGE_TAG) $(IMAGE_TAG)

# -------------------------------------------------------- environments

.PHONY: bootstrap-env plan deploy smoke destroy
bootstrap-env: ## Print the env vars the other targets need, from terraform/bootstrap outputs
	@echo "export AWS_REGION=$$($(TERRAFORM) -chdir=terraform/bootstrap output -raw aws_region)"
	@echo "export TF_STATE_BUCKET=$$($(TERRAFORM) -chdir=terraform/bootstrap output -raw state_bucket)"
	@echo "export ECR_REPOSITORY=$$($(TERRAFORM) -chdir=terraform/bootstrap output -raw ecr_repository_name)"

plan: ## Plan ENV=dev|prod for IMAGE_TAG (no changes applied)
	PLAN_ONLY=1 IMAGE_TAG=$(IMAGE_TAG) bash scripts/ci/deploy.sh $(ENV)

deploy: ## Plan, apply and smoke test ENV=dev|prod with IMAGE_TAG
	IMAGE_TAG=$(IMAGE_TAG) bash scripts/ci/deploy.sh $(ENV)

smoke: ## Re-run the post-deploy smoke test against ENV
	APP_URL=$$(bash scripts/ci/tf.sh $(ENV) output -raw app_url) \
	ASG_NAME=$$(TF_SKIP_INIT=1 bash scripts/ci/tf.sh $(ENV) output -raw asg_name) \
	EXPECTED_VERSION=$$(TF_SKIP_INIT=1 bash scripts/ci/tf.sh $(ENV) output -raw deployed_image | sed 's/.*://') \
	bash scripts/ci/smoke_test.sh

destroy: ## Tear down ENV (uses the currently deployed tag so the ECR check passes)
	tag=$$(bash scripts/ci/tf.sh $(ENV) output -raw deployed_image 2>/dev/null | sed 's/.*://'); \
	TF_SKIP_INIT=1 TF_VAR_image_tag=$${tag:-$(IMAGE_TAG)} \
	  bash scripts/ci/tf.sh $(ENV) destroy -var-file=env/$(ENV).tfvars

# ------------------------------------------------------- local stack

.PHONY: up down run
up: ## App + Postgres in Docker Compose on http://localhost:8080
	docker compose up --build -d
	@echo "http://localhost:8080/api/info"

down: ## Stop the compose stack and delete its data
	docker compose down -v

run: ## Run the app directly (in-memory storage) on http://localhost:8080
	cd app && APP_VERSION=local $(PY) -m gunicorn -c gunicorn.conf.py webapp.wsgi:app

.PHONY: clean
clean: ## Remove build, test and Terraform working files
	rm -rf reports .pytest_cache .ruff_cache .coverage ansible/.ansible
	find . -name __pycache__ -type d -prune -exec rm -rf {} +
	find terraform -name .terraform -type d -prune -exec rm -rf {} +
	rm -rf $(TF_LIVE)/.build $(TF_LIVE)/tfplan
