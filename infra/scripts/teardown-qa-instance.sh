#!/usr/bin/env bash
# Tears down one QA's mock-service instance: stops/deletes the ECS service
# and deregisters its task definitions. The EFS access point (and the QA's
# data under it) is left in place by default - pass --delete-data to also
# remove it permanently.
#
# Usage: ./teardown-qa-instance.sh <qa-id> [--delete-data]

set -euo pipefail

QA_ID="${1:?Usage: $0 <qa-id> [--delete-data]}"
DELETE_DATA="${2:-}"
: "${ECS_CLUSTER:?}"; : "${EFS_FILE_SYSTEM_ID:?}"

SERVICE_NAME="mock-svc-${QA_ID}"

echo "==> Scaling ${SERVICE_NAME} to 0 and deleting the service"
aws ecs update-service --cluster "${ECS_CLUSTER}" --service "${SERVICE_NAME}" --desired-count 0 >/dev/null 2>&1 || true
aws ecs delete-service --cluster "${ECS_CLUSTER}" --service "${SERVICE_NAME}" --force >/dev/null 2>&1 || true

echo "==> Deregistering task definition revisions for family mock-svc-${QA_ID}"
for arn in $(aws ecs list-task-definitions --family-prefix "mock-svc-${QA_ID}" --query 'taskDefinitionArns' --output text); do
  aws ecs deregister-task-definition --task-definition "${arn}" >/dev/null
done

if [[ "${DELETE_DATA}" == "--delete-data" ]]; then
  echo "==> --delete-data set: removing the EFS access point (and QA's stored data) permanently"
  ACCESS_POINT_ID="$(aws efs describe-access-points \
    --file-system-id "${EFS_FILE_SYSTEM_ID}" \
    --query "AccessPoints[?Tags[?Key=='qa-id' && Value=='${QA_ID}']].AccessPointId | [0]" \
    --output text)"
  if [[ -n "${ACCESS_POINT_ID}" && "${ACCESS_POINT_ID}" != "None" ]]; then
    aws efs delete-access-point --access-point-id "${ACCESS_POINT_ID}"
    echo "==> Deleted access point ${ACCESS_POINT_ID}"
  fi
else
  echo "==> Data under /qa-instances/${QA_ID} on EFS is left intact (re-run provision-qa-instance.sh to reuse it)"
fi

echo "==> Done."
