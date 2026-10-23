Red Hat Case Management Attachment CLI
A lightweight, POSIX-compatible shell utility for managing Red Hat Customer Portal support case attachments from the command line.
This community-maintained tool uses the Red Hat Case Management Attachment Service API to list, upload, check, and delete attachments. It can be particularly useful when uploading large diagnostic archives (such as OpenShift must-gather bundles or RHEL sosreport files) through a web browser is unreliable.
[!IMPORTANT]
Unofficial utility. This repository is an independently developed convenience script, not an official Red Hat product or a replacement for Red Hat Support procedures. It requires a Red Hat account authorized to access the target support case. Test the tool in a non-production support case before using it for sensitive customer data.

Features
- List attachments on a support case, including creation time, filename, attachment ID, reported size, and status.
- Upload one or more files as separate case attachments, with up to four concurrent workers.
- Check status for a specific attachment and view related metadata.
- Delete an attachment, with interactive confirmation by default.
- Obtain an OAuth access token from a user-provided Red Hat offline token, and refresh the access token automatically as needed.
- Transfer files via HTTP/1.1 using time-limited presigned URLs.
- Wait through backend processing states such as IN_PROGRESS and SCANNING until COMPLETED.
- By default, download each uploaded attachment and compare it byte-for-byte against the local original.
- Save timestamped diagnostic logs in the directory where the command is run.
Requirements
- Operating systems: macOS or Linux (including Red Hat Enterprise Linux).
- Shell: POSIX sh; the script can also be invoked using bash or zsh.
- Command-line tools: curl, jq, and standard Unix utilities (awk, cmp, date, df, mkfifo, mktemp, sed, stty, tee, etc.).
- Connectivity: HTTPS access to the Red Hat SSO, Case Management API, and the storage/CDN hostname provided in each presigned URL. Corporate proxy/firewall rules may need to allow the destinations documented in the Attachment Service API Guide.
- Permissions: a Red Hat Customer Portal account that can access the target case and obtain an offline token. The Red Hat API getting-started guide describes token prerequisites and permissions.
- Terminal: an interactive TTY for entering the offline token and confirming deletion.
Install jq if it is missing:
# macOS with Homebrew
brew install jq

# RHEL (with appropriate repositories enabled)
sudo dnf install jq
Installation
git clone https://github.com/TerryHu82/rh-case-management.git
cd rh-case-management
chmod +x rh-case-management.sh
./rh-case-management.sh --help
Alternatively, download rh-case-management.sh from this repository and run it locally. Review the script before executing it, particularly in a customer or enterprise environment.
Authentication
1. Sign in to the Red Hat API Tokens page using the account that has access to the support case.
2. Generate or retrieve your offline token, following Getting started with Red Hat APIs.
3. Run a command. When prompted, paste the offline token and press Enter. Input is hidden and will not echo to the terminal.
4. The script exchanges the offline token for a short-lived OAuth access token, then refreshes the access token automatically when it is nearing expiration or when a request returns HTTP 401.
The access token normally has a lifetime of 900 seconds (15 minutes). The offline token is kept in the running script's memory and is not intentionally printed to the diagnostic log. Never enable shell tracing (sh -x, bash -x, or set -x) while using credentials.
Usage
./rh-case-management.sh <COMMAND> [OPTIONS] <ARGUMENTS>
Command	Syntax	Purpose
list	list [--include-deleted] CASE_NUMBER	List attachments on a case.
upload	upload [--verify-download=true|false] [--parallel=N] CASE_NUMBER FILE [FILE ...]	Upload one or more files.
status	status CASE_NUMBER ATTACHMENT_ID	Read upload status and case attachment metadata.
delete	delete [--yes] CASE_NUMBER ATTACHMENT_ID	Delete one attachment from a case.


Place command-specific options before CASE_NUMBER. Substitute your own case number, attachment ID, and local file paths in the examples below.
List attachments
./rh-case-management.sh list 01234567

# Include deleted attachment records, if available from the API
./rh-case-management.sh list --include-deleted 01234567
The output includes the creation date, filename, attachment ID (uuid), size as reported by the API, status, and last-modified date.
Upload one file
./rh-case-management.sh upload 01234567 ./must-gather.tar.gz
By default, upload verification includes downloading a complete copy after the API reports completion and comparing it with the local file using cmp. Allow sufficient network bandwidth, time, and disk space for the additional download.
To skip the download/content comparison:
./rh-case-management.sh upload --verify-download=false 01234567 ./must-gather.tar.gz
Skipping verification does not skip the backend status checks; the tool still waits for completion and confirms that the attachment is listed on the case. However, it does not independently prove that the remote bytes match the local file.
Upload multiple files
# Two concurrent workers (the default)
./rh-case-management.sh upload --parallel=2 01234567 \
  ./must-gather-a.tar.gz \
  ./must-gather-b.tar.gz \
  ./sosreport.tar.xz

# Sequential uploads
./rh-case-management.sh upload --parallel=1 01234567 \
  ./file-a.tar.gz ./file-b.tar.gz

# Up to four concurrent workers
./rh-case-management.sh upload --parallel=4 --verify-download=false \
  01234567 ./file-a.tar.gz ./file-b.tar.gz ./file-c.tar.gz
Each file is initialized and managed as a separate case attachment, with its own attachment ID, presigned URL, transfer result, status polling, and optional download verification. In parallel mode, individual curl progress bars are suppressed so that output stays readable. A final summary reports results per file; if a file fails, other workers may still succeed and their attachments remain on the case.
Current script limits: Each input file must be nonempty and at most 5 GiB (5,368,709,120 bytes), and the combined size of all input files must also be at most 5 GiB. These are limits implemented by this utility, not the maximum capability of the underlying Red Hat API. The script does not implement multipart uploads for files above the single-PUT threshold.
Check an attachment's status
./rh-case-management.sh status 01234567 ATTACHMENT_ID
This retrieves the specific upload status and matching metadata from the case attachment list. Replace ATTACHMENT_ID with the value returned by upload or list.
Delete an attachment
# Prompts you to type YES to confirm
./rh-case-management.sh delete 01234567 ATTACHMENT_ID

# Non-interactive confirmation bypass; use with extra care
./rh-case-management.sh delete --yes 01234567 ATTACHMENT_ID
Deletion is destructive. Double-check the case number and attachment ID, especially when using --yes. Deletion may remove both the case attachment record and the stored file, as described in the API documentation.
Get help
./rh-case-management.sh
./rh-case-management.sh --help
Options and settings
Option or setting	Default	Description
--verify-download=true	true	Download and compare each uploaded attachment with its original.
--verify-download=false	—	Skip the download/byte comparison.
--parallel=N	2	Number of concurrent upload workers (1 to 4).
--include-deleted	false	Include deleted records in list, where supported.
--yes	false	Skip interactive confirmation for delete.
POLL_INTERVAL	30 seconds	Interval between processing-status queries.
STATUS_TIMEOUT	7200 seconds	Maximum wait for backend processing per upload.
LIST_TIMEOUT	600 seconds	Maximum wait for case attachment metadata confirmation.


The timing settings are environment variables, not command-line flags. For example:
POLL_INTERVAL=60 STATUS_TIMEOUT=14400 LIST_TIMEOUT=1200 \
  ./rh-case-management.sh upload 01234567 ./must-gather.tar.gz
These are client-side waiting limits, not published Red Hat backend service timeouts.
How uploads work
1. Verify input files, total size, and (when download verification is enabled) available space on the current working directory's filesystem.
2. Read the offline token without echoing it, then request an OAuth access token.
3. Confirm access to the target case.
4. Initialize a SINGLE_PUT attachment upload for each file via the Case Management API.
5. Send the full file to the returned presigned URL, forcing HTTP/1.1 for transfer. Record HTTP status, bytes sent, duration, transfer rate, and connection diagnostics.
6. Poll the attachment status until COMPLETED. The observed intermediate states can include IN_PROGRESS and SCANNING.
7. Confirm the attachment appears in the case list with status Completed.
8. Unless --verify-download=false was set, obtain a presigned download URL, download the attachment to a temporary location, and use cmp to verify that the content matches the original byte-for-byte.
Note about reported file size: In actual testing, the attachment-list API has sometimes returned size: 0 even with uploadStatus: Completed. The script warns about that inconsistency instead of treating it as proof of an empty file. With download verification enabled, success is based on successfully downloading and comparing the actual bytes.
The script does not automatically retry an interrupted PUT or delete an incomplete attachment. If an upload stops unexpectedly, record its Attachment ID and inspect the status before deciding whether to delete it or start a new upload.
Logs and disk space
The tool writes command output to a timestamped .log file in the current working directory, using a filename similar to:
rh-case-management-v1.1-upload-YYYYMMDD-HHMMSS-PID.log
The script uses restrictive permissions (umask 077). Logs are intended to support troubleshooting, but they can include case numbers, local file paths, attachment filenames, attachment IDs, IP addresses, timings, and HTTP responses. Review and redact diagnostic logs before attaching them to a public GitHub issue or sharing them outside your organization. Do not upload access tokens, offline tokens, presigned URLs, or customer diagnostic archives to this public repository.
When content verification is enabled, temporary downloads are placed on the filesystem containing the current working directory and are removed after verification. The script checks available space before upload and before each download, reserving an additional 64 MiB as a safety buffer. For parallel uploads, adequate space and bandwidth should be available for the active verification copies.
If disk space is insufficient, free or increase space, choose a working directory with more capacity, or use --verify-download=false to skip the additional download. The latter disables independent byte-for-byte verification.
Troubleshooting
Symptom	Suggested next step
HTTP 401	Check Red Hat SSO authentication and offline token validity; the script will attempt to refresh its access token.
HTTP 403	Confirm that the authenticated Red Hat account has access to the support case.
HTTP 404	Check case number, attachment ID, and whether the attachment was deleted.
HTTP 5xx	Record the command, time, HTTP response, and redacted diagnostic log for the appropriate support team.
Upload fails with curl 16 / 18	Investigate network/proxy/CDN stability. This tool forces HTTP/1.1 for the file PUT; do not assume a failed transfer has been stored completely.
Status remains IN_PROGRESS or SCANNING	Continue polling within the configured timeout. If it times out, inspect the attachment ID; do not blindly re-upload.
Completed but size: 0	Use the default download comparison to determine whether the attachment content is intact.
Insufficient free space	Clean up files, change to a roomier working directory, or disable download verification.
Token input fails	Run from an interactive terminal rather than a non-interactive pipeline or CI task.


For corporate firewall/proxy allowlists and presigned storage endpoints, consult the Red Hat Attachment Service API Guide. A 404 when opening the attachment service hostname root in a browser is not by itself a valid upload API connectivity test.
Security and support considerations
- Treat the offline token as a password; do not paste it into issues, chat messages, scripts, shell history, or configuration files.
- Avoid enabling set -x/shell tracing when handling tokens or presigned URLs.
- Obtain explicit authorization before uploading support archives, since must-gather and sosreport files can contain sensitive diagnostic information.
- Run the tool from a trusted environment over approved corporate network paths.
- Review any script downloaded from a public GitHub repository before executing it.
- This project is an unofficial helper, provided without a guarantee of compatibility with future Red Hat API changes. For service-side incidents or account permissions, use the official Red Hat Support process.
Official Red Hat references
- Red Hat Case Management — Attachment Service API Guide
- Getting started with Red Hat APIs
Version: 1.1
Repository: https://github.com/TerryHu82/rh-case-management
Feedback: Open a GitHub issue with reproducible steps and sanitized logs (never upload credentials or private customer data).
