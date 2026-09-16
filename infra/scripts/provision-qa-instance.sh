#!/usr/bin/env bash
# Spins up (or updates) one QA's mock-service instance: an EFS Access Point
# scoped to that QA's own directory on the shared filesystem, an ECS task
# definition wired to it, and an ECS service running it.
#
# Run once per QA, triggered by whatever already creates their mock instance
# today (CI job, internal admin tool, etc). Safe to re-run for the same
# QA_ID - the access point and service are both created idempotently.
#
# Requires: aws cli v2, jq, envsubst (gettext package). AWS credentials with
# permission to manage EFS access points, ECS task defs/services, and IAM
# PassRole for the execution/task roles.
#
# Required env vars (values come from `terraform output -json` in
# infra/terraform-shared, plus your image and networking):
#   AWS_REGION, EFS_FILE_SYSTEM_ID, ECS_CLUSTER, EXECUTION_ROLE_ARN,
#   TASK_ROLE_ARN, LOG_GROUP, IMAGE_URI, SUBNET_IDS (comma-separated),
#   SECURITY_GROUP_ID
#
# Usage: ./provision-qa-instance.sh <qa-id>

set -euo pipefail

QA_ID="${1:?Usage: $0 <qa-id>}"
: "${AWS_REGION:?}"; : "${EFS_FILE_SYSTEM_ID:?}"; : "${ECS_CLUSTER:?}"
: "${EXECUTION_ROLE_ARN:?}"; : "${TASK_ROLE_ARN:?}"; : "${LOG_GROUP:?}"
: "${IMAGE_URI:?}"; : "${SUBNET_IDS:?}"; : "${SECURITY_GROUP_ID:?}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Looking for an existing EFS access point for QA '${QA_ID}'"
ACCESS_POINT_ID="$(aws efs describe-access-points \
  --file-system-id "${EFS_FILE_SYSTEM_ID}" \
  --query "AccessPoints[?Tags[?Key=='qa-id' && Value=='${QA_ID}']].AccessPointId | [0]" \
  --output text)"

if [[ "${ACCESS_POINT_ID}" == "None" || -z "${ACCESS_POINT_ID}" ]]; then
  echo "==> None found, creating one (root dir: /qa-instances/${QA_ID})"
  ACCESS_POINT_ID="$(aws efs create-access-point \
    --file-system-id "${EFS_FILE_SYSTEM_ID}" \
    --posix-user 'Uid=1000,Gid=1000' \
    --root-directory "RootDirectory={Path=/qa-instances/${QA_ID},CreationInfo={OwnerUid=1000,OwnerGid=1000,Permissions=0755}}" \
    --tags "Key=qa-id,Value=${QA_ID}" "Key=managed-by,Value=provision-qa-instance.sh" \
    --query 'AccessPointId' --output text)"
  echo "==> Created access point ${ACCESS_POINT_ID}"
else
  echo "==> Reusing existing access point ${ACCESS_POINT_ID}"
fi

echo "==> Rendering task definition for QA '${QA_ID}'"
export QA_ID EFS_FILE_SYSTEM_ID ACCESS_POINT_ID EXECUTION_ROLE_ARN TASK_ROLE_ARN \
       IMAGE_URI LOG_GROUP AWS_REGION
RENDERED="$(mktemp)"
envsubst < "${SCRIPT_DIR}/../ecs/task-definition.template.json" > "${RENDERED}"

echo "==> Registering task definition mock-svc-${QA_ID}"
TASK_DEF_ARN="$(aws ecs register-task-definition \
  --cli-input-json "file://${RENDERED}" \
  --query 'taskDefinition.taskDefinitionArn' --output text)"
rm -f "${RENDERED}"
echo "==> Registered ${TASK_DEF_ARN}"

SERVICE_NAME="mock-svc-${QA_ID}"
NETWORK_CONFIG="awsvpcConfiguration={subnets=[$(echo "${SUBNET_IDS}" | sed 's/,/,/g')],securityGroups=[${SECURITY_GROUP_ID}],assignPublicIp=DISABLED}"

if aws ecs describe-services --cluster "${ECS_CLUSTER}" --services "${SERVICE_NAME}" \
     --query 'services[?status!=`INACTIVE`]' --output text | grep -q .; then
  echo "==> Service ${SERVICE_NAME} exists, updating it to the new task definition"
  aws ecs update-service \
    --cluster "${ECS_CLUSTER}" \
    --service "${SERVICE_NAME}" \
    --task-definition "${TASK_DEF_ARN}" \
    --force-new-deployment >/dev/null
else
  echo "==> Creating service ${SERVICE_NAME}"
  aws ecs create-service \
    --cluster "${ECS_CLUSTER}" \
    --service-name "${SERVICE_NAME}" \
    --task-definition "${TASK_DEF_ARN}" \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "${NETWORK_CONFIG}" >/dev/null
fi

echo "==> Done. QA '${QA_ID}' mock service is on ECS service '${SERVICE_NAME}',"
echo "    data persisted at EFS path /qa-instances/${QA_ID} via access point ${ACCESS_POINT_ID}."
