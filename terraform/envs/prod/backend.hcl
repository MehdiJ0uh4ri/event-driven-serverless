# Partial backend config: terraform init -backend-config=envs/prod/backend.hcl
bucket       = "order-platform-tfstate-CHANGEME"
key          = "prod/terraform.tfstate"
region       = "eu-west-1"
encrypt      = true
use_lockfile = true
