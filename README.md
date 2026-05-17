# pi-ddns

Keeps a Route53 A record pointing at your home server's current public IP.
A cron job on the Pi calls an API Gateway endpoint every 5 minutes; a Lambda
function reads the request's source IP and upserts the record.

## Architecture

```
Pi (cron, curl) → API Gateway (REST, API key, rate-limit) → Lambda → Route53
```

- **API key** — required on every request; managed by a Usage Plan
- **Rate limit** — 1 rps steady / 1 burst / 300 requests per day
- **Source IP** — detected server-side from `requestContext.identity.sourceIp`;
  the Pi does not need to know its own IP

## Bootstrap (first time)

These steps are only needed once. After that, CI handles all deployments.

### 1. Prerequisites

- AWS CLI configured with admin credentials
- Terraform ≥ 1.6
- Node.js 20
- An S3 bucket for Terraform state (create one if needed)
- GitHub OIDC provider registered in your AWS account:

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

### 2. Build the Lambda

```bash
cd lambda
npm ci
npm run build
cd ..
```

### 3. Configure Terraform

```bash
cp terraform/backend.hcl.example terraform/backend.hcl
# Edit backend.hcl — set your S3 bucket name

cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars — set hosted_zone_id, record_name, github_org, github_repo
```

### 4. Apply

```bash
cd terraform
terraform init -backend-config=backend.hcl
terraform apply
```

### 5. Note the outputs

```
api_endpoint           = "https://<id>.execute-api.us-west-2.amazonaws.com/prod/update"
api_key_id             = "<key-id>"
github_actions_role_arn = "arn:aws:iam::<account>:role/pi-ddns-github-actions"
```

Retrieve the API key value:

```bash
aws apigateway get-api-key --api-key <key-id> --include-value --query value --output text
```

### 6. Set GitHub repository secrets

| Secret | Value |
|--------|-------|
| `AWS_ROLE_ARN` | `github_actions_role_arn` output |
| `AWS_REGION` | e.g. `us-west-2` |
| `TF_STATE_BUCKET` | your S3 bucket name |
| `HOSTED_ZONE_ID` | Route53 hosted zone ID |
| `RECORD_NAME` | e.g. `home.example.com` |

### 7. Cron job on the Pi

```bash
# /etc/cron.d/ddns  (or crontab -e)
*/5 * * * * root curl -sf -X POST \
  -H "x-api-key: <your-api-key>" \
  https://<id>.execute-api.us-west-2.amazonaws.com/prod/update \
  >> /var/log/ddns.log 2>&1
```

## CI/CD

| Trigger | Workflow | Action |
|---------|----------|--------|
| Push to `main` | `deploy.yml` | `terraform apply` |
| Pull request | `plan.yml` | `terraform plan`, posts diff to PR |
