---
name: aksk-manager
description: Find credential metadata, edit existing records using native field references, and run authorized local commands without putting secrets into chat.
---

# AKSK Manager

Use `list_secrets` and `get_secret_metadata` to locate the intended account, environment and fields.
If several entries match a consequential operation, ask the user to identify the intended account.
New plaintext credentials are entered through **更多工具 → AKSK Manager**, never through chat.
Use `update_secret` for authorized edits to existing records without UI automation.

## Agent editing

Read the target with `get_secret_metadata`, then supply its `id` as `secret_id` and
its `revision` as `expected_revision`. `changes` can update name, kind, provider,
account, environment, tags and notes. Omitted/null changes preserve metadata;
an empty string or empty tags list clears that metadata. Never put credentials or
connection values into these public metadata fields.

`field_refs` maps destination field names to `{secret_id, revision, field}` from
existing records. Values move only within the signed native helper, not through
model/tool arguments or results. An optional `json_path` is an ordered list of
object keys selecting a string inside an existing JSON credential. For example,
use `["connection", "password"]` only when the JSON structure is known from the
authorized source; do not probe paths to reveal contents.

Same-kind edits preserve other values. A kind change replaces the old field set:
provide references for every field to retain, including required fields for the
new kind. `remove_fields` explicitly removes optional values. References check
source revisions as well as the target revision under the existing local lock.
Source records are unchanged. There is no create, trash, restore or purge action
in this tool, and it cannot accept a new plaintext password.

After a successful update, read metadata again to verify ID, type, fields and
revision. On conflicts or timeouts, read back before retrying; never replay an
uncertain write blindly. Local revision checks do not provide global iCloud CAS.

## Panel lifecycle and UI recovery

The credential editor uses the host's fullscreen workspace, not an inline chat card.
A UI automation timeout alone does not prove the panel or native helper crashed.
Before asking for a reopen, inspect the existing app tabs and read the intended
panel again. Use short action batches with bounded locator timeouts, and inspect
the resulting state between dependent actions. Never repeat a write whose outcome
is unknown; verify metadata and revision first. Do not confuse IAB browser-route
errors with MCP Apps failures, or another instance's offscreen-suspension log with
the panel being edited.

Installing an update does not hot-replace an existing chat's plugin process or
open UI. Verify the loaded version separately from the installed package. Do not
claim a host lifecycle fix from preview tests or installation alone, and do not
modify host binaries or add background heartbeats to defeat host suspension.

## Credential use

Use `run_with_secrets` with an argument array, an absolute working directory and bindings of
environment variable names to `{secret_id, field}`. Fields are `access_key`, `secret_key`,
`session_token`, or `token`. For AWS, bind `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and,
when present, `AWS_SESSION_TOKEN`. Do not assume every provider uses AWS variable names.

Database entries have kind `database`. Connection fields are `engine`, `host`, optional `port`,
`database`, `username`, `password`, and `ssl_mode`. Their values are private just like tokens;
metadata exposes only field names. Ask the user to enter them in the Database Connection
(数据库连接) form. Never put connection values into the name, notes, or other metadata.
Bind only fields present in metadata. For PostgreSQL clients, map `PGHOST` to `host`, `PGPORT`
to `port`, `PGDATABASE` to `database`, `PGUSER` to `username`, `PGPASSWORD` to `password`, and
`PGSSLMODE` to `ssl_mode` as needed. Other clients need their own supported variable mappings.
Do not print or reconstruct connection strings in chat. Storing a configuration does not verify
connectivity; database commands still need authorization for their actual effects.

Command execution can change local files and remote systems. Honor the human's actual authorization,
applicable instructions, and host restrictions. The vault does not add another per-use approval.
Do not use it to bypass a denied command or an approval requirement in another tool.

Never invoke commands intended to print, encode, export, copy to files or exfiltrate credentials.
Do not invoke app-only reveal or mutation tools on the model's behalf.
Secret values are not tool arguments: use references even when assembling shell scripts.
Do not promise that arbitrary child processes cannot disclose secrets; they receive real credentials.

Poll `get_run` using the returned id. Output is available only after completion and known raw secrets
are redacted. Jobs are session-local; do not start the same mutating command again just because a
connection failed. Report unknown outcomes and inspect effects before retrying.

`MISSING_ENTITLEMENT`, `SIGNING_REQUIRED`, `HELPER_MISSING` and `HELPER_STOPPED` require fixing the
native component, not switching to plaintext storage. `KEYCHAIN_LOCKED` requires system unlock.
The app reports local reads/writes only; iCloud synchronization to another Mac needs independent verification.
