# file: handler.py
import json
import os
import urllib.request
import logging

import boto3
from botocore.exceptions import ClientError

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

s3 = boto3.client("s3")
lambda_client = boto3.client("lambda")

# ---------- Config via environment variables ----------
DEST_BUCKET     = os.environ["DEST_BUCKET"]                         # required
DEST_PREFIX     = os.environ.get("DEST_PREFIX", "lambda-code-backups")
TARGET_FUNCTION = [s.strip() for s in os.environ.get("TARGET_FUNCTION", "").split(",") if s.strip()]  # optional for polling
STATE_PREFIX    = os.environ.get("STATE_PREFIX", f"{DEST_PREFIX}/.state")  # where we store last seen CodeSha256
# ------------------------------------------------------

def ensure_bucket_versioning(bucket: str):
    """Enable versioning on the destination bucket if not already enabled."""
    try:
        resp = s3.get_bucket_versioning(Bucket=bucket)
        status = resp.get("Status", "")
        if status != "Enabled":
            LOG.info("Enabling versioning on bucket %s", bucket)
            s3.put_bucket_versioning(
                Bucket=bucket,
                VersioningConfiguration={"Status": "Enabled"}
            )
    except ClientError as e:
        LOG.error("Failed to check/enable versioning: %s", e)
        raise

def _state_key(function_name: str) -> str:
    return f"{STATE_PREFIX}/{function_name}.json"

def load_last_state(function_name: str) -> dict | None:
    """
    Return prior state JSON or None.
    Treat AccessDenied as 'no state' to support roles without ListBucket on the prefix.
    """
    key = _state_key(function_name)
    try:
        obj = s3.get_object(Bucket=DEST_BUCKET, Key=key)
        return json.loads(obj["Body"].read().decode("utf-8"))
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code")
        if code in ("NoSuchKey", "404", "AccessDenied"):
            LOG.info("No prior state for %s (%s). Treating as first run.", function_name, code)
            return None
        raise

def save_state(function_name: str, state: dict):
    key = _state_key(function_name)
    s3.put_object(
        Bucket=DEST_BUCKET,
        Key=key,
        Body=json.dumps(state, separators=(",", ":"), ensure_ascii=False).encode("utf-8"),
        ContentType="application/json"
    )

def fetch_lambda_package_info(function_name: str) -> dict:
    """Return dict with code_url, code_sha, last_modified, version, function_arn."""
    resp = lambda_client.get_function(FunctionName=function_name)
    cfg = resp["Configuration"]
    code = resp["Code"]
    return {
        "function_arn": cfg.get("FunctionArn"),
        "version": cfg.get("Version"),
        "last_modified": cfg.get("LastModified"),
        "code_sha": cfg.get("CodeSha256"),
        "code_url": code.get("Location"),
    }

def download_bytes(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=60) as fh:
        return fh.read()

def upload_zip(function_name: str, zip_bytes: bytes, metadata: dict) -> dict:
    """
    Upload to a stable key so S3 versioning keeps history.
    Key: {DEST_PREFIX}/{function_name}.zip
    """
    key = f"{DEST_PREFIX}/{function_name}.zip"
    s3.put_object(
        Bucket=DEST_BUCKET,
        Key=key,
        Body=zip_bytes,
        ContentType="application/zip",
        Metadata={
            "function_arn": metadata.get("function_arn", ""),
            "lambda_version": metadata.get("version", ""),
            "last_modified": metadata.get("last_modified", ""),
            "code_sha": metadata.get("code_sha", ""),
        }
    )
    head = s3.head_object(Bucket=DEST_BUCKET, Key=key)
    return {"bucket": DEST_BUCKET, "key": key, "version_id": head.get("VersionId")}

def process_function(function_name: str) -> dict:
    info = fetch_lambda_package_info(function_name)
    code_sha = info["code_sha"]
    if not code_sha or not info["code_url"]:
        raise RuntimeError(f"Missing code info for {function_name}")

    last_state = load_last_state(function_name)
    if last_state and last_state.get("code_sha") == code_sha:
        LOG.info("No code change for %s (CodeSha256 unchanged).", function_name)
        return {"function": function_name, "changed": False}

    LOG.info("Change detected for %s, downloading package...", function_name)
    blob = download_bytes(info["code_url"])
    upload_info = upload_zip(function_name, blob, info)

    save_state(function_name, {
        "code_sha": code_sha,
        "last_modified": info["last_modified"],
        "s3_bucket": upload_info["bucket"],
        "s3_key": upload_info["key"],
        "s3_version_id": upload_info["version_id"],
    })

    LOG.info("Uploaded %s to s3://%s/%s (version %s)",
             function_name, upload_info["bucket"], upload_info["key"], upload_info["version_id"])

    return {
        "function": function_name,
        "changed": True,
        "s3": upload_info,
        "code_sha": code_sha,
    }

def function_name_from_event(event: dict) -> str | None:
    """Extract target function from EventBridge CloudTrail event."""
    try:
        if event.get("detail-type") == "AWS API Call via CloudTrail":
            detail = event.get("detail", {})
            if detail.get("eventSource") == "lambda.amazonaws.com":
                return detail.get("requestParameters", {}).get("functionName")
    except Exception:
        pass
    return None

def lambda_handler(event, context):
    """
    Modes:
      - Event-driven: invoked by EventBridge CloudTrail events for Lambda updates
      - Polling: if TARGET_FUNCTION is set, iterate those names
    """
    LOG.info("Event: %s", json.dumps(event))
    ensure_bucket_versioning(DEST_BUCKET)

    targets = []
    event_fn = function_name_from_event(event)
    if event_fn:
        targets = [event_fn]
    elif TARGET_FUNCTION:
        targets = TARGET_FUNCTION
    else:
        raise RuntimeError("No target functions provided. Set TARGET_FUNCTION or invoke from EventBridge update events.")

    results = []
    for fn in targets:
        try:
            results.append(process_function(fn))
        except Exception as e:
            LOG.exception("Failed processing %s: %s", fn, e)
            results.append({"function": fn, "error": str(e)})

    return {"results": results}
