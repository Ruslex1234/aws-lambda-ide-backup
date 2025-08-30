#!/usr/bin/env python3
"""
lambda-code-watcher
Backs up Lambda deployment packages to S3 whenever code changes.

Modes
- Event-driven (recommended): triggered by EventBridge (CloudTrail mgmt events).
  Uses detail.requestParameters.functionName from the event.
- Manual/Polling: if no event function is present, falls back to TARGET_FUNCTION(S) env.

Env
- DEST_BUCKET (required)
- DEST_PREFIX (default: "lambda-code-backups")
- STATE_PREFIX (default: f"{DEST_PREFIX}/.state")
- TARGET_FUNCTION or TARGET_FUNCTIONS (comma-separated list; optional for polling)
"""

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

# ---------- Config via env ----------
DEST_BUCKET   = os.environ["DEST_BUCKET"]                        # required
DEST_PREFIX   = os.environ.get("DEST_PREFIX", "lambda-code-backups")
STATE_PREFIX  = os.environ.get("STATE_PREFIX", f"{DEST_PREFIX}/.state")

# Accept either TARGET_FUNCTION or TARGET_FUNCTIONS
_env_tf  = os.environ.get("TARGET_FUNCTION", "")
_env_tfs = os.environ.get("TARGET_FUNCTIONS", "")
TARGETS_FROM_ENV = [s.strip() for s in (_env_tf + "," + _env_tfs).split(",") if s.strip()]
# ------------------------------------

def ensure_bucket_versioning(bucket: str):
    """Enable S3 versioning if not already enabled."""
    try:
        resp = s3.get_bucket_versioning(Bucket=bucket)
        if resp.get("Status") != "Enabled":
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
    Treat AccessDenied/NoSuchKey as 'no state' to support minimal S3 list perms.
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
    """
    Return dict with code_url, code_sha, last_modified, version, function_arn.
    function_name may be a name or full ARN.
    """
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
    Upload to a stable key so S3 versioning keeps history:
      s3://DEST_BUCKET/DEST_PREFIX/{function_name}.zip
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
    # HeadObject requires s3:GetObject; returns VersionId when versioning is on
    head = s3.head_object(Bucket=DEST_BUCKET, Key=key)
    return {"bucket": DEST_BUCKET, "key": key, "version_id": head.get("VersionId")}

def compare_sha(last_state: dict | None, current_sha: str) -> bool:
    """Return True if code changed vs last_state."""
    return not last_state or last_state.get("code_sha") != current_sha

def process_function(target: str) -> dict:
    info = fetch_lambda_package_info(target)
    code_sha = info["code_sha"]
    if not code_sha or not info["code_url"]:
        raise RuntimeError(f"Missing code info for {target}")

    last_state = load_last_state(target.rsplit(":", 1)[-1])  # prefer short name key if ARN
    if not compare_sha(last_state, code_sha):
        LOG.info("No code change for %s (CodeSha256 unchanged).", target)
        return {"function": target, "changed": False}

    LOG.info("Change detected for %s, downloading package...", target)
    blob = download_bytes(info["code_url"])
    upload_info = upload_zip(target.rsplit(":", 1)[-1], blob, info)

    save_state(target.rsplit(":", 1)[-1], {
        "code_sha": code_sha,
        "last_modified": info["last_modified"],
        "s3_bucket": upload_info["bucket"],
        "s3_key": upload_info["key"],
        "s3_version_id": upload_info["version_id"],
    })

    LOG.info("Uploaded %s to s3://%s/%s (version %s)",
             target, upload_info["bucket"], upload_info["key"], upload_info["version_id"])

    return {
        "function": target,
        "changed": True,
        "s3": upload_info,
        "code_sha": code_sha,
    }

def function_name_from_event(event: dict) -> str | None:
    """
    Extract the function from CloudTrail-style events (EventBridge).
    Accepts both short name and full ARN.
    """
    try:
        if event.get("detail-type") == "AWS API Call via CloudTrail":
            det = event.get("detail", {})
            if det.get("eventSource") == "lambda.amazonaws.com":
                fn = det.get("requestParameters", {}).get("functionName")
                return fn
    except Exception:
        pass
    return None

def lambda_handler(event, context):
    LOG.info("Event: %s", json.dumps(event))
    ensure_bucket_versioning(DEST_BUCKET)

    event_fn = function_name_from_event(event)
    if event_fn:
        LOG.info("Using event-supplied function: %s", event_fn)
        targets = [event_fn]
    elif TARGETS_FROM_ENV:
        LOG.info("Using env TARGET_FUNCTION(S): %s", TARGETS_FROM_ENV)
        targets = TARGETS_FROM_ENV
    else:
        raise RuntimeError("No target functions provided. Set TARGET_FUNCTION(S) or invoke via EventBridge (CloudTrail event).")

    results = []
    for fn in targets:
        try:
            results.append(process_function(fn))
        except Exception as e:
            LOG.exception("Failed processing %s: %s", fn, e)
            results.append({"function": fn, "error": str(e)})

    return {"results": results}
