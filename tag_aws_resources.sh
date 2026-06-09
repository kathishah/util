#!/usr/bin/env bash
# Tag AWS resources for one or more applications in a repo.
#
# NAMING CONVENTIONS (AWS resource names):
#   Single-app repo : <repo>-<env>           e.g.  myapp-prod
#   Multi-app repo  : <repo>_<app>-<env>     e.g.  myrepo_worker-prod
#
# PREFIX AUTO-DETECTION (runs when -f is used):
#   Scans .github/workflows/*.yml, config files, Python source, and shell
#   scripts for AWS resource name literals (ECR repos, secret paths, RDS
#   endpoints, IAM roles) to infer the correct search prefix automatically.
#   e.g. myrepo → "shortname" detected from .github/workflows/aws_deploy.yml
#
# OVERRIDE (.aws-tagger.yml in project root — only needed for edge cases):
#   prefix: shortname        # explicit prefix when auto-detection isn't enough
#   lambda_prefix: pa         # separate prefix for Lambda functions (e.g. photoapp→pa)
#   app: myrepo            # Application tag override (defaults to directory name)
#
# WORKFLOW:
#   Phase 1 — Find    : per-service prefix scan — discovers ALL resources,
#                        including completely untagged ones.
#   Phase 2 — Diff    : reads current tags per resource and compares to desired.
#   Phase 3 — Apply   : uses resourcegroupstaggingapi tag-resources (merges
#                        existing tags, works for any AWS service type).
#                        -n skips apply and previews the changes instead.
#
# Adding a new AWS service type: copy any discover_X() function below, update
# the AWS CLI call for that service, and call it in run_discovery(). Phase 3
# never needs updating — tag-resources is service-agnostic.
#
# ─────────────────────────────────────────────────────────────────────────────
# Usage:
#   ./scripts/tag_aws_resources.sh [flags] [app] [environment]
#
# Flags:
#   -f, --find          auto-detect repo from current directory; find all apps
#   -n, --dry-run       show what would be tagged; make no AWS changes
#   -h, --help          show this help
#   --prefix PREFIX     override the AWS resource name search prefix
#                       (default: repo/directory name)
#   -j, --jobs N        discovery/diff jobs to run in parallel (default: 6)
#
# Arguments:
#   app          full app name, e.g. myapp or myrepo_worker
#                omit to tag all apps under the repo (requires -f)
#   environment  dev | staging | prod | all  (default: all)
#
# Examples:
#   cd ~/dev/myapp  &&  ./scripts/tag_aws_resources.sh -f -n
#   cd ~/dev/myrepo          &&  ./scripts/tag_aws_resources.sh -f -n
#   cd ~/dev/myrepo          &&  ./scripts/tag_aws_resources.sh -f -n --prefix shortname
#   ./scripts/tag_aws_resources.sh myapp prod -n
#   ./scripts/tag_aws_resources.sh -h

set -euo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────

FIND=false
DRY_RUN=false
APP_FILTER=""
ENV_FILTER="all"
REGION="${AWS_REGION:-us-west-2}"
PARALLEL_JOBS="${AWS_TAGGER_JOBS:-6}"
REPO=""
SEARCH_PREFIX=""   # overrides REPO for AWS name queries; defaults to REPO

usage() {
  echo "Usage: $(basename "$0") [flags] [app] [environment]"
  echo ""
  echo "Flags:"
  echo "  -f, --find          auto-detect repo from current directory; find all apps"
  echo "  -n, --dry-run       show what would be tagged; make no AWS changes"
  echo "  -h, --help          show this help"
  echo "  --prefix PREFIX     override the AWS resource name search prefix"
  echo "                      (default: repo/directory name)"
  echo "  -j, --jobs N        discovery/diff jobs to run in parallel (default: 6)"
  echo ""
  echo "Arguments:"
  echo "  app          e.g. myapp  or  myrepo_worker"
  echo "               omit to tag all apps under the repo (requires -f)"
  echo "  environment  dev | staging | prod | all  (default: all)"
  echo ""
  echo "Examples:"
  echo "  cd ~/dev/myapp  &&  $(basename "$0") -f -n"
  echo "  cd ~/dev/myrepo          &&  $(basename "$0") -f -n"
  echo "  cd ~/dev/myrepo          &&  $(basename "$0") -f -n --prefix shortname"
  echo "  $(basename "$0") myapp prod -n"
  echo ""
  echo "Config file (.aws-tagger.yml in project root):"
  echo "  prefix: shortname        # search prefix when AWS names differ from repo name"
  echo "  lambda_prefix: pa         # separate Lambda prefix (e.g. pa- for photoapp)"
  echo "  app: myrepo            # Application tag override (defaults to directory name)"
}

args=("$@")
i=0
while [[ $i -lt ${#args[@]} ]]; do
  arg="${args[$i]}"
  case "$arg" in
    -f|--find)    FIND=true ;;
    -n|--dry-run) DRY_RUN=true ;;
    -h|--help)    usage; exit 0 ;;
    --prefix)     ((i++)); SEARCH_PREFIX="${args[$i]}" ;;
    -j|--jobs)    ((i++)); PARALLEL_JOBS="${args[$i]}" ;;
    dev|staging|prod|all) ENV_FILTER="$arg" ;;
    -*) echo "Unknown option: $arg  (use -h for help)"; exit 1 ;;
    *)  [[ -z "$APP_FILTER" ]] && APP_FILTER="$arg" ;;
  esac
  ((i++))
done

if ! [[ "$PARALLEL_JOBS" =~ ^[0-9]+$ ]] || [[ "$PARALLEL_JOBS" -lt 1 ]]; then
  echo "-j/--jobs must be a positive integer"
  exit 1
fi

if $FIND; then
  REPO=$(basename "$(pwd)")
elif [[ -n "$APP_FILTER" ]]; then
  if [[ "$APP_FILTER" == *_* ]]; then
    REPO="${APP_FILTER%%_*}"    # myrepo_worker → myrepo
  else
    REPO="$APP_FILTER"          # myapp → myapp
  fi
else
  echo "Error: provide an app name or use -f (run from the project directory)."
  echo ""
  usage
  exit 1
fi

# .aws-tagger.yml — explicit override (highest priority; CLI --prefix beats it).
if [[ -f ".aws-tagger.yml" ]]; then
  cfg_prefix=$(grep -E '^prefix:' .aws-tagger.yml 2>/dev/null | awk '{print $2}' | tr -d '"'"'" || true)
  cfg_app=$(grep -E '^app:' .aws-tagger.yml 2>/dev/null | awk '{print $2}' | tr -d '"'"'" || true)
  cfg_lambda=$(grep -E '^lambda_prefix:' .aws-tagger.yml 2>/dev/null | awk '{print $2}' | tr -d '"'"'" || true)
  [[ -n "$cfg_prefix" && -z "$SEARCH_PREFIX" ]] && SEARCH_PREFIX="$cfg_prefix"
  [[ -n "$cfg_app"    ]] && REPO="$cfg_app"
  [[ -n "$cfg_lambda" ]] && LAMBDA_PREFIX="$cfg_lambda"
fi
# SEARCH_PREFIX is finalised in main (after all functions are defined) so that
# auto-detection — which needs the function definitions — can run first.

# ── Colors & logging ──────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

header() { echo ""; echo -e "${BOLD}── $1 ──${NC}"; }

# ── Global state ──────────────────────────────────────────────────────────────

# Each entry: "service|name|arn|desired_app|desired_env"
#   service : display label (apprunner | rds | s3 | ecr | secretsmgr | iam)
#   arn     : full ARN used for tagging (bucket name for s3, role name for iam)
declare -a RESOURCE_LIST=()

# Each entry: "service|name|arn|desired_app|desired_env|change_desc"
declare -a CHANGES=()

ALREADY_OK=0
ERRORS=0
ACCOUNT_ID=""

JOB_TMP_DIR=""
JOB_COUNT=0
declare -a JOB_PIDS=()
declare -a JOB_LABELS=()
declare -a JOB_OUTS=()
declare -a JOB_ERRS=()

# ── Core helpers ──────────────────────────────────────────────────────────────

get_account_id() {
  if [[ -z "$ACCOUNT_ID" ]]; then
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
  fi
  echo "$ACCOUNT_ID"
}

reset_jobs() {
  JOB_COUNT=0
  JOB_PIDS=()
  JOB_LABELS=()
  JOB_OUTS=()
  JOB_ERRS=()
}

active_jobs() {
  local n=0 i pid
  for ((i=0; i<JOB_COUNT; i++)); do
    pid="${JOB_PIDS[$i]:-}"
    [[ -n "$pid" ]] && n=$((n + 1))
  done
  echo "$n"
}

process_finished_job() {
  local idx="$1"
  local pid="${JOB_PIDS[$idx]:-}"
  local running
  [[ -z "$pid" ]] && return 1
  for running in $(jobs -pr); do
    [[ "$running" == "$pid" ]] && return 1
  done
  wait "$pid" 2>/dev/null || true
  JOB_PIDS[$idx]=""
  return 0
}

cleanup_job_tmp() {
  [[ -n "${JOB_TMP_DIR:-}" ]] && rm -rf "$JOB_TMP_DIR"
}

progress_clear() {
  printf '\r\033[K' >&2
}

progress_draw() {
  local phase="$1" completed="$2" total="$3" active="$4"
  printf '\r\033[K%s: %d/%d done, %d active' "$phase" "$completed" "$total" "$active" >&2
}

progress_done() {
  local phase="$1" label="$2" completed="$3" total="$4" active="$5"
  printf '\r\033[K%s: %s done  (%d/%d done, %d active)' "$phase" "$label" "$completed" "$total" "$active" >&2
}

# Derive environment from resource name suffix.
derive_env() {
  local name="$1"
  if   [[ "$name" == *"-prod-"*    || "$name" == *"-prod"    ]]; then echo "prod"
  elif [[ "$name" == *"-staging-"* || "$name" == *"-staging" ]]; then echo "staging"
  elif [[ "$name" == *"-dev-"*     || "$name" == *"-dev"     ]]; then echo "dev"
  else echo "prod"
  fi
}

# Parse resource name → "app_tag|env"
# Handles four cases:
#   1. myrepo_worker-prod (REPO=SEARCH_PREFIX=myrepo)     → myrepo_worker|prod
#   2. myapp-prod (REPO=SEARCH_PREFIX=myapp) → myapp|prod
#   3. shortname-prod        (REPO=myrepo, SEARCH_PREFIX=shortname) → myrepo|prod
#   4. shortname_worker-prod (same)                             → myrepo_worker|prod
parse_name() {
  local name="$1"
  local env; env=$(derive_env "$name")
  local app_tag
  if [[ "$name" == "${REPO}_"* ]]; then
    # Standard multi-app convention: <repo>_<apppart>-<env>
    local after="${name#${REPO}_}"
    local app_part="${after%%-${env}*}"
    app_tag="${REPO}_${app_part}"
  elif [[ "$SEARCH_PREFIX" != "$REPO" && "$name" == "${SEARCH_PREFIX}_"* ]]; then
    # Custom-prefix multi-app: <prefix>_<apppart>-<env> → <repo>_<apppart>
    local after="${name#${SEARCH_PREFIX}_}"
    local app_part="${after%%-${env}*}"
    app_tag="${REPO}_${app_part}"
  else
    app_tag="$REPO"
  fi
  echo "${app_tag}|${env}"
}

env_matches() {
  [[ "$ENV_FILTER" == "all" || "$ENV_FILTER" == "$1" ]]
}

should_process() {
  local app_tag="$1" env="$2"
  if [[ -n "$APP_FILTER" ]]; then
    [[ "$app_tag" == "$APP_FILTER" || "$app_tag" == "${REPO}_${APP_FILTER}" ]] || return 1
  fi
  env_matches "$env" || return 1
}

# Add a resource to RESOURCE_LIST and print it.
add_resource() {
  if [[ -n "${DISCOVERY_OUT_FILE:-}" ]]; then
    printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$DISCOVERY_OUT_FILE"
    return
  fi
  RESOURCE_LIST+=("$1|$2|$3|$4|$5")
  printf "    ${YELLOW}→${NC}  %-14s %-42s ${DIM}[app=%s env=%s]${NC}\n" "$1" "$2" "$4" "$5"
}

merge_discovered_resource() {
  local service="$1" name="$2" tag_id="$3" app="$4" env="$5"
  resource_already_listed "$service" "$tag_id" && return
  RESOURCE_LIST+=("${service}|${name}|${tag_id}|${app}|${env}")
  printf "    ${YELLOW}→${NC}  %-14s %-42s ${DIM}[app=%s env=%s]${NC}\n" "$service" "$name" "$app" "$env"
}

resource_already_listed() {
  local service="$1" tag_id="$2" record listed_service listed_name listed_id listed_app listed_env
  [[ ${#RESOURCE_LIST[@]} -eq 0 ]] && return 1
  for record in "${RESOURCE_LIST[@]}"; do
    IFS='|' read -r listed_service listed_name listed_id listed_app listed_env <<< "$record"
    [[ "$listed_service" == "$service" && "$listed_id" == "$tag_id" ]] && return 0
  done
  return 1
}

# ── Phase 1: per-service discovery ───────────────────────────────────────────
# Finds ALL resources including completely untagged ones.
# To support a new AWS service: copy one of these functions, update the AWS
# CLI query for that service, and add a call in run_discovery().

discover_app_runner() {
  local raw
  raw=$(aws apprunner list-services --region "$REGION" \
    --query "ServiceSummaryList[?starts_with(ServiceName,'${SEARCH_PREFIX}')].[ServiceName,ServiceArn]" \
    --output text 2>/dev/null) || true
  [[ -z "$raw" ]] && return
  while IFS=$'\t' read -r name arn; do
    local p; p=$(parse_name "$name")
    local app="${p%%|*}" env="${p##*|}"
    should_process "$app" "$env" || continue
    add_resource "apprunner" "$name" "$arn" "$app" "$env"
  done <<< "$raw"
}

discover_rds() {
  local raw
  raw=$(aws rds describe-db-instances --region "$REGION" \
    --query "DBInstances[?starts_with(DBInstanceIdentifier,'${SEARCH_PREFIX}')].DBInstanceIdentifier" \
    --output text 2>/dev/null) || true
  [[ -z "$raw" ]] && return
  local acct; acct=$(get_account_id)
  for name in $raw; do
    local p; p=$(parse_name "$name")
    local app="${p%%|*}" env="${p##*|}"
    should_process "$app" "$env" || continue
    add_resource "rds" "$name" "arn:aws:rds:${REGION}:${acct}:db:${name}" "$app" "$env"
  done
}

discover_s3() {
  local raw
  raw=$(aws s3api list-buckets \
    --query "Buckets[?starts_with(Name,'${SEARCH_PREFIX}')].Name" \
    --output text 2>/dev/null) || true
  [[ -z "$raw" ]] && return
  for name in $raw; do
    local p; p=$(parse_name "$name")
    local app="${p%%|*}" env="${p##*|}"
    should_process "$app" "$env" || continue
    add_resource "s3" "$name" "$name" "$app" "$env"   # S3 tagging uses bucket name, not ARN
  done
}

discover_ecr() {
  local raw
  raw=$(aws ecr describe-repositories --region "$REGION" \
    --query "repositories[?starts_with(repositoryName,'${SEARCH_PREFIX}')].repositoryName" \
    --output text 2>/dev/null) || true
  [[ -z "$raw" ]] && return
  local acct; acct=$(get_account_id)
  for name in $raw; do
    local p; p=$(parse_name "$name")
    local app="${p%%|*}" env="${p##*|}"
    should_process "$app" "$env" || continue
    add_resource "ecr" "$name" "arn:aws:ecr:${REGION}:${acct}:repository/${name}" "$app" "$env"
  done
}

discover_secrets() {
  local raw
  raw=$(aws secretsmanager list-secrets --region "$REGION" \
    --query "SecretList[?starts_with(Name,'${SEARCH_PREFIX}')].[Name,ARN]" \
    --output text 2>/dev/null) || true
  [[ -z "$raw" ]] && return
  while IFS=$'\t' read -r name arn; do
    local p; p=$(parse_name "$name")
    local app="${p%%|*}" env="${p##*|}"
    should_process "$app" "$env" || continue
    add_resource "secretsmgr" "$name" "$arn" "$app" "$env"
  done <<< "$raw"
}

discover_iam() {
  local raw
  raw=$(aws iam list-roles \
    --query "Roles[?starts_with(RoleName,'${SEARCH_PREFIX}')].RoleName" \
    --output text 2>/dev/null) || true
  [[ -z "$raw" ]] && return
  for name in $raw; do
    local p; p=$(parse_name "$name")
    local app="${p%%|*}" env="${p##*|}"
    should_process "$app" "$env" || continue
    add_resource "iam" "$name" "$name" "$app" "$env"   # IAM tagging uses role name, not ARN
  done
}

discover_lambda() {
  local lpfx="${LAMBDA_PREFIX:-$SEARCH_PREFIX}"
  local raw
  raw=$(aws lambda list-functions --region "$REGION" --no-paginate \
    --query "Functions[?starts_with(FunctionName,'${lpfx}')].[FunctionName,FunctionArn]" \
    --output text 2>/dev/null) || true
  [[ -z "$raw" ]] && return
  while IFS=$'\t' read -r name arn; do
    [[ -z "$name" ]] && continue
    local p; p=$(parse_name "$name")
    local app="${p%%|*}" env="${p##*|}"
    should_process "$app" "$env" || continue
    add_resource "lambda" "$name" "$arn" "$app" "$env"
  done <<< "$raw"
}

discover_ec2() {
  local raw
  # Find instances by Name tag prefix; exclude terminated instances.
  raw=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=${SEARCH_PREFIX}*" \
              "Name=instance-state-name,Values=running,stopped,stopping,pending" \
    --query "Reservations[].Instances[].[Tags[?Key=='Name'].Value|[0],InstanceId]" \
    --output text 2>/dev/null) || true
  [[ -z "$raw" ]] && return
  while IFS=$'\t' read -r name iid; do
    [[ -z "$name" || -z "$iid" ]] && continue
    local p; p=$(parse_name "$name")
    local app="${p%%|*}" env="${p##*|}"
    should_process "$app" "$env" || continue
    add_resource "ec2" "$name" "$iid" "$app" "$env"   # store instance ID; ARN built at apply time
  done <<< "$raw"
}

discover_sg() {
  local raw
  raw=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=group-name,Values=${SEARCH_PREFIX}*" \
    --query "SecurityGroups[].[GroupName,GroupId]" \
    --output text 2>/dev/null) || true
  [[ -z "$raw" ]] && return
  while IFS=$'\t' read -r name gid; do
    [[ -z "$name" || -z "$gid" ]] && continue
    local p; p=$(parse_name "$name")
    local app="${p%%|*}" env="${p##*|}"
    should_process "$app" "$env" || continue
    add_resource "sg" "$name" "$gid" "$app" "$env"   # store SG ID; ARN built at apply time
  done <<< "$raw"
}

discover_iam_policies() {
  local raw
  raw=$(aws iam list-policies --scope Local \
    --query "Policies[?starts_with(PolicyName,'${SEARCH_PREFIX}')].[PolicyName,Arn]" \
    --output text 2>/dev/null) || true
  [[ -z "$raw" ]] && return
  while IFS=$'\t' read -r name arn; do
    [[ -z "$name" ]] && continue
    local p; p=$(parse_name "$name")
    local app="${p%%|*}" env="${p##*|}"
    should_process "$app" "$env" || continue
    add_resource "iam-policy" "$name" "$arn" "$app" "$env"
  done <<< "$raw"
}

discover_logs_prefix() {
  local prefix="$1" raw
  raw=$(aws logs describe-log-groups --region "$REGION" \
    --log-group-name-prefix "$prefix" \
    --query "logGroups[].logGroupName" \
    --output text 2>/dev/null) || true
  [[ -z "$raw" ]] && return
  for name in $raw; do
    [[ -z "$name" ]] && continue
    local parse_target="${name##*/}"
    local p; p=$(parse_name "$parse_target")
    local app="${p%%|*}" env="${p##*|}"
    should_process "$app" "$env" || continue
    add_resource "logs" "$name" "$name" "$app" "$env"
  done
}

discover_apprunner_logs_prefix() {
  local prefix="$1" raw
  raw=$(aws logs describe-log-groups --region "$REGION" \
    --log-group-name-prefix "$prefix" \
    --query "logGroups[].logGroupName" \
    --output text 2>/dev/null) || true
  [[ -z "$raw" ]] && return
  for name in $raw; do
    [[ -z "$name" ]] && continue
    local service_name="${name#/aws/apprunner/}"
    service_name="${service_name%%/*}"
    [[ -z "$service_name" || "$service_name" == "$name" ]] && continue
    local p; p=$(parse_name "$service_name")
    local app="${p%%|*}" env="${p##*|}"
    should_process "$app" "$env" || continue
    add_resource "logs" "$name" "$name" "$app" "$env"
  done
}

discover_logs() {
  local lpfx="${LAMBDA_PREFIX:-$SEARCH_PREFIX}"
  discover_logs_prefix "$SEARCH_PREFIX"
  discover_logs_prefix "/aws/lambda/${lpfx}"
  discover_apprunner_logs_prefix "/aws/apprunner/${SEARCH_PREFIX}"
}

discover_dynamodb_prefix() {
  local prefix="$1"
  local raw
  raw=$(aws dynamodb list-tables --region "$REGION" \
    --query "TableNames[?starts_with(@,'${prefix}')]" \
    --output text 2>/dev/null) || true
  [[ -z "$raw" ]] && return
  for name in $raw; do
    [[ -z "$name" ]] && continue
    local arn
    arn=$(aws dynamodb describe-table --region "$REGION" --table-name "$name" \
      --query "Table.TableArn" --output text 2>/dev/null) || true
    [[ -z "$arn" || "$arn" == "None" ]] && continue
    local p; p=$(parse_name "$name")
    local app="${p%%|*}" env="${p##*|}"
    should_process "$app" "$env" || continue
    resource_already_listed "dynamodb" "$arn" && continue
    add_resource "dynamodb" "$name" "$arn" "$app" "$env"
  done
}

discover_dynamodb() {
  local lpfx="${LAMBDA_PREFIX:-}"
  discover_dynamodb_prefix "$SEARCH_PREFIX"
  if [[ -n "$lpfx" && "$lpfx" != "$SEARCH_PREFIX" ]]; then
    discover_dynamodb_prefix "$lpfx"
  fi
}

discover_ses_identities() {
  local raw
  raw=$(aws ses list-identities --region "$REGION" \
    --query "Identities[]" \
    --output text 2>/dev/null) || true
  [[ -z "$raw" ]] && return
  local acct; acct=$(get_account_id)
  for identity in $raw; do
    [[ -z "$identity" || "$identity" == "None" ]] && continue
    local parse_target=""
    if [[ "$identity" == "${SEARCH_PREFIX}"* ]]; then
      parse_target="${identity%@*}"
      parse_target="${parse_target%%.*}"
    elif [[ "$identity" == *@* ]]; then
      local domain="${identity#*@}"
      if [[ "$domain" == "${SEARCH_PREFIX}"* ]]; then
        parse_target="${domain%%.*}"
      fi
    fi
    [[ -z "$parse_target" ]] && continue
    local p; p=$(parse_name "$parse_target")
    local app="${p%%|*}" env="${p##*|}"
    should_process "$app" "$env" || continue
    add_resource "ses-identity" "$identity" "arn:aws:ses:${REGION}:${acct}:identity/${identity}" "$app" "$env"
  done
}

start_discovery_job() {
  local label="$1" func="$2"
  local idx="$JOB_COUNT"
  local out="$JOB_TMP_DIR/${idx}.${label}.out"
  local err="$JOB_TMP_DIR/${idx}.${label}.err"

  (
    DISCOVERY_OUT_FILE="$out"
    "$func"
  ) >/dev/null 2>"$err" &

  JOB_PIDS[$idx]="$!"
  JOB_LABELS[$idx]="$label"
  JOB_OUTS[$idx]="$out"
  JOB_ERRS[$idx]="$err"
  JOB_COUNT=$((JOB_COUNT + 1))
}

run_discovery_jobs() {
  local labels funcs total launched completed active i
  labels=(apprunner rds s3 ecr secretsmgr iam iam-policy ec2 sg lambda logs dynamodb ses-identity)
  funcs=(discover_app_runner discover_rds discover_s3 discover_ecr discover_secrets discover_iam discover_iam_policies discover_ec2 discover_sg discover_lambda discover_logs discover_dynamodb discover_ses_identities)
  total="${#labels[@]}"
  launched=0
  completed=0

  reset_jobs
  JOB_TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aws-tag-discovery.XXXXXX")
  progress_draw "Discovery" "$completed" "$total" 0

  while [[ "$completed" -lt "$total" ]]; do
    active=$(active_jobs)
    while [[ "$launched" -lt "$total" && "$active" -lt "$PARALLEL_JOBS" ]]; do
      start_discovery_job "${labels[$launched]}" "${funcs[$launched]}"
      launched=$((launched + 1))
      active=$((active + 1))
      progress_draw "Discovery" "$completed" "$total" "$active"
    done

    for ((i=0; i<JOB_COUNT; i++)); do
      if process_finished_job "$i"; then
        completed=$((completed + 1))
        active=$(active_jobs)
        progress_done "Discovery" "${JOB_LABELS[$i]}" "$completed" "$total" "$active"
      fi
    done

    [[ "$completed" -lt "$total" ]] && sleep 0.2
  done
  progress_clear

  for ((i=0; i<JOB_COUNT; i++)); do
    if [[ -s "${JOB_OUTS[$i]}" ]]; then
      local service name tag_id app env
      while IFS='|' read -r service name tag_id app env; do
        [[ -z "$service" ]] && continue
        merge_discovered_resource "$service" "$name" "$tag_id" "$app" "$env"
      done < "${JOB_OUTS[$i]}"
    fi
    if [[ -s "${JOB_ERRS[$i]}" ]]; then
      local err
      err=$(head -c 200 "${JOB_ERRS[$i]}" 2>/dev/null | tr '\n' ' ')
      [[ -n "$err" ]] && echo -e "    ${YELLOW}!${NC}  ${JOB_LABELS[$i]} discovery warning: ${DIM}${err}${NC}" >&2
    fi
  done

  cleanup_job_tmp
  JOB_TMP_DIR=""
}

run_discovery() {
  header "Phase 1 — Finding resources  [repo: ${REPO}]"
  $FIND && echo -e "  ${DIM}(detected from directory: $(pwd))${NC}"
  if [[ "$SEARCH_PREFIX" != "$REPO" ]]; then
    local _pfx_note="from .aws-tagger.yml or --prefix"
    [[ -n "${DETECTED_PREFIX_SOURCE:-}" ]] && _pfx_note="auto-detected from ${DETECTED_PREFIX_SOURCE}"
    echo -e "  ${DIM}search prefix : ${SEARCH_PREFIX}  (${_pfx_note})${NC}"
  fi
  if [[ -n "${LAMBDA_PREFIX:-}" && "$LAMBDA_PREFIX" != "$SEARCH_PREFIX" ]]; then
    local _lpfx_note="${DETECTED_LAMBDA_SOURCE:-from .aws-tagger.yml}"
    echo -e "  ${DIM}lambda prefix : ${LAMBDA_PREFIX}  (${_lpfx_note})${NC}"
  fi
  [[ -n "$APP_FILTER" ]] && echo -e "  ${DIM}app filter    : ${APP_FILTER}${NC}"
  [[ "$ENV_FILTER" != "all" ]] && echo -e "  ${DIM}env filter    : ${ENV_FILTER}${NC}"
  echo ""
  echo -e "  ${DIM}discover jobs : ${PARALLEL_JOBS}${NC}"
  run_discovery_jobs
  echo ""
  local n="${#RESOURCE_LIST[@]}"
  if [[ $n -eq 0 ]]; then
    echo -e "  ${YELLOW}No resources found matching '${SEARCH_PREFIX}*' in ${REGION}.${NC}"
    if [[ "$SEARCH_PREFIX" == "$REPO" ]]; then
      echo    "  Auto-detection found no prefix — your AWS resources may use a different"
      echo    "  name. Pass --prefix <aws-prefix> to override, or add a one-line"
      echo    "  .aws-tagger.yml:  prefix: <aws-prefix>"
    fi
    exit 0
  fi
  echo -e "  Found ${BOLD}${n}${NC} resource(s)"
}

# ── Phase 2: fetch current tags and diff ──────────────────────────────────────
# One read API call per resource. Returns "cur_app|cur_env".

fetch_current_tags() {
  local service="$1" tag_id="$2"
  local app="" env=""

  case "$service" in
    apprunner)
      # App Runner list-tags-for-resource returns tags as an array [{Key,Value}],
      # not as a dict, so use the array-filter JMESPath form.
      app=$(aws apprunner list-tags-for-resource --resource-arn "$tag_id" \
        --region "$REGION" \
        --query "Tags[?Key=='Application'].Value|[0]" \
        --output text 2>/dev/null || true)
      env=$(aws apprunner list-tags-for-resource --resource-arn "$tag_id" \
        --region "$REGION" \
        --query "Tags[?Key=='Environment'].Value|[0]" \
        --output text 2>/dev/null || true)
      ;;
    rds)
      app=$(aws rds list-tags-for-resource --resource-name "$tag_id" \
        --region "$REGION" --query "TagList[?Key=='Application'].Value|[0]" \
        --output text 2>/dev/null || true)
      env=$(aws rds list-tags-for-resource --resource-name "$tag_id" \
        --region "$REGION" --query "TagList[?Key=='Environment'].Value|[0]" \
        --output text 2>/dev/null || true)
      ;;
    s3)
      app=$(aws s3api get-bucket-tagging --bucket "$tag_id" \
        --query "TagSet[?Key=='Application'].Value|[0]" \
        --output text 2>/dev/null || true)
      env=$(aws s3api get-bucket-tagging --bucket "$tag_id" \
        --query "TagSet[?Key=='Environment'].Value|[0]" \
        --output text 2>/dev/null || true)
      ;;
    ecr)
      # ECR list-tags-for-resource returns tags as an array [{Key,Value}],
      # not as a dict, so use the array-filter JMESPath form.
      app=$(aws ecr list-tags-for-resource --resource-arn "$tag_id" \
        --region "$REGION" \
        --query "tags[?Key=='Application'].Value|[0]" \
        --output text 2>/dev/null || true)
      env=$(aws ecr list-tags-for-resource --resource-arn "$tag_id" \
        --region "$REGION" \
        --query "tags[?Key=='Environment'].Value|[0]" \
        --output text 2>/dev/null || true)
      ;;
    secretsmgr)
      app=$(aws secretsmanager describe-secret --secret-id "$tag_id" \
        --region "$REGION" --query "Tags[?Key=='Application'].Value|[0]" \
        --output text 2>/dev/null || true)
      env=$(aws secretsmanager describe-secret --secret-id "$tag_id" \
        --region "$REGION" --query "Tags[?Key=='Environment'].Value|[0]" \
        --output text 2>/dev/null || true)
      ;;
    lambda)
      # Lambda list-tags returns tags as a dict {"Tags": {"Key": "Value"}},
      # not an array, so use direct JMESPath (not the array-filter form).
      app=$(aws lambda list-tags --resource "$tag_id" \
        --region "$REGION" --query "Tags.Application" --output text 2>/dev/null || true)
      env=$(aws lambda list-tags --resource "$tag_id" \
        --region "$REGION" --query "Tags.Environment" --output text 2>/dev/null || true)
      ;;
    ec2)
      # tag_id is the instance ID (e.g. i-0abc123)
      app=$(aws ec2 describe-instances --instance-ids "$tag_id" --region "$REGION" \
        --query "Reservations[0].Instances[0].Tags[?Key=='Application'].Value|[0]" \
        --output text 2>/dev/null || true)
      env=$(aws ec2 describe-instances --instance-ids "$tag_id" --region "$REGION" \
        --query "Reservations[0].Instances[0].Tags[?Key=='Environment'].Value|[0]" \
        --output text 2>/dev/null || true)
      ;;
    sg)
      # tag_id is the security group ID (e.g. sg-0abc123)
      app=$(aws ec2 describe-security-groups --group-ids "$tag_id" --region "$REGION" \
        --query "SecurityGroups[0].Tags[?Key=='Application'].Value|[0]" \
        --output text 2>/dev/null || true)
      env=$(aws ec2 describe-security-groups --group-ids "$tag_id" --region "$REGION" \
        --query "SecurityGroups[0].Tags[?Key=='Environment'].Value|[0]" \
        --output text 2>/dev/null || true)
      ;;
    iam-policy)
      # tag_id is the full policy ARN
      app=$(aws iam list-policy-tags --policy-arn "$tag_id" \
        --query "Tags[?Key=='Application'].Value|[0]" --output text 2>/dev/null || true)
      env=$(aws iam list-policy-tags --policy-arn "$tag_id" \
        --query "Tags[?Key=='Environment'].Value|[0]" --output text 2>/dev/null || true)
      ;;
    iam)
      app=$(aws iam list-role-tags --role-name "$tag_id" \
        --query "Tags[?Key=='Application'].Value|[0]" --output text 2>/dev/null || true)
      env=$(aws iam list-role-tags --role-name "$tag_id" \
        --query "Tags[?Key=='Environment'].Value|[0]" --output text 2>/dev/null || true)
      ;;
    logs)
      app=$(aws logs list-tags-log-group --log-group-name "$tag_id" \
        --region "$REGION" --query "tags.Application" --output text 2>/dev/null || true)
      env=$(aws logs list-tags-log-group --log-group-name "$tag_id" \
        --region "$REGION" --query "tags.Environment" --output text 2>/dev/null || true)
      ;;
    dynamodb)
      app=$(aws dynamodb list-tags-of-resource --resource-arn "$tag_id" \
        --region "$REGION" --query "Tags[?Key=='Application'].Value|[0]" \
        --output text 2>/dev/null || true)
      env=$(aws dynamodb list-tags-of-resource --resource-arn "$tag_id" \
        --region "$REGION" --query "Tags[?Key=='Environment'].Value|[0]" \
        --output text 2>/dev/null || true)
      ;;
    ses-identity)
      app=$(aws sesv2 list-tags-for-resource --resource-arn "$tag_id" \
        --region "$REGION" --query "Tags[?Key=='Application'].Value|[0]" \
        --output text 2>/dev/null || true)
      env=$(aws sesv2 list-tags-for-resource --resource-arn "$tag_id" \
        --region "$REGION" --query "Tags[?Key=='Environment'].Value|[0]" \
        --output text 2>/dev/null || true)
      ;;
  esac

  [[ "$app" =~ ^(None|null)$ ]] && app=""
  [[ "$env" =~ ^(None|null)$ ]] && env=""
  echo "${app}|${env}"
}

diff_resource_record() {
  local idx="$1" total="$2" record="$3"
  local service name arn desired_app desired_env
  IFS='|' read -r service name arn desired_app desired_env <<< "$record"

  local current; current=$(fetch_current_tags "$service" "$arn")
  local cur_app="${current%%|*}" cur_env="${current##*|}"

  if [[ "$cur_app" == "$desired_app" && "$cur_env" == "$desired_env" ]]; then
    printf 'OK|%s|%s|%s|%s|%s|%s|%s|\n' "$idx" "$total" "$service" "$name" "$arn" "$desired_app" "$desired_env"
    return
  fi

  local desc=""
  if   [[ -z "$cur_app" && -z "$cur_env" ]]; then
    desc="add Application + Environment"
  elif [[ -z "$cur_app" && "$cur_env" == "$desired_env" ]]; then
    desc="add Application"
  elif [[ "$cur_app" == "$desired_app" && -z "$cur_env" ]]; then
    desc="add Environment"
  elif [[ -z "$cur_app" ]]; then
    desc="add Application; update Environment '${cur_env}' → '${desired_env}'"
  elif [[ -z "$cur_env" ]]; then
    desc="update Application '${cur_app}' → '${desired_app}'; add Environment"
  else
    desc="Application '${cur_app}'→'${desired_app}'; Environment '${cur_env}'→'${desired_env}'"
  fi

  printf 'CHANGE|%s|%s|%s|%s|%s|%s|%s|%s\n' "$idx" "$total" "$service" "$name" "$arn" "$desired_app" "$desired_env" "$desc"
}

start_diff_job() {
  local idx="$1" total="$2" record="$3"
  local slot="$JOB_COUNT"
  local out="$JOB_TMP_DIR/${slot}.diff.out"
  local err="$JOB_TMP_DIR/${slot}.diff.err"
  local service name arn desired_app desired_env
  IFS='|' read -r service name arn desired_app desired_env <<< "$record"

  (
    diff_resource_record "$idx" "$total" "$record"
  ) >"$out" 2>"$err" &

  JOB_PIDS[$slot]="$!"
  JOB_LABELS[$slot]="${service}:${name}"
  JOB_OUTS[$slot]="$out"
  JOB_ERRS[$slot]="$err"
  JOB_COUNT=$((JOB_COUNT + 1))
}

run_diff_jobs() {
  local total="${#RESOURCE_LIST[@]}" launched=0 completed=0 active i

  reset_jobs
  JOB_TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aws-tag-diff.XXXXXX")
  progress_draw "Diff" "$completed" "$total" 0

  while [[ "$completed" -lt "$total" ]]; do
    active=$(active_jobs)
    while [[ "$launched" -lt "$total" && "$active" -lt "$PARALLEL_JOBS" ]]; do
      start_diff_job "$((launched + 1))" "$total" "${RESOURCE_LIST[$launched]}"
      launched=$((launched + 1))
      active=$((active + 1))
      progress_draw "Diff" "$completed" "$total" "$active"
    done

    for ((i=0; i<JOB_COUNT; i++)); do
      if process_finished_job "$i"; then
        completed=$((completed + 1))
        active=$(active_jobs)
        progress_done "Diff" "${JOB_LABELS[$i]}" "$completed" "$total" "$active"
      fi
    done

    [[ "$completed" -lt "$total" ]] && sleep 0.2
  done
  progress_clear

  for ((i=0; i<JOB_COUNT; i++)); do
    if [[ -s "${JOB_OUTS[$i]}" ]]; then
      local status idx total_count service name arn desired_app desired_env desc
      IFS='|' read -r status idx total_count service name arn desired_app desired_env desc < "${JOB_OUTS[$i]}"
      printf "  [%2d/%d]  %-12s %-42s" "$idx" "$total_count" "$service" "$name"
      if [[ "$status" == "OK" ]]; then
        echo -e "${GREEN}✓ ok${NC}"
        ALREADY_OK=$((ALREADY_OK + 1))
      else
        echo -e "${YELLOW}~ ${desc}${NC}"
        CHANGES+=("${service}|${name}|${arn}|${desired_app}|${desired_env}|${desc}")
      fi
    fi
    if [[ -s "${JOB_ERRS[$i]}" ]]; then
      local err
      err=$(head -c 200 "${JOB_ERRS[$i]}" 2>/dev/null | tr '\n' ' ')
      [[ -n "$err" ]] && echo -e "    ${YELLOW}!${NC}  ${JOB_LABELS[$i]} diff warning: ${DIM}${err}${NC}" >&2
    fi
  done

  cleanup_job_tmp
  JOB_TMP_DIR=""
}

run_diff() {
  header "Phase 2 — Checking current tags"
  echo ""
  echo -e "  ${DIM}diff jobs     : ${PARALLEL_JOBS}${NC}"
  run_diff_jobs
}

# ── Phase 3: apply via resourcegroupstaggingapi ────────────────────────────────
# tag-resources merges tags (never removes others) and works for any AWS service.
# S3 uses its bucket name as the ARN: arn:aws:s3:::<bucket>.

to_s3_arn()  { echo "arn:aws:s3:::$1"; }
to_iam_arn() { local acct; acct=$(get_account_id); echo "arn:aws:iam::${acct}:role/$1"; }
to_ec2_arn() { local acct; acct=$(get_account_id); echo "arn:aws:ec2:${REGION}:${acct}:instance/$1"; }
to_sg_arn()  { local acct; acct=$(get_account_id); echo "arn:aws:ec2:${REGION}:${acct}:security-group/$1"; }

run_apply() {
  local n="${#CHANGES[@]}"
  echo ""

  if [[ $n -eq 0 ]]; then
    echo -e "  ${GREEN}✓ All ${ALREADY_OK} resource(s) already correctly tagged. Nothing to do.${NC}"
    return
  fi

  if $DRY_RUN; then
    header "Phase 3 — Dry-run preview  [${n} change(s) pending]"
    echo ""
    local i=1
    for change in "${CHANGES[@]}"; do
      IFS='|' read -r service name arn desired_app desired_env desc <<< "$change"
      echo -e "  ${CYAN}[${i}/${n}]${NC}  ${service}: ${name}"
      echo    "         Application=${desired_app}  Environment=${desired_env}"
      echo -e "         ${DIM}(${desc})${NC}"
      echo ""
      ((i++))
    done
    echo -e "  ${CYAN}Dry run: ${n} change(s) pending. Re-run without -n to apply.${NC}"
    return
  fi

  header "Phase 3 — Applying tags  [${n} change(s)]"
  echo ""

  local i=1
  for change in "${CHANGES[@]}"; do
    IFS='|' read -r service name arn desired_app desired_env desc <<< "$change"
    printf "  [%d/%d]  %-12s %s ... " "$i" "$n" "$service" "$name"

    # Resolve the correct ARN for services that store a shorthand in RESOURCE_LIST
    local tag_arn="$arn"
    [[ "$service" == "s3"         ]] && tag_arn=$(to_s3_arn  "$arn")
    [[ "$service" == "iam"        ]] && tag_arn=$(to_iam_arn  "$arn")
    [[ "$service" == "ec2"        ]] && tag_arn=$(to_ec2_arn  "$arn")
    [[ "$service" == "sg"         ]] && tag_arn=$(to_sg_arn   "$arn")

    # Capture stderr separately so errors aren't silently swallowed.
    local result _etmp _ec=0
    _etmp=$(mktemp)
    if [[ "$service" == "ecr" ]]; then
      # resourcegroupstaggingapi silently no-ops for ECR even when it has no
      # effect (returns HTTP 200 / empty FailedResourcesMap without writing tags).
      # Use the ECR-native API instead, which requires only ecr:TagResource.
      result=$(aws ecr tag-resource \
        --resource-arn "$tag_arn" \
        --tags "Key=Application,Value=${desired_app}" "Key=Environment,Value=${desired_env}" \
        --region "$REGION" 2>"$_etmp") || _ec=$?
    elif [[ "$service" == "logs" ]]; then
      result=$(aws logs tag-log-group \
        --log-group-name "$tag_arn" \
        --tags "{\"Application\":\"${desired_app}\",\"Environment\":\"${desired_env}\"}" \
        --region "$REGION" 2>"$_etmp") || _ec=$?
    elif [[ "$service" == "dynamodb" ]]; then
      result=$(aws dynamodb tag-resource \
        --resource-arn "$tag_arn" \
        --tags "Key=Application,Value=${desired_app}" "Key=Environment,Value=${desired_env}" \
        --region "$REGION" 2>"$_etmp") || _ec=$?
    elif [[ "$service" == "ses-identity" ]]; then
      result=$(aws sesv2 tag-resource \
        --resource-arn "$tag_arn" \
        --tags "Key=Application,Value=${desired_app}" "Key=Environment,Value=${desired_env}" \
        --region "$REGION" 2>"$_etmp") || _ec=$?
    else
      result=$(aws resourcegroupstaggingapi tag-resources \
        --resource-arn-list "$tag_arn" \
        --tags "{\"Application\":\"${desired_app}\",\"Environment\":\"${desired_env}\"}" \
        --region "$REGION" \
        --query "FailedResourcesMap" \
        --output json 2>"$_etmp") || _ec=$?
    fi
    if [[ -z "$result" ]]; then
      local _emsg; _emsg=$(head -c 200 "$_etmp" 2>/dev/null | tr '\n' ' ')
      if [[ -n "$_emsg" ]]; then
        result="$_emsg"                    # AWS CLI printed an error to stderr
      elif [[ $_ec -ne 0 ]]; then
        result="CLI error (exit ${_ec})"   # non-zero exit, but no error text
      else
        # Both ecr tag-resource (always) and resourcegroupstaggingapi tag-resources
        # (AWS CLI v2, empty FailedResourcesMap) produce no stdout on success.
        result="{}"
      fi
    fi
    rm -f "$_etmp"

    if [[ "$result" == "{}" || "$result" == "null" ]]; then
      echo -e "${GREEN}✓${NC}"
    else
      echo -e "${RED}✗ failed${NC}  ${DIM}(${result})${NC}"
      ERRORS=$((ERRORS + 1))
    fi
    ((i++))
  done

  echo ""
  local applied=$((n - ERRORS))
  local summary="${GREEN}${applied} tagged${NC}, ${ALREADY_OK} already correct"
  [[ $ERRORS -gt 0 ]] && summary+=", ${RED}${ERRORS} failed${NC}"
  echo -e "  Done: ${summary}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
# Auto-detect search prefix from project files when -f is used and no explicit
# prefix was given via --prefix or .aws-tagger.yml.
# Scans: .github/workflows, config files, Python source, shell scripts, CDK infra.
# Priority: --prefix > .aws-tagger.yml > auto-detect > repo name (fallback).

DETECTED_PREFIX_SOURCE=""
LAMBDA_PREFIX="${LAMBDA_PREFIX:-}"      # may already be set from .aws-tagger.yml
DETECTED_LAMBDA_SOURCE=""

if $FIND && [[ -z "$SEARCH_PREFIX" ]]; then
  # Write the detector to a temp file (avoids heredoc-inside-$() quoting issues).
  _py_tmp=$(mktemp /tmp/aws_pfx_detect_XXXXX.py)
  cat > "$_py_tmp" <<'PYEOF'
import sys, os, re, glob
from collections import Counter

repo         = sys.argv[1] if len(sys.argv) > 1 else ""
cands        = Counter()
srcs         = {}
lambda_cands = Counter()
lambda_srcs  = {}

TYPE_SFX = {
    "bot","web","api","worker","handler","server","service","pipeline",
    "monitor","frontend","backend","cli","app","function","lambda",
    "role","policy","sg","key","ec2","elb","alb","rds","ecr","ses",
    "session","logs","log","data","state","storage","assets","uploads",
    "access","deploy","actions","github","read","only","send","email",
}
ENV_SFX = {"dev","prod","staging","test","qa"}
SKIP    = ("venv/","node_modules/",".git/","__pycache__/","cdk.out/",
           "archive/","explore/")

def add(prefix, source, weight):
    if not prefix:
        return
    prefix = prefix.lower().strip().strip("-")
    if not re.match(r"^[a-z][a-z0-9-]+$", prefix) or len(prefix) < 3:
        return
    cands[prefix] += weight
    if prefix not in srcs or weight > srcs[prefix][1]:
        srcs[prefix] = (source, weight)

def strip_sfx(name):
    parts = name.rstrip("-").split("-")
    while len(parts) > 1:
        last = parts[-1]
        if (last in TYPE_SFX or last in ENV_SFX
                or re.fullmatch(r"[0-9]{8,12}", last)
                or re.fullmatch(r"[a-f0-9]{8,}", last)):
            parts.pop()
        else:
            break
    return "-".join(parts)

for wf in (glob.glob(".github/workflows/*.yml") +
           glob.glob(".github/workflows/*.yaml")):
    try:
        txt = open(wf, errors="ignore").read()
        src = os.path.relpath(wf)
        for m in re.finditer(r"ECR_REPOSITORY\s*[=:]\s*[\"']?([a-z][a-z0-9-]+)", txt):
            add(strip_sfx(m.group(1)), src, 3)
        for m in re.finditer(r"SERVICE_NAME\s*[=:]\s*[\"']?([a-z][a-z0-9-]+)", txt):
            add(strip_sfx(m.group(1)), src, 3)
        for m in re.finditer(r":secrets?:([a-z][a-z0-9-]+)/", txt):
            add(m.group(1), src, 3)
        for m in re.finditer(r"\.amazonaws\.com/([a-z][a-z0-9-]+)", txt):
            add(strip_sfx(m.group(1)), src, 2)
        for m in re.finditer(r":role/(?:github-?actions?-)?([a-z][a-z0-9-]+)", txt):
            add(strip_sfx(m.group(1)), src, 2)
        for m in re.finditer(r"secret[_-]name\s*=\s*[\"']([a-z][a-z0-9-]+)/", txt, re.I):
            add(m.group(1).lower(), src, 3)
        # Lambda FN_NAME templates: FN_NAME="sa-${fn}" or FN_NAME="sa-pipeline-${fn}"
        # Scope to FN_NAME= to avoid matching SERVICE_NAME or other non-Lambda vars.
        for m in re.finditer(r'FN_NAME\s*=\s*["\']([a-z][a-z0-9-]+)-\$\{', txt):
            lpfx = m.group(1).rstrip("-")
            if len(lpfx) >= 2 and lpfx not in ENV_SFX:
                lambda_cands[lpfx] += 3
                if lpfx not in lambda_srcs:
                    lambda_srcs[lpfx] = (src, 3)
    except Exception:
        pass

for cfg in (glob.glob("**/config*.yaml", recursive=True) +
            glob.glob("**/config*.yml",  recursive=True)):
    if any(s in cfg for s in SKIP):
        continue
    try:
        txt = open(cfg, errors="ignore").read()
        src = os.path.relpath(cfg)
        for m in re.finditer(
                r"host\s*[:\"]\s*[\"']?([a-z][a-z0-9-]+)-(dev|prod|staging)\."
                r"[a-z0-9]+\.[a-z0-9-]+\.rds\.amazonaws", txt):
            add(m.group(1), src, 3)
        for m in re.finditer(
                r"secret[_-](?:id|name)\s*[:\"]\s*f?[\"']([a-z][a-z0-9-]+)/",
                txt, re.I):
            add(m.group(1).lower(), src, 3)
        for m in re.finditer(
                r"bucket[^\"':\n]*[\"']([a-z][a-z0-9-]+)-(dev|prod|staging)",
                txt, re.I):
            add(m.group(1), src, 2)
    except Exception:
        pass

py_files = [p for p in glob.glob("**/*.py", recursive=True)
            if not any(s in p for s in SKIP)][:200]
for py in py_files:
    try:
        txt = open(py, errors="ignore").read()
        src = os.path.relpath(py)
        for m in re.finditer(
                r"secret[_-]name\s*=\s*f?[\"']([a-z][a-z0-9-]+)/", txt, re.I):
            add(m.group(1).lower(), src, 3)
        for m in re.finditer(r"SecretId\s*=\s*[\"']([a-z][a-z0-9-]+)/", txt):
            add(m.group(1), src, 2)
        for m in re.finditer(
                r"bucket[_-]name\s*=\s*f?[\"']([a-z][a-z0-9-]+)"
                r"-(dev|prod|staging|[{])", txt, re.I):
            add(m.group(1).lower(), src, 2)
    except Exception:
        pass

for sh in (glob.glob("scripts/*.sh") + glob.glob("deploy/*.sh") +
           glob.glob("*.sh")         + glob.glob("docker/*.sh")):
    try:
        txt = open(sh, errors="ignore").read()
        src = os.path.relpath(sh)
        for m in re.finditer(
                r"(?:ROLE_NAME|SG_NAME|POLICY_NAME|INSTANCE_NAME)\s*="
                r"\s*[\"']?([a-z][a-z0-9-]+)", txt):
            add(strip_sfx(m.group(1)), src, 2)
        for m in re.finditer(
                r"SECRET_NAME[^=\n]*=\s*[\"'${\w]*:-([a-z][a-z0-9-]+)/", txt):
            add(m.group(1), src, 3)
        for m in re.finditer(r"SECRET_NAME\s*=\s*[\"']([a-z][a-z0-9-]+)/", txt):
            add(m.group(1), src, 3)
        for m in re.finditer(r"\bBUCKET\s*=\s*[\"']([a-z][a-z0-9-]+)", txt):
            add(strip_sfx(m.group(1)), src, 2)
    except Exception:
        pass

for py in glob.glob("infra/**/*.py", recursive=True):
    if "cdk.out" in py:
        continue
    try:
        txt = open(py, errors="ignore").read()
        src = os.path.relpath(py)
        for m in re.finditer(
                r"bucket_name\s*=\s*f?[\"']([a-z][a-z0-9-]+)[-{]", txt):
            add(strip_sfx(m.group(1).rstrip("-")), src, 2)
        for m in re.finditer(
                r"secret_name\s*=\s*f?[\"']([a-z][a-z0-9-]+)/", txt):
            add(m.group(1), src, 2)
    except Exception:
        pass

if cands:
    winner, _ = max(cands.items(), key=lambda x: x[1])
    print(winner + "\t" + srcs.get(winner, ("?",))[0])
    # If Lambda functions clearly use a different prefix, emit it on a second line.
    if lambda_cands:
        # Prefer higher count; break ties by shorter prefix (more general).
        lw, _ = max(lambda_cands.items(), key=lambda x: (x[1], -len(x[0])))
        if lw != winner:
            print("lambda:" + lw + "\t" + lambda_srcs.get(lw, ("?",))[0])
PYEOF
  _det_out=$(python3 "$_py_tmp" "$REPO" 2>/dev/null) || _det_out=""
  rm -f "$_py_tmp"
  # grep exits 1 on empty input; || true prevents set -e from aborting.
  _det_prefix=$(printf '%s' "$_det_out" | grep -v '^lambda:' | cut -f1 | head -1 || true)
  _det_source=$(printf '%s' "$_det_out" | grep -v '^lambda:' | cut -f2 | head -1 || true)
  if [[ -n "$_det_prefix" && "$_det_prefix" != "$REPO" ]]; then
    SEARCH_PREFIX="$_det_prefix"
    DETECTED_PREFIX_SOURCE="$_det_source"
  fi
  # Lambda-specific prefix (only if different from main prefix)
  _det_lambda_line=$(printf '%s' "$_det_out" | grep '^lambda:' | head -1 || true)
  if [[ -n "$_det_lambda_line" && -z "$LAMBDA_PREFIX" ]]; then
    LAMBDA_PREFIX=$(echo "$_det_lambda_line" | cut -f1 | sed 's/^lambda://' || true)
    DETECTED_LAMBDA_SOURCE=$(echo "$_det_lambda_line" | cut -f2 || true)
  fi
fi

# Final fallback: use repo name when nothing was detected or explicitly set
[[ -z "$SEARCH_PREFIX" ]] && SEARCH_PREFIX="$REPO"

DRY_NOTE=""; $DRY_RUN && DRY_NOTE=" ${CYAN}[DRY RUN]${NC}"

echo -e "${BOLD}==========================================${NC}"
echo -e "  AWS Resource Tagging${DRY_NOTE}"
echo    "  Repo   : ${REPO}"
if [[ "$SEARCH_PREFIX" != "$REPO" ]]; then
  _pfx_src="${DETECTED_PREFIX_SOURCE:-from .aws-tagger.yml or --prefix}"
  echo    "  Prefix : ${SEARCH_PREFIX}  (${_pfx_src})"
fi
if [[ -n "${LAMBDA_PREFIX:-}" && "$LAMBDA_PREFIX" != "$SEARCH_PREFIX" ]]; then
  _lpfx_src="${DETECTED_LAMBDA_SOURCE:-from .aws-tagger.yml}"
  echo    "  Lambda : ${LAMBDA_PREFIX}  (${_lpfx_src})"
fi
echo    "  Region : ${REGION}"
echo -e "${BOLD}==========================================${NC}"

run_discovery
run_diff
run_apply

echo ""
echo -e "${BOLD}==========================================${NC}"
echo    "  NOTE: NAT Gateways must be tagged manually:"
echo    "  aws ec2 describe-nat-gateways --region ${REGION} --output table"
echo    "  aws ec2 create-tags --resources nat-XXXXX \\"
echo    "    --tags Key=Application,Value=<app> Key=Environment,Value=prod"
echo -e "${BOLD}==========================================${NC}"
