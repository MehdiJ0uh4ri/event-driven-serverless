# Partial backend config: terraform init -backend-config=envs/dev/backend.hcl
#
# The bucket and lock table are expected to exist already (bootstrapped once,
# out of band -- state storage should not be managed by the state it stores).
bucket       = "order-platform-tfstate-CHANGEME"
key          = "dev/terraform.tfstate"
region       = "eu-west-1"
encrypt      = true
use_lockfile = true
