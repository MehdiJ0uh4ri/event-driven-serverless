.DEFAULT_GOAL := help
SHELL := /bin/bash

ENV        ?= dev
TF         := terraform -chdir=terraform
TFVARS     := envs/$(ENV)/terraform.tfvars
BACKEND    := envs/$(ENV)/backend.hcl
SAMPLES    ?= 20
PROFILE    ?= tools/profiles/$(ENV).json

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# --- build ------------------------------------------------------------------

.PHONY: build
build: ## Build all deployment artefacts into dist/
	./scripts/build.sh

.PHONY: clean
clean: ## Remove build artefacts
	rm -rf dist src/nodejs/node_modules

# --- test -------------------------------------------------------------------

.PHONY: test
test: test-node test-python ## Run every unit test

.PHONY: test-node
test-node: ## Node unit tests
	cd src/nodejs && node --test tests/

.PHONY: test-python
test-python: ## Python unit tests (audit consumer + cost model)
	python -m pytest src/python/tests tools/tests -q

.PHONY: lint
lint: ## Format check + validate the IaC
	terraform fmt -check -recursive
	$(TF) init -backend=false && $(TF) validate
	@command -v tflint >/dev/null && tflint --recursive --chdir=terraform || echo "tflint not installed, skipping"

.PHONY: fmt
fmt: ## Auto-format the Terraform
	terraform fmt -recursive

# --- deploy -----------------------------------------------------------------

.PHONY: init
init: ## terraform init for $(ENV)
	$(TF) init -backend-config=$(BACKEND)

.PHONY: plan
plan: build ## Build, then plan $(ENV)
	$(TF) plan -var-file=$(TFVARS)

.PHONY: apply
apply: build ## Build, then apply $(ENV)
	$(TF) apply -var-file=$(TFVARS)

.PHONY: destroy
destroy: ## Tear down $(ENV)
	$(TF) destroy -var-file=$(TFVARS)

.PHONY: output
output: ## Write terraform outputs to tf-output.json
	$(TF) output -json > tf-output.json
	@echo "wrote tf-output.json"

# --- SAM (the alternative IaC path) -----------------------------------------

.PHONY: sam-build
sam-build: ## sam build
	sam build --template sam/template.yaml

.PHONY: sam-deploy
sam-deploy: sam-build ## sam deploy --guided
	sam deploy --guided --template sam/template.yaml \
		--parameter-overrides Environment=$(ENV)

.PHONY: sam-local
sam-local: sam-build ## Invoke createOrder locally
	sam local invoke CreateOrderFunction \
		--event events/create_order.json \
		--template sam/template.yaml

# --- verification & analysis ------------------------------------------------

.PHONY: smoke
smoke: output ## End-to-end smoke test against the deployed $(ENV) stack
	python tools/smoke_test.py --terraform-output tf-output.json

.PHONY: cost
cost: ## Project the monthly cost for $(ENV)
	python tools/cost_model.py --profile $(PROFILE) --format table

.PHONY: cost-ci
cost-ci: output ## Cost projection against the live stack, failing on breach
	python tools/cost_model.py \
		--terraform-output tf-output.json \
		--profile $(PROFILE) \
		--fail-on-breach

.PHONY: bench
bench: ## Cold-start benchmark sweep ($(SAMPLES) samples per function)
	python tools/coldstart_benchmark.py --discover --samples $(SAMPLES)

.PHONY: bench-report
bench-report: ## Sweep and write docs/benchmarks.md
	python tools/coldstart_benchmark.py --discover --samples $(SAMPLES) \
		--format markdown --output docs/benchmarks.md

.PHONY: dashboard
dashboard: ## Open the CloudWatch dashboard
	@python -c "import json,webbrowser,subprocess; \
		out=json.loads(subprocess.check_output(['terraform','-chdir=terraform','output','-json'])); \
		webbrowser.open(out['dashboard_url']['value'])"

.PHONY: logs
logs: ## Tail the create-order function logs
	aws logs tail /aws/lambda/order-platform-$(ENV)-create-order --follow --format short

.PHONY: trace
trace: ## Follow one request end to end: make trace CID=<correlation-id>
	@test -n "$(CID)" || (echo "usage: make trace CID=<correlation-id>" && exit 1)
	aws logs start-query \
		--log-group-names $$(aws logs describe-log-groups \
			--log-group-name-prefix /aws/lambda/order-platform-$(ENV) \
			--query 'logGroups[].logGroupName' --output text) \
		--start-time $$(( $$(date +%s) - 3600 )) \
		--end-time $$(date +%s) \
		--query-string 'fields @timestamp, function_name, message, correlationId | filter correlationId = "$(CID)" | sort @timestamp asc'
