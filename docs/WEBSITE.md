# 官网维护与验证 / Website maintenance and evidence

## Scope and deployment

Buildless HTML/CSS in `website/`, Chinese at `/Keylane/`, English at `/Keylane/en/`. Assets and language links are relative so project Pages subpaths work. No third-party scripts, analytics, fonts, runtime dependencies, or copied competitor assets. Visual references: [SuperCmd](https://supercmd.sh/) and [Raycast](https://www.raycast.com/), consulted for product-led presentation, not copied UI or claims.

The independent `.github/workflows/pages.yml` validates PRs targeting dev/main, and deploys **only main**, after validation. Manual runs from other branches only validate. It uploads the static website artifact, never an app installer, tag, or GitHub Release. This branch preserves the `ci.yml`, `release.yml`, `check-installer-scope.py` and `check-version.py` supplied by dev #137 without modification. Ordinary application CI on PR/push has read-only repository permission and no distribution secrets. Software publication is a separate manual Release run on main with an exact `target_sha`; Pages never invokes it. The installer scope checker conservatively includes `.github/workflows/` and `scripts/`, so this PR can build a temporary CI test DMG, which is not a public software release. Ordinary main synchronization does not require a version/build bump.

### Pages setup still required

1. Merge this PR into dev after review; coordinate the separately authorized dev → main snapshot sync. This PR does not merge main or invoke the manual software Release workflow.
2. In GitHub repository Settings → Pages, choose **GitHub Actions** as Source. Confirm Actions policy permits the pinned official Pages actions and `pages: write` / OIDC. Configure the `github-pages` environment deployment rule for main only.
3. Run Website on main or let a matching main push trigger it. Verify the deployed Chinese and English URLs before removing the README's “after Pages setup” wording.
4. Expected URLs: `https://acckion.github.io/Keylane/` and `/Keylane/en/`. They are intended destinations, not a claim of deployment. The Pages API returned HTTP 404 during this task; this may mean no configured Pages site or insufficient access. No settings were changed.

## Content contracts

Release facts were checked against the GitHub [Beta 1 release](https://github.com/Acckion/Keylane/releases/tag/v1.0.2-beta.1): tag `v1.0.2-beta.1`, build 27, commit `891ab2cca019a60750b7b90321014ef0a06c84df`, macOS 26+, Apple Silicon, ad-hoc signature, no notarization, manual installation. All download links target that release, never `releases/latest`.

Current synchronized dev baseline `69d203ff6eb179c02bece1bf7d33159d69f9bf39` includes GPL migration #134, community standards #135, system actions #136 and the validation/manual release split #137. The pre-sync main snapshot `877ca22` and Beta 1 retain their PolyForm Noncommercial license. Recheck these branch snapshots whenever updating the site; GPL does not retroactively change old installers. Raycast compatibility, migration, and iPhone app launching are explicitly outside the released Beta. Website and both READMEs repeat the first-launch/upgrade and Navigation focus validation gaps from the release.

## Asset provenance and privacy

- `website/assets/icon.png`: existing project artwork copied from `Resources/Keylane.icon/Assets/Keylane.png`.
- `calculator.png` and `emoji.png`: window-only captures through Computer Use of a real copy of the published Beta 1 DMG app on 2026-11-16. The local DMG matches the release digest `e1ec855851dc135b204241c72dd4220ebb649b55a16f78a3c0be0bcca7c6d607`.
- A temporary copy used bundle identifier `org.keylane.website-demo` and a fresh temporary HOME / CFFIXED_USER_HOME, with its own Application Support databases. The copy was re-signed ad-hoc after its bundle identifier changed. No application source or UI was modified. Re-signing changes the executable signature bytes; this copy is not a new distributed build and is not submitted as an installer.
- This is **data-directory isolation, not an OS sandbox**: app discovery, Shortcuts discovery and OS permission status can still reflect the host. Those views were not captured or published. No OS permissions were granted, no private fixtures or user databases were copied into the site.
- The published captures contain only fixed calculation `128 * 24 = 3072` and a query for `星` in the built-in Emoji/symbol dataset. No personal app lists, Shortcuts, clipboard entries, contacts, calendars, files or account details appear. Screenshots retain the real Chinese UI in both language pages; captions disclose this. There are no fabricated interface elements or UI retouches.
- Temporary app, homes, logs, preview captures and build products are outside tracked content. Only the three reviewed PNG assets are committed.

## Validation performed

- `python3 scripts/check-website.py`: passed; both HTML language attributes, local links/fragments, image alt presence, viewport metadata, release/license markers and project-relative resources.
- `python3 scripts/check-version.py`: passed, 1.0.2 build 27 unchanged.
- `python3 -m unittest discover -s Tests/ReleaseTests -p 'test_*.py'`: 6 tests passed.
- Browser QA served the actual directory at `http://127.0.0.1:8765/Keylane/`. Chinese and English language navigation worked in both directions. All images loaded; 390px and 320px phone checks and 1280px desktop check had document scroll width equal to viewport width. Reviewed actual desktop and mobile renders. Screenshots retained outside the repo in `../work/website-evidence/`.
- Keyboard Tab reached the visible skip link with solid focus outline; Return navigated to `#main`. Enter toggled the native English installation details. Semantic headings, nav landmarks, native links/details, descriptive screenshot alt, decorative icon alt, visible focus and reduced-motion support are present.
- Calculated text contrast: primary 16.79:1, secondary 10.29:1, muted 8.77:1, notes 9.63:1, CTA 13.77:1 against their CSS backgrounds. These checks cover website text, not the contents of the actual app screenshots.
- Manual bilingual review checked equivalent release, requirements, privacy, license and development-status claims. No claim that the app itself has an English interface.
- Swift tests: compiled with temporary module caches; 161 tests ran, two `ExtensionClipboardContentTests` cases produced 8 assertion failures when named pasteboard access returned nil/false in the restricted environment. Other tests passed. Automatic approval review rejected an unsandboxed full-suite rerun, citing risk of system clipboard access. It was not executed or bypassed. The two observed cases use UUID-named NSPasteboard instances, but the complete suite was not audited for external system effects, so a full unsandboxed pass is **not claimed**.
- Local packaging was attempted with `KEYLANE_ALLOW_ADHOC=1`; the release build failed at `dsymutil` with Operation not permitted. Package verification could not run without a produced DMG. No installer was published. Application code and packaging scripts are unchanged.

## Historical follow-up: local restrictions versus PR changes

The completed [application CI run 43789875017](https://github.com/Acckion/Keylane/actions/runs/43789875017), associated with PR head `d272bcb10ef23e0ad9e4290c44f0b4391096dfc4`, checked out GitHub's synthetic merge `7b12bd4b7ed10429ac2e3682aa89e86ff00d70b3` (that head merged into dev `f7f5903`). Its log confirms:

| Check | Local restricted environment | GitHub macOS runner |
| --- | --- | --- |
| Swift XCTest suite | 161 tests, 8 assertions failed in two named-pasteboard cases | **161 tests, zero failures**, including both cases |
| Production build / DMG packaging | Nested build invocation of `dsymutil` returns `Operation not permitted` | **Build drag-to-Applications DMG passed** |
| Package verification | No locally produced DMG to verify | **DMG layout, app metadata, license, file inventory, architecture and signature: OK** |
| Software release | None | **Publish release skipped**; the existing workflow uploaded a temporary Actions test artifact, not a GitHub Release asset |
| Website | Resource and bilingual checks passed | [Website check passed](https://github.com/Acckion/Keylane/actions/runs/43789875146), deployment skipped as intended on a PR |

The two clipboard cases instantiate `NSPasteboard(name: UUID-based test name)` and pass that explicit board into `ExtensionClipboardContent.write(to:)`. That function writes only to its supplied board; it does not obtain `NSPasteboard.general`. The failing assertions reported false writes and nil reads. The cases and application implementation are unchanged from the dev baseline and pass on the CI runner. This supports an environment-specific pasteboard-service restriction, rather than a regression introduced by the website change. No real user clipboard was read or modified during this follow-up. The rejected unsandboxed full-suite operation was not retried, and no alternative route was used to exercise clipboard access.

For `dsymutil`, a synthetic C fixture was compiled with a retained object file under `/tmp` without executing the result. Its dSYM generated successfully with matching binary/dSYM UUIDs. A direct invocation on the already-built `keylane-extension` binary also generated a matching dSYM, both under `/tmp` and at the original build output path, within the existing restricted environment. Re-running the unchanged packaging script still failed when Swift's build service invoked the same tool. Therefore this is **not a universal failure of dsymutil or basic directory write permission**. Evidence points to the nested build-service execution context; the exact denied operation was not established. CI independently validates the unchanged production build and packaging path. No sandbox policy was weakened, build/debug flags changed, test skipped to claim success, or local package uploaded.

Follow-up checks also passed: both language pages share the same external destinations (apart from their language-specific README), corresponding image sources match, all README local links exist, both READMEs retain matching release/license/system markers and reciprocal language navigation, and the website icon is byte-identical to the original project artwork. Both committed screenshots were visually re-inspected: only the fixed calculator expression and built-in Emoji search are visible, with no private data. No new application capture or host-data access was needed.

The Pages API was rechecked and still returned HTTP 404; no settings or deployment were changed. Static review confirms relative `/Keylane/` resources, main-only deployment, PR deployment exclusion, least-scope deployment permissions, and separation from application publishing. These results supersede the earlier pending-CI status, **not** the recorded local failures or remaining real-device acceptance gaps.

## Not verified

No live Pages deployment, production smoke test, VoiceOver session, automated axe audit, real phone hardware, or complete first-launch/upgrade acceptance was performed. Existing Beta app acceptance gaps remain. GitHub Actions results on this PR are reported separately; historical green runs above apply to their recorded SHAs and do not stand in for current-head CI.

## Local preview

```sh
python3 scripts/check-website.py
# Serve from a parent directory with website mounted/symlinked as Keylane,
# then open /Keylane/ and /Keylane/en/ to test the real project subpath.
python3 -m http.server 8765 --bind 127.0.0.1 --directory /path/to/preview-parent
```

Keep both language pages and READMEs aligned when changing release or license information. Re-run the checker and browser checks after modifying the layout or relative URLs.

## Synchronization with dev #137

Synchronized dev `69d203ff6eb179c02bece1bf7d33159d69f9bf39` into the existing website branch with a normal merge, preserving published history. The worktree was clean before the merge; no parallel website branch owner or duplicate worktree was found in the active task/worktree inventory. The only conflict was README's development/release section. The resolution keeps the product presentation and adopts #137's validation/manual-release contract in both languages. No application source, CI/release safeguards, version metadata or screenshots were edited by the resolution.

Rechecks after resolving the conflict:

- Website checker, version `--sync-policy`, `git diff --check`, and **18 ReleaseTests** passed. These include automatic-event rejection, read-only CI/no-secrets rules, manual release entry and release artifact guards.
- Inherited `ci.yml`, `release.yml`, `check-installer-scope.py` and `check-version.py` are byte-identical to synchronized dev. Pages has no contents-write permission, distribution secrets, release invocation or tag commands. It deploys website content only on main; ordinary PR/push cannot invoke the software Release workflow. No workflow was manually dispatched for this task.
- Both READMEs' local links exist and consistently describe `target_sha`, `validate_installer`, no-release ordinary synchronization, Beta 1, system requirements, current GPL source and historical PolyForm versions. Existing screenshots are byte-identical to the previously reviewed captures; they show only the fixed calculation and built-in Emoji query, with no private contents.
- Browser recheck at `/Keylane/` and `/Keylane/en/`: 390px Chinese, 320px English and 1280px desktop renders reviewed, images loaded and no horizontal overflow. Tab/Return skip navigation, visible focus, Enter details toggle and language round trip passed. New preview captures are retained outside the repository in `../work/website-evidence/synced-mobile-{zh,en}.png`.
- GitHub main was rechecked as `877ca22df5cea229b41256fdc70e79cd1780a766`; Beta 1 still identifies build 27 at `891ab2c`, ad-hoc signing, no notarization, manual installation and the recorded focus/first-launch gaps. Pages API still returns 404. The intended Pages URL remains explicitly pending setup, not claimed live.

Current-head GitHub checks are reported on PR #138. Historical local pasteboard/build-service restrictions and the unperformed real-device/production checks above remain disclosed; no rejected operation was retried as part of this synchronization.

The public copy calls `877ca22` the pre-sync main snapshot rather than timeless “current main”, so the historical PolyForm disclosure remains accurate after the later coordinated Pages/main synchronization. The exact SHA and Beta license boundary are retained in both languages.

### Final target advance during CI

While validating the synchronized branch, dev advanced to `7a2e32ebc230ba78517b0e9d0adbfdec0cb46bdc` by merging #139 (safe system-action tests and acceptance documentation only). This was merged without conflict to keep the website branch current. No application source or CI/release behavior changed in that advance. Before this final ancestry-only synchronization, head `fccbcfeb57f4a1cb5b1307b6738813013a2207b2` passed [application CI 43797970245](https://github.com/Acckion/Keylane/actions/runs/43797970245): **161 tests, zero failures**, and DMG layout/metadata/license/inventory/architecture/signature verification passed. [Website CI 43797970114](https://github.com/Acckion/Keylane/actions/runs/43797970114) passed and deployment was skipped. The PR was then marked ready for review; new-head checks remain authoritative on the PR.

After merging #139, website checks, version sync policy, 18 ReleaseTests and 4 safe SystemActions source-contract tests passed locally. The inherited `verify-system-actions-safe.py` passed its fake-audio fixture but could not compile the Finder AppleScript dictionary in the restricted local environment (`Can't get application id com.apple.finder`, -1728). It never executed those scripts, launched the application, requested permissions, queried real audio (the optional flag was not used), or accessed clipboard. This is recorded as an additional local environment limit, not a completed system-interaction acceptance or a new website regression. No workaround or permission escalation was attempted.

## Product-site refresh (2026-11-17, Beijing time)

This refresh replaces preview-led marketing with a bilingual product introduction: black surfaces, red lighting aligned with the project icon, the launcher/file/clipboard workflows, selective Raycast migration, native architecture, free/open-source positioning, and a clearly future-facing roadmap. Beta status now appears only where relevant to download and installation. Download targets remain the actual `v1.0.2-beta.1` release; no stable software release is implied. The installation and license disclosures retain ad-hoc signing, no Apple notarization and the historical installer's PolyForm Noncommercial license.

The three new assets `launcher.png`, `file-search.png`, and `clipboard.png` are the owner's provided screenshots, explicitly approved by the owner for public website use without redaction. They are byte-for-byte copies of the originals, shared with the README refresh; no UI content was regenerated or retouched. The original icon is unchanged. Do not apply the earlier isolated-demo provenance to these new images. Comparison links point to first-party product/architecture pages; native architecture is described without an unmeasured performance ranking.

Local checks for the refresh:
- Website checker passed for both languages, project-subpath references, local images, fragments, alt text, exact release target and release/license disclosures. Its outdated assertion requiring the old pre-sync main SHA in marketing copy is replaced by the enduring license and installation contracts plus the three required product images.
- Version/sync-policy check and all 18 ReleaseTests passed; `git diff --check` passed. App source, version, CI/release workflows and packaging logic are unchanged. Full Swift compilation and packaging were not repeated locally for a content/style change; current PR Checks remain required.
- Real Safari on the connected Mac loaded the actual `/Keylane/` directory from a loopback preview server. Desktop hero and migration layout were visually inspected. Safari Responsive Design Mode at 390 × 844 and 320 × 844 rendered the Chinese and English layouts without visible clipping. Phone hero, feature cards, file image, download, installation and footer were inspected, not just source-reviewed.
- Chinese → English → Chinese navigation, feature/migration/download anchor navigation, installation expand and keyboard Return collapse, license expand, direct file-screenshot opening and browser Back all worked. No JavaScript, third-party fonts, telemetry or application runtime dependencies were introduced.
- Production verification is pending the coordinated dev → main synchronization with README/repository cleanup. Reopen both deployed languages and verify their navigation, images and installation disclosures after deployment; local rendering is not production verification. No tag, app installer or GitHub Release is created by this task.
