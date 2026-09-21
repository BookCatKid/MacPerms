# macOS TCC (Transparency, Consent, and Control) Internals — Research Notes

> Scope: permission-management GUI for macOS (SIP disabled). Public sources verified
> through macOS 26 "Tahoe". **On-device findings for macOS 27.0 (build 26A428) are
> integrated inline and marked [macOS 27 VERIFIED].** Items marked ⚠️ are uncertain
> or version-dependent.

## 1. Database locations, protection, and service routing

| DB | Path | Protection |
|---|---|---|
| System | `/Library/Application Support/com.apple.TCC/TCC.db` | [macOS 27 VERIFIED] `-rw-r--r-- root:wheel` — world-readable, root-writable. |
| User | **MOVED in macOS 27** → `/private/var/containers/Data/ProtectedSystem/<per-user-UUID>/Data/Library/Application Support/com.apple.TCC/TCC.db` | [macOS 27 VERIFIED] owned by the user (`-rw------- simon`), inside a `drwx------` per-user container. The old `~/Library/Application Support/com.apple.TCC/` path no longer exists. |

- [macOS 27 VERIFIED] The user DB path was confirmed via `lsof -p <user tccd pid>` — the per-user `tccd` holds fd → the ProtectedSystem container.
- [macOS 27 VERIFIED] **REG.db** at `/Library/Application Support/com.apple.TCC/REG.db` has schema `registry(abs_path TEXT PK, first_seen REAL, last_seen REAL, trusted INTEGER)` — it is the registry of valid TCC database paths (matches entitlement `com.apple.private.tcc.internal.db_path_registry`). Use it to enumerate DB locations rather than hardcoding paths.
- [macOS 27 VERIFIED] No `-wal`/`-shm` files observed → journal mode is not WAL; commits land in the main file immediately.

**Which services live in which DB** [macOS 27 VERIFIED by row counts]:

- **System DB:** `kTCCServiceAccessibility` (36 rows), `kTCCServiceSystemPolicyAllFiles` (FDA, 12), `kTCCServiceScreenCapture` (11), `kTCCServicePostEvent` (10), `kTCCServiceListenEvent` (5), `kTCCServiceDeveloperTool` (1).
- **User DB:** `kTCCServiceLiverpool` (79 — iCloud-related grants, heavily populated by system daemons), `kTCCServiceUbiquity` (34), `kTCCServiceAppleEvents` (18), `kTCCServiceMicrophone` (13), `kTCCServiceBluetoothAlways`, `kTCCServiceFileProviderDomain`, `kTCCServiceSystemPolicy{Downloads,Documents,Desktop}Folder`, `kTCCServiceCalendar`, `kTCCServiceWebBrowserPublicKeyCredential`, `kTCCServiceAddressBook`, `kTCCServiceCamera`, `kTCCServiceFocusStatus`, `kTCCServiceMediaLibrary`, `kTCCServiceReminders`, `kTCCServiceSystemPolicyRemovableVolumes`, `kTCCServicePhotos`.
- FDA can *only* be granted via the system DB.

Sources: https://www.rainforestqa.com/blog/macos-tcc-db-deep-dive , https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-tcc/index.html , https://objective-see.org/blog/blog_0x4C.html , on-device `sqlite3` dumps.

**Daemons** [macOS 27 VERIFIED]:
- System `tccd` runs as root: LaunchDaemon `com.apple.tccd.system.plist`, Mach service `com.apple.tccd.system`, argv `tccd system`.
- Per-user `tccd`: LaunchAgent `com.apple.tccd.plist`, Mach service `com.apple.tccd`.
- Both publish event `com.apple.tccd.events` (DomainInternal).
- Binary: `/System/Library/PrivateFrameworks/TCC.framework/Support/tccd`.
- `MDMOverrides.plist` watch path still present.

## 2. TCC.db schema [macOS 27 VERIFIED — both DBs dumped]

```sql
CREATE TABLE access (
    service TEXT NOT NULL, client TEXT NOT NULL, client_type INTEGER NOT NULL,
    auth_value INTEGER NOT NULL, auth_reason INTEGER NOT NULL, auth_version INTEGER NOT NULL,
    csreq BLOB, policy_id INTEGER,
    indirect_object_identifier_type INTEGER,
    indirect_object_identifier TEXT NOT NULL DEFAULT 'UNUSED',
    indirect_object_code_identity BLOB,
    flags INTEGER,
    last_modified INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
    pid INTEGER, pid_version INTEGER,
    boot_uuid TEXT NOT NULL DEFAULT 'UNUSED',
    last_reminded INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
    one_time_reprompt_eligible INTEGER,          -- NEW in macOS 27
    reminder_count INTEGER NOT NULL DEFAULT 0,   -- NEW in macOS 27
    PRIMARY KEY (service, client, client_type, indirect_object_identifier),
    FOREIGN KEY (policy_id) REFERENCES policies(id) ON DELETE CASCADE ON UPDATE CASCADE);
```

Other tables [macOS 27 VERIFIED]: `admin`, `policies`, `active_policy`, `access_overrides`,
`expired`, `integrity_flag`, **`managed_overrides` (NEW in 27)** — mirrors `access` plus
`admin_auth_value INTEGER NOT NULL`; tccd SQL shows MDM grants now write here first
("Override: routing %@ for %@ to managed_overrides"). User DB additionally has
`fine_grained_table_kTCCServiceSystemPolicyAppDataDetailed` (per-category AppData grants).

`admin` table version: `INSERT OR IGNORE INTO admin VALUES ('version', 36)` in tccd's
DDL — DB schema version 36 on macOS 27.

Column semantics (auth_value: 0=denied, 1=unknown, 2=allowed, 3=limited;
auth_reason: 2=User Consent, 3=User Set, 4=System Set, 5=Service Policy, 6=MDM,
7=Override, 8=Missing usage string, 9=Prompt timeout, 10=Preflight unknown, 11=Entitled,
12=App Type Policy) — sources: https://hacktricks.wiki/.../macos-tcc/ , rainforestqa.
[macOS 27 VERIFIED] observed `auth_value=2, auth_reason=4` for system-granted rows;
`auth_status` column does NOT exist (still `auth_value`).

## 3. Service names — full `strings tccd` list captured on macOS 27

New-ish vs older lists: `kTCCServiceAccessoryAutomaticAudioSwitching`,
`kTCCServiceAccessoryLiveActivities`, `kTCCServiceAccessoryNotifications`,
`kTCCServiceAccessoryWiFiNetworkSharing`, `kTCCServiceAudioAccessoryHeadTrackData`,
`kTCCServiceAudioCapture`, `kTCCServiceExternalAIProviderBlocked`,
`kTCCServiceExternalAIVisibleToSystem`, `kTCCServiceExternalCameraMedia`,
`kTCCServiceMicrophoneInjection`, `kTCCServicePasteboard`, `kTCCServiceRemoteDesktop`,
`kTCCServiceVirtualMachineNetworking`, `kTCCServiceSystemPolicyAppDataDetailed`,
plus the full SensorKit/legacy set. (Complete list in `docs/services.txt`.)

Semantics: `ListenEvent`=Input Monitoring, `PostEvent`=synthetic input, `ScreenCapture`
=Screen Recording, `SystemPolicyAllFiles`=Full Disk Access, `AppleEvents`=Automation
(indirect_object = target app), `Liverpool`=iCloud/"sharingd" scope.

## 4. `tccutil` [macOS 27 VERIFIED]

Only verb: `tccutil reset SERVICE [BUNDLE_ID]` (`All` resets everything). Man page dated
2012. Holds `com.apple.private.tcc.manager.access.delete`-equivalent authority.

## 5. Private TCC.framework API — dlsym-verified on macOS 27

| Symbol | Present? | Unentitled behavior |
|---|---|---|
| `TCCAccessRequest` | yes | (not called — would prompt) |
| `TCCAccessRequestIndirect` | yes | — |
| `TCCAccessPreflight` | yes | **WORKS unentitled** — returns int enum (observed `2` for a never-granted adhoc binary) |
| `TCCAccessCheckAuditToken` | yes | — |
| `TCCAccessSetForAuditToken` | yes | — |
| `TCCAccessSetForBundle` | yes | **SIGTRAPs** (entitlement abort) |
| `TCCAccessSetForPath` | yes | — |
| `TCCAccessResetForBundle` | yes | — |
| `TCCAccessCopyInformation` | yes | — |
| `TCCAccessCopyBundleIdentifiersForService` | yes | returns NULL unentitled |
| `TCCAccessSetForResponsiblePid` | **REMOVED** | — |
| `TCCAccessSelectPolicyForExtension*` | removed | — |
| `TCCAccessGetInformation` | removed | — |
| `kTCCAccessCheckOptionPrompt` | yes | — |

**Entitlements** [VERIFIED on SecurityPrivacyExtension.appex]:
`com.apple.private.tcc.allow`, `com.apple.private.tcc.manager.access.read`,
`com.apple.private.tcc.manager.access.modify`, `com.apple.private.tcc.manager.access.delete`,
`com.apple.private.tcc.manager.service-composition`.
tccd's full entitlement-string list also reveals: `com.apple.private.tcc.manager.check-by-audit-token`,
`com.apple.private.tcc.manager.set-responsible`, `com.apple.private.tcc.manager.compute-designated-requirement`,
`com.apple.private.tcc.manager.compute-indirect-object-identity`,
`com.apple.private.tcc.manager.expiration.{read,delete}`,
`com.apple.private.tcc.manager.get-identity-for-credential`,
`com.apple.private.tcc.internal.db_path_registry`, `com.apple.private.tcc.system`.

**Consequence [VERIFIED]:** with AMFI enforcing (no `amfi_get_out_of_my_way` boot-arg on
this machine — `nvram boot-args` empty), the Set/* APIs hard-abort for our binaries. The
viable write paths are (a) direct sqlite writes + tccd invalidation, or (b) a privileged
helper / `amfi_get_out_of_my_way` for the private-API path.

## 6. Writing changes — caching, gotchas

- Direct sqlite writes DO take effect historically; tccd keeps an **identity cache**
  ([macOS 27 VERIFIED] unified log: `identityCache: adding: com.mitchellh.ghostty for
  accessor: ...`) — verdicts may be cached, so `killall tccd` (user instance killable as
  user; system instance needs root) after writes is the safe play; it restarts on demand.
- Kernel-side verdict caching exists (Tahoe-era bug report); running apps may keep
  old verdicts → relaunch affected apps after changes.
- csreq needed for Settings-visible rows esp. AppleEvents (both client + indirect object).
- System-DB writes: SIP off + root. User-DB writes on 27: user owns the file.
- tccd's actual write statements (extracted from binary): `INSERT OR REPLACE INTO access
  (service, client, client_type, auth_value, auth_reason, auth_version, csreq,
  policy_id, indirect_object_identifier, flags, pid, pid_version, boot_uuid,
  one_time_reprompt_eligible, last_reminded, reminder_count) VALUES (16 params)` —
  note `indirect_object_identifier_type` is NOT in the modern write path.

## 7. Public preflight/request APIs

AXIsProcessTrusted[WithOptions], CGPreflight/RequestScreenCaptureAccess,
CGPreflight/RequestListenEventAccess, CGRequestPostEventAccess,
IOHIDRequestAccess(kIOHIDRequestTypeListenEvent), AVCaptureDevice auth APIs,
AEDeterminePermissionToAutomateTarget, EKEventStore, CNContactStore, PHPhotoLibrary,
CLLocationManager, CBManager, SFSpeechRecognizer. No public grant/revoke API.
Plus private `TCCAccessPreflight` works unentitled for the CALLING process [VERIFIED].

## 8. Open-source tools

jslegendre/tccplus (private API, needs SIP+AMFI off), jacobsalmela/tccutil (Python/sqlite),
uinaf/tccutil-rs (sqlite, claims macOS 26.2 support), EricRabil/tccpls, Clearance (SwiftUI
offline db editor), SentryKit (GUI reader + tccutil reset), disclaim (responsible-process).

## 9. Identity model

client_type 0 = bundle id / signing identifier; 1 = absolute path. csreq = designated
requirement blob (generate via `csreq(1)`). Responsible-process attribution
(`p_responsible_pid`) means CLI tools inherit their terminal's grants — visible in
[VERIFIED] logs: Ghostty preflights were attributed to `com.mitchellh.ghostty`.
AdhocSignatureCache dirs exist alongside both DBs (adhoc-signed client identity cache).

## 10. MDM / managed path [macOS 27 UPDATED]

MDM grants route to `managed_overrides` (admin_auth_value = admin-set verdict,
auth_value = effective user verdict); `policies`/`active_policy` map clients to profile
UUIDs. Strings: "Set managed override for service=%s client=%s auth_value=%d
set_user=%d set_admin=%d". GUI should treat managed rows as read-only.

## 11. Design implications

1. Read: sqlite on both DBs; enumerate DB paths via REG.db `registry` (trusted=1).
2. Write (user DB): direct REPLACE INTO, then `killall tccd`. 
3. Write (system DB): requires root — privileged helper (SMJobBless/SMAppService) or
   per-op `osascript ... with administrator privileges`; then `sudo killall tccd`.
4. Verify after write: re-read DB row AND, for self, `TCCAccessPreflight`; warn user to
   relaunch affected apps (kernel/tccd caching).
5. Present auth_reason provenance; mark managed_overrides rows read-only.
6. Automation rows: one per target (indirect_object_identifier), PK includes it.
7. Schema-tolerant code via `PRAGMA table_info(access)` — 27 adds columns.
