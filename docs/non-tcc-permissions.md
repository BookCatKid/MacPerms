# Permission stores outside TCC.db — macOS 27

Investigated on-device. TCC.db is only one of several per-app consent stores.
These are the others that exist, how they're enforced, and where the state lives.

## 1. Local Network ✅ (the one that prompted this)

**Not a TCC service at all.** Enforced by **`nehelper`** (`/usr/libexec/nehelper`),
which owns mach service `com.apple.network.localnetworkdecision` and shows the
prompt via `showLocalNetworkAlertForApp:` (requires `NSLocalNetworkUsageDescription`
in the app's Info.plist or it won't even prompt — "App did not provide a local
network usage string, not prompting").

**Decision flow** (from nehelper log strings):
`Local network preference not yet set, prompting` → `User responded with local
network: %u` → `Local network allowed/denied by preference for %@`.
Decisions are per-user (`user %s local network access for %@`), and replies for
pending requests are "drained" once decided.

**Store**: `/Library/Preferences/com.apple.networkextension.plist` — the same
root-owned NSKeyedArchiver file that holds VPN configurations. Each app's decision
is an `NEConfiguration`/`NEAppRule`/`NEPathRule` object with keys:
`DenyAll`, `DenyMulticast`, `DenyCellularFallback`, `MulticastPreferenceSet`,
`WiFiBehavior`, `CellularBehavior`, `AggregatePersonalWiFiBehavior`,
`AggregatePersonalCellularBehavior`, `TemporaryAllowMulticastNetworkName`,
`DesignatedRequirement`, `SigningIdentifier`, `AllowEmptyDesignatedRequirement`.
Pane-generated configs are named `com.apple.preferences.networkprivacy-<UUID>`.

**Identity cache**: `/Library/Preferences/com.apple.networkextension.uuidcache.plist`
— a **binary** format, magic `CUEN`, mapping code-signing UUIDs → app identifiers
(`57T9237FN3.net.whatsapp.WhatsApp`, `PathRuleDefaultNonSystemIdentifier`, adhoc
ids like `CrossOver-55554…`). "Clearing cached UUIDs and restarting session"
happens when a preference exists but a prompt still fired — i.e. the cache
invalidates decisions when the binary is re-signed/updated.

**Settings pane**: `PrivacyLocalNetworkService` /
`PrivacyLocalNetworkServiceView` inside `SecurityPrivacyExtension.appex`
(`toggleLocalNetworkSetting(for:to:completion:)`,
`updateLocalNetworkConfigurations()`). The string
`com.apple.preferences.networkprivacy` is the **preference domain** the pane
writes through `setMachine*:forKey:inDomain:` helpers.

**Management surface**:
- `NEConfigurationManager` (NetworkExtension.framework) — needs
  `com.apple.developer.networking.networkextension` entitlement.
- `SCPreferences` on the file directly — needs root; file is NSKeyedArchive,
  not flat plist, so surgical edits require unarchiving `NEConfiguration` objects.
- MDM: `/Library/Managed Preferences/mobile/com.apple.networkextension.control.plist`
  + "Installing default local network access policies" in nehelper.
- `Allow-listing %@` / `Deny-listing %@` / "Installing default local network
  access policies" — nehelper synthesizes default allow entries
  (`cache-allow-synthesis`, `clearUUIDCache` XPC commands exist).

**Confirmed archive layout (implemented in `Sources/NEPlist.swift`)**:
- `$top` keys are config UUIDs (+ `Index`, `Generation`, `Version`,
  `SCPreferencesSignature2`); each UUID → an `NEConfiguration` dict.
- Config → `PathController` → **`Rules`** (the archive key; the ObjC property is
  `pathRules`) → array of `NEPathRule` dicts. NSArrays archive as
  `{NS.objects: [uid,…]}`; `Identifier`/`DesignatedRequirement` similar.
- bplist UID refs parse as opaque `CFKeyedArchiverUID` (`__NSCFType`) objects —
  index recovered from the `{value = N}` in its description; XML plists keep
  `{CF$UID: n}` dicts. `NEPlist.uidIndex` handles both.
- Decision mapping, confirmed across all 160 rules on this machine:
  - `DenyMulticast` = the flag (false→allowed, true→denied)
  - `MulticastPreferenceSet` = explicit user choice vs implicit default
  - `SigningIdentifier` = bundle id (or `PathRuleDefaultNonSystemIdentifier`
    for the default rule, or adhoc `Name-<sha1>` ids); `Path` when present is a
    per-binary rule.
- **Verified write path**: `SCPreferencesSetValue("$objects", mutatedObjects)`
  + `SCPreferencesCommitChanges` as root (`Helper/main.swift` = `needt`).
  Round-trip test: flip `DenyMulticast` on one rule → re-parse → exactly 1
  diff, archive intact. Whether nehelper picks up the write without restart
  is **unverified** — needs the equivalent of the tccd live-SELECT experiment.

## 2. Location Services — `locationd`

Per-app location authorization is **locationd's own store**, not TCC.
`/var/db/locationd/` is now empty on 27; the CFPreferences domain
`com.apple.locationaccessstored` exists and contains
`{ LocationAccessRecordsAge, LastRecordingTime }` — records live wherever
cfprefsd resolves that domain for `_locationd` (likely its ProtectedSystem
container — the ProtectedSystem containers on this Mac also hold RemoteManagement,
PrivateCloudCompute, keychain TrustedPeersHelper, and DeviceConfiguration stores,
so this layout is the new normal for sensitive per-daemon state).

**Implemented path**: `needt loc-dump` (root) dumps `/var/db/locationd/*.plist`
as JSON — `clients.plist`/`clients-b.plist` hold per-app `{Authorized, Executable,
Requirement, …}` entries. `needt loc-set` writes `Authorized` directly — marked
**UNVERIFIED** in the UI (whether locationd notices without restart is untested).

## 3. Background Items / Login Items — `backgroundtaskmanagementd`

`/private/var/db/com.apple.backgroundtaskmanagement/BackgroundItems-v18-*.btm`
(binary, root-only; one file per user UUID + a `FFFFEEEE-…` wildcard file).
This is what System Settings → General → Login Items & Extensions edits
("Allow in the Background"). Not TCC.

**Implemented read path**: `sfltool dumpbtm` works unprivileged and prints every
item — name, developer, team id, type (app/login item/daemon/agent/background
tasks/developer), `Disposition: [enabled, allowed, notified] (0xN)` hex flags
(bit0=enabled, bit1=allowed, bit3=notified), identifier, URL, last-use.
**Mutation**: no per-item toggle exists in `sfltool`; the only supported write is
`sfltool resetbtm` (wipes the whole DB — apps re-register on next launch).
Offered in the UI as a clearly-labelled destructive action.

## 4. Gatekeeper / system-extension & first-run approval — `syspolicyd`

`/var/db/SystemPolicyConfiguration/ExecPolicy` (sqlite, WAL, `rw-------` root)
— every GK assessment (quarantined app launches, "Open Anyway" overrides,
developer/system-extension approvals). `.LastGKReject` and
`.SystemPolicy-default` alongside it. This is the store behind
"Security → Allow applications downloaded from".

**Implemented path**: `spctl --list` reads all assessment rules unprivileged
(`N[Label] Pnn allow|deny type` + requirement lines — 2,717 rules here).
Writes go through `spctl` as root via `needt gk …`: `--enable`/`--disable`/
`--remove` by `--label`. ExecPolicy itself is left alone — spctl is the
supported front-end to it.

## 5. Notifications — `usernoted`/`notificationcenter`

Per-app notification authorization lives in NotificationCenter's own DB —
not TCC. On macOS 27 the authoritative store was **not located**: no `db2`
sqlite under `com.apple.notificationcenter` containers, `com.apple.ncprefs`
holds prefs not per-app auth, Biome streams are event history. The UI pane
is an honest read-only placeholder until the store is mapped.

## 6. Accessory connection approval ("Allow accessories to connect")

`com.apple.accessoryaccess.uiagent` domain exists (USB/Thunderbolt accessory
prompts). Decision persistence is separate from TCC (aksd/AMFi-style accessory
auth); only the menu-item pref was visible unprivileged — needs a root pass to
confirm the record file.

## 7. ManagedSettings / Screen Time

`/private/var/containers/Data/ProtectedSystem/<uuid>/Data/Library/
com.apple.DeviceConfiguration/` — `EffectiveConfigurations/*` per-scope stores
and `Stores/com.apple.managedsettings/…` — Screen Time & managed restrictions,
incl. a `com.apple.Accessibility` store that intersects TCC (tccd listens for
`com.apple.ManagedSettings.effective-settings.changed` "privacy" group — the
`managed_overrides` table path).

## What this means for the app — implemented

The app now has two sidebar sections. The **TCC** section is unchanged. The
**Other Stores** section gives each subsystem its own reader/writer — nothing
is forced through the TCC `access`-table model:

| Pane | Read | Write |
|---|---|---|
| Local Network | `NEPlist` archive surgery (unprivileged) | `needt ne-set/ne-reset` → SCPreferences as root; verified round-trip; nehelper pickup unverified |
| Background Items | `sfltool dumpbtm` (unprivileged) | `sfltool resetbtm` (root) — reset-all only |
| Gatekeeper | `spctl --list` (unprivileged) | `spctl --enable/--disable/--remove --label` via `needt gk` (root) |
| Location Services | `needt loc-dump` (root) | `needt loc-set` Authorized flag — UNVERIFIED |
| Notifications | — | placeholder: store unmapped on 27 |
