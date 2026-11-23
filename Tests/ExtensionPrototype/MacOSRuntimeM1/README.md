# macOS runtime M1 first batch

First-party signed compiler integration only. Uses the actual Core
`MacOSExtensionBuild` contract and the pinned official esbuild archive from M0.
No public extension, default product service, enrollment or installer is enabled.

See [implementation, evidence and remaining M1 work](../../../docs/MACOS-BUILD-M1.md).
The probe returns 3/incomplete when this slice succeeds, 2 on observed failures.
All executable candidates use an existing Apple Development identity; no ad-hoc
fallback. Do not run third-party scripts through this fixture or package it.
