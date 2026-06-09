#!/usr/bin/env bash
#
# AWS tag audit (read-only by default; optional interactive tagging).
#
# This script scans commonly-used AWS resources and prints resources that are
# missing required cost-allocation tags. Use -t/--tag to interactively apply
# Application and Environment tags to missing resources. Add -n/--dry-run with
# -t to walk through the same prompts without making AWS changes.
#
# Defaults:
#   Region        : us-west-2, or $AWS_REGION if set
#   Required tags : Application,Environment
#   Services      : all supported services listed in --help
#
# Examples:
#   ./audit_aws_tags.sh
#   ./audit_aws_tags.sh -c missing-tags.csv
#   ./audit_aws_tags.sh -s ec2-instance,rds-instance,s3,lambda,apprunner
#   ./audit_aws_tags.sh -a
#   ./audit_aws_tags.sh -j 8
#   ./audit_aws_tags.sh -t
#   ./audit_aws_tags.sh -t -n
#
set -u
set -o pipefail

REGION="${AWS_REGION:-us-west-2}"
REGION_EXPLICIT=false
CSV_FILE=""
OUTPUT="table"
SERVICES_ARG=""
SHOW_TAGGED=false
QUIET=false
INTERACTIVE_TAG=false
DRY_RUN=false
PARALLEL_JOBS="${AWS_AUDIT_JOBS:-6}"
REQUIRED_TAGS=("Application" "Environment")
RECORD_FIELD_SEP=$'\x1e'
MISSING_RESOURCES_FILE=""
TAG_VALUES_APPS_FILE=""
TAG_VALUES_ENVS_FILE=""
TAG_JOB_PIDS=()
TAGGED_SERVICES=()
TAGGED_NAMES=()
TAGGED_APPS=()
TAGGED_ENVS=()
TOTAL_SCANNED=0
TOTAL_MISSING=0
TOTAL_ERRORS=0

usage() {
  cat <<'EOF'
Usage: ./audit_aws_tags.sh [flags]

AWS tag audit for common cost-bearing resources (read-only unless -t/--tag).

By default, this scans every supported service in us-west-2 plus global
services such as S3, CloudFront, and Route53.

Flags:
  -r, --region REGION          Scan one region (default: us-west-2 or $AWS_REGION)
  -s, --services a,b,c         Restrict to service labels; default is all labels
  -c, --csv FILE               Also write missing resources to CSV
  -o, --output table|csv       Print missing resources as table or CSV (default: table)
  -a, --include-tagged         Include correctly tagged resources in output
  -j, --jobs N                 Number of services to scan in parallel (default: 6)
  -q, --quiet                  Hide scan progress
  -t, --tag                    Interactively fix missing or malformed required tags
  -n, --dry-run                With -t, run the interactive flow without applying tags
  -h, --help                   Show help

Service labels:
  s3, cloudfront, route53,
  ec2-instance, ebs-volume, ebs-snapshot, eip, nat-gateway, security-group,
  elbv2, elb, rds-instance, rds-cluster, ecr, lambda, secretsmanager,
  logs, cloudwatch, cloudwatch-alarm, dynamodb, sqs, sns,
  ses, ses-identity, ses-configuration-set,
  ecs-cluster, ecs-service, efs, apprunner
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--region)
      REGION="$2"
      REGION_EXPLICIT=true
      shift 2
      ;;
    -s|--services)
      SERVICES_ARG="$2"
      shift 2
      ;;
    -c|--csv)
      CSV_FILE="$2"
      shift 2
      ;;
    -o|--output)
      OUTPUT="$2"
      shift 2
      ;;
    -a|--include-tagged)
      SHOW_TAGGED=true
      shift
      ;;
    -j|--jobs)
      PARALLEL_JOBS="$2"
      shift 2
      ;;
    -q|--quiet)
      QUIET=true
      shift
      ;;
    -t|--tag)
      INTERACTIVE_TAG=true
      shift
      ;;
    -n|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$OUTPUT" != "table" && "$OUTPUT" != "csv" ]]; then
  echo "--output must be table or csv" >&2
  exit 1
fi

if ! [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] || [[ "$PARALLEL_JOBS" -lt 1 ]]; then
  echo "-j/--jobs must be a positive integer" >&2
  exit 1
fi

if $DRY_RUN && ! $INTERACTIVE_TAG; then
  echo "-n/--dry-run requires -t/--tag" >&2
  exit 1
fi

want_service() {
  local service="$1"
  [[ -z "$SERVICES_ARG" || ",${SERVICES_ARG}," == *",${service},"* ]]
}

log() {
  $QUIET || echo "$*" >&2
}

clean_value() {
  local value="${1//$'\r'/}"
  value="${value//$'\n'/ }"
  value="${value# }"
  value="${value% }"
  printf '%s' "$value"
}

is_missing_value() {
  local value
  value=$(clean_value "${1:-}")
  [[ -z "$value" || "$value" == "None" || "$value" == "none" || "$value" == "null" || "$value" == "NULL" || "$value" == "[]" || "$value" == "M" ]]
}

is_malformed_tag_value() {
  local value
  value=$(clean_value "${1:-}")
  is_missing_value "$value" && return 1
  [[ "$value" == \[malformed\]* ]] && return 0

  # Pasted audit rows, ARNs, and resource IDs are not valid app/env labels.
  [[ "$value" == *[[:space:]]* ]] && return 0
  ((${#value} > 64)) && return 0
  [[ "$value" == *,* ]] && return 0
  [[ "$value" == *arn:aws:* ]] && return 0
  [[ "$value" =~ vol-[0-9a-f]+ ]] && return 0
  [[ "$value" =~ i-[0-9a-f]{8,} ]] && return 0
  [[ "$value" =~ sg-[0-9a-f]{8,} ]] && return 0
  [[ "$value" =~ eipalloc-[0-9a-f]+ ]] && return 0
  [[ "$value" =~ Z[0-9A-Z]{10,} ]] && return 0
  [[ "$value" =~ ^(s3|cloudfront|route53|ec2-instance|ebs-volume|ebs-snapshot|eip|nat-gateway|security-group|elbv2|elb|rds-instance|rds-cluster|ecr|lambda|secretsmanager|logs|cloudwatch-alarm|dynamodb|sqs|sns|ses-identity|ses-configuration-set|ecs-cluster|ecs-service|efs|apprunner)[[:space:]] ]] && return 0
  return 1
}

format_malformed_display() {
  local value="$1"
  value=$(clean_value "$value")
  value=$(table_cell "$value" 96)
  printf '[malformed] %s' "$value"
}

classify_required_tag_value() {
  local value="$1"
  if is_missing_value "$value"; then
    printf 'missing'
  elif is_malformed_tag_value "$value"; then
    printf 'malformed'
  else
    printf 'ok'
  fi
}

join_by() {
  local sep="$1"
  shift || true
  local out=""
  local item
  for item in "$@"; do
    if [[ -z "$out" ]]; then
      out="$item"
    else
      out+="$sep$item"
    fi
  done
  printf '%s' "$out"
}

csv_escape() {
  local value="${1//\"/\"\"}"
  printf '"%s"' "$value"
}

csv_row() {
  local account="$1" region="$2" service="$3" name="$4" resource_id="$5" tags="$6"
  csv_escape "$account"; printf ','
  csv_escape "$region"; printf ','
  csv_escape "$service"; printf ','
  csv_escape "$name"; printf ','
  csv_escape "$resource_id"; printf ','
  csv_escape "$tags"; printf '\n'
}

aws_text() {
  local out
  out=$(aws "$@" --output text 2>/dev/null) || out=""
  clean_value "$out"
}

aws_query_text() {
  local query="$1"
  shift
  local out
  out=$(aws "$@" --query "$query" --output text 2>/dev/null) || out=""
  clean_value "$out"
}

aws_query_rows() {
  local query="$1"
  shift
  local out
  out=$(aws "$@" --query "$query" --output text 2>/dev/null) || out=""
  out="${out//$'\r'/}"
  printf '%s' "$out"
}

aws_query_list() {
  local query="$1"
  shift
  local out
  out=$(aws "$@" --query "$query" --output text 2>/dev/null) || out=""
  out="${out//$'\r'/}"
  # Text output may separate array elements with tabs or newlines; never join with spaces.
  printf '%s' "$out" | tr '\t' '\n'
}

required_tags_check() {
  local query_template="$1"
  shift
  local missing=()
  local display=()
  local key query value status
  for key in "${REQUIRED_TAGS[@]}"; do
    query="${query_template//__TAG_KEY__/$key}"
    value=$(aws_query_text "$query" "$@")
    status=$(classify_required_tag_value "$value")
    case "$status" in
      missing)
        missing+=("$key")
        display+=("M")
        ;;
      malformed)
        missing+=("$key")
        display+=("$(format_malformed_display "$value")")
        ;;
      *)
        display+=("$value")
        ;;
    esac
  done
  TAGS_COLUMN=$(join_by "," "${display[@]}")
  if [[ ${#missing[@]} -eq 0 ]]; then
    REQUIRED_MISSING=""
  else
    REQUIRED_MISSING=$(join_by "," "${missing[@]}")
  fi
}

required_ec2_tags_check() {
  local region="$1" resource_id="$2"
  local missing=()
  local display=()
  local key value status
  for key in "${REQUIRED_TAGS[@]}"; do
    value=$(aws_query_text "Tags[0].Value" ec2 describe-tags --region "$region" --filters "Name=resource-id,Values=$resource_id" "Name=key,Values=$key")
    status=$(classify_required_tag_value "$value")
    case "$status" in
      missing)
        missing+=("$key")
        display+=("M")
        ;;
      malformed)
        missing+=("$key")
        display+=("$(format_malformed_display "$value")")
        ;;
      *)
        display+=("$value")
        ;;
    esac
  done
  TAGS_COLUMN=$(join_by "," "${display[@]}")
  if [[ ${#missing[@]} -eq 0 ]]; then
    REQUIRED_MISSING=""
  else
    REQUIRED_MISSING=$(join_by "," "${missing[@]}")
  fi
}

emit_resource() {
  local region="$1" service="$2" name="$3" resource_id="$4" missing="$5"
  local missing_resource=false
  local display_name display_resource tags_display
  TOTAL_SCANNED=$((TOTAL_SCANNED + 1))
  if [[ -n "$missing" ]]; then
    missing_resource=true
    TOTAL_MISSING=$((TOTAL_MISSING + 1))
  fi

  tags_display="${TAGS_COLUMN:-}"
  if $INTERACTIVE_TAG; then
    [[ -n "$tags_display" ]] && record_tag_values "$tags_display"
    if $missing_resource; then
      record_missing_resource "$region" "$service" "$name" "$resource_id" "$missing" "${tags_display:--}"
    fi
  fi

  if [[ -z "$missing" ]] && ! $SHOW_TAGGED; then
    TAGS_COLUMN=""
    return
  fi

  [[ -z "$tags_display" ]] && tags_display="-"
  TAGS_COLUMN=""

  if [[ "$OUTPUT" == "table" ]]; then
    display_name=$(table_cell "$name" 48)
    display_resource=$(table_cell "$resource_id" 64)
    if $REGION_EXPLICIT; then
      printf '%-14s %-18s %-48s %-64s %s\n' "$region" "$service" "$display_name" "$display_resource" "$tags_display"
    else
      printf '%-18s %-48s %-64s %s\n' "$service" "$display_name" "$display_resource" "$tags_display"
    fi
  else
    csv_row "$ACCOUNT_ID" "$region" "$service" "$name" "$resource_id" "$tags_display"
  fi

  if [[ -n "$CSV_FILE" && "$missing_resource" == true ]]; then
    csv_row "$ACCOUNT_ID" "$region" "$service" "$name" "$resource_id" "$tags_display" >> "$CSV_FILE"
  fi
}

table_cell() {
  local value="$1" width="$2"
  value=$(clean_value "$value")
  if [[ ${#value} -gt "$width" && "$width" -gt 3 ]]; then
    printf '%s...' "${value:0:$((width - 3))}"
  else
    printf '%s' "$value"
  fi
}

record_tag_values() {
  local tags_display="$1" app_val env_val
  [[ -z "$TAG_VALUES_APPS_FILE" || -z "$TAG_VALUES_ENVS_FILE" ]] && return 0
  IFS=',' read -r app_val env_val <<< "$tags_display"
  if [[ "$app_val" != "M" && "$app_val" != \[malformed\]* ]] && ! is_missing_value "$app_val" && ! is_malformed_tag_value "$app_val"; then
    printf '%s\n' "$app_val" >> "$TAG_VALUES_APPS_FILE"
  fi
  if [[ "$env_val" != "M" && "$env_val" != \[malformed\]* ]] && ! is_missing_value "$env_val" && ! is_malformed_tag_value "$env_val"; then
    printf '%s\n' "$env_val" >> "$TAG_VALUES_ENVS_FILE"
  fi
}

record_missing_resource() {
  local region="$1" service="$2" name="$3" resource_id="$4" missing="$5" tags_display="$6"
  [[ -z "$MISSING_RESOURCES_FILE" ]] && return 0
  printf '%s\n' \
    "${region}${RECORD_FIELD_SEP}${service}${RECORD_FIELD_SEP}${name}${RECORD_FIELD_SEP}${resource_id}${RECORD_FIELD_SEP}${missing}${RECORD_FIELD_SEP}${tags_display}" \
    >> "$MISSING_RESOURCES_FILE"
}

build_key_value_tags() {
  local missing="$1" app="$2" env="$3"
  local tags=()
  [[ -n "$app" ]] && tags+=("Key=Application,Value=$app")
  [[ -n "$env" ]] && tags+=("Key=Environment,Value=$env")
  ((${#tags[@]})) && printf '%s\n' "${tags[@]}"
}

build_map_tags() {
  local missing="$1" app="$2" env="$3"
  local tags=()
  [[ -n "$app" ]] && tags+=("Application=$app")
  [[ -n "$env" ]] && tags+=("Environment=$env")
  ((${#tags[@]})) && printf '%s\n' "${tags[@]}"
}

build_ecs_tags() {
  local missing="$1" app="$2" env="$3"
  local tags=()
  [[ -n "$app" ]] && tags+=("key=Application,value=$app")
  [[ -n "$env" ]] && tags+=("key=Environment,value=$env")
  ((${#tags[@]})) && printf '%s\n' "${tags[@]}"
}

build_cloudfront_tags() {
  local missing="$1" app="$2" env="$3"
  local items=()
  [[ -n "$app" ]] && items+=("{Key=Application,Value=$app}")
  [[ -n "$env" ]] && items+=("{Key=Environment,Value=$env}")
  ((${#items[@]})) && printf 'Items=[%s]' "$(join_by , "${items[@]}")"
}

describe_tags_to_apply() {
  local missing="$1" app="$2" env="$3"
  local parts=()
  [[ -n "$app" ]] && parts+=("Application=$app")
  [[ -n "$env" ]] && parts+=("Environment=$env")
  ((${#parts[@]})) && join_by ", " "${parts[@]}"
}

aws_quiet() {
  aws "$@" >/dev/null || return 1
}

apply_route53_tags() {
  local resource_id="$1" missing="$2" app="$3" env="$4"
  local tags=() tag args=(route53 change-tags-for-resource --resource-type hostedzone --resource-id "$resource_id")

  read_lines_into tags < <(build_key_value_tags "$missing" "$app" "$env")
  ((${#tags[@]})) || return 0
  for tag in "${tags[@]}"; do
    args+=(--add-tags "$tag")
  done
  aws_quiet "${args[@]}"
}

apply_s3_tags() {
  local bucket="$1" missing="$2" app="$3" env="$4"
  local raw key value items=()

  raw=$(aws_query_rows "TagSet[].[Key,Value]" s3api get-bucket-tagging --bucket "$bucket" 2>/dev/null) || raw=""
  while IFS=$'\t' read -r key value; do
    [[ -z "$key" || "$key" == "None" ]] && continue
    [[ "$key" == "Application" && -n "$app" ]] && continue
    [[ "$key" == "Environment" && -n "$env" ]] && continue
    items+=("{Key=${key},Value=${value}}")
  done <<< "$raw"

  [[ -n "$app" ]] && items+=("{Key=Application,Value=$app}")
  [[ -n "$env" ]] && items+=("{Key=Environment,Value=$env}")

  aws_quiet s3api put-bucket-tagging --bucket "$bucket" --tagging "TagSet=[$(join_by , "${items[@]}")]"
}

read_lines_into() {
  local array_name="$1"
  local line
  eval "${array_name}=()"
  while IFS= read -r line; do
    [[ -n "$line" ]] && eval "${array_name}+=(\"\$line\")"
  done
}

apply_resource_tags() {
  local region="$1" service="$2" resource_id="$3" missing="$4" app="$5" env="$6"
  local tags=() map_tags=() ecs_tags=() arn cf_tags summary

  if $DRY_RUN; then
    summary=$(describe_tags_to_apply "$missing" "$app" "$env")
    [[ -z "$summary" ]] && return 0
    log "[dry-run] Would tag ${service} ${resource_id} (${region}): ${summary}"
    return 0
  fi

  case "$service" in
    ec2-instance|ebs-volume|ebs-snapshot|eip|nat-gateway|security-group)
      read_lines_into tags < <(build_key_value_tags "$missing" "$app" "$env")
      ((${#tags[@]})) || return 0
      aws_quiet ec2 create-tags --region "$region" --resources "$resource_id" --tags "${tags[@]}"
      ;;
    s3)
      apply_s3_tags "$resource_id" "$missing" "$app" "$env"
      ;;
    cloudfront)
      cf_tags=$(build_cloudfront_tags "$missing" "$app" "$env")
      [[ -z "$cf_tags" ]] && return 0
      arn="arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${resource_id}"
      aws_quiet cloudfront tag-resource --resource "$arn" --tags "$cf_tags"
      ;;
    route53)
      apply_route53_tags "$resource_id" "$missing" "$app" "$env"
      ;;
    elbv2)
      read_lines_into tags < <(build_key_value_tags "$missing" "$app" "$env")
      ((${#tags[@]})) || return 0
      aws_quiet elbv2 add-tags --region "$region" --resource-arns "$resource_id" --tags "${tags[@]}"
      ;;
    elb)
      read_lines_into tags < <(build_key_value_tags "$missing" "$app" "$env")
      ((${#tags[@]})) || return 0
      aws_quiet elb add-tags --region "$region" --load-balancer-names "$resource_id" --tags "${tags[@]}"
      ;;
    rds-instance|rds-cluster)
      read_lines_into tags < <(build_key_value_tags "$missing" "$app" "$env")
      ((${#tags[@]})) || return 0
      aws_quiet rds add-tags-to-resource --region "$region" --resource-name "$resource_id" --tags "${tags[@]}"
      ;;
    ecr)
      read_lines_into tags < <(build_key_value_tags "$missing" "$app" "$env")
      ((${#tags[@]})) || return 0
      aws_quiet ecr tag-resource --region "$region" --resource-arn "$resource_id" --tags "${tags[@]}"
      ;;
    lambda)
      read_lines_into map_tags < <(build_map_tags "$missing" "$app" "$env")
      ((${#map_tags[@]})) || return 0
      aws_quiet lambda tag-resource --region "$region" --resource "$resource_id" --tags "$(join_by , "${map_tags[@]}")"
      ;;
    secretsmanager)
      read_lines_into tags < <(build_key_value_tags "$missing" "$app" "$env")
      ((${#tags[@]})) || return 0
      aws_quiet secretsmanager tag-resource --region "$region" --secret-id "$resource_id" --tags "${tags[@]}"
      ;;
    logs)
      read_lines_into map_tags < <(build_map_tags "$missing" "$app" "$env")
      ((${#map_tags[@]})) || return 0
      aws_quiet logs tag-log-group --region "$region" --log-group-name "$resource_id" --tags "$(join_by , "${map_tags[@]}")"
      ;;
    cloudwatch-alarm)
      read_lines_into tags < <(build_key_value_tags "$missing" "$app" "$env")
      ((${#tags[@]})) || return 0
      aws_quiet cloudwatch tag-resource --region "$region" --resource-arn "$resource_id" --tags "${tags[@]}"
      ;;
    dynamodb)
      read_lines_into tags < <(build_key_value_tags "$missing" "$app" "$env")
      ((${#tags[@]})) || return 0
      aws_quiet dynamodb tag-resource --region "$region" --resource-arn "$resource_id" --tags "${tags[@]}"
      ;;
    sqs)
      read_lines_into map_tags < <(build_map_tags "$missing" "$app" "$env")
      ((${#map_tags[@]})) || return 0
      aws_quiet sqs tag-queue --region "$region" --queue-url "$resource_id" --tags "$(join_by , "${map_tags[@]}")"
      ;;
    sns)
      read_lines_into tags < <(build_key_value_tags "$missing" "$app" "$env")
      ((${#tags[@]})) || return 0
      aws_quiet sns tag-resource --region "$region" --resource-arn "$resource_id" --tags "${tags[@]}"
      ;;
    ses-identity|ses-configuration-set)
      read_lines_into tags < <(build_key_value_tags "$missing" "$app" "$env")
      ((${#tags[@]})) || return 0
      aws_quiet sesv2 tag-resource --region "$region" --resource-arn "$resource_id" --tags "${tags[@]}"
      ;;
    ecs-cluster|ecs-service)
      read_lines_into ecs_tags < <(build_ecs_tags "$missing" "$app" "$env")
      ((${#ecs_tags[@]})) || return 0
      aws_quiet ecs tag-resource --region "$region" --resource-arn "$resource_id" --tags "${ecs_tags[@]}"
      ;;
    apprunner)
      read_lines_into tags < <(build_key_value_tags "$missing" "$app" "$env")
      ((${#tags[@]})) || return 0
      aws_quiet apprunner tag-resource --region "$region" --resource-arn "$resource_id" --tags "${tags[@]}"
      ;;
    efs)
      read_lines_into tags < <(build_key_value_tags "$missing" "$app" "$env")
      ((${#tags[@]})) || return 0
      aws_quiet efs tag-resource --region "$region" --resource-id "$resource_id" --tags "${tags[@]}"
      ;;
    *)
      echo "Unsupported service for tagging: $service" >&2
      return 1
      ;;
  esac
}

load_unique_values() {
  local file="$1"
  local dest_name="$2"
  local line
  eval "${dest_name}=()"
  [[ ! -s "$file" ]] && return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] && eval "${dest_name}+=(\"\$line\")"
  done < <(sort -u "$file")
}

reply_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

merge_interactive_scan_files() {
  MERGED_MISSING_FILE="$RUN_TMP_DIR/missing.tsv"
  MERGED_APPS_FILE="$RUN_TMP_DIR/apps.txt"
  MERGED_ENVS_FILE="$RUN_TMP_DIR/envs.txt"
  : > "$MERGED_MISSING_FILE"
  : > "$MERGED_APPS_FILE"
  : > "$MERGED_ENVS_FILE"

  local i
  for ((i=0; i<JOB_COUNT; i++)); do
    [[ -s "$RUN_TMP_DIR/${i}.${JOB_LABELS[$i]}.missing" ]] && \
      cat "$RUN_TMP_DIR/${i}.${JOB_LABELS[$i]}.missing" >> "$MERGED_MISSING_FILE"
    [[ -s "$RUN_TMP_DIR/${i}.${JOB_LABELS[$i]}.apps" ]] && \
      cat "$RUN_TMP_DIR/${i}.${JOB_LABELS[$i]}.apps" >> "$MERGED_APPS_FILE"
    [[ -s "$RUN_TMP_DIR/${i}.${JOB_LABELS[$i]}.envs" ]] && \
      cat "$RUN_TMP_DIR/${i}.${JOB_LABELS[$i]}.envs" >> "$MERGED_ENVS_FILE"
  done
}

wait_tag_jobs() {
  local pid
  # Bash 3.2 + set -u treats "${array[@]}" on an empty array as unbound.
  if ((${#TAG_JOB_PIDS[@]} > 0)); then
    for pid in "${TAG_JOB_PIDS[@]}"; do
      wait "$pid" 2>/dev/null || true
    done
  fi
  TAG_JOB_PIDS=()
}

append_tag_error_log() {
  local service="$1" name="$2" err_file="$3"
  local line
  [[ ! -s "$err_file" ]] && return 0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    printf '[%s %s] %s\n' "$service" "$name" "$line" >> "${TAG_FAILURES_FILE}.log"
  done < "$err_file"
}

queue_resource_tags() {
  local region="$1" service="$2" name="$3" resource_id="$4" missing="$5" app="$6" env="$7"
  local err_file
  if $DRY_RUN; then
    apply_resource_tags "$region" "$service" "$resource_id" "$missing" "$app" "$env"
    return 0
  fi
  err_file="${TAG_ERR_DIR}/job.${#TAG_JOB_PIDS[@]}.err"
  (
    if ! apply_resource_tags "$region" "$service" "$resource_id" "$missing" "$app" "$env" 2>"$err_file"; then
      printf '%s\n' "${service}${RECORD_FIELD_SEP}${name}${RECORD_FIELD_SEP}${resource_id}" >> "$TAG_FAILURES_FILE"
      append_tag_error_log "$service" "$name" "$err_file"
    fi
  ) &
  TAG_JOB_PIDS+=("$!")
}

print_tag_session_summary() {
  local total="$1" tagged="$2" skipped="$3"
  local untagged="$4" i failed=0
  local display_service display_name line fail_service fail_name fail_id

  if [[ -s "$TAG_FAILURES_FILE" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && failed=$((failed + 1))
    done < "$TAG_FAILURES_FILE"
  fi

  echo "" >&2
  echo "Tagging summary:" >&2
  echo "  Untagged resources: ${untagged}" >&2
  echo "  Tagged resources: ${tagged}" >&2
  if [[ "$failed" -gt 0 ]]; then
    echo "  Failed resources: ${failed}" >&2
  fi
  if [[ "$skipped" -gt 0 ]]; then
    echo "  Skipped resources: ${skipped}" >&2
  fi
  if [[ "$tagged" -eq 0 ]]; then
    if [[ "$failed" -gt 0 && -s "${TAG_FAILURES_FILE}.log" ]]; then
      echo "" >&2
      echo "Errors:" >&2
      cat "${TAG_FAILURES_FILE}.log" >&2
    fi
    return 0
  fi

  echo "" >&2
  printf '%-18s %-48s %-24s %s\n' "SERVICE" "RESOURCE_NAME" "APP" "ENV" >&2
  printf '%-18s %-48s %-24s %s\n' "------------------" "------------------------------------------------" "------------------------" "----------------" >&2
  for ((i=0; i<tagged; i++)); do
    display_service=$(table_cell "${TAGGED_SERVICES[$i]}" 18)
    display_name=$(table_cell "${TAGGED_NAMES[$i]}" 48)
    printf '%-18s %-48s %-24s %s\n' \
      "$display_service" "$display_name" "${TAGGED_APPS[$i]}" "${TAGGED_ENVS[$i]}" >&2
  done

  if [[ "$failed" -gt 0 ]]; then
    echo "" >&2
    echo "Failed:" >&2
    while IFS= read -r line; do
      IFS="$RECORD_FIELD_SEP" read -r fail_service fail_name fail_id <<< "$line"
      [[ -z "$fail_service" ]] && continue
      printf '  %s %s (%s)\n' "$fail_service" "$fail_name" "$fail_id" >&2
    done < "$TAG_FAILURES_FILE"
    if [[ -s "${TAG_FAILURES_FILE}.log" ]]; then
      echo "" >&2
      echo "Errors:" >&2
      cat "${TAG_FAILURES_FILE}.log" >&2
    fi
  fi
}

interactive_tag_resources() {
  local missing_lines=() known_apps=() known_envs=()
  local reply reply_l app env region service name resource_id missing tags_display
  local total tagged=0 skipped=0 i
  local apps_list envs_list

  TAG_JOB_PIDS=()
  TAGGED_SERVICES=()
  TAGGED_NAMES=()
  TAGGED_APPS=()
  TAGGED_ENVS=()
  TAG_FAILURES_FILE="$RUN_TMP_DIR/tag-failures.tsv"
  TAG_ERR_DIR="$RUN_TMP_DIR/tag-errors"
  mkdir -p "$TAG_ERR_DIR"
  : > "$TAG_FAILURES_FILE"
  : > "${TAG_FAILURES_FILE}.log"

  merge_interactive_scan_files
  read_lines_into missing_lines < "$MERGED_MISSING_FILE"
  load_unique_values "$MERGED_APPS_FILE" known_apps
  load_unique_values "$MERGED_ENVS_FILE" known_envs
  total="${#missing_lines[@]}"

  if [[ "$total" -eq 0 ]]; then
    log "No resources with missing or malformed required tags."
    return 0
  fi

  apps_list=$(
    if ((${#known_apps[@]})); then join_by ", " "${known_apps[@]}"; else echo "(none found)"; fi
  )
  envs_list=$(
    if ((${#known_envs[@]})); then join_by ", " "${known_envs[@]}"; else echo "(none found)"; fi
  )

  echo "" >&2
  if $DRY_RUN; then
    echo "Interactive tagging (dry-run): ${total} resource(s) with missing or malformed tags." >&2
  else
    echo "Interactive tagging: ${total} resource(s) with missing or malformed tags." >&2
  fi
  echo "Enter app,env for each resource, or s to skip, q to quit." >&2

  for ((i=0; i<total; i++)); do
    IFS="$RECORD_FIELD_SEP" read -r region service name resource_id missing tags_display <<< "${missing_lines[$i]}"
    echo "" >&2
    echo "[$((i + 1))/${total}] ${service} ${name}" >&2
    [[ "$tags_display" != "-" ]] && echo "  Current tags: ${tags_display}" >&2
    echo "  Applications: ${apps_list}" >&2
    echo "  Environments: ${envs_list}" >&2

    while true; do
      read -r -p "app,env (s=skip q=quit): " reply
      reply=$(clean_value "$reply")
      reply_l=$(reply_lower "$reply")
      case "$reply_l" in
        q|quit)
          break 2
          ;;
        s|skip)
          skipped=$((skipped + 1))
          break
          ;;
        *)
          if [[ "$reply" == *,* ]]; then
            IFS=',' read -r app env <<< "$reply"
            app=$(clean_value "$app")
            env=$(clean_value "$env")
            if [[ -n "$app" && -n "$env" ]]; then
              if is_malformed_tag_value "$app" || is_malformed_tag_value "$env"; then
                echo "Invalid app or env (too long, whitespace, or looks like pasted audit output). Try again." >&2
                continue
              fi
              TAGGED_SERVICES+=("$service")
              TAGGED_NAMES+=("$name")
              TAGGED_APPS+=("$app")
              TAGGED_ENVS+=("$env")
              queue_resource_tags "$region" "$service" "$name" "$resource_id" "$missing" "$app" "$env"
              tagged=$((tagged + 1))
              break
            fi
          fi
          echo "Enter app,env or s or q." >&2
          ;;
      esac
    done
  done

  wait_tag_jobs
  print_tag_session_summary "$total" "$tagged" "$skipped" "$((total - tagged - skipped))"
  if ! $DRY_RUN && [[ "$tagged" -gt 0 ]]; then
    local applied=$((tagged))
    if [[ -s "$TAG_FAILURES_FILE" ]]; then
      local fail_line fail_count=0
      while IFS= read -r fail_line; do
        [[ -n "$fail_line" ]] && fail_count=$((fail_count + 1))
      done < "$TAG_FAILURES_FILE"
      applied=$((tagged - fail_count))
    fi
    if [[ "$applied" -gt 0 ]]; then
      TOTAL_MISSING=$((TOTAL_MISSING - applied))
      (( TOTAL_MISSING < 0 )) && TOTAL_MISSING=0
    fi
  fi
}

region_enabled() {
  local region="$1"
  [[ -n "$region" && "$region" != "None" ]]
}

scan_s3() {
  want_service s3 || return
  log "Scanning global service: s3"
  local buckets bucket region missing
  buckets=$(aws_query_text "Buckets[].Name" s3api list-buckets)
  [[ -z "$buckets" || "$buckets" == "None" ]] && return
  for bucket in $buckets; do
    region=$(aws_query_text "LocationConstraint" s3api get-bucket-location --bucket "$bucket")
    [[ -z "$region" || "$region" == "None" ]] && region="us-east-1"
    [[ "$region" == "EU" ]] && region="eu-west-1"
    required_tags_check "TagSet[?Key=='__TAG_KEY__'].Value|[0]" s3api get-bucket-tagging --bucket "$bucket"; missing="$REQUIRED_MISSING"
    emit_resource "$region" "s3" "$bucket" "$bucket" "$missing"
  done
}

scan_cloudfront() {
  want_service cloudfront || return
  log "Scanning global service: cloudfront"
  local raw id arn domain missing
  raw=$(aws_query_rows "DistributionList.Items[].[Id,ARN,DomainName]" cloudfront list-distributions)
  [[ -z "$raw" || "$raw" == "None" ]] && return
  while IFS=$'\t' read -r id arn domain; do
    [[ -z "$id" || "$id" == "None" ]] && continue
    required_tags_check "Tags.Items[?Key=='__TAG_KEY__'].Value|[0]" cloudfront list-tags-for-resource --resource "$arn"; missing="$REQUIRED_MISSING"
    emit_resource "global" "cloudfront" "${domain:-$id}" "$id" "$missing"
  done <<< "$raw"
}

scan_route53() {
  want_service route53 || return
  log "Scanning global service: route53"
  local raw id name short_id missing
  raw=$(aws_query_rows "HostedZones[].[Id,Name]" route53 list-hosted-zones)
  [[ -z "$raw" || "$raw" == "None" ]] && return
  while IFS=$'\t' read -r id name; do
    [[ -z "$id" || "$id" == "None" ]] && continue
    short_id="${id##*/}"
    required_tags_check "ResourceTagSet.Tags[?Key=='__TAG_KEY__'].Value|[0]" route53 list-tags-for-resource --resource-type hostedzone --resource-id "$short_id"; missing="$REQUIRED_MISSING"
    emit_resource "global" "route53" "$name" "$short_id" "$missing"
  done <<< "$raw"
}

scan_ec2_instances() {
  local region="$1"
  want_service ec2-instance || return
  log "Scanning $region: ec2-instance"
  local ids id name missing
  ids=$(aws_query_text "Reservations[].Instances[].InstanceId" ec2 describe-instances --region "$region" --filters "Name=instance-state-name,Values=pending,running,stopping,stopped")
  [[ -z "$ids" || "$ids" == "None" ]] && return
  for id in $ids; do
    name=$(aws_query_text "Reservations[0].Instances[0].Tags[?Key=='Name'].Value|[0]" ec2 describe-instances --region "$region" --instance-ids "$id")
    is_missing_value "$name" && name="$id"
    required_ec2_tags_check "$region" "$id"; missing="$REQUIRED_MISSING"
    emit_resource "$region" "ec2-instance" "$name" "$id" "$missing"
  done
}

scan_ebs_volumes() {
  local region="$1"
  want_service ebs-volume || return
  log "Scanning $region: ebs-volume"
  local ids id name missing
  ids=$(aws_query_text "Volumes[].VolumeId" ec2 describe-volumes --region "$region")
  [[ -z "$ids" || "$ids" == "None" ]] && return
  for id in $ids; do
    name=$(aws_query_text "Tags[0].Value" ec2 describe-tags --region "$region" --filters "Name=resource-id,Values=$id" "Name=key,Values=Name")
    is_missing_value "$name" && name="$id"
    required_ec2_tags_check "$region" "$id"; missing="$REQUIRED_MISSING"
    emit_resource "$region" "ebs-volume" "$name" "$id" "$missing"
  done
}

scan_ebs_snapshots() {
  local region="$1"
  want_service ebs-snapshot || return
  log "Scanning $region: ebs-snapshot"
  local ids id name missing
  ids=$(aws_query_text "Snapshots[].SnapshotId" ec2 describe-snapshots --region "$region" --owner-ids self)
  [[ -z "$ids" || "$ids" == "None" ]] && return
  for id in $ids; do
    name=$(aws_query_text "Tags[0].Value" ec2 describe-tags --region "$region" --filters "Name=resource-id,Values=$id" "Name=key,Values=Name")
    is_missing_value "$name" && name="$id"
    required_ec2_tags_check "$region" "$id"; missing="$REQUIRED_MISSING"
    emit_resource "$region" "ebs-snapshot" "$name" "$id" "$missing"
  done
}

scan_eips() {
  local region="$1"
  want_service eip || return
  log "Scanning $region: eip"
  local raw alloc ip name missing
  raw=$(aws_query_rows "Addresses[].[AllocationId,PublicIp]" ec2 describe-addresses --region "$region")
  [[ -z "$raw" || "$raw" == "None" ]] && return
  while IFS=$'\t' read -r alloc ip; do
    [[ -z "$alloc" || "$alloc" == "None" ]] && continue
    name=$(aws_query_text "Tags[0].Value" ec2 describe-tags --region "$region" --filters "Name=resource-id,Values=$alloc" "Name=key,Values=Name")
    is_missing_value "$name" && name="$ip"
    required_ec2_tags_check "$region" "$alloc"; missing="$REQUIRED_MISSING"
    emit_resource "$region" "eip" "$name" "$alloc" "$missing"
  done <<< "$raw"
}

scan_nat_gateways() {
  local region="$1"
  want_service nat-gateway || return
  log "Scanning $region: nat-gateway"
  local ids id name missing
  ids=$(aws_query_text "NatGateways[?State!='deleted'].NatGatewayId" ec2 describe-nat-gateways --region "$region")
  [[ -z "$ids" || "$ids" == "None" ]] && return
  for id in $ids; do
    name=$(aws_query_text "Tags[0].Value" ec2 describe-tags --region "$region" --filters "Name=resource-id,Values=$id" "Name=key,Values=Name")
    is_missing_value "$name" && name="$id"
    required_ec2_tags_check "$region" "$id"; missing="$REQUIRED_MISSING"
    emit_resource "$region" "nat-gateway" "$name" "$id" "$missing"
  done
}

scan_security_groups() {
  local region="$1"
  want_service security-group || return
  log "Scanning $region: security-group"
  local raw id name missing
  raw=$(aws_query_rows "SecurityGroups[?GroupName!='default'].[GroupId,GroupName]" ec2 describe-security-groups --region "$region")
  [[ -z "$raw" || "$raw" == "None" ]] && return
  while IFS=$'\t' read -r id name; do
    [[ -z "$id" || "$id" == "None" ]] && continue
    required_ec2_tags_check "$region" "$id"; missing="$REQUIRED_MISSING"
    emit_resource "$region" "security-group" "$name" "$id" "$missing"
  done <<< "$raw"
}

scan_elbv2() {
  local region="$1"
  want_service elbv2 || return
  log "Scanning $region: elbv2"
  local raw name arn missing
  raw=$(aws_query_rows "LoadBalancers[].[LoadBalancerName,LoadBalancerArn]" elbv2 describe-load-balancers --region "$region")
  [[ -z "$raw" || "$raw" == "None" ]] && return
  while IFS=$'\t' read -r name arn; do
    [[ -z "$arn" || "$arn" == "None" ]] && continue
    required_tags_check "TagDescriptions[0].Tags[?Key=='__TAG_KEY__'].Value|[0]" elbv2 describe-tags --region "$region" --resource-arns "$arn"; missing="$REQUIRED_MISSING"
    emit_resource "$region" "elbv2" "$name" "$arn" "$missing"
  done <<< "$raw"
}

scan_elb() {
  local region="$1"
  want_service elb || return
  log "Scanning $region: elb"
  local names name missing
  names=$(aws_query_text "LoadBalancerDescriptions[].LoadBalancerName" elb describe-load-balancers --region "$region")
  [[ -z "$names" || "$names" == "None" ]] && return
  for name in $names; do
    required_tags_check "TagDescriptions[0].Tags[?Key=='__TAG_KEY__'].Value|[0]" elb describe-tags --region "$region" --load-balancer-names "$name"; missing="$REQUIRED_MISSING"
    emit_resource "$region" "elb" "$name" "$name" "$missing"
  done
}

scan_rds_instances() {
  local region="$1"
  want_service rds-instance || return
  log "Scanning $region: rds-instance"
  local raw name arn missing
  raw=$(aws_query_rows "DBInstances[].[DBInstanceIdentifier,DBInstanceArn]" rds describe-db-instances --region "$region")
  [[ -z "$raw" || "$raw" == "None" ]] && return
  while IFS=$'\t' read -r name arn; do
    [[ -z "$arn" || "$arn" == "None" ]] && continue
    required_tags_check "TagList[?Key=='__TAG_KEY__'].Value|[0]" rds list-tags-for-resource --region "$region" --resource-name "$arn"; missing="$REQUIRED_MISSING"
    emit_resource "$region" "rds-instance" "$name" "$arn" "$missing"
  done <<< "$raw"
}

scan_rds_clusters() {
  local region="$1"
  want_service rds-cluster || return
  log "Scanning $region: rds-cluster"
  local raw name arn missing
  raw=$(aws_query_rows "DBClusters[].[DBClusterIdentifier,DBClusterArn]" rds describe-db-clusters --region "$region")
  [[ -z "$raw" || "$raw" == "None" ]] && return
  while IFS=$'\t' read -r name arn; do
    [[ -z "$arn" || "$arn" == "None" ]] && continue
    required_tags_check "TagList[?Key=='__TAG_KEY__'].Value|[0]" rds list-tags-for-resource --region "$region" --resource-name "$arn"; missing="$REQUIRED_MISSING"
    emit_resource "$region" "rds-cluster" "$name" "$arn" "$missing"
  done <<< "$raw"
}

scan_ecr() {
  local region="$1"
  want_service ecr || return
  log "Scanning $region: ecr"
  local raw name arn missing
  raw=$(aws_query_rows "repositories[].[repositoryName,repositoryArn]" ecr describe-repositories --region "$region")
  [[ -z "$raw" || "$raw" == "None" ]] && return
  while IFS=$'\t' read -r name arn; do
    [[ -z "$arn" || "$arn" == "None" ]] && continue
    required_tags_check "tags[?Key=='__TAG_KEY__'].Value|[0]" ecr list-tags-for-resource --region "$region" --resource-arn "$arn"; missing="$REQUIRED_MISSING"
    emit_resource "$region" "ecr" "$name" "$arn" "$missing"
  done <<< "$raw"
}

scan_lambda() {
  local region="$1"
  want_service lambda || return
  log "Scanning $region: lambda"
  local raw name arn missing
  raw=$(aws_query_rows "Functions[].[FunctionName,FunctionArn]" lambda list-functions --region "$region")
  [[ -z "$raw" || "$raw" == "None" ]] && return
  while IFS=$'\t' read -r name arn; do
    [[ -z "$arn" || "$arn" == "None" ]] && continue
    required_tags_check "Tags.\"__TAG_KEY__\"" lambda list-tags --region "$region" --resource "$arn"; missing="$REQUIRED_MISSING"
    emit_resource "$region" "lambda" "$name" "$arn" "$missing"
  done <<< "$raw"
}

scan_secretsmanager() {
  local region="$1"
  want_service secretsmanager || return
  log "Scanning $region: secretsmanager"
  local raw name arn missing
  raw=$(aws_query_rows "SecretList[].[Name,ARN]" secretsmanager list-secrets --region "$region")
  [[ -z "$raw" || "$raw" == "None" ]] && return
  while IFS=$'\t' read -r name arn; do
    [[ -z "$arn" || "$arn" == "None" ]] && continue
    required_tags_check "Tags[?Key=='__TAG_KEY__'].Value|[0]" secretsmanager describe-secret --region "$region" --secret-id "$arn"; missing="$REQUIRED_MISSING"
    emit_resource "$region" "secretsmanager" "$name" "$arn" "$missing"
  done <<< "$raw"
}

scan_logs() {
  local region="$1"
  want_service logs || return
  log "Scanning $region: logs"
  local name missing
  while IFS= read -r name; do
    [[ -z "$name" || "$name" == "None" ]] && continue
    required_tags_check "tags.\"__TAG_KEY__\"" logs list-tags-log-group --region "$region" --log-group-name "$name"; missing="$REQUIRED_MISSING"
    emit_resource "$region" "logs" "$name" "$name" "$missing"
  done <<< "$(aws_query_list "logGroups[].logGroupName" logs describe-log-groups --region "$region")"
}

scan_cloudwatch_alarms() {
  local region="$1"
  want_service cloudwatch-alarm || want_service cloudwatch || return
  log "Scanning $region: cloudwatch-alarm"
  local raw name arn missing
  raw=$(aws_query_rows "MetricAlarms[].[AlarmName,AlarmArn]" cloudwatch describe-alarms --region "$region")
  [[ -z "$raw" || "$raw" == "None" ]] && return
  while IFS=$'\t' read -r name arn; do
    [[ -z "$arn" || "$arn" == "None" ]] && continue
    required_tags_check "Tags[?Key=='__TAG_KEY__'].Value|[0]" cloudwatch list-tags-for-resource --region "$region" --resource-arn "$arn"; missing="$REQUIRED_MISSING"
    emit_resource "$region" "cloudwatch-alarm" "$name" "$arn" "$missing"
  done <<< "$raw"
}

scan_dynamodb() {
  local region="$1"
  want_service dynamodb || return
  log "Scanning $region: dynamodb"
  local tables table arn missing
  tables=$(aws_query_text "TableNames[]" dynamodb list-tables --region "$region")
  [[ -z "$tables" || "$tables" == "None" ]] && return
  for table in $tables; do
    arn=$(aws_query_text "Table.TableArn" dynamodb describe-table --region "$region" --table-name "$table")
    [[ -z "$arn" || "$arn" == "None" ]] && continue
    required_tags_check "Tags[?Key=='__TAG_KEY__'].Value|[0]" dynamodb list-tags-of-resource --region "$region" --resource-arn "$arn"; missing="$REQUIRED_MISSING"
    emit_resource "$region" "dynamodb" "$table" "$arn" "$missing"
  done
}

scan_sqs() {
  local region="$1"
  want_service sqs || return
  log "Scanning $region: sqs"
  local urls url name missing
  urls=$(aws_query_text "QueueUrls[]" sqs list-queues --region "$region")
  [[ -z "$urls" || "$urls" == "None" ]] && return
  for url in $urls; do
    name="${url##*/}"
    required_tags_check "Tags.\"__TAG_KEY__\"" sqs list-queue-tags --region "$region" --queue-url "$url"; missing="$REQUIRED_MISSING"
    emit_resource "$region" "sqs" "$name" "$url" "$missing"
  done
}

scan_sns() {
  local region="$1"
  want_service sns || return
  log "Scanning $region: sns"
  local arns arn name missing
  arns=$(aws_query_text "Topics[].TopicArn" sns list-topics --region "$region")
  [[ -z "$arns" || "$arns" == "None" ]] && return
  for arn in $arns; do
    name="${arn##*:}"
    required_tags_check "Tags[?Key=='__TAG_KEY__'].Value|[0]" sns list-tags-for-resource --region "$region" --resource-arn "$arn"; missing="$REQUIRED_MISSING"
    emit_resource "$region" "sns" "$name" "$arn" "$missing"
  done
}

scan_ses() {
  local region="$1"
  if want_service ses-identity || want_service ses; then
    log "Scanning $region: ses-identity"
    local identities identity arn missing
    identities=$(aws_query_text "Identities[]" ses list-identities --region "$region")
    if [[ -n "$identities" && "$identities" != "None" ]]; then
      for identity in $identities; do
        arn="arn:aws:ses:${region}:${ACCOUNT_ID}:identity/${identity}"
        required_tags_check "Tags[?Key=='__TAG_KEY__'].Value|[0]" sesv2 list-tags-for-resource --region "$region" --resource-arn "$arn"; missing="$REQUIRED_MISSING"
        emit_resource "$region" "ses-identity" "$identity" "$arn" "$missing"
      done
    fi
  fi

  want_service ses-configuration-set || want_service ses || return
  log "Scanning $region: ses-configuration-set"
  local sets set arn missing
  sets=$(aws_query_text "ConfigurationSets[].Name" ses list-configuration-sets --region "$region")
  [[ -z "$sets" || "$sets" == "None" ]] && return
  for set in $sets; do
    arn="arn:aws:ses:${region}:${ACCOUNT_ID}:configuration-set/${set}"
    required_tags_check "Tags[?Key=='__TAG_KEY__'].Value|[0]" sesv2 list-tags-for-resource --region "$region" --resource-arn "$arn"; missing="$REQUIRED_MISSING"
    emit_resource "$region" "ses-configuration-set" "$set" "$arn" "$missing"
  done
}

scan_ecs() {
  local region="$1"
  if want_service ecs-cluster; then
    log "Scanning $region: ecs-cluster"
    local clusters cluster cname missing services service sname
    clusters=$(aws_query_text "clusterArns[]" ecs list-clusters --region "$region")
    if [[ -n "$clusters" && "$clusters" != "None" ]]; then
      for cluster in $clusters; do
        cname="${cluster##*/}"
        required_tags_check "tags[?key=='__TAG_KEY__'].value|[0]" ecs list-tags-for-resource --region "$region" --resource-arn "$cluster"; missing="$REQUIRED_MISSING"
        emit_resource "$region" "ecs-cluster" "$cname" "$cluster" "$missing"
      done
    fi
  fi
  want_service ecs-service || return
  log "Scanning $region: ecs-service"
  local cluster services service sname missing
  clusters=$(aws_query_text "clusterArns[]" ecs list-clusters --region "$region")
  [[ -z "$clusters" || "$clusters" == "None" ]] && return
  for cluster in $clusters; do
    services=$(aws_query_text "serviceArns[]" ecs list-services --region "$region" --cluster "$cluster")
    [[ -z "$services" || "$services" == "None" ]] && continue
    for service in $services; do
      sname="${service##*/}"
      required_tags_check "tags[?key=='__TAG_KEY__'].value|[0]" ecs list-tags-for-resource --region "$region" --resource-arn "$service"; missing="$REQUIRED_MISSING"
      emit_resource "$region" "ecs-service" "$sname" "$service" "$missing"
    done
  done
}

scan_efs() {
  local region="$1"
  want_service efs || return
  log "Scanning $region: efs"
  local ids id name missing
  ids=$(aws_query_text "FileSystems[].FileSystemId" efs describe-file-systems --region "$region")
  [[ -z "$ids" || "$ids" == "None" ]] && return
  for id in $ids; do
    name=$(aws_query_text "Tags[?Key=='Name'].Value|[0]" efs describe-tags --region "$region" --file-system-id "$id")
    is_missing_value "$name" && name="$id"
    required_tags_check "Tags[?Key=='__TAG_KEY__'].Value|[0]" efs describe-tags --region "$region" --file-system-id "$id"; missing="$REQUIRED_MISSING"
    emit_resource "$region" "efs" "$name" "$id" "$missing"
  done
}

scan_apprunner() {
  local region="$1"
  want_service apprunner || return
  log "Scanning $region: apprunner"
  local raw name arn missing
  raw=$(aws_query_rows "ServiceSummaryList[].[ServiceName,ServiceArn]" apprunner list-services --region "$region")
  [[ -z "$raw" || "$raw" == "None" ]] && return
  while IFS=$'\t' read -r name arn; do
    [[ -z "$arn" || "$arn" == "None" ]] && continue
    required_tags_check "Tags[?Key=='__TAG_KEY__'].Value|[0]" apprunner list-tags-for-resource --region "$region" --resource-arn "$arn"; missing="$REQUIRED_MISSING"
    emit_resource "$region" "apprunner" "$name" "$arn" "$missing"
  done <<< "$raw"
}

scan_region() {
  local region="$1"
  region_enabled "$region" || return
  scan_ec2_instances "$region"
  scan_ebs_volumes "$region"
  scan_ebs_snapshots "$region"
  scan_eips "$region"
  scan_nat_gateways "$region"
  scan_security_groups "$region"
  scan_elbv2 "$region"
  scan_elb "$region"
  scan_rds_instances "$region"
  scan_rds_clusters "$region"
  scan_ecr "$region"
  scan_lambda "$region"
  scan_secretsmanager "$region"
  scan_logs "$region"
  scan_cloudwatch_alarms "$region"
  scan_dynamodb "$region"
  scan_sqs "$region"
  scan_sns "$region"
  scan_ses "$region"
  scan_ecs "$region"
  scan_efs "$region"
  scan_apprunner "$region"
}

TASK_LABELS=()
TASK_FUNCS=()
TASK_ARGS=()
JOB_PIDS=()
JOB_LABELS=()
JOB_OUTS=()
JOB_METAS=()
JOB_CSVS=()
JOB_ERRS=()
JOB_COUNT=0
RUN_TMP_DIR=""
ORIGINAL_CSV_FILE=""

add_task() {
  local label="$1" func="$2" arg="${3:-}"
  local idx="${#TASK_LABELS[@]}"
  TASK_LABELS[$idx]="$label"
  TASK_FUNCS[$idx]="$func"
  TASK_ARGS[$idx]="$arg"
}

build_tasks() {
  TASK_LABELS=()
  TASK_FUNCS=()
  TASK_ARGS=()
  want_service s3 && add_task "s3" "scan_s3"
  want_service cloudfront && add_task "cloudfront" "scan_cloudfront"
  want_service route53 && add_task "route53" "scan_route53"
  want_service ec2-instance && add_task "ec2-instance" "scan_ec2_instances" "$REGION"
  want_service ebs-volume && add_task "ebs-volume" "scan_ebs_volumes" "$REGION"
  want_service ebs-snapshot && add_task "ebs-snapshot" "scan_ebs_snapshots" "$REGION"
  want_service eip && add_task "eip" "scan_eips" "$REGION"
  want_service nat-gateway && add_task "nat-gateway" "scan_nat_gateways" "$REGION"
  want_service security-group && add_task "security-group" "scan_security_groups" "$REGION"
  want_service elbv2 && add_task "elbv2" "scan_elbv2" "$REGION"
  want_service elb && add_task "elb" "scan_elb" "$REGION"
  want_service rds-instance && add_task "rds-instance" "scan_rds_instances" "$REGION"
  want_service rds-cluster && add_task "rds-cluster" "scan_rds_clusters" "$REGION"
  want_service ecr && add_task "ecr" "scan_ecr" "$REGION"
  want_service lambda && add_task "lambda" "scan_lambda" "$REGION"
  want_service secretsmanager && add_task "secretsmanager" "scan_secretsmanager" "$REGION"
  want_service logs && add_task "logs" "scan_logs" "$REGION"
  if want_service cloudwatch || want_service cloudwatch-alarm; then
    add_task "cloudwatch-alarm" "scan_cloudwatch_alarms" "$REGION"
  fi
  want_service dynamodb && add_task "dynamodb" "scan_dynamodb" "$REGION"
  want_service sqs && add_task "sqs" "scan_sqs" "$REGION"
  want_service sns && add_task "sns" "scan_sns" "$REGION"
  if want_service ses || want_service ses-identity || want_service ses-configuration-set; then
    add_task "ses" "scan_ses" "$REGION"
  fi
  if want_service ecs-cluster || want_service ecs-service; then
    add_task "ecs" "scan_ecs" "$REGION"
  fi
  want_service efs && add_task "efs" "scan_efs" "$REGION"
  want_service apprunner && add_task "apprunner" "scan_apprunner" "$REGION"
}

active_jobs() {
  local n=0 i pid
  for ((i=0; i<JOB_COUNT; i++)); do
    pid="${JOB_PIDS[$i]:-}"
    [[ -n "$pid" ]] && n=$((n + 1))
  done
  echo "$n"
}

progress_clear() {
  $QUIET && return
  printf '\r\033[K' >&2
}

progress_draw() {
  $QUIET && return
  local completed="$1" total="$2" active="$3"
  printf '\r\033[KScanning services: %d/%d complete, %d active' "$completed" "$total" "$active" >&2
}

progress_done() {
  $QUIET && return
  local label="$1" scanned="$2" missing="$3" completed="$4" total="$5" active="$6"
  local tagged=$((scanned - missing))
  printf '\r\033[K%s: %d tagged, %d missing  (%d/%d complete, %d active)' "$label" "$tagged" "$missing" "$completed" "$total" "$active" >&2
}

start_scan_job() {
  local label="$1" func="$2" arg="$3"
  local idx="$JOB_COUNT"
  local out="$RUN_TMP_DIR/${idx}.${label}.out"
  local meta="$RUN_TMP_DIR/${idx}.${label}.meta"
  local csv="$RUN_TMP_DIR/${idx}.${label}.csv"
  local err="$RUN_TMP_DIR/${idx}.${label}.err"

  (
    TOTAL_SCANNED=0
    TOTAL_MISSING=0
    CSV_FILE=""
    MISSING_RESOURCES_FILE=""
    TAG_VALUES_APPS_FILE=""
    TAG_VALUES_ENVS_FILE=""
    if $INTERACTIVE_TAG; then
      MISSING_RESOURCES_FILE="$RUN_TMP_DIR/${idx}.${label}.missing"
      TAG_VALUES_APPS_FILE="$RUN_TMP_DIR/${idx}.${label}.apps"
      TAG_VALUES_ENVS_FILE="$RUN_TMP_DIR/${idx}.${label}.envs"
      : > "$MISSING_RESOURCES_FILE"
      : > "$TAG_VALUES_APPS_FILE"
      : > "$TAG_VALUES_ENVS_FILE"
    fi
    [[ -n "$ORIGINAL_CSV_FILE" ]] && CSV_FILE="$csv"
    if [[ -n "$arg" ]]; then
      "$func" "$arg"
    else
      "$func"
    fi
    printf '%s %s\n' "$TOTAL_SCANNED" "$TOTAL_MISSING" > "$meta"
  ) > "$out" 2> "$err" &

  JOB_PIDS[$idx]="$!"
  JOB_LABELS[$idx]="$label"
  JOB_OUTS[$idx]="$out"
  JOB_METAS[$idx]="$meta"
  JOB_CSVS[$idx]="$csv"
  JOB_ERRS[$idx]="$err"
  JOB_COUNT=$((JOB_COUNT + 1))
}

process_finished_job() {
  local idx="$1"
  local pid="${JOB_PIDS[$idx]:-}"
  local running
  FINISHED_SCANNED=0
  FINISHED_MISSING=0
  [[ -z "$pid" ]] && return 1
  for running in $(jobs -pr); do
    [[ "$running" == "$pid" ]] && return 1
  done

  wait "$pid" 2>/dev/null || true

  if [[ -n "$ORIGINAL_CSV_FILE" && -s "${JOB_CSVS[$idx]}" ]]; then
    cat "${JOB_CSVS[$idx]}" >> "$ORIGINAL_CSV_FILE"
  fi

  if [[ -s "${JOB_METAS[$idx]}" ]]; then
    local scanned missing
    read scanned missing < "${JOB_METAS[$idx]}"
    FINISHED_SCANNED="$scanned"
    FINISHED_MISSING="$missing"
    TOTAL_SCANNED=$((TOTAL_SCANNED + scanned))
    TOTAL_MISSING=$((TOTAL_MISSING + missing))
  fi

  JOB_PIDS[$idx]=""
  return 0
}

run_parallel_scans() {
  build_tasks
  local total="${#TASK_LABELS[@]}"
  if [[ "$total" -eq 0 ]]; then
    echo "No services matched: ${SERVICES_ARG}" >&2
    return
  fi

  RUN_TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aws-tag-audit.XXXXXX")
  trap '[[ -n "${RUN_TMP_DIR:-}" ]] && rm -rf "$RUN_TMP_DIR"' EXIT

  local launched=0 completed=0 active=0 i
  progress_draw "$completed" "$total" "$active"

  while [[ "$completed" -lt "$total" ]]; do
    active=$(active_jobs)
    while [[ "$launched" -lt "$total" && "$active" -lt "$PARALLEL_JOBS" ]]; do
      start_scan_job "${TASK_LABELS[$launched]}" "${TASK_FUNCS[$launched]}" "${TASK_ARGS[$launched]}"
      launched=$((launched + 1))
      active=$((active + 1))
      progress_draw "$completed" "$total" "$active"
    done

    for ((i=0; i<JOB_COUNT; i++)); do
      if process_finished_job "$i"; then
        completed=$((completed + 1))
        active=$(active_jobs)
        progress_done "${JOB_LABELS[$i]}" "$FINISHED_SCANNED" "$FINISHED_MISSING" "$completed" "$total" "$active"
      fi
    done

    [[ "$completed" -lt "$total" ]] && sleep 0.2
  done

  progress_clear
}

print_output_header() {
  if [[ "$OUTPUT" == "table" ]]; then
    if $REGION_EXPLICIT; then
      printf '%-14s %-18s %-48s %-64s %s\n' "REGION" "SERVICE" "NAME" "RESOURCE_ID" "TAGS"
      printf '%-14s %-18s %-48s %-64s %s\n' "--------------" "------------------" "------------------------------------------------" "----------------------------------------------------------------" "------------"
    else
      printf '%-18s %-48s %-64s %s\n' "SERVICE" "NAME" "RESOURCE_ID" "TAGS"
      printf '%-18s %-48s %-64s %s\n' "------------------" "------------------------------------------------" "----------------------------------------------------------------" "------------"
    fi
  else
    csv_row "account" "region" "service" "name" "resource_id" "tags"
  fi
}

print_scan_results() {
  local i
  for ((i=0; i<JOB_COUNT; i++)); do
    [[ -s "${JOB_OUTS[$i]}" ]] && cat "${JOB_OUTS[$i]}"
  done
}

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI not found" >&2
  exit 1
fi

ACCOUNT_ID=$(aws_query_text "Account" sts get-caller-identity)
if is_missing_value "$ACCOUNT_ID"; then
  echo "Unable to call aws sts get-caller-identity. Check AWS CLI credentials." >&2
  exit 1
fi

if [[ -n "$CSV_FILE" ]]; then
  csv_row "account" "region" "service" "name" "resource_id" "tags" > "$CSV_FILE"
  ORIGINAL_CSV_FILE="$CSV_FILE"
fi

if ! region_enabled "$REGION"; then
  echo "Invalid region: $REGION" >&2
  exit 1
fi

run_parallel_scans
print_output_header
print_scan_results

log ""
log "Account: $ACCOUNT_ID"
log "Region: $REGION"
log "Required tags: $(join_by "," "${REQUIRED_TAGS[@]}")"
log "Scanned resources: $TOTAL_SCANNED"
log "Resources missing or malformed required tags: $TOTAL_MISSING"
if [[ -n "$CSV_FILE" ]]; then
  log "CSV written: $CSV_FILE"
fi

if $INTERACTIVE_TAG; then
  if [[ -t 0 ]]; then
    interactive_tag_resources
  else
    echo "Interactive tagging requires a TTY. Re-run with -t in a terminal." >&2
  fi
fi

if [[ $TOTAL_MISSING -gt 0 ]]; then
  exit 2
fi
