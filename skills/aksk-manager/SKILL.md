---
name: aksk-manager
description: Find cloud AK/SK or API Token metadata and run authorized local commands using credential references, without putting secrets into chat.
---

# AKSK Manager

Use `list_secrets` and `get_secret_metadata` to locate the intended account, environment and fields.
If several entries match a consequential operation, ask the user to identify the intended account.
Ask users to add or update secrets through **更多工具 → AKSK Manager**, never through chat.

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
