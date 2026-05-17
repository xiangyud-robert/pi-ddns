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

- AWS CLI configured with admin credentials — the active profile must have the following permissions:

  | AWS Managed Policy                | Why                                                          |
  |-----------------------------------|--------------------------------------------------------------|
  | `AmazonAPIGatewayAdministrator`   | Create and configure the REST API, usage plan, and API key   |
  | `AmazonRoute53FullAccess`         | Upsert DNS records for ACM cert validation and the API alias |
  | `AmazonS3FullAccess`              | Read and write Terraform state in the S3 bucket              |
  | `AWSCertificateManagerFullAccess` | Request and validate the ACM certificate                     |
  | `AWSLambda_FullAccess`            | Create and configure the Lambda function                     |
  | `IAMFullAccess`                   | Create IAM roles, policies, and the OIDC provider            |

- Terraform ≥ 1.10
- Node.js 24 (LTS)

- Create an S3 bucket for Terraform state (versioning + encryption recommended):

```bash
REGION="us-west-2"
BUCKET="pi-ddns-terraform-state-$(aws sts get-caller-identity --query Account --output text)"
# Or choose any globally unique name:
# BUCKET="your-terraform-state-bucket-name"

aws s3api create-bucket \
  --bucket "$BUCKET" \
  --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"

aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

aws s3api put-bucket-tagging \
  --bucket "$BUCKET" \
  --tagging 'TagSet=[{Key=Environment,Value=global},{Key=ManagedBy,Value=terraform},{Key=Name,Value="Terraform State Store"}]'

echo "Bucket: $BUCKET"
```

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
# Edit backend.hcl — set bucket and region

cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars — set aws_account_id, hosted_zone_id, record_names, api_domain_name, tf_state_bucket, github_org, github_repo
```

`aws_account_id` must match the account your AWS CLI profile is authenticated to. Terraform validates this at plan time and errors out immediately if they differ.

### 4. Apply

```bash
cd terraform
terraform init -backend-config=backend.hcl
terraform apply
```

### 5. Note the outputs

```
api_endpoint            = "https://ddns-api.example.com/update"
api_health_endpoint     = "https://ddns-api.example.com/health"
api_key_id              = "<key-id>"
github_actions_role_arn = "arn:aws:iam::<account>:role/github-actions-pi-ddns-deploy"
```

Retrieve the API key value:

```bash
aws apigateway get-api-key --api-key <key-id> --include-value --query value --output text
```

### 6. Verify with health check

Confirm the API Gateway and Lambda are working before wiring up CI or the cron job:

```bash
curl -H "x-api-key: <your-api-key>" https://ddns-api.example.com/health
# {"status":"ok","timestamp":"2026-05-16T10:00:00.000Z"}
```

A `200` response confirms everything is wired up correctly. No DNS record is modified.

### 7. Set GitHub repository secrets

| Secret | Value |
|--------|-------|
| `AWS_ROLE_ARN` | `github_actions_role_arn` output |
| `AWS_ACCOUNT_ID` | your AWS account ID |
| `AWS_REGION` | e.g. `us-west-2` |
| `HOSTED_ZONE_ID` | Route53 hosted zone ID |
| `RECORD_NAMES` | e.g. `["home.example.com","vpn.example.com"]` |
| `API_DOMAIN_NAME` | e.g. `ddns-api.example.com` |
| `TF_STATE_BUCKET` | your S3 bucket name for Terraform state |

### 8. Manually update A Records on any machine

```bash
curl -sX POST -H "x-api-key: <your-api-key>" https://ddns-api.example.com/update
```

### 9. Set up cron job on the Pi

**Option A — create ddns file at `/etc/cron.d/ddns`** (system-wide, runs as root):

```
*/5 * * * * root /bin/bash -c 'echo "$(date -u +\%Y-\%m-\%dT\%H:\%M:\%SZ) $(curl -sX POST -H "x-api-key: <your-api-key>" https://ddns-api.example.com/update 2>&1)" >> /var/log/ddns.log'
```

**Option B — `crontab -e`** (current user's crontab, no username field):

```
*/5 * * * * /bin/bash -c 'echo "$(date -u +\%Y-\%m-\%dT\%H:\%M:\%SZ) $(curl -sX POST -H "x-api-key: <your-api-key>" https://ddns-api.example.com/update 2>&1)" >> /var/log/ddns.log'
```

Check log at  /var/log/ddns.log and each line in the log will look like:

```
2026-05-17T23:00:01Z {"records":["home.example.com","vpn.example.com"],"ip":"1.2.3.4","updated":true}
```

## Switching to a different AWS account

No code changes are needed — only `terraform.tfvars`, `backend.hcl`, GitHub secrets, and a one-time bootstrap in the new account.

> Make sure the AWS CLI profile for the new account has all the permission to modify the AWS resources, otherwise the resource creation will fail without notice. Here are the permission needed:
>
> | AWS Managed Policy                | Why                                                          |
> |-----------------------------------|--------------------------------------------------------------|
> | `AmazonAPIGatewayAdministrator`   | Create and configure the REST API, usage plan, and API key   |
> | `AmazonRoute53FullAccess`         | Upsert DNS records for ACM cert validation and the API alias |
> | `AmazonS3FullAccess`              | Read and write Terraform state in the S3 bucket              |
> | `AWSCertificateManagerFullAccess` | Request and validate the ACM certificate                     |
> | `AWSLambda_FullAccess`            | Create and configure the Lambda function                     |
> | `IAMFullAccess`                   | Create IAM roles, policies, and the OIDC provider            |

### 1. Destroy infrastructure in the old account

Point your AWS CLI at the old account, then tear down all Terraform-managed resources:

```bash
export AWS_PROFILE=old-account

cd terraform
terraform destroy
```

Then delete the Terraform state bucket (this is not managed by Terraform itself):

```bash
OLD_BUCKET="your-old-terraform-state-bucket-name"

# Empty the bucket first (required before deletion)
aws s3 rm s3://"$OLD_BUCKET" --recursive

# Delete the bucket
aws s3api delete-bucket --bucket "$OLD_BUCKET"
```

### 2. Bootstrap the new account

```bash
# Point your AWS CLI at the new account
export AWS_PROFILE=new-account   # or configure credentials as needed

# Create the state bucket
REGION="us-west-2"
BUCKET="pi-ddns-terraform-state-$(aws sts get-caller-identity --query Account --output text)"
# Or choose any globally unique name:
# BUCKET="your-new-terraform-state-bucket-name"

aws s3api create-bucket \
  --bucket "$BUCKET" \
  --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"

aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

aws s3api put-bucket-tagging \
  --bucket "$BUCKET" \
  --tagging 'TagSet=[{Key=Environment,Value=global},{Key=ManagedBy,Value=terraform},{Key=Name,Value="Terraform State Store"}]'

# Register GitHub OIDC provider
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

### 3. Apply Terraform locally

Update `terraform/backend.hcl` and `terraform/terraform.tfvars` with the new `aws_account_id` and `tf_state_bucket`, then:

```bash
cd terraform
terraform init -backend-config=backend.hcl
terraform apply
```

Note the new `github_actions_role_arn` output.

### 4. Update GitHub repository secrets

Only these secrets need to change:

| Secret | Update to |
|--------|-----------|
| `AWS_ROLE_ARN` | new `github_actions_role_arn` output |
| `AWS_ACCOUNT_ID` | new AWS account ID |
| `TF_STATE_BUCKET` | new S3 bucket name |
| `HOSTED_ZONE_ID` | new account's Route53 hosted zone ID |

`AWS_REGION`, `RECORD_NAMES`, and `API_DOMAIN_NAME` stay the same unless also changing region or domain.

After updating the secrets, the next push to `main` will deploy against the new account.

## CI/CD

| Trigger | Workflow | Action |
|---------|----------|--------|
| Push to `main` | `deploy.yml` | `terraform apply` |
| Pull request | `plan.yml` | `terraform plan`, posts diff to PR |
