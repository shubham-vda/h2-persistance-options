# Employee mock service — persistent H2 on ECS via EFS

## The problem

The client's mock service runs on ECS, with one instance spun up per QA
engineer. Because ECS tasks have ephemeral local disk, every redeploy wipes
whatever the QA had stored in the H2 database — they lose their test data
and have to rebuild it from scratch.

## The approach: EFS, not S3

An earlier iteration of this proof-of-concept explored backing up the H2
file to S3 and restoring it on startup (see the `main` branch). That works,
but it means:
- writing and maintaining backup/restore code in the app itself,
- a recovery-point window (data since the last backup can be lost on a hard
  kill), and
- one S3 bucket-per-instance would be an anti-pattern — buckets are
  slow-to-create, account-wide resources with a default 100/account limit.

**EFS is a better fit for this specific problem.** It's a real POSIX
filesystem that ECS Fargate mounts directly into the task
(`efsVolumeConfiguration`), so the H2 file just lives there and survives
redeploys — no backup/restore code needed at all. Per-QA isolation comes
from **EFS Access Points**: one shared filesystem, with each QA getting
their own access point scoped to their own subdirectory (`/qa-instances/<qa-id>`)
and their own POSIX permissions. That avoids resource sprawl (one filesystem,
not one per QA) while still keeping each QA's data separate.

| | S3 backup/restore | EFS (this branch) |
|---|---|---|
| App code changes | Yes — scheduled backup, restore-on-startup listener | None — just point the JDBC URL's file path at the mount |
| Data loss on hard kill | Up to the backup interval | None — writes go straight to persistent storage |
| Per-instance resource | N/A (shared bucket + key prefix) | One lightweight Access Point per QA (shared filesystem) |
| Relative cost | Lower (S3 storage) | Slightly higher (EFS), negligible at this scale |

## What changed in the app

- `application.properties`: the datasource URL now reads its data directory
  from `DB_DATA_DIR` (defaults to `./data` locally). In ECS, the task
  definition sets `DB_DATA_DIR=/data`, which is where the EFS volume is
  mounted.
- Added Spring Boot Actuator's health endpoint (`/actuator/health`) for the
  ECS task definition's container health check.
- Removed the S3 backup/restore code from `main` — it's unnecessary once the
  filesystem itself is persistent.

Everything else (the `Employee` entity, `POST/GET /api/employees`) is
unchanged.

## Infrastructure

```
infra/
├── terraform-shared/         # one-time, mostly-static infra
│   ├── main.tf                 EFS filesystem + mount targets, ECS cluster,
│   │                           execution/task IAM roles, log group
│   ├── variables.tf
│   └── outputs.tf
├── ecs/
│   └── task-definition.template.json   rendered per QA by the script below
└── scripts/
    ├── provision-qa-instance.sh   creates a QA's access point + service (idempotent)
    └── teardown-qa-instance.sh    tears a QA's service down; data kept unless --delete-data
```

### One-time setup

```
cd infra/terraform-shared
terraform init
terraform apply \
  -var vpc_id=<vpc-id> \
  -var 'private_subnet_ids=["subnet-aaa","subnet-bbb"]' \
  -var ecs_tasks_security_group_id=<existing-tasks-sg>
```

This creates the shared EFS filesystem, the ECS cluster, IAM roles, and a
CloudWatch log group. It's run once (or whenever the shared infra changes),
not per QA.

### Per-QA instance (the "on the fly" part)

Whatever already triggers spinning up a new QA's mock instance today (CI
job, internal tool) calls:

```
export AWS_REGION=us-east-1
export EFS_FILE_SYSTEM_ID=<from terraform output>
export ECS_CLUSTER=<from terraform output>
export EXECUTION_ROLE_ARN=<from terraform output>
export TASK_ROLE_ARN=<from terraform output>
export LOG_GROUP=<from terraform output>
export IMAGE_URI=<ecr-repo>:<tag>
export SUBNET_IDS=subnet-aaa,subnet-bbb
export SECURITY_GROUP_ID=<existing-tasks-sg>

./infra/scripts/provision-qa-instance.sh <qa-id>
```

This creates (or reuses) an EFS Access Point rooted at `/qa-instances/<qa-id>`,
registers a task definition (`mock-svc-<qa-id>`) that mounts it at `/data`,
and creates (or updates, on redeploy) an ECS service running it. Re-running
it for the same QA — e.g. on every redeploy — reuses their existing access
point, so their data comes right back.

`teardown-qa-instance.sh <qa-id>` stops and removes that QA's service; pass
`--delete-data` to also delete their access point and data once they're done
with the engagement.

## Status / what's not yet verified

This branch was built and its Java changes were run and tested locally
(`mvn package`, hit both endpoints, confirmed data survives a restart). The
Terraform was `terraform validate`d and the ECS task definition template was
rendered and checked as valid JSON, but **the actual AWS resources
(EFS, ECS task/service, access points) have not been applied or tested
against a real AWS account** — there's no AWS access from this environment.
Before rolling this out, run `terraform apply` and the provisioning script
against a real (ideally non-prod) VPC/cluster and confirm a task can mount
the access point and that data survives a `provision-qa-instance.sh` re-run
after a task replacement.
