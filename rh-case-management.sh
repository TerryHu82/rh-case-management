#!/bin/sh
# Red Hat Case Management Attachment CLI v1.1
# POSIX sh syntax: run on macOS (zsh terminal) and RHEL/Linux (bash terminal).
# KB: https://access.redhat.com/articles/7146201
# KB: https://access.redhat.com/articles/3626371
# Never use sh -x / set -x: credentials may appear in traced commands.
set +x
set -eu
umask 077

BASE='https://api.access.redhat.com/support'
TOKEN_URL='https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token'
POLL_INTERVAL=${POLL_INTERVAL:-30}
STATUS_TIMEOUT=${STATUS_TIMEOUT:-7200}
LIST_TIMEOUT=${LIST_TIMEOUT:-600}
VERIFY_DOWNLOAD=true
PARALLEL=2
YES=false
INCLUDE_DELETED=false
TMP_DIR=''
LOG_ACTIVE=0
TOKEN_TTY=0
OFFLINE_TOKEN=''
ACCESS_TOKEN=''
ATTACHMENT_ID=''
ACTIVE_PIDS=''
WORKER_ACTIVE=0
VERIFY_DIR=''
AUTH_TMP=''

usage() {
    cat <<'HELP'
Red Hat Case Management Attachment CLI — v1.1

USAGE
  rh-case-management.sh <COMMAND> [OPTIONS] <ARGUMENTS>

COMMANDS
  list   [--include-deleted] CASE_NUMBER
                  List attachments: created time, filename, ID, size, status.

  upload [--verify-download=true|false] [--parallel=N] CASE_NUMBER FILE [FILE ...]
                  Upload one or more files. By default, download each file
                  afterward and verify it is byte-for-byte identical.

  status CASE_NUMBER ATTACHMENT_ID
                  Show a specific attachment's processing state and metadata.

  delete [--yes] CASE_NUMBER ATTACHMENT_ID
                  Delete the attachment from the Case (confirmation required
                  unless --yes is specified).

OPTIONS
  --verify-download=true    Download and compare after upload (DEFAULT).
  --verify-download=false   Skip download/content verification.
  --parallel=N              Concurrent file uploads: 1 to 4 (DEFAULT: 2).
                            Use --parallel=1 for sequential uploads.
  --include-deleted         Also list deleted attachments (list only).
  --yes                     Skip interactive deletion confirmation (delete only).
  -h, --help                Show this help.

LIMITS
  * Upload uses SINGLE_PUT: each file and their combined total must be
    greater than 0 and <= 5 GiB (5,368,709,120 bytes).
  * Multiple files are uploaded as SEPARATE Case attachments, not as an archive.
  * Parallel workers have independent Attachment IDs, status and verification.
  * PUT and download use HTTP/1.1. Presigned URLs are not logged.
  * No automatic retry/re-upload after an incomplete or failed PUT.

LOGGING / VERIFICATION
  * A timestamped .log file is written in the CURRENT directory.
  * Offline Token entry is hidden and not recorded in the log.
  * Download copies are created temporarily on the CURRENT directory's
    filesystem and removed after verification. Free space is checked.
  * An API-reported size of 0 with status Completed generates a warning;
    downloadable content is verified when --verify-download=true.

ENVIRONMENT (optional)
  POLL_INTERVAL=30           Seconds between status checks.
  STATUS_TIMEOUT=7200        Maximum seconds waiting for scanning/processing.
  LIST_TIMEOUT=600           Maximum seconds waiting for Case list confirmation.

EXAMPLES
  ./rh-case-management.sh list 07794244
  ./rh-case-management.sh list --include-deleted 07794244
  ./rh-case-management.sh upload 07794244 ./must-gather.tar.gz
  ./rh-case-management.sh upload --parallel=2 07794244 ./a.tar.gz ./b.tar.gz
  ./rh-case-management.sh upload --parallel=1 --verify-download=false 07794244 ./a.tar.gz ./b.tar.gz
  ./rh-case-management.sh status 07794244 ATTACHMENT_ID
  ./rh-case-management.sh delete 07794244 ATTACHMENT_ID
  ./rh-case-management.sh delete --yes 07794244 ATTACHMENT_ID

RED HAT DOCUMENTATION
  Attachment Service API Guide:
    https://access.redhat.com/articles/7146201
  Getting started with Red Hat APIs (Offline / Access Token):
    https://access.redhat.com/articles/3626371
HELP
}

say() { printf '%s\n' "$*"; }
clock() { date '+%Y-%m-%d %H:%M:%S %Z'; }
step() { printf '\n========== STEP %s: %s ==========\n' "$1" "$2"; }
fail() {
    printf '\n[ERROR] %s\n' "$*" >&2
    if [ -n "$ATTACHMENT_ID" ]; then
        printf '[INFO] Case=%s Attachment ID=%s\n' "$CASE_NUMBER" "$ATTACHMENT_ID" >&2
        printf '[INFO] Inspect this ID before retrying; no automatic deletion/re-upload.\n' >&2
    fi
    if [ "$WORKER_ACTIVE" -eq 1 ]; then
        printf 'FAIL\t%s\t%s\t%s\n' "$WORK_INDEX" "$FILE_NAME" "$ATTACHMENT_ID" > "$WORK_RESULT"
    fi
    if [ "$LOG_ACTIVE" -eq 1 ]; then
        printf '[INFO] Diagnostic log: %s\n' "$LOG_FILE" >&2
    fi
    exit 1
}

cleanup() {
    if [ "$TOKEN_TTY" -eq 1 ]; then
        stty echo </dev/tty 2>/dev/null || :
    fi
    # All children must close the logging pipe before we drain tee.
    CLEANUP_PIDS=$ACTIVE_PIDS
    while [ -n "$CLEANUP_PIDS" ]; do
        P=${CLEANUP_PIDS%% *}
        case "$CLEANUP_PIDS" in
            *' '*) CLEANUP_PIDS=${CLEANUP_PIDS#* } ;;
            *) CLEANUP_PIDS='' ;;
        esac
        kill "$P" 2>/dev/null || :
        wait "$P" 2>/dev/null || :
    done
    unset OFFLINE_TOKEN ACCESS_TOKEN PRESIGNED_URL DOWNLOAD_URL
    if [ "$LOG_ACTIVE" -eq 1 ]; then
        exec 1>&3 2>&4
        exec 3>&- 4>&-
        wait "$LOGGER_PID" 2>/dev/null || :
    fi
    [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
}
trap cleanup 0
trap 'exit 130' 2
trap 'exit 143' 15

# Argument parser: command options precede CASE_NUMBER.
if [ "$#" -eq 0 ]; then usage; exit 0; fi
case "$1" in
    -h|--help|help) usage; exit 0 ;;
    list|upload|status|delete) COMMAND=$1; shift ;;
    *) say "[ERROR] Unknown command: $1" >&2; usage >&2; exit 2 ;;
esac
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --verify-download|--verify-download=true)
            [ "$COMMAND" = upload ] || fail 'verify-download applies to upload only'
            VERIFY_DOWNLOAD=true ;;
        --verify-download=false)
            [ "$COMMAND" = upload ] || fail 'verify-download applies to upload only'
            VERIFY_DOWNLOAD=false ;;
        --verify-download=*) fail "Invalid --verify-download: $1" ;;
        --parallel=*)
            [ "$COMMAND" = upload ] || fail 'parallel applies to upload only'
            PARALLEL=${1#*=} ;;
        --parallel)
            [ "$COMMAND" = upload ] || fail 'parallel applies to upload only'
            shift; [ "$#" -gt 0 ] || fail '--parallel requires a value'
            PARALLEL=$1 ;;
        --include-deleted)
            [ "$COMMAND" = list ] || fail 'include-deleted applies to list only'
            INCLUDE_DELETED=true ;;
        --yes)
            [ "$COMMAND" = delete ] || fail '--yes applies to delete only'
            YES=true ;;
        --) shift; break ;;
        -*) fail "Unknown option: $1" ;;
        *) break ;;
    esac
    shift
done
case "$COMMAND" in
    upload) [ "$#" -ge 2 ] || { usage >&2; exit 2; } ;;
    list)   [ "$#" -eq 1 ] || { usage >&2; exit 2; } ;;
    status|delete) [ "$#" -eq 2 ] || { usage >&2; exit 2; } ;;
esac
CASE_NUMBER=$1
shift
case "$CASE_NUMBER" in ''|*[!0-9]*) fail 'Case Number must contain digits only' ;; esac
if [ "$COMMAND" = status ] || [ "$COMMAND" = delete ]; then
    ATTACHMENT_ID=$1
    case "$ATTACHMENT_ID" in ''|*[!a-zA-Z0-9_-]*) fail 'Invalid Attachment ID' ;; esac
fi
case "$PARALLEL" in 1|2|3|4) : ;; *) fail 'Use --parallel=1, 2, 3, or 4' ;; esac
for VALUE in "$POLL_INTERVAL" "$STATUS_TIMEOUT" "$LIST_TIMEOUT"; do
    case "$VALUE" in ''|0|*[!0-9]*) fail 'Polling settings must be positive integer seconds' ;; esac
done

for CMD in curl jq wc date stty mktemp mkfifo tee awk df tr sed sleep cmp uname pwd rm mkdir; do
    command -v "$CMD" >/dev/null 2>&1 || fail "Missing command: $CMD"
done
WORK_DIR=$(pwd -P) || fail 'Unable to determine current directory'
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rh-case-management.XXXXXX") || fail 'Unable to create temp directory'
LOG_FILE="$WORK_DIR/rh-case-management-v1.1-$COMMAND-$(date '+%Y%m%d-%H%M%S')-$$.log"
: > "$LOG_FILE" || fail "Cannot create log file: $LOG_FILE"
mkfifo "$TMP_DIR/output.fifo" || fail 'Cannot create log pipe'
exec 3>&1 4>&2
tee -a "$LOG_FILE" < "$TMP_DIR/output.fifo" >&3 &
LOGGER_PID=$!
exec > "$TMP_DIR/output.fifo" 2>&1
LOG_ACTIVE=1
START_TS=$(date +%s)
AUTH_TMP="$TMP_DIR/token-parent.json"
say '============================================================'
say ' Red Hat Case Management Attachment CLI v1.1'
say '============================================================'
say "Command:    $COMMAND"
say "Case:       $CASE_NUMBER"
say "Started:    $(clock)"
say "System:     $(uname -s) $(uname -m)"
say "Log:        $LOG_FILE"

# Secure authentication, common to all commands.
read_offline_token() {
    if [ "$COMMAND" = upload ]; then
        step 2 'Authenticate: enter Red Hat Offline Token'
    else
        step 1 'Authenticate: enter Red Hat Offline Token'
    fi
    say 'Please visit https://access.redhat.com/management/api'
    say 'Copy your Offline Token and paste it below, then press Enter.'
    say 'Your input is hidden (no echo); the token will NOT be written to the log.'
    printf 'Paste Offline Token (hidden): '
    TOKEN_TTY=1
    stty -echo </dev/tty || fail 'Cannot hide terminal input (interactive TTY required)'
    if ! IFS= read -r OFFLINE_TOKEN </dev/tty; then
        stty echo </dev/tty 2>/dev/null || :
        fail 'Unable to read Offline Token'
    fi
    stty echo </dev/tty 2>/dev/null || :
    TOKEN_TTY=0
    printf '\n'
    [ -n "$OFFLINE_TOKEN" ] || fail 'Empty Offline Token'
    if [ "$COMMAND" = upload ]; then
        say '[STEP 2] Token accepted without logging it'
    else
        say '[STEP 1] Token accepted without logging it'
    fi
}
refresh_token() {
    TOKEN_REASON=$1
    say "[AUTH] Obtaining access token ($TOKEN_REASON) at $(clock)"
    TOKEN_RC=0
    TOKEN_HTTP=$(printf '%s' "$OFFLINE_TOKEN" |
        curl -sS --connect-timeout 30 --max-time 90 \
          -o "$AUTH_TMP" -w '%{http_code}' \
          -X POST "$TOKEN_URL" \
          -d 'grant_type=refresh_token' \
          -d 'client_id=rhsm-api' \
          --data-urlencode 'refresh_token@-') || TOKEN_RC=$?
    [ "$TOKEN_RC" -eq 0 ] || fail "SSO connection failed (curl=$TOKEN_RC)"
    [ "$TOKEN_HTTP" = 200 ] || fail "SSO returned HTTP $TOKEN_HTTP"
    ACCESS_TOKEN=$(jq -er '.access_token' "$AUTH_TMP") || fail 'No access_token in SSO response'
    TOKEN_LIFETIME=$(jq -er '(.expires_in // 900) | tonumber' "$AUTH_TMP") || fail 'Missing token lifetime'
    TOKEN_ISSUED_AT=$(date +%s)
    rm -f "$AUTH_TMP"
    say "[AUTH] Access Token ready for ${TOKEN_LIFETIME}s"
}
ensure_token() {
    TOKEN_REMAINING=$((TOKEN_LIFETIME - $(date +%s) + TOKEN_ISSUED_AT))
    if [ "$TOKEN_REMAINING" -le 60 ]; then
        refresh_token 'expired or near expiry'
    fi
}
# API method: GET / POST(json) / DELETE. 401 gets one fresh token retry.
api_request() {
    API_METHOD=$1
    API_URL=$2
    API_OUT=$3
    API_DATA=${4:-}
    API_ATTEMPT=1
    while [ "$API_ATTEMPT" -le 2 ]; do
        ensure_token
        API_RC=0
        case "$API_METHOD" in
            GET)
                API_HTTP=$(curl -sS --connect-timeout 30 --max-time 90 \
                    -H 'Accept: application/json' \
                    -H "Authorization: Bearer $ACCESS_TOKEN" \
                    -o "$API_OUT" -w '%{http_code}' "$API_URL") || API_RC=$? ;;
            POST)
                API_HTTP=$(curl -sS --connect-timeout 30 --max-time 90 \
                    -X POST -H 'Content-Type: application/json' \
                    -H "Authorization: Bearer $ACCESS_TOKEN" \
                    -o "$API_OUT" -w '%{http_code}' \
                    -d "$API_DATA" "$API_URL") || API_RC=$? ;;
            DELETE)
                API_HTTP=$(curl -sS --connect-timeout 30 --max-time 90 \
                    -X DELETE -H "Authorization: Bearer $ACCESS_TOKEN" \
                    -o "$API_OUT" -w '%{http_code}' "$API_URL") || API_RC=$? ;;
            *) fail 'Unsupported HTTP method' ;;
        esac
        [ "$API_RC" -eq 0 ] || fail "API transport error (method=$API_METHOD curl=$API_RC)"
        if [ "$API_HTTP" = 401 ] && [ "$API_ATTEMPT" -eq 1 ]; then
            refresh_token 'HTTP 401 retry'
            API_ATTEMPT=2
            continue
        fi
        case "$API_HTTP" in
            2??) return 0 ;;
            *)
                say "[HTTP] $API_METHOD request failed: status=$API_HTTP"
                say '[HTTP] Check Case permission, request parameters and server logs.'
                fail "API returned HTTP $API_HTTP" ;;
        esac
    done
}

# Print one attachment per block, preserving long filenames and IDs.
render_attachment_list() {
    JSON_FILE=$1
    jq -r '
      if type != "array" then error("Expected JSON array") else . end
      | to_entries[] |
        "  [\(.key + 1)] Date: \(.value.createdDate // .value.createDate // "unknown")\n" +
        "      File: \(.value.fileName // "unknown")\n" +
        "      ID:   \(.value.uuid // "unknown")\n" +
        "      Size: \(.value.size // "unknown") bytes | Status: \(.value.uploadStatus // "unknown")\n" +
        "      Modified: \(.value.lastModifiedDate // "unknown")\n"
    ' "$JSON_FILE" || fail 'Malformed attachment list response'
}

# Management commands: list, status, delete.
if [ "$COMMAND" != upload ]; then
    read_offline_token
    step 2 'Obtain OAuth Access Token'
    refresh_token 'initial authentication'
    case "$COMMAND" in
        list)
            step 3 'List Case attachments'
            LIST_URL="$BASE/v3/cases/$CASE_NUMBER/attachments"
            [ "$INCLUDE_DELETED" = false ] || LIST_URL="$LIST_URL?includeDeleted=true"
            api_request GET "$LIST_URL" "$TMP_DIR/list.json"
            COUNT=$(jq -er 'if type=="array" then length else empty end' "$TMP_DIR/list.json") || fail 'Invalid list response'
            say "HTTP=$API_HTTP | Attachments=$COUNT | Include deleted=$INCLUDE_DELETED"
            [ "$COUNT" -eq 0 ] || render_attachment_list "$TMP_DIR/list.json"
            say '[RESULT] list completed' ;;
        status)
            step 3 'Get attachment upload status'
            api_request GET "$BASE/v3/cases/$CASE_NUMBER/attachments/$ATTACHMENT_ID/status" "$TMP_DIR/status.json"
            say "HTTP=$API_HTTP | Attachment ID=$ATTACHMENT_ID"
            jq . "$TMP_DIR/status.json" || fail 'Invalid status JSON'
            step 4 'Get matching Case attachment metadata'
            api_request GET "$BASE/v3/cases/$CASE_NUMBER/attachments" "$TMP_DIR/list.json"
            jq --arg id "$ATTACHMENT_ID" '
                [.[] | select(.uuid == $id) |
                 {createdDate,fileName,uuid,size,uploadStatus,lastModifiedDate,description}]
            ' "$TMP_DIR/list.json" || fail 'Invalid metadata JSON'
            say '[NOTE] size=0 can appear even when status is Completed.'
            say '[RESULT] status completed' ;;
        delete)
            step 3 'Review attachment before deletion'
            api_request GET "$BASE/v3/cases/$CASE_NUMBER/attachments" "$TMP_DIR/list.json"
            jq --arg id "$ATTACHMENT_ID" '
                [.[] | select(.uuid == $id) |
                 {createdDate,fileName,uuid,size,uploadStatus}]
            ' "$TMP_DIR/list.json" || fail 'Invalid list response'
            say "Case: $CASE_NUMBER | Attachment ID: $ATTACHMENT_ID"
            if [ "$YES" = false ]; then
                say 'WARNING: Deletion cannot be undone.'
                printf 'Delete this attachment? Type YES to confirm: '
                if ! IFS= read -r CONFIRM </dev/tty; then fail 'Unable to read confirmation'; fi
                [ "$CONFIRM" = YES ] || { say '[RESULT] Delete cancelled'; exit 0; }
            fi
            step 4 'Delete the attachment'
            api_request DELETE "$BASE/v3/cases/attachments/deleteFile/$CASE_NUMBER/$ATTACHMENT_ID" "$TMP_DIR/delete.body"
            [ "$API_HTTP" = 204 ] || fail "Expected HTTP 204; received HTTP $API_HTTP"
            say "HTTP 204: attachment deleted (Case=$CASE_NUMBER ID=$ATTACHMENT_ID)"
            say '[RESULT] delete completed' ;;
    esac
    say "Log file: $LOG_FILE"
    exit 0
fi

# Upload: one or more files, each a separate SINGLE_PUT.
step 1 'Check upload files and local environment'
TOTAL_SIZE=0
FILE_COUNT=0
for FILE in "$@"; do
    [ -f "$FILE" ] && [ -r "$FILE" ] || fail "Missing/unreadable file: $FILE"
    SIZE=$(wc -c < "$FILE" | tr -d '[:space:]')
    [ "$SIZE" -gt 0 ] || fail "Empty file: $FILE"
    [ "$SIZE" -le 5368709120 ] || fail "File exceeds 5 GiB: $FILE"
    FILE_COUNT=$((FILE_COUNT + 1))
    TOTAL_SIZE=$((TOTAL_SIZE + SIZE))
    say "  [$FILE_COUNT] $FILE ($SIZE bytes)"
done
[ "$TOTAL_SIZE" -le 5368709120 ] || fail "Combined upload size $TOTAL_SIZE exceeds 5 GiB"
say "Files=$FILE_COUNT Total=$TOTAL_SIZE bytes Parallel=$PARALLEL Download verification=$VERIFY_DOWNLOAD"
say "Platform: $(uname -s) $(uname -m) | curl: $(curl --version | sed -n '1p')"
say "jq: $(jq --version) | PUT: HTTP/1.1"

check_space() {
    SPACE_BYTES=$1
    SPACE_LABEL=$2
    SPACE_KIB=$(df -Pk "$WORK_DIR" | awk 'NR==2 {print $4}') || fail 'Cannot query available disk space'
    case "$SPACE_KIB" in ''|*[!0-9]*) fail 'Invalid df output' ;; esac
    SPACE_AVAILABLE=$((SPACE_KIB * 1024))
    SPACE_REQUIRED=$((SPACE_BYTES + 67108864))
    say "[DISK] $SPACE_LABEL | Available=$SPACE_AVAILABLE Required=$SPACE_REQUIRED (includes 64 MiB buffer)"
    if [ "$SPACE_AVAILABLE" -lt "$SPACE_REQUIRED" ]; then
        say '[DISK] Not enough free space for post-upload download verification.'
        say '[DISK] Free space / enlarge the local filesystem, or use --verify-download=false.'
        fail 'Insufficient disk space; stopping.'
    fi
}
if [ "$VERIFY_DOWNLOAD" = true ]; then
    check_space "$TOTAL_SIZE" 'Before upload (worst-case all copies)'
fi
say '[STEP 1] PASSED'
read_offline_token
step 3 'Obtain OAuth Access Token'
refresh_token 'initial authentication'
step 4 'Check Case attachment API access'
api_request GET "$BASE/v3/cases/$CASE_NUMBER/attachments" "$TMP_DIR/before.json"
BEFORE_COUNT=$(jq -er 'if type=="array" then length else empty end' "$TMP_DIR/before.json") || fail 'Invalid list response'
say "HTTP $API_HTTP | Existing attachments: $BEFORE_COUNT"

# Worker is run in a SUBSHELL, isolated from the parent and other workers.
# This is important: each concurrent job has its own token state, curl files,
# Attachment ID, and cleanup of its verification copy.
worker_upload() {
    FILE=$1
    WORK_INDEX=$2
    WORKER_ACTIVE=1
    ATTACHMENT_ID=''
    FILE_NAME=${FILE##*/}
    FILE_SIZE=$(wc -c < "$FILE" | tr -d '[:space:]')
    WDIR="$TMP_DIR/worker-$WORK_INDEX"
    mkdir -p "$WDIR" || fail 'Cannot create worker temp directory'
    AUTH_TMP="$WDIR/token.json"
    WORK_RESULT="$TMP_DIR/result-$WORK_INDEX.tsv"
    VERIFY_DIR=''
    # Worker trap only clears its own download copy. Parent owns shared log/temp.
    trap '[ -z "$VERIFY_DIR" ] || rm -rf "$VERIFY_DIR"' 0
    trap 'exit 130' 2
    trap 'exit 143' 15
    say "[FILE $WORK_INDEX/$FILE_COUNT] START: $FILE_NAME ($FILE_SIZE bytes) at $(clock)"

    say "[FILE $WORK_INDEX] STEP 5: Initiate SINGLE_PUT"
    BODY=$(jq -nc --arg n "$FILE_NAME" --argjson s "$FILE_SIZE" --arg c "$CASE_NUMBER" \
        '{fileName:$n,fileSize:$s,caseNumber:$c,clientId:"sct-portal",description:"Uploaded via Red Hat Case Management Attachment CLI v1.1"}')
    api_request POST "$BASE/v3/cases/attachments/upload" "$WDIR/init.json" "$BODY"
    STRATEGY=$(jq -er '.uploadStrategy' "$WDIR/init.json") || fail 'No uploadStrategy'
    [ "$STRATEGY" = SINGLE_PUT ] || fail "Unexpected upload strategy: $STRATEGY"
    ATTACHMENT_ID=$(jq -er '.attachmentId' "$WDIR/init.json") || fail 'No attachmentId'
    PRESIGNED_URL=$(jq -er '.presignedUrl' "$WDIR/init.json") || fail 'No presignedUrl'
    case "$PRESIGNED_URL" in https://*) : ;; *) fail 'Presigned URL must be HTTPS' ;; esac
    EXPIRES=$(jq -r '.expirationTime // "unknown"' "$WDIR/init.json")
    say "[FILE $WORK_INDEX] Init HTTP=$API_HTTP ID=$ATTACHMENT_ID URL expires=$EXPIRES"

    say "[FILE $WORK_INDEX] STEP 6: HTTP/1.1 PUT START at $(clock)"
    PUT_START=$(date +%s)
    PUT_RC=0
    if [ "$PARALLEL" -eq 1 ] || [ "$FILE_COUNT" -eq 1 ]; then
        PUT_METRICS=$(curl --http1.1 --show-error --progress-bar --connect-timeout 30 \
           -D "$WDIR/put.headers" -H 'Content-Type: application/octet-stream' \
           --upload-file "$FILE" -o "$WDIR/put.body" \
           -w 'HTTP_VERSION=%{http_version}\nHTTP_CODE=%{http_code}\nUPLOADED_BYTES=%{size_upload}\nSECONDS=%{time_total}\nBYTES_PER_SECOND=%{speed_upload}\nREMOTE_IP=%{remote_ip}\n' \
           "$PRESIGNED_URL") || PUT_RC=$?
    else
        # Suppress overlapping curl progress bars from parallel workers.
        PUT_METRICS=$(curl --http1.1 --silent --show-error --connect-timeout 30 \
           -D "$WDIR/put.headers" -H 'Content-Type: application/octet-stream' \
           --upload-file "$FILE" -o "$WDIR/put.body" \
           -w 'HTTP_VERSION=%{http_version}\nHTTP_CODE=%{http_code}\nUPLOADED_BYTES=%{size_upload}\nSECONDS=%{time_total}\nBYTES_PER_SECOND=%{speed_upload}\nREMOTE_IP=%{remote_ip}\n' \
           "$PRESIGNED_URL") || PUT_RC=$?
    fi
    PUT_DURATION=$(($(date +%s) - PUT_START))
    PUT_HTTP=$(printf '%s\n' "$PUT_METRICS" | sed -n 's/^HTTP_CODE=//p')
    PUT_BYTES=$(printf '%s\n' "$PUT_METRICS" | sed -n 's/^UPLOADED_BYTES=//p')
    say "[FILE $WORK_INDEX] PUT curl-exit=$PUT_RC duration=${PUT_DURATION}s"
    printf '[FILE %s] %s\n' "$WORK_INDEX" "$(printf '%s\n' "$PUT_METRICS" | tr '\n' ' ')"
    [ "$PUT_RC" -eq 0 ] || fail "PUT interrupted (curl=$PUT_RC, HTTP=$PUT_HTTP)"
    case "$PUT_HTTP" in 2??) : ;; *) fail "PUT returned HTTP $PUT_HTTP" ;; esac
    [ "$PUT_BYTES" = "$FILE_SIZE" ] || fail "PUT bytes mismatch: $PUT_BYTES expected $FILE_SIZE"
    say "[FILE $WORK_INDEX] STEP 6 PASSED"
    if [ "$PUT_DURATION" -ge 900 ]; then
        say "[FILE $WORK_INDEX] PUT >=15m; refresh OAuth Access Token before status checks"
        refresh_token 'upload >= 15 minutes'
    else
        ensure_token
    fi

    say "[FILE $WORK_INDEX] STEP 7: Wait for processing / SCANNING / COMPLETED"
    STATUS_START=$(date +%s)
    POLL=0
    while :; do
        POLL=$((POLL + 1))
        api_request GET "$BASE/v3/cases/$CASE_NUMBER/attachments/$ATTACHMENT_ID/status" "$WDIR/status.json"
        STATUS=$(jq -r 'if type=="array" then .[0].status // "UNKNOWN" else .status // "UNKNOWN" end' "$WDIR/status.json" | tr '[:lower:] ' '[:upper:]_')
        ELAPSED=$(($(date +%s) - STATUS_START))
        say "[FILE $WORK_INDEX] $(clock) status=$STATUS poll=$POLL elapsed=${ELAPSED}s"
        case "$STATUS" in
            COMPLETED) break ;;
            IN_PROGRESS|SCANNING|UPLOAD_PENDING|METADATA_CREATION_PENDING|METADATA_CREATION_COMPLETED|PROCESSING) : ;;
            *FAILED*|ABORTED|DELETED) fail "Backend status=$STATUS" ;;
            *) say "[FILE $WORK_INDEX] Warning: unknown status; continue until timeout" ;;
        esac
        [ "$ELAPSED" -lt "$STATUS_TIMEOUT" ] || fail "Backend processing timeout at $STATUS"
        sleep "$POLL_INTERVAL"
    done

    say "[FILE $WORK_INDEX] STEP 8: Verify Case attachment list"
    LIST_START=$(date +%s)
    while :; do
        api_request GET "$BASE/v3/cases/$CASE_NUMBER/attachments" "$WDIR/list.json"
        MATCH=$(jq -c --arg id "$ATTACHMENT_ID" '[.[]|select(.uuid==$id)] | .[0] // {}' "$WDIR/list.json") || fail 'Bad attachment list'
        REMOTE_STATUS=$(printf '%s\n' "$MATCH" | jq -r '.uploadStatus // "NOT_FOUND"')
        REMOTE_SIZE=$(printf '%s\n' "$MATCH" | jq -r '.size // -1')
        REMOTE_STATUS_UPPER=$(printf '%s' "$REMOTE_STATUS" | tr '[:lower:] ' '[:upper:]_')
        say "[FILE $WORK_INDEX] Case list status=$REMOTE_STATUS size=$REMOTE_SIZE"
        case "$REMOTE_STATUS_UPPER" in
            COMPLETED)
                if [ "$REMOTE_SIZE" != "$FILE_SIZE" ]; then
                    say "[FILE $WORK_INDEX] WARNING: API size=$REMOTE_SIZE (expected $FILE_SIZE); will rely on downloaded content verification if enabled"
                fi
                break ;;
            *FAILED*|DELETED|ABORTED) fail "Case list status=$REMOTE_STATUS" ;;
        esac
        [ "$(($(date +%s) - LIST_START))" -lt "$LIST_TIMEOUT" ] || fail 'Case list verification timeout'
        sleep "$POLL_INTERVAL"
    done

    if [ "$VERIFY_DOWNLOAD" = true ]; then
        say "[FILE $WORK_INDEX] STEP 9: Download and byte-for-byte verify"
        check_space "$FILE_SIZE" "Before download (file $WORK_INDEX)"
        VERIFY_DIR=$(mktemp -d "$WORK_DIR/.rh-case-verify.XXXXXX") || fail 'Unable to create verification directory'
        VERIFY_FILE="$VERIFY_DIR/$FILE_NAME"
        DL_WAIT_START=$(date +%s)
        while :; do
            api_request GET "$BASE/v3/cases/attachments/downloadFile/$CASE_NUMBER/$ATTACHMENT_ID" "$WDIR/download.json"
            case "$API_HTTP" in
                200) break ;;
                202)
                    [ "$(($(date +%s) - DL_WAIT_START))" -lt "$LIST_TIMEOUT" ] || fail 'Download URL remained in processing state'
                    sleep "$POLL_INTERVAL" ;;
                *) fail "Unexpected download URL HTTP $API_HTTP" ;;
            esac
        done
        DOWNLOAD_URL=$(jq -er '.downloadUrl' "$WDIR/download.json") || fail 'Missing downloadUrl'
        case "$DOWNLOAD_URL" in https://*) : ;; *) fail 'Download URL must be HTTPS' ;; esac
        DL_RC=0
        DL_START=$(date +%s)
        if [ "$PARALLEL" -eq 1 ] || [ "$FILE_COUNT" -eq 1 ]; then
            DL_HTTP=$(curl --http1.1 --show-error --progress-bar --connect-timeout 30 \
                -L -o "$VERIFY_FILE" -w '%{http_code}' "$DOWNLOAD_URL") || DL_RC=$?
        else
            DL_HTTP=$(curl --http1.1 --silent --show-error --connect-timeout 30 \
                -L -o "$VERIFY_FILE" -w '%{http_code}' "$DOWNLOAD_URL") || DL_RC=$?
        fi
        say "[FILE $WORK_INDEX] Download HTTP=$DL_HTTP curl-exit=$DL_RC duration=$(($(date +%s) - DL_START))s"
        [ "$DL_RC" -eq 0 ] || fail "Download interrupted (curl=$DL_RC)"
        case "$DL_HTTP" in 2??) : ;; *) fail "Download HTTP $DL_HTTP" ;; esac
        DL_SIZE=$(wc -c < "$VERIFY_FILE" | tr -d '[:space:]')
        [ "$DL_SIZE" = "$FILE_SIZE" ] || fail "Downloaded size=$DL_SIZE expected=$FILE_SIZE"
        cmp -s "$FILE" "$VERIFY_FILE" || fail 'Downloaded data differs from local original'
        VERIFY_RESULT='PASS (byte-for-byte identical)'
        say "[FILE $WORK_INDEX] STEP 9 PASSED: byte-for-byte identical"
        # Reclaim space early, not at the end of all parallel jobs.
        rm -rf "$VERIFY_DIR"
        VERIFY_DIR=''
    else
        VERIFY_RESULT='SKIPPED (not independently verified)'
        say "[FILE $WORK_INDEX] STEP 9 SKIPPED (--verify-download=false)"
    fi
    printf 'PASS\t%s\t%s\t%s\t%s\t%s\n' "$WORK_INDEX" "$FILE_NAME" "$ATTACHMENT_ID" "$PUT_DURATION" "$VERIFY_RESULT" > "$WORK_RESULT"
    say "[FILE $WORK_INDEX/$FILE_COUNT] SUCCESS File=$FILE_NAME ID=$ATTACHMENT_ID Verify=$VERIFY_RESULT"
}

step 5 'Upload and verify attachments'
say "Concurrency: $PARALLEL (use --parallel=1 for sequential uploads)"
if [ "$FILE_COUNT" -gt 1 ] && [ "$PARALLEL" -gt 1 ]; then
    say 'Parallel mode: progress bars suppressed to avoid interleaved output.'
fi
ACTIVE_COUNT=0
FILE_INDEX=0
FAILURES=0
for FILE in "$@"; do
    FILE_INDEX=$((FILE_INDEX + 1))
    ( worker_upload "$FILE" "$FILE_INDEX" ) &
    WPID=$!
    ACTIVE_PIDS="${ACTIVE_PIDS}${ACTIVE_PIDS:+ }$WPID"
    ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
    if [ "$ACTIVE_COUNT" -ge "$PARALLEL" ]; then
        FIRST_PID=${ACTIVE_PIDS%% *}
        if wait "$FIRST_PID"; then :; else FAILURES=$((FAILURES + 1)); fi
        case "$ACTIVE_PIDS" in
            *' '*) ACTIVE_PIDS=${ACTIVE_PIDS#* } ;;
            *) ACTIVE_PIDS='' ;;
        esac
        ACTIVE_COUNT=$((ACTIVE_COUNT - 1))
    fi
done
while [ -n "$ACTIVE_PIDS" ]; do
    WPID=${ACTIVE_PIDS%% *}
    case "$ACTIVE_PIDS" in
        *' '*) ACTIVE_PIDS=${ACTIVE_PIDS#* } ;;
        *) ACTIVE_PIDS='' ;;
    esac
    if wait "$WPID"; then :; else FAILURES=$((FAILURES + 1)); fi
done
ACTIVE_PIDS=''

printf '\n============================================================\n'
say ' FINAL UPLOAD SUMMARY'
say '============================================================'
say "Case=$CASE_NUMBER | Files=$FILE_COUNT | Total=$TOTAL_SIZE bytes | Parallel=$PARALLEL"
I=1
while [ "$I" -le "$FILE_COUNT" ]; do
    RESULT_FILE="$TMP_DIR/result-$I.tsv"
    if [ -f "$RESULT_FILE" ]; then
        awk -F '\t' '{if ($1=="PASS") {printf "  [%s] %-5s File=%s | ID=%s | PUT=%ss | Verify=%s\n",$2,$1,$3,$4,$5,$6} else {printf "  [%s] %-5s File=%s | ID=%s\n",$2,$1,$3,$4}}' "$RESULT_FILE"
    else
        say "  [$I] FAILED / no result record (see log)"
        FAILURES=$((FAILURES + 1))
    fi
    I=$((I + 1))
done
say "Total duration: $(($(date +%s) - START_TS))s"
say "Diagnostic log: $LOG_FILE"
if [ "$FAILURES" -ne 0 ]; then
    say "FINAL RESULT: PARTIAL/FAILED ($FAILURES error(s)); successful attachments remain on the Case."
    exit 1
fi
say 'FINAL RESULT: SUCCESS (all attachments completed; download verification per file as shown)'
