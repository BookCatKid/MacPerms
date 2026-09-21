# TCC Architecture on macOS 27 — Verified Findings

Everything below was verified on-device (macOS 27.0, build 26A428, arm64, SIP disabled,
AMFI enforcing — no `amfi_get_out_of_my_way` boot-arg).

## Storage layer

| DB | Path | Owner | Services |
|---|---|---|---|
| System | `/Library/Application Support/com.apple.TCC/TCC.db` | root:wheel, world-readable | Accessibility, ScreenCapture, PostEvent, ListenEvent, DeveloperTool, SystemPolicyAllFiles (FDA) |
| User | `/private/var/containers/Data/ProtectedSystem/<UUID>/Data/Library/Application Support/com.apple.TCC/TCC.db` | user (700 dir, 600 file) | everything else: Camera, Microphone, AppleEvents, Photos, folders, Liverpool, Ubiquity, … |
| Registry | `/Library/Application Support/com.apple.TCC/REG.db` | root:wheel | `registry(abs_path, first_seen, last_seen, trusted)` — canonical DB-path registry |

- The user DB **moved** in macOS 27 from `~/Library/Application Support/com.apple.TCC/`
  into a per-user ProtectedSystem data container. Discovery: glob
  `/private/var/containers/Data/ProtectedSystem/*/Data/Library/Application Support/com.apple.TCC/TCC.db`
  and union with REG.db `registry` rows where `trusted=1`.
- Journal mode is `delete` (no `-wal`/`-shm`) — committed writes are visible to all
  readers immediately.
- `AdhocSignatureCache/` sits next to each DB (per-DB cache of adhoc code identities).

## Schema (version 36, per `admin` table)

`access` PK = `(service, client, client_type, indirect_object_identifier)`.
Notable columns: `auth_value` (0 denied / 1 unknown / 2 allowed / 3 limited),
`auth_reason` (2 user-consent, 3 user-set, 4 system-set, 5 service-policy, 6 MDM,
7 override, 8 missing-usage-string, 9 prompt-timeout, 10 preflight-unknown,
11 entitled, 12 app-type-policy), `auth_version`=1, `csreq` (designated-requirement
blob), `indirect_object_identifier` (Automation target bundle id or 'UNUSED'),
`flags` (bit 0 = non-user/expired-ish per tccd's `flags & 1` filter),
`pid`/`pid_version`/`boot_uuid`/`last_reminded` (Sequoia+), and **new in 27**:
`one_time_reprompt_eligible`, `reminder_count` (re-prompt machinery).

New in 27: `managed_overrides` (MDM writes land here first; `admin_auth_value` is the
admin-set verdict, `auth_value` the user-side verdict) and, in the user DB,
`fine_grained_table_kTCCServiceSystemPolicyAppDataDetailed`.
Also present: `expired` (expired grants), `integrity_flag`, `access_overrides`,
`policies`/`active_policy` (client → profile UUID).

tccd's own write statement (extracted from binary):
```sql
INSERT OR REPLACE INTO access
(service, client, client_type, auth_value, auth_reason, auth_version, csreq,
 policy_id, indirect_object_identifier, flags, pid, pid_version, boot_uuid,
 one_time_reprompt_eligible, last_reminded, reminder_count)
VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
```
— `indirect_object_identifier_type` is **not** in the modern write path.

## Daemons

- `tccd` (user, uid 501) — LaunchAgent `com.apple.tccd`, Mach service `com.apple.tccd`.
- `tccd system` (root) — LaunchDaemon `com.apple.tccd.system`, Mach `com.apple.tccd.system`.
- Both `EnablePressuredExit`, publish `com.apple.tccd.events` (DomainInternal),
  watch `…/com.apple.TCC/MDMOverrides.plist`, and launch on
  `com.apple.ManagedSettings.effective-settings.changed` (privacy group).

## Enforcement & the request path (from unified log, `subsystem=com.apple.TCC`)

1. Client framework sends XPC dict `{"function": "TCCAccessRequest", …}` to
   `com.apple.tccd` or `com.apple.tccd.system`.
2. `AttributionChain`: tccd resolves `requesting` process and **`responsible` process**
   (`p_responsible_pid`). A CLI tool launched inside a terminal attributes to the
   **terminal's** identity (verified: `probe_one` under Ghostty → subject
   `com.mitchellh.ghostty`). Only apps launched via LaunchServices (`open`, Finder,
   Dock) are self-responsible.
3. `IDENTITY_ATTRIBUTION` resolves the client to `identifier` + `client_type`
   (0 = signing/bundle identifier, 1 = executable path), computes/validates the
   designated requirement (`matchesCodeRequirement`), keeps an `identityCache`.
4. `AUTHREQ_CTX → AUTHREQ_ATTRIBUTION → AUTHREQ_SUBJECT → AUTHREQ_RESULT`:
   `authValue`, `authReason`, `authVersion`, `desired_auth`, `error`.
5. Sandboxed access is also backstopped by the platform sandbox profile
   (`with user-approval`) via kernel → `sandboxd` → tccd.

## Write semantics — EXPERIMENTALLY VERIFIED

Using a dlsym'd `TCCAccessPreflight` probe (return enum measured: **0=allowed,
1=denied, 2=unknown**):

| Direct sqlite op on user DB | tccd verdict after op |
|---|---|
| `INSERT … auth_value=2` | allowed — **immediate, no daemon restart** |
| `UPDATE auth_value=0` | denied — immediate |
| `DELETE` | unknown — immediate |

So tccd performs a live SELECT per authorization request for clients without an
in-flight cached verdict. Caveats: a running process that already holds a resource
(e.g. an active capture session, or a kernel-cached verdict per the Tahoe-era
caching bug) may not re-check — the app should warn users to relaunch affected
clients, and offer a "restart tccd" action.

## API surface (dlsym-verified)

Works unentitled:
- `TCCAccessPreflight(service, options)` → int (self only)
- `TCCAccessRequest`, `TCCAccessRequestIndirect` (request/prompt path)
- `TCCAccessCopyBundleIdentifiersForService` → NULL unentitled (no crash)

Entitlement-gated (SIGTRAP without `com.apple.private.tcc.manager.access.*`):
- `TCCAccessSetForBundle`, `TCCAccessSetForPath`, `TCCAccessSetForAuditToken`,
  `TCCAccessResetForBundle`, `TCCAccessCheckAuditToken`, `TCCAccessCopyInformation`
- Removed since earlier releases: `TCCAccessSetForResponsiblePid`,
  `TCCAccessSelectPolicyForExtension*`, `TCCAccessGetInformation`.

Entitlements held by System Settings (`SecurityPrivacyExtension.appex`):
`com.apple.private.tcc.allow`, `.manager.access.read`, `.manager.access.modify`,
`.manager.access.delete`, `.manager.service-composition`.

`tccutil` (macOS 27): only `tccutil reset SERVICE [BUNDLE_ID]` (`All` = all services).

## Implications for TCCManager

1. **Read**: sqlite3 on both DBs. System DB is world-readable; user DB is
   user-readable. No privileges needed to *display* everything.
2. **Write (user DB)**: direct `INSERT OR REPLACE`/`UPDATE`/`DELETE` as the user —
   verified effective immediately.
3. **Write (system DB)**: file is root-owned → needs elevation. Implemented as a
   privileged helper invoked via `osascript 'do shell script … with administrator
   privileges'` (standard macOS admin auth dialog, no SIP/AMFI weakening).
4. **Grant/revoke**: `REPLACE`/`UPDATE` `auth_value` (2/0), `auth_reason=3`
   (user-set), `auth_version=1`. Keep existing `csreq` if present; for new records
   generate csreq via `csreq(1)`/`codesign -d -r-` so the row verifies cleanly.
5. **Reset**: `DELETE` the access row(s) — equivalent to `tccutil reset SERVICE
   bundle-id` but without the private entitlement.
6. **Verify**: re-read the row + report. (True enforcement probes like
   `TCCAccessCheckAuditToken` need entitlements we don't have.)
7. **Managed rows** (`managed_overrides`, `auth_reason=6`): render read-only.
8. **Automation**: one row per `indirect_object_identifier` target; show target app.
9. **Confirmation before every mutation**; all SQL parameterized; writes wrapped in
   a transaction with read-back before reporting success.
