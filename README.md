# Lambda Code Watcher — S3 Versioned Backups

Backs up AWS Lambda **deployment packages** to S3 whenever code changes. It listens to **EventBridge** (CloudTrail management events), downloads the latest ZIP, and writes to S3 under a stable key so **S3 versioning** keeps history.

---

## How it works

1. **EventBridge rule** listens for CloudTrail management events:
   - `UpdateFunctionCode*` (deploy to `$LATEST`)
   - `PublishVersion*` (publish an immutable version)
   > We match by **prefix** because CloudTrail often emits versioned names like `UpdateFunctionCode20150331v2`.
2. **Watcher Lambda** receives the event.
3. It calls **`lambda:GetFunction`** to get:
   - `CodeSha256` (code fingerprint)
   - `Code.Location` (pre-signed ZIP URL)
4. It compares to prior state (stored in S3). If SHA changed:
   - Downloads the ZIP
   - Uploads to `s3://DEST_BUCKET/DEST_PREFIX/FUNCTION_NAME.zip`
   - S3 versioning creates a new **VersionId** per change
   - Saves `STATE_PREFIX/FUNCTION_NAME.json` with last SHA + S3 VersionId

---

## Repo layout

```
.
├─ README.md
├─ samples/
│  ├─ sample-inline-policy.json        # example IAM inline policy for the watcher role
│  └─ sample-eventbridge-rule.json     # example EventBridge rule pattern
├─ src/
│  └─ lambda/
│     └─ code_watcher/
│        └─ handler.py                 # watcher Lambda
├─ terraform/
│  ├─ main.tf                          # S3, IAM role+policy, Lambda, EventBridge
│  ├─ variables.tf                     # all inputs (no secrets checked in)
│  ├─ outputs.tf
│  └─ backend.tf                       # optional remote state (fill in or remove)
└─ .github/
   └─ workflows/
      └─ terraform.yml                 # manual-only workflow; prompts for inputs
```

---

## Environment variables (Lambda)

| Name                 | Required | Default                 | Purpose |
|----------------------|----------|-------------------------|---------|
| `DEST_BUCKET`        | ✅       | —                       | S3 bucket for ZIP backups & state |
| `DEST_PREFIX`        |          | `lambda-code-backups`   | Key prefix for ZIPs |
| `STATE_PREFIX`       |          | `<DEST_PREFIX>/.state`  | Key prefix for state JSON |
| `TARGET_FUNCTION(S)` |          | —                       | Comma-separated list for **manual/polling** runs (ignored when the event includes `functionName`) |

> With EventBridge, you **don’t** need `TARGET_FUNCTION(S)`; the event supplies the function name.

---

## IAM — inline policy for the watcher (execution role)

Use `samples/sample-inline-policy.json` and replace placeholders.

**Why each statement exists**

- `lambda:GetFunction` — fetches pre-signed ZIP URL + `CodeSha256`.
- `s3:GetBucketVersioning` / `s3:PutBucketVersioning` — ensures bucket versioning is **Enabled**.
- `s3:ListBucket` on `YOUR_PREFIX/.state*` — lets first-run reads behave (distinguish “no state” vs access denied).
- `s3:PutObject` / `s3:GetObject` / `s3:GetObjectVersion` on `YOUR_PREFIX/*` — write/read ZIP and state JSON.
- `logs:*` — standard Lambda logging.
- *(Optional)* `kms:*` — only if the bucket uses a **customer-managed** KMS key.

---

## EventBridge rule (pattern)

See `samples/sample-eventbridge-rule.json`.

**Broad (all functions):**
```json
{
  "source": ["aws.lambda"],
  "detail-type": ["AWS API Call via CloudTrail"],
  "detail": {
    "eventSource": ["lambda.amazonaws.com"],
    "eventName": [
      { "prefix": "UpdateFunctionCode" },
      { "prefix": "PublishVersion" }
    ]
  }
}
```

**Filtered (specific function):**
```json
{
  "source": ["aws.lambda"],
  "detail-type": ["AWS API Call via CloudTrail"],
  "detail": {
    "eventSource": ["lambda.amazonaws.com"],
    "eventName": [
      { "prefix": "UpdateFunctionCode" },
      { "prefix": "PublishVersion" }
    ],
    "requestParameters": {
      "functionName": [
        "FUNCTION_NAME",
        "arn:aws:lambda:REGION:ACCOUNT_ID:function:FUNCTION_NAME"
      ]
    }
  }
}
```

**Target:** the watcher Lambda, **Input** = “Matched event”.

---

## Manual setup (console)

1. **Create S3 bucket** for backups (versioning can start disabled).
2. **Create the watcher Lambda** (Python 3.11), handler `handler.lambda_handler`. Zip `src/lambda/code_watcher`.
3. **Attach execution role** with:
   - Inline policy from `samples/sample-inline-policy.json`
   - `AWSLambdaBasicExecutionRole` (or equivalent logs actions)
4. **Set env vars**: `DEST_BUCKET` (required), optionally `DEST_PREFIX` / `STATE_PREFIX`.
5. **Create EventBridge rule** → paste the JSON **pattern** above → **Target = watcher Lambda**.

---

## Terraform + GitHub Actions (manual, prompted inputs)

The workflow at `.github/workflows/terraform.yml` is **manual-only** (`workflow_dispatch`). When you click **Run workflow**, GitHub asks for inputs and passes them into Terraform via `TF_VAR_*` environment variables. No `tfvars` are committed.

**You will be prompted for** (defaults can be set in the workflow):

- Region  
- Backup bucket name  
- Destination prefix  
- Watcher Lambda name  
- EventBridge rule name  
- (Optional) Account ID + Function name (to filter the rule and tighten IAM)  
- Log retention days  
- (Optional) KMS key ARN  

**One-time prerequisite:** create an **OIDC assume role** for GitHub Actions and set repo secret `AWS_OIDC_ROLE_ARN` (see next section).

**Run it**

1. GitHub → **Actions** → **Terraform (manual)** → **Run workflow**.
2. Fill inputs → choose `plan`, `apply`, or `destroy`.
3. The workflow runs `terraform init/validate` and then your chosen action.

**Local alternative**
```bash
cd terraform
terraform init
terraform plan  -var='backup_bucket=YOUR_BUCKET' -var='watcher_name=YOUR_WATCHER' -var='region=YOUR_REGION'
terraform apply -auto-approve -var='backup_bucket=YOUR_BUCKET' -var='watcher_name=YOUR_WATCHER' -var='region=YOUR_REGION'
```

> If you use a remote backend, edit `terraform/backend.tf`. Otherwise, remove it to keep local state.

---

## Create the GitHub Actions **assume role** (OIDC)

You’ll create:
1) An **OIDC provider** for GitHub, and  
2) An **IAM role** the workflow can assume.

### 1) Add the OIDC provider (once per account)

- IAM → **Identity providers** → **Add provider**
  - Provider type: **OpenID Connect**
  - Provider URL: `https://token.actions.githubusercontent.com`
  - Audience: `sts.amazonaws.com`

### 2) Create the deploy role

- IAM → **Roles** → **Create role** → **Web identity**
  - Provider: the OIDC provider above
  - Audience: `sts.amazonaws.com`
  - Conditions (trust policy): limit to your repo (and optional branch)

**Trust policy (sample)**
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": [
          "repo:OWNER/REPO:*"
          // or lock to main only:
          // "repo:OWNER/REPO:ref:refs/heads/main"
        ]
      }
    }
  }]
}
```

**Permissions policy (sample)**  
Grant just enough for the Terraform in this repo (tighten later if desired):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": [
        "iam:CreateRole","iam:DeleteRole","iam:GetRole","iam:PassRole",
        "iam:PutRolePolicy","iam:DeleteRolePolicy",
        "iam:AttachRolePolicy","iam:DetachRolePolicy",
        "iam:TagRole","iam:UntagRole","iam:ListAttachedRolePolicies"
      ], "Resource": "*" },

    { "Effect": "Allow", "Action": [
        "lambda:CreateFunction","lambda:UpdateFunctionCode","lambda:UpdateFunctionConfiguration",
        "lambda:PublishVersion","lambda:DeleteFunction","lambda:GetFunction","lambda:TagResource"
      ], "Resource": "*" },

    { "Effect": "Allow", "Action": [
        "logs:CreateLogGroup","logs:PutRetentionPolicy",
        "logs:CreateLogStream","logs:PutLogEvents","logs:DescribeLogGroups","logs:DeleteLogGroup"
      ], "Resource": "*" },

    { "Effect": "Allow", "Action": [
        "events:PutRule","events:DeleteRule","events:PutTargets","events:RemoveTargets",
        "events:DescribeRule","events:ListTargetsByRule"
      ], "Resource": "*" },

    { "Effect": "Allow", "Action": [
        "s3:CreateBucket","s3:DeleteBucket","s3:ListBucket","s3:GetBucketLocation",
        "s3:GetBucketVersioning","s3:PutBucketVersioning",
        "s3:PutBucketEncryption","s3:GetEncryptionConfiguration",
        "s3:PutBucketPolicy","s3:PutPublicAccessBlock"
      ], "Resource": "arn:aws:s3:::*" },

    { "Effect": "Allow", "Action": [
        "s3:PutObject","s3:GetObject","s3:DeleteObject"
      ], "Resource": "arn:aws:s3:::*/*" }

    // If you enable KMS on the bucket, also allow:
    // "kms:Encrypt","kms:Decrypt","kms:GenerateDataKey" on that key ARN.
  ]
}
```

- Save the role and copy its **Role ARN**.
- Repo → **Settings → Secrets and variables → Actions** → add secret **`AWS_OIDC_ROLE_ARN`** with this ARN.

---

## Testing

1. Make a small code change on a target Lambda → **Deploy** (or **Publish new version**).
2. EventBridge rule → **Monitoring**: “Matched events” increments.
3. Watcher Lambda → **CloudWatch Logs**:
   - “Change detected … Uploaded … (version …)” **or**
   - “No code change (CodeSha256 unchanged)”
4. S3 → **Show versions** → confirm a new **VersionId** for `DEST_PREFIX/FUNCTION_NAME.zip` when code changed.

---

## Troubleshooting

- **No invocation**  
  Rule disabled, wrong region, or the rule’s **target** isn’t the watcher Lambda.
- **No match**  
  Pattern too strict. Try the **broad** pattern (no `functionName` filter) first.
- **First-run AccessDenied**  
  Ensure the `ListStatePrefixOnly` statement exists; the code also treats `AccessDenied` as “no state”.
- **Private VPC**  
  Downloading the ZIP requires outbound internet. If the watcher runs in a private subnet without NAT, downloads fail. Give it NAT or run outside a VPC.
- **Config-only changes**  
  Changing env/memory/etc. emits `UpdateFunctionConfiguration*` (not matched by default). Add another `{ "prefix": "UpdateFunctionConfiguration" }` if you want those to trigger a backup (the watcher will no-op if code SHA didn’t change).

---

## Costs

- **CloudTrail management events → EventBridge**: free by default (no trail required).
- **EventBridge** matching AWS service events: free.
- You pay for **Lambda** runtime, **CloudWatch Logs**, and **S3** storage/requests (plus **KMS** if enabled).

---

## License

MIT (or your choice).
