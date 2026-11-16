# Native uninstall preview

## Scope

Extracted from PR #144 (`6986ce0`) onto dev `503d84a`. This branch leaves the original branch and worktree unchanged. It contains the review model/view, application-action integration, registered review page, and the search bar Back button's existing page-specific back handler. It does not contain auto-quit picker, menu-window, or IME changes.

The application is selected by default, while associated files are opt-in. Filtering and sorting do not change selection; hidden selected entries remain selected and the selection count includes them. Submit is disabled unless the application is selected, captures the snapshot once, and disables repeated submission. Back, page leave and launcher dismissal invalidate the pending review. Existing trash-time application identity, running-app, shared-copy and leftover identity checks remain in place. Directories display an unknown size rather than recursively scanning personal data.

## Safe verification

`scripts/verify-uninstall-preview.sh` builds production sources with a replacement entry point. It initializes neither Delegate nor Model/background services. It uses a random bundle identifier, temporary home, fake app bundles and a fake cache file. Confirmation/cancellation are recording closures: no production uninstall operation is called and no file is trashed. Checks cover opt-in leftovers, hidden selection, sorting/navigation, disabled submit, repeated submit/cancel, replacement, unknown targets and fixture-file preservation.

Use `--prepare` to build only or `--interactive` for a demo of the production review component. These do not demonstrate the complete installed-app workflow or actual deletion. The original menu fixture was deliberately not carried over, so this PR can be tested independently of the user's menu work.

## Validation status

See PR description for the final local and CI result. Mac native Swift tests: 161 passed; release Python tests: 18 passed; version check passed. The initial restricted run failed existing named-pasteboard assertions; the native rerun passed. Independent review state regression passed with recording callbacks. Ad-hoc package build and DMG verification passed. Isolated component UI was opened on Mac: filtering kept the window open, re-preparing restored default selection, and cancelling emptied the list and disabled confirmation. This does not validate the production launcher focus path. No user app has been uninstalled, no user data read or deleted, no current installation replaced, and no software release created.

## Remaining acceptance

Complete installed-app entry, Back/dismiss/reopen integration, dark/light appearance, VoiceOver and real trash execution are not established by model checks. Any real uninstall requires an explicitly disposable target and authorization. A green CI alone does not prove these flows.

## Reference screenshots

Compared against the two owner-provided screenshots on 2026-11-16. The extracted view keeps checkbox/name/path/size/icon rows, search filtering and a top-right sort control. Names and paths now share a row; the sort picker is supplied through the existing search-bar accessory. Selection summary reports the known size and explicitly marks unmeasured directories instead of fabricating a total. Associated files remain opt-in (unlike the all-selected reference) to preserve the existing safety contract. No recursive directory scan was added. Existing application-list styling and launcher chrome are retained, not pixel-matched or rewritten. The test window is an isolated component harness, not the production launcher shell.

## Review follow-up

Fixed the lifecycle finding where hiding cancelled the snapshot but retained the preview page ID. Its registered resume callback now returns an empty review to application selection; it does not reconstruct the snapshot or restore deletion consent. The isolated regression exercises the same leave/resume hooks, active-snapshot preservation, repeated resume and submit-after-cancellation. Full native Launcher focus/dismiss integration remains a separate acceptance item.
