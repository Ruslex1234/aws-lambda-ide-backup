# Lambda Code Watcher — S3 Versioned Backups

Backs up AWS Lambda **deployment packages** to S3 whenever code changes. Triggers from **EventBridge** on CloudTrail management events; downloads the latest ZIP and writes it to S3 under a stable key so **S3 versioning** keeps history.

## How it works
1. **EventBridge rule** listens for CloudTrail management events:
   - `UpdateFunctionCode*` (Deploy)
   - `PublishVersion*` (Publish an immutable version)
   > We use **prefix** matching because CloudTrail often emits versioned names (e.g., `UpdateFunctionCode20150331v2`).
2. **Watcher Lambda** (this project) receives the event.
3. It calls **`lambda:GetFunction`** → gets:
   - `CodeSha256` (code fingerprint)
   - `Code.Location` (pre-signed ZIP URL)
4. Compares to prior state (stored in S3). If SHA changed:
   - Downloads ZIP
   - Uploads to `s3://DEST_BUCKET/DEST_PREFIX/FUNCTION_NAME.zip`
   - S3 has **versioning enabled**, so you retain every version
   - Saves a tiny `STATE_PREFIX/FUNCTION_NAME.json` with the last SHA and S3 VersionId

## Repo layout

samples/ # example JSONs (inline policy & event pattern)
src/lambda/code_watcher/ # Lambda source (handler.py)
terraform/ # IaC (S3, IAM, Lambda, EventBridge)
envs/ # tfvars per env
.github/workflows/terraform.yml


## Environment variables (Lambda)
| Name               | Required | Default                 | Purpose |
|--------------------|----------|-------------------------|---------|
| `DEST_BUCKET`      | ✅       | —                       | S3 bucket for backups & state |
| `DEST_PREFIX`      |          | `lambda-code-backups`   | Key prefix for ZIPs |
| `STATE_PREFIX`     |          | `<DEST_PREFIX>/.state`  | Key prefix for state JSON |
| `TARGET_FUNCTION(S)` |        | —                       | Comma-separated list for manual/polling invocations |

> With EventBridge, you **don’t** need `TARGET_FUNCTION(S)`; the event supplies the function name.

## IAM — inline policy (execution role)
See `samples/sample-inline-policy.json`. Replace placeholders.

**Why each line matters**
- `lambda:GetFunction` — read `CodeSha256` + pre-signed ZIP URL.
- `s3:Get/PutBucketVersioning` — ensure bucket versioning is **Enabled**.
- `s3:ListBucket` on `YOUR_PREFIX/.state*` — lets first-run reads behave (absence vs. permission).
- `s3:PutObject/GetObject/GetObjectVersion` on `YOUR_PREFIX/*` — write/read ZIP and state.
- `logs:*` — standard Lambda logging.
- KMS block (optional) — only if your bucket uses a **customer-managed** KMS key.

## EventBridge rule (pattern)
See `samples/sample-eventbridge-rule.json`.

- `source: ["aws.lambda"]` — AWS service that emitted the event
- `detail-type: ["AWS API Call via CloudTrail"]` — this is how mgmt events show up
- `detail.eventSource: ["lambda.amazonaws.com"]` — Lambda API
- `detail.eventName: [{ "prefix": "UpdateFunctionCode" }, { "prefix": "PublishVersion" }]` — covers versioned names
- `detail.requestParameters.functionName: ["FUNCTION_NAME", "arn:...:FUNCTION_NAME"]` — include **name and ARN** (either can appear)

**Target:** your watcher Lambda, input = **Matched event**.

## Manual setup (console)
1. Create S3 bucket for backups (versioning can start disabled).
2. Create the watcher Lambda (runtime: Python 3.11), handler `handler.lambda_handler`. Zip contents of `src/lambda/code_watcher`.
3. Attach an **execution role** with the inline policy above (and `AWSLambdaBasicExecutionRole` for logs).
4. Set env vars: `DEST_BUCKET`, `DEST_PREFIX` (optional), `STATE_PREFIX` (optional).
5. EventBridge → **Create rule** → paste the **sample-eventbridge-rule.json** as the pattern → **Target = watcher Lambda**.

## Terraform deployment
- Edit `terraform/envs/dev.tfvars` (bucket name, optional function ARNs to tighten IAM).
- If using remote state, edit `terraform/backend.tf` placeholders before running.
- Locally:
  ```bash
  cd terraform
  terraform init
  terraform plan -var-file="envs/dev.tfvars"
  terraform apply -var-file="envs/dev.tfvars" -auto-approve

    Via GitHub Actions:

        Create OIDC role and store ARN in repo secret: AWS_OIDC_ROLE_ARN.

        Push to main. The workflow runs init/validate/apply using envs/dev.tfvars.

Testing

    On a target Lambda, make a small code change → Deploy (or Publish new version).

    EventBridge Rule → Monitoring: Matched events increments.

    Watcher Lambda → CloudWatch Logs: shows either “Change detected… Uploaded…” or “No code change…”.

    S3 → enable Show versions → confirm a new VersionId for DEST_PREFIX/FUNCTION_NAME.zip.

Troubleshooting

    No invocation? Rule disabled, wrong region, or target set to the wrong Lambda.

    No match? Pattern too strict. Try the broad pattern (no functionName filter).

    AccessDenied on first run? Ensure the ListStatePrefixOnly statement exists; code also treats AccessDenied as “no state”.

    VPC egress: downloading ZIP needs outbound internet (use NAT or run outside VPC).
