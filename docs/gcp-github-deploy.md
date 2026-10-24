# Manual GCP production deployment

The `Deploy Pairwise to GCP production` workflow runs only when manually
dispatched from `main`, the operator types `DEPLOY`, and the push CI run for
that exact commit has completed successfully. It uses GitHub OIDC and
Workload Identity Federation (no service-account key), transfers a source-only
archive through IAP, rebuilds only the API container, and verifies `/readyz`
and the exact `/version` commit before reporting success. If verification fails,
the host restores the previous API image. LiveKit, the Cloud SQL proxy, the
database volume, generated configuration, and certificates are not replaced.

## One-time GCP setup

The production project is `named-tube-444103-p0`; its existing GitHub pool is
`github`. Do not change the pool's existing provider or reuse another product's
service account. Create a dedicated provider restricted to this repository and
the protected `main` branch, then a dedicated deployment service account:

```sh
PROJECT_ID=named-tube-444103-p0
PROJECT_NUMBER=316016512837
POOL_ID=github
PROVIDER_ID=pairwise-deploy-main
DEPLOYER_SA=pairwise-github-deployer

gcloud services enable iap.googleapis.com --project "$PROJECT_ID"
gcloud iam service-accounts create "$DEPLOYER_SA" --project "$PROJECT_ID"
gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
  --project "$PROJECT_ID" --location global --workload-identity-pool "$POOL_ID" \
  --issuer-uri https://token.actions.githubusercontent.com \
  --attribute-mapping='google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref' \
  --attribute-condition="assertion.repository == 'EvAlssment/Pairwise' && assertion.ref == 'refs/heads/main'"

gcloud iam service-accounts add-iam-policy-binding \
  "$DEPLOYER_SA@$PROJECT_ID.iam.gserviceaccount.com" --project "$PROJECT_ID" \
  --role roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$POOL_ID/attribute.repository/EvAlssment/Pairwise"
```

The provider condition enforces both the repository and `refs/heads/main`.
The service-account policy binds only that repository attribute; keep the
provider condition in place because IAM binding conditions do not expose the
provider's mapped `attribute.ref` value.

Grant the service account only read/list access needed for `gcloud compute ssh`
at project scope, and OS Login/IAP access on the PairDesk VM. IAP is restricted
to SSH port 22. The VM's runtime service account binding is scoped to the
existing PairDesk API identity:

```sh
gcloud iam roles create pairwiseGcpDeployRead \
  --project "$PROJECT_ID" --title 'Pairwise GCP deploy read access' \
  --description 'Read-only VM lookup for Pairwise GitHub deployment' \
  --permissions compute.instances.get,compute.instances.list,compute.projects.get,compute.zones.get,resourcemanager.projects.get \
  --stage GA
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$DEPLOYER_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="projects/$PROJECT_ID/roles/pairwiseGcpDeployRead"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$DEPLOYER_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role roles/serviceusage.serviceUsageConsumer
gcloud compute instances add-iam-policy-binding pairdesk-server \
  --project "$PROJECT_ID" --zone us-central1-a \
  --member="serviceAccount:$DEPLOYER_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role roles/compute.osAdminLogin
gcloud iam service-accounts add-iam-policy-binding \
  pairdesk-api-runtime@$PROJECT_ID.iam.gserviceaccount.com --project "$PROJECT_ID" \
  --member="serviceAccount:$DEPLOYER_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role roles/iam.serviceAccountUser
```

Grant IAP access on the VM's **IAP tunnel policy**, not the Compute instance
policy. Preserve the existing policy while adding the restricted SSH binding:

```sh
set -euo pipefail
MEMBER="serviceAccount:$DEPLOYER_SA@$PROJECT_ID.iam.gserviceaccount.com"
IAP_POLICY=$(mktemp)
trap 'rm -f "$IAP_POLICY"' EXIT
IAP_BASE="https://iap.googleapis.com/v1/projects/$PROJECT_NUMBER/iap_tunnel"
curl --fail --silent --show-error -X POST \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H 'Content-Type: application/json' -d '' \
  "$IAP_BASE/zones/us-central1-a/instances/pairdesk-server:getIamPolicy" > "$IAP_POLICY"
python3 - "$IAP_POLICY" "$MEMBER" <<'PY'
import json, sys
path, member = sys.argv[1:]
with open(path) as stream:
    policy = json.load(stream)
bindings = policy.setdefault("bindings", [])
binding = next((item for item in bindings if item.get("role") == "roles/iap.tunnelResourceAccessor" and item.get("condition", {}).get("expression") == "destination.port == 22"), None)
if binding is None:
    binding = {"role": "roles/iap.tunnelResourceAccessor", "members": [], "condition": {"title": "Pairwise SSH only", "expression": "destination.port == 22"}}
    bindings.append(binding)
if member not in binding["members"]:
    binding["members"].append(member)
with open(path, "w") as stream:
    json.dump({"policy": policy}, stream)
PY
curl --fail --silent --show-error -X POST \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H 'Content-Type: application/json' --data-binary "@$IAP_POLICY" \
  "$IAP_BASE/zones/us-central1-a/instances/pairdesk-server:setIamPolicy"
```

The OS Login role grants administrator access to the PairDesk VM; deployment
therefore has the same host-level authority as a trusted operator. The
Workload Identity provider and service-account binding restrict which GitHub
repository and branch can obtain that authority. Protect `main`, and do not add
PR or tag refs to the provider condition.

## One-time GitHub setup

Set these repository variables (no credentials or private keys):

```sh
gh variable set PAIRDESK_GCP_PROJECT_ID --repo EvAlssment/Pairwise --body named-tube-444103-p0
gh variable set PAIRDESK_GCP_ZONE --repo EvAlssment/Pairwise --body us-central1-a
gh variable set PAIRDESK_GCP_VM --repo EvAlssment/Pairwise --body pairdesk-server
gh variable set PAIRDESK_GCP_WIF_PROVIDER --repo EvAlssment/Pairwise \
  --body projects/316016512837/locations/global/workloadIdentityPools/github/providers/pairwise-deploy-main
gh variable set PAIRDESK_GCP_DEPLOYER_SA --repo EvAlssment/Pairwise \
  --body pairwise-github-deployer@named-tube-444103-p0.iam.gserviceaccount.com
```

The repository's `main` branch requires pull requests, one approval, resolved
review conversations, and passing `workflow-lint`, `android`, `api-image`,
`ios`, `postgres-integration`, and `macos` checks. The `production` environment
allows only `main`, requires approval from `bharathasija`, prevents self-review,
and disables administrator bypass. After the GCP and GitHub setup, wait for IAM
propagation, then dispatch the workflow from `main` and enter `DEPLOY`. The
first deployment should be observed directly and `/version` should match the
full commit SHA shown in the workflow run.

## Recovery

The deployment command retains the previous image under a rollback tag. A
failed exact-commit or readiness check restores that image and recreates only
the API container. If automatic rollback itself fails, connect to the VM with
IAP, inspect `docker compose -p pairdesk-prod ps` and the API logs, then restore
the `pairdesk-prod-api:rollback-<commit-prefix>` tag to
`pairdesk-prod-api:latest` and run `infra/production/manage.sh status`.

The workflow has not been executed against production until its WIF provider,
IAM grants, and GitHub variables/environment are configured and a manual run
passes. It is deliberately separate from routine test CI and release tagging.
