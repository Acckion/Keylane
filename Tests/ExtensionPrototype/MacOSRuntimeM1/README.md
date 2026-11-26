# macOS runtime M1 acceptance

The production helper is in Sources/KeylaneExtensionBuildHelper. This directory
contains only the signed first-party product-composition host and documentation;
it is never included in Keylane.app. The native host exercises the actual Core
profile, OS signature checks, Keychain, compiler, seal, registry and installer.

See [implementation and acceptance](../../../docs/MACOS-BUILD-M1.md).
The compile subset probe remains 3/incomplete. The product composition and the
aggregate check pass only when all required observations and cleanup succeed.
All executable candidates use an existing Apple Development identity. No ad-hoc
fallback, public extension execution or product runtime activation is permitted.
