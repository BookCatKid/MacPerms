# TCC Manager

A native macOS app for inspecting and managing Transparency, Consent & Control (TCC)
privacy permissions — Accessibility, Screen Recording, Full Disk Access, Automation,
Input Monitoring, Camera, Microphone, and ~110 other services — **plus** the
non-TCC permission stores (Local Network, Background Items, Gatekeeper, Location
Services) — without navigating System Settings.

Built and verified on **macOS 27.0** (SIP disabled). See `docs/architecture.md` for the
reverse-engineered TCC architecture, `docs/non-tcc-permissions.md` for the other
stores, and `docs/research-notes.md` for sourced research.

## Build & run

```sh
make          # compiles to build/TCCManager.app (CLT only, no Xcode needed)
make run      # builds and launches
```

Requires Command Line Tools with the MacOSX26.5 SDK (the 27.0 SDK's macro-based
SwiftUI needs an Xcode-only plugin the CLT lacks).

## Features

- **By Service / By App** views over every record in both TCC databases
- Status pills (Allowed / Denied / Limited / Unknown), provenance (User Consent,
  User Set, System Set, MDM, Entitled…), last-modified, target app for Automation
- **Grant / Revoke / Reset** per record or per app, always behind a confirmation
  sheet; every write is **verified by read-back** and reported
- **Add permission record** for arbitrary apps (bundle-id or executable-path
  clients), with designated-requirement (csreq) generation via `codesign`/`csreq`
- User-DB writes are direct SQLite (user owns the file); system-DB writes go through
  a privileged helper via `osascript … with administrator privileges` (standard
  admin-auth dialog, no security weakening)
- Managed (MDM) rows are read-only; tccd restart actions (user / system); deep link
  to System Settings privacy pane

## Other Stores section

The sidebar has a second section for permission stores that live **outside** TCC
(each keeps its own reader/writer — nothing is forced through the TCC model):

- **Local Network** — per-app allow/deny rules from the per-user
  `networkprivacy` `NEConfiguration` in `com.apple.networkextension.plist`
  (enforced by `nehelper`). Shows explicit vs implicit choices and the default
  rule. **Allow / Deny / Reset** writes via `SCPreferences` as root — surgery
  verified by archive round-trip (exactly the target rule changes).
- **Background Items** — every login item / launch agent / daemon / app
  background task from `sfltool dumpbtm`, with enabled/allowed/notified flags.
  Read-only plus a labelled `sfltool resetbtm` nuclear option.
- **Gatekeeper** — all `spctl --list` assessment rules (labels, priorities,
  requirements). Enable/disable/remove by label via `spctl` as root.
- **Location Services** — per-app `Authorized` flags from `/var/db/locationd`
  (root read). Toggle writes `Authorized` — marked **unverified** pending a
  live-enforcement test.
- **Notifications** — placeholder: the authoritative store isn't mapped on
  macOS 27 yet.

All Other-section mutations require confirmation and administrator auth; every
pane states its verification status honestly rather than pretending a write is
supported when it isn't.

## Verified mechanics (docs/architecture.md)

- User TCC.db **moved** in macOS 27 → `/private/var/containers/Data/ProtectedSystem/
  <UUID>/Data/Library/Application Support/com.apple.TCC/TCC.db`; `REG.db` is the
  canonical DB-path registry.
- Direct DB writes take effect **immediately** (probed with `TCCAccessPreflight`:
  0=allowed, 1=denied, 2=unknown) — tccd does live SELECTs; a daemon restart is
  optional belt-and-suspenders, and affected *apps* may still need relaunching
  (kernel-side caching).
- `TCCAccessSetForBundle` & friends SIGTRAP without
  `com.apple.private.tcc.manager.access.*` entitlements (AMFI enforcing) — hence the
  sqlite+elevation design.

## Layout

```
Sources/            SwiftUI app (model, sqlite store, resolver, elevation, views,
                    NEPlist archive surgery, OtherStores readers, OtherViews panes)
Helper/main.swift   needt — privileged helper for non-TCC stores (NE writes via
                    SCPreferences, locationd dump/set, spctl passthrough)
Resources/          tcc-system-write.sh — privileged system-DB write helper
Scripts/            dlsym/call probes used during reverse engineering
Tests/              selftest — exercises the real write path end-to-end
docs/               architecture.md, non-tcc-permissions.md, research-notes.md,
                    services.txt
```

## Safety notes

- All SQL is parameterized/quoted; writes go through a confirmation sheet only.
- Nothing silently approves permission requests — this tool edits stored decisions.
- System-DB writes require interactive admin auth each time; there is no persistent
  helper daemon.
