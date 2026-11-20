# 官方扩展商店交付

## 范围

目标是完整 Raycast 官方公开目录的浏览、安装、配置、运行、启停与卸载。目录中的扩展不按名称或作者设准入白名单；运行时不支持的 API、缺失配置与构建失败须给出真实原因。目录收录、下载、安装、成功运行是不同状态。

## 第一切片

- 替换 Keylane 工具里的商店占位入口，接入普通应用构建。
- 从官方仓库解析固定提交对应的完整 extensions 子树，支持搜索、已加载分类、详情、图标、上游源码。拒绝截断目录，不用精选列表掩盖加载失败。
- 每次选择固定完整提交 SHA 与目录成员，拒绝可变引用和路径注入。元数据读取不执行 package.json 脚本；网络响应有大小上限，最终 URL 必须与请求一致。
- 此切片不显示伪安装成功，不提供未经接线的安装按钮，不把尚未验证标为不兼容。

## 后续边界

商店负责目录和来源身份，源码层负责受限树/文件校验，构建服务只在既有隔离来宾内处理扩展及依赖。宿主不得执行安装脚本、插件、npm postinstall 或扩展 JS。构建输出经完整性、清单和签名边界验证后，才可写入安装记录并注册命令。生命周期和权限代理复用正在集成的运行时，不复制实验分支整套宿主。

尚未接线：通用依赖获取、隔离构建部署、持久安装记录、偏好配置、生产命令启动和卸载。因此当前切片不等于完整商店交付。

## 验证记录

- macOS 隔离工作区原生应用与测试目标编译通过；15 项目录、来源和源码快照测试通过。
- 源码下载先从固定提交解析扩展子树，拒绝链接、子模块、路径冲突和超限数据；文件字节核对 Git blob 摘要后才交给后续构建服务。
- `RaycastStoreBackend` 明确定义 prepare/install/launch/setEnabled/uninstall 接口；当前 availability 为不可用，未提供伪后端。
- 目录网络行为使用受控 URLProtocol 响应测试；来源身份使用合成官方目录条目测试。不是第三方扩展安装实测。
- 全量测试运行遇到原有系统服务相关失败：ScopedBookmarksAgent 无法通信以及独立测试剪贴板写入失败。相关源文件未修改，不据此宣称全量通过；应在可访问系统服务的测试会话复验。
- 未安装覆盖用户的 Keylane，未运行新获取的扩展代码，未访问签名凭据。

## 第二切片：安装协调与失败语义

- 新增可注入后端的协调器：准备与安装提交分开，同扩展串行；准备失败、取消、来源或摘要不匹配不进入安装。已确认安装可启停、校验命令后启动、卸载。
- 后端提交结果不明时禁止盲目重试，必须从持久记录核对；启停依赖返回的新代次回执，不能凭 UI 假造成功。
- 商店可注入后端并展示安装、启停和卸载动作；默认后端仍不可用，安装按钮禁用。失败只展示受控错误，不暴露原始构建输出。结果不明时提供核对记录操作。
- 详情与动作固定在用户选择的源码提交；目录刷新不会静默换源。目录筛选明确标记详情关键词仅覆盖已读取项目。网络拒绝跳转，不发送 Cookie 或保存的 URL 凭据。
- 干净基线 `91bda02` 同机全量 254 项测试也复现相同 16 条失败（6 unexpected），与第一切片 258 项运行的失败集合、每例失败数一致。没有新失败证据。
- 协调器测试全部使用受控后端和不执行的合成源文件，不是生产扩展安装验证。

## 第三切片：通用源码数据包

`RaycastPublicCatalog.prepareSource` 沿固定提交解析指定扩展子树，受限下载并逐文件验证，返回 `RaycastStoreSourcePackage`。包包含全部原始文件、清单摘要、作者与许可字段和许可文件路径。任何脚本仍然只是字节，不在宿主执行。声明依赖的清单必须携带受支持版本的 package-lock 元数据；锁/清单一致性、依赖完整性和原生模块兼容仍是隔离构建器的后续检查，不能把“有锁文件”称为构建通过。

此数据包不是已安装制品。签名 runner、隔离构建与可复用来宾数据传输尚未接入。当前 27 项专项测试通过，覆盖目录、源码完整性、原始许可保留、锁文件边界及安装协调器；全部使用受控输入。

## 回执恢复补充

每次安装前读取后端权威记录，避免 App 重启后或缓存过期时重复安装；其他版本的已有安装不能被无提示覆盖。商店在后端接入时可显示已安装清单里的命令运行入口。28 项专项测试通过，包括重启回执恢复、外部移除后的重装、并发请求只提交一次。生产偏好编辑、安装列表恢复和隔离 runner 接线仍待完成。

## 安装列表恢复与配置边界

- `backend.installations()` 是持久安装列表的唯一来源。只在完整成功读取且回执无重复时替换缓存；失败保留最后确认的可见列表并关闭运行入口。商店的“已安装”筛选包括远程目录已移除的本地安装。
- `launchReadiness` 默认返回运行环境不可用。明确通过偏好、能力和运行环境检查才启用命令按钮；调用 launch 前再次查询，真正的后端 dispatch 仍须原子检查安装代次和能力。必填配置未完成时测试确认 launch 调用次数为零。
- 通用和命令级偏好沿用 `RaycastExtensionManifest.Field`，作用域与字段名组成独立键。支持文本、勾选、选项和写入型密码；应用、文件、目录选择明确等待有能力授权约束的选择器。
- `RaycastStorePreferencePersistence` 绑定安装 UUID 与代次。读取只返回普通值和密码存在标记；密码编辑与普通变更分开，无 Codable、文件或 UserDefaults 存储，表单不回填密码且提交后释放草稿。真实安全持久层尚未接入；未访问钥匙串。
- 36 项专项测试与原生应用编译通过，含安装列表失败保留、重启恢复、必填偏好拦截、作用域隔离、默认值/字段类型、密码边界和受控持久层的过时代次拒绝。
- 这些仍是受控组件/编译验证，不是生产 runner、真实扩展安装或实机表单交互验收。

## 独立复审修复

- 操作一个安装时只失效其 UUID 对应的运行就绪项，不再禁用其他安装的命令。
- 权威安装列表成功刷新后清除过期失败、待核对和就绪提示；读取失败不伪装成已修复。
- 已安装扩展的详情和源码链接优先采用安装回执里的固定提交，而非更新后的商店提交；恢复不同来源版本时清除旧详情缓存。
- 实际控制器采用可测的 `RaycastStorePresentationState` 转换，3 项新回归测试覆盖上述行为；总计 39 项专项测试及原生应用编译通过。尚未进行真实 UI 点击验收。

## 2026-11-19 公网只读验收

直接编译当前生产目录/源码类型，读取 GitHub 官方公开仓库；未运行扩展、npm、构建脚本或安装程序。

- 完整非递归目录：`3b0fba8a588e45995dffe4f6de44bbcc7fcbd154`，3614 条。生产代码拒绝截断树，本次成功获得完整快照。
- `chmod-lookup` 固定 `8d846393b506d23c5d9ebae29bb35e3dc7653829`：`prepareSource` 成功，14 文件、4,340,616 字节；package-lock v3；作者 `taha_harradi`，清单声明 MIT，1 命令 `chmod`。
- `uuid-generator` 固定 `886cbd73fe377ad1d8f0c17083e6cd4c96748a33`：`prepareSource` 成功，20 文件、168,498 字节；package-lock v3；作者 `jmaeso`，清单声明 MIT，9 命令。
- 两个扩展子树均没有独立许可文件。UUID 同提交的仓库根 `LICENSE` 单独读取成功：1064 字节，MIT，Copyright (c) 2021 Raycast，SHA-256 `7f727f8b20cdd0e65f84e70b9cac2fce337dcecee4dc88955eb012ea27f02755`。CHMOD 同提交根 LICENSE 的有界读取发生 TLS 握手超时，未重试，不能视为已验收。
- `SourcePackage` 当前保留扩展子树与 package.json 的许可声明，不包含仓库根许可。后续分发需把同提交的仓库级许可作为独立 attribution 附件保留，不伪装成扩展树文件、不覆盖扩展清单条款。上游许可与审阅也不等于 Keylane 兼容或安全验收。

可重复的显式 opt-in harness（默认不联网；限流立即退出，不重试）：

```sh
xcrun swiftc -module-cache-path /tmp/keylane-store-live-module-cache -parse-as-library -swift-version 5 \
  Sources/KeylaneCore/RaycastPublicCatalog.swift Sources/KeylaneCore/RaycastStoreSource.swift \
  Sources/KeylaneCore/RaycastStoreSnapshot.swift Sources/KeylaneCore/RaycastStoreSourcePackage.swift \
  Tests/Integration/store-source-live.swift -o /tmp/keylane-store-source-live
KEYLANE_STORE_LIVE_QA=1 /tmp/keylane-store-source-live \
  8d846393b506d23c5d9ebae29bb35e3dc7653829 886cbd73fe377ad1d8f0c17083e6cd4c96748a33
```

两项只是固定 QA 用例，不是安装白名单。公网快照会变化，以上计数仅对应记录的提交。此次验收不证明依赖解析、隔离构建、运行、偏好、复制或安装成功。

## Static dependency lock slice (2026-11-19)

`RaycastStoreDependencyPlan` reads bounded package-lock v3 data only. It keeps
full logical `node_modules` paths, production/development/optional/peer edges and
raw npm dev/devOptional/optional flags. Nested versions are never flattened.
Nearest ancestor lookup records the target path, **not semver satisfaction**.
It rejects invalid paths/parents, unsupported exact versions (currently only
stable numeric x.y.z), malformed SHA-512 SRI, >2 MiB JSON, >4096 packages,
>32768 edges, and oversized fields. It exposes blockers for noncanonical registry
sources, linked/bundled packages, declared install hooks, platform/native hints,
and unresolved required package edges. Root and optional/peer missing targets are
preserved explicitly for later policy; this is not a ready-to-build artifact.

Canonical registry URLs have no credentials/query/redirect authority. The pure
`verifiesTarball` checks SHA-512 against at most 16 MiB compressed bytes, with no
network, extraction or execution. A matching digest establishes only agreement
with the supplied lock, not package safety or actual manifest/lock consistency.
The reader does not certify undeclared install hooks/native code; archive content
validation, safe extraction and aggregate download budgets remain builder work.
It does not select platform optional packages, solve ranges/peer constraints,
handle aliases/workspaces/git/file sources or enable installation. No package
manager or third-party scripts ran on the host. No runner/host/guest files changed.

Live metadata evidence, UUID source pinned to
`886cbd73fe377ad1d8f0c17083e6cd4c96748a33`:
- package-lock.json read once from the official raw GitHub URL: 119748 bytes,
  257 package nodes; 137 dev, 0 devOptional, 26 optional.
- root `uuid` 11.1.1 and `typeid-js/node_modules/uuid` 10.0.0 remain separate.
- `ulidx` 2.4.1 resolves `layerr` to hoisted root `node_modules/layerr` 3.0.0.
- 27 nodes marked blocked: esbuild declares `hasInstallScript`; 26 platform nodes.
- One read-only, redirect-refusing download of
  `https://registry.npmjs.org/uuid/-/uuid-11.1.1.tgz` returned 19965 compressed bytes.
  Production verifier returned true against that pinned lock's SHA-512. The bytes
  stayed in scratch storage; not extracted, imported or executed.

Tests include a selected genuine UUID dependency metadata fixture (original
versions, hashes, edges; root list reduced to selected nodes, attributed in test),
plus synthetic hostile path/source/hash/size and scoped-peer cases. Full default
Store test filter is network-free. Real network evidence above was an opt-in
scratch harness, not claimed as install/build/launch or complete dependency fetch.

`productionReachablePaths` conservatively follows only non-dev root edges and
includes their optional/peer descendants, independently of the lock's dev flags.
It excludes isolated dev-only roots, but deliberately does not claim guest Linux
arm64 eligibility until platform/peer/range policy exists. In this actual UUID
lock, esbuild is **not dev-only**: root production `@raycast/api` declares esbuild
`^0.25.0`, and its lock node has dev=false. Replacing Raycast API with the guest
compatibility shim needs an explicit reviewed build transform; silently dropping
its transitive dependencies would not be a valid lock resolution.

Final verification: 46 network-free Store tests passed (including 7 new dependency
plan tests), app/CLI test build succeeded; `scripts/check-version.py` and
`git diff --check` passed. Log: `/tmp/keylane-store-lock-all-final.log`.
This slice intentionally leaves API externalization to the versioned runtime
contract; dependencies needed by other reachable nodes must not be removed just
because they are also reachable through the API package.

## Integrity-first npm archive reader (2026-11-19)

`RaycastStoreDependencyArchive` accepts a locked node and compressed bytes. The
lock's canonical registry URL and SHA-512 verification run **before** decompression.
Declared node blockers fail closed. Gzip is limited to one member, no trailing
bytes, 16 MiB compressed / 32 MiB inflated; tar has at most 4096 entries and 8 MiB
per file, bounded UTF-8 paths, header checksums, and two zero end blocks. Only plain
regular-file/directory POSIX ustar (or old blank magic) entries are accepted.
PAX/GNU extension records, links, devices and other special types are unsupported.
No archive is extracted to the filesystem. Paths must stay under `package/` and
cannot contain traversal, control characters, backslash, colon, bundled
node_modules, Unicode/case collisions, or file-vs-parent shadowing. Common native
extensions, binding.gyp and ELF/Mach-O/PE magic are rejected. These checks are NOT
a proof that arbitrary JavaScript is safe: guest isolation is still mandatory.

package.json must match lock name/version exactly, fit 1 MiB, and not declare
native/platform/bundled dependency requirements or preinstall/install/postinstall
hooks. Published-registry `prepare` is inert authoring metadata, recorded as
`hasInertPrepareMetadata`, never invoked. This distinction follows npm lifecycle
documentation (https://docs.npmjs.com/cli/v11/using-npm/scripts/#life-cycle-scripts)
and does not extend to git/local sources, which are not accepted.
Declared main/module/concrete exports must already exist in the archive; missing
build outputs, wildcard exports, directory entry resolution, and absent default
index.js fail closed. Conditions are not evaluated and no readiness is inferred.

The real already-downloaded UUID 11.1.1 archive passed lock integrity, gzip/tar,
manifest identity and existing entry checks: 190 inert files, 134222 bytes,
installation path `node_modules/uuid`. Its `prepare: husky` remained unexecuted
metadata. The initial conservative implementation rejected prepare; this was
corrected before commit and regression tested without relaxing install hooks.
No dependency code ran and no additional network fetch was required.

Output is `[package-relative path: raw Data]` plus the **exact locked** installation
path (e.g. `node_modules/typeid-js/node_modules/uuid`), name and version. Intended
next transport: a bounded manifest/data envelope per graph node sent to the trusted
guest builder; guest independently rechecks content hashes, destination paths,
aggregate budgets and versioned build contract before writing to its disposable
workspace. Do not flatten keys, stage through host node_modules, or run package
scripts. This commit does not implement transport, graph eligibility, range/peer/
optional policy or @raycast/api externalization; none is guessed from tar success.

Final archive verification: 53 Store tests passed, including 7 new archive tests
covering integrity ordering, inert files, traversals/link/special entries, case and
parent collisions, native signatures, lifecycle hooks, limits/corruption, concrete
exports and missing runtime outputs. App/CLI test build, version check and
`git diff --check` passed. Log: `/tmp/keylane-store-archive-final3.log`.

## Signed Store integration checkpoint

The combined development branch preserves both topic histories. The Store
launcher module accepts an injected installation backend and preference store;
the application defaults to **browsing only** without a qualified production
service. The install coordinator resolves pinned build data, delegates only to
one app-owned service, persists staging with an installation UUID, and restores
that exact staging receipt after restart. It never runs a shell or invokes the
test guest by default. Disable and uninstall write the new inactive generation
before requesting revocation. The guest service must admit against preferences
and capability policy at the same live broker boundary that advances the
generation watermark; a cached readiness result cannot authorize execution.

Checks on macOS: 72 focused Store catalogue, registry, runtime and coordinator
tests passed. The coordinator synthetic fixture passes staging recovery,
preference-required denial, launch, disable, re-enable and uninstall. A test
also pauses launch between the registry check and simulated broker admission,
revokes the original generation, and confirms that no launch is admitted.
These are contract checks, not a UI, VM, or real extension validation.

Live data-only assembly receipts: pinned UUID Generator (`886cbd7`) produced
349 files / 645,474 raw bytes, including five verified dependency tarballs;
pinned CHMOD Lookup (`8d84639`) produced 14 files / 4,340,616 raw bytes and no
third-party tarballs after projecting out its runtime-provided SDK package.
The probes made hypothetical exact SDK qualifications of 1.93.2 and 1.104.25,
respectively. Neither version is declared qualified in production by these probes.

Remaining integration: a production-signed guest bundle and fresh-guest driver
that build a project instead of the test-only single-file recipe; an app-owned
durable artifact issuer/verifier and current installation/preference authority;
verified SDK qualification and isolated in-app acceptance. A missing signer,
resource, driver, or authority must not enable installs. No third-party
extension was executed for this checkpoint.


### Durable artifact seal and registry authority

The app-owned seal binds its pinned source, installation UUID, immutable build
generation, signed recipe/runtime digest, project digest, commands and
capabilities with a P-256 signature. The verification key is supplied separately
from the on-disk envelope. The production coordinator also requires an
independently stored, durable registry compare-and-swap anchor. It advances the
anchor before atomically replacing its bounded state file, so a failed
replacement is quarantined as a mismatch, not accepted as an old enabled
generation. Revocation failure leaves the installation disabled; older valid
receipts cannot clear the quarantine. Runtime admission still needs the live
broker check after reading the stored receipt.

Tests reopen an isolated disk registry with a new public-key verifier instance
and a fixture anchor, verify the unchanged receipt, reject different signing
keys or recipes and modified payloads, then simulate failed revocation followed
by roll-back or deletion. The fixture uses an in-memory test-only signing key and
anchor, never the real Keychain. Production signing-key custody, a durable
app-owned anchor and explicit recovery/migration on a recipe change still need
to be wired. Treat an anchor mismatch as repair-required rather than resetting
or silently reimporting old state.

### Protected receipt state and recovery requirements

The opt-in protected-state model binds one registry scope, the expected public
signing key, the signed runtime recipe and qualified SDK versions to its latest
registry digest. All of that metadata must move together in one durable
compare-and-swap. The signing secret is not part of this record. The real
storage provider is deliberately not configured: a plain preferences file or
an unconditional Security.framework item update does not establish
cross-process compare-and-swap. The model's tests inject a locked in-memory
provider, not the actual Keychain.

A production composition must retain a stable registry ID and signer independently
of the extension state. Serialize all writers through one app-owned authority,
prove that the protected update is durable before replacing the state file, and
test two writers plus process death before and after each write. Do not claim
that two storage resources commit atomically. If the protected head advances and
the disk file does not match it, halt launches and keep the files for review.
An old matching predecessor cannot prove whether a crash or a rollback occurred.

- **New setup:** only an explicitly new scope, with no observed prior registry
  or evidence of an earlier installation, may create protected state. An
  existing file with missing protected state is a repair case, not first run.
- **Signer, runtime or SDK qualification change:** show migration required.
  Migration must verify the prior trusted scope, stop/revoke old sessions, and
  rebuild from the pinned source against the new recipe. A reviewed migration
  leaves extensions disabled until the new state and artifacts are verified.
- **Missing, unreadable or mismatched state:** show repair required, disable
  launch and never auto-restore predecessor data. A repair can recover only a
  verified image matching the current protected head or, with separate user
  authority and after preserving evidence, initialize a fresh disabled scope.
  No automatic reset, legacy signer trust or reinstall from the old file.
- **No proven protected provider:** keep only catalogue browsing. No indirect
  host runner or test key in production.

### Candidate runtime compile integration

The combined branch includes runtime checkpoint `6addce8`: the fixed
offline candidate guest, signed-helper packaging gate, and app-side process
driver. macOS Swift test/build compiled the helper and app and passed 84 focused
Store/guest tests. Six isolated packaging script tests passed. The wired test
uses the signed-engine abstraction with a fake driver and temporary registry:
an authenticated artifact passes the run boundary after reopen, then the same
artifact is refused after a failed-revocation quarantine. The installed-helper
constructor separately rejects an isolated app with no nested signed helper;
it does not fall back to the fake driver or to a host runner.

This does not establish signed VM startup or signed SDK eligibility. Production
requires qualified packaged resources, independently protected state and
signer, and a broker which both denies stale requests and confirms actual
child termination before reporting uninstall. The default remains browse-only.

### Signed first-party lifecycle fixture (not distributed)

The isolated native branch includes signed first-party runtime checkpoint
`ccd0cc9`. A separate test-only SwiftUI executable lives under
`Tests/ExtensionPrototype/StoreLifecycleFixture`. It is not the production
Store surface and is not copied into the normal app bundle. It compiles with:

```sh
swift build --disable-sandbox --product keylane-store-lifecycle-fixture
```

Manual fixture QA, if separately authorized: supply a verified scratch signed
outer bundle, the expected signing team, and the independently recorded
runtime resource digest as process arguments
`--signed-scratch-helper <scratch-app> <team> <runtime-resource-digest>`.
Only a canonical scratch app under `/private/tmp/keylane-store-signed-candidate.*`
and recipe `test-noview-synthetic-v1` are accepted. Setup only checks identity
and creates a private disposable registry. The install/run buttons use the
fixed self-authored TypeScript source, with the app-supplied toast-only broker.
No official extension fetch, credential storage, production SDK qualification,
or host fallback can be selected by this runner.

Expected manual flow: install; Run is denied for missing synthetic configuration;
configure; run and observe exactly one broker toast; reopen the same disk
registry with a fresh backend in the same process; disable and verify run is
unavailable; re-enable and run; uninstall; reopen and verify empty inventory.
Verify generation and stop receipts independently. This launcher was built, not
executed at this checkpoint. The successful earlier first-party probe does not
establish that this UI sequence passed or that settings persist across process
restart.

Remaining gates include actual in-flight revocation, cooperative guest stop and
timeout-path confirmation using signed first-party fixtures; a reproducible
reviewed asset lock and licensing for embedded runtime components; real
protected key/anchor custody and recovery with safe migration; exact SDK and
feature qualification for each first supported command. Do not claim production
availability or run third-party code based on the scratch fixture.

The same fixture has a headless QA entry when `--scripted` is the first
argument, followed by the identical `--signed-scratch-helper <scratch-app>
<team> <runtime-resource-digest>` options. It drives the fixture window's
model and installer/service, not a second simulated lifecycle. It emits at most
13 newline-delimited JSON receipts, each under 1 KiB. Schema 1 records a fixed
phase, pass/fail, generation/enabled when installed, counters for build,
completed run and fixed broker toast, and only the synthetic artifact SHA-256
on the build phase. No paths, raw errors, source or credentials are emitted.
It exits nonzero at the first unverified phase. The persistence field
`same-process-disk-reopen` expressly means a new backend over the same
temporary registry, not a real application restart or persistent Keychain
authority. The deny-only CLI smoke test supplied no helper, verified one failed
preflight receipt and exit 1, and did not start the guest. Successful scripted
execution against signed resources remains a separate acceptance step.

The original one-shot CLI acceptance stopped at preflight, before starting a
guest. A targeted no-guest check showed that Foundation canonicalizes the
scratch URL's `/private/tmp` spelling to `/tmp`; the old literal prefix check
rejected that valid bundle. The fixture now compares canonical path components
and exact scratch nesting. `--preflight-only` emits a single bounded stage
receipt and stops after signed resources, disposable protected state and empty
registry have been verified. Negative smoke cases (missing args, wrong
location, wrong runtime digest) stopped at the expected finite stage; the exact
signed ccd0cc scratch runtime reached `ready`, with zero build/run/toast counts.
No VM retry was performed.

The current fixture supersedes the above v1 address and receipt schema: it
accepts only the explicitly supplied canonical scratch context-v2 bundle at
`/private/tmp/keylane-store-context-signed.*/unpacked/KeylaneStorePackagingProbe.app`,
validated team and exact recorded resource digest, and recipe
`test-noview-synthetic-v2`. Schema 2 replaces the toast counter with in-memory
copy and HUD counters. The host validates the fixed command argument name from
its manifest, resolves a saved ordinary text preference and ordinary checkbox
default, and excludes the optional password field from the launch DTO. A
self-authored no-view command checks that context, requests one synthetic
copy, asserts that paste is denied, and sends one plain HUD message. The
fixture's sinks only record those two values in memory; no native pasteboard,
navigation, preferences store or Keychain is accessed. This is the candidate
for one combined v2 lifecycle run, not proof that the run passed; the signed
runtime's separate context-v2 first-party probe is tracked in the transport
README. No SDK releases are declared compatible in either probe.

### Combined signed self-authored lifecycle acceptance (macOS)

The single reviewed headless run from exact combined commit
`77fd611d5dfee69bb64e5aa43c411205f823ddbc` exited 0 with 13 passing schema-2
receipts. Strict outer and nested bundle signatures were verified first, and
the kernel, initramfs, helper binary and fixture binary matched their recorded
SHA-256 values. One build produced artifact
`08a0a403f901adcae5c8773f7a73511343f4c1cdc1590183747ed3fcb163610e`.

Install produced generation 1. Missing configuration blocked launch; after
configuration, the signed guest consumed the fixed synthetic argument and
ordinary preferences, reported one copy/HUD pair to the in-memory sink,
asserted paste denial and stopped. Reopening the same temporary registry with
a fresh backend preserved the installation. Disable advanced to generation 2
and blocked another run without changing the counters. Re-enable advanced to
generation 3 and a second freshly isolated run succeeded without rebuilding.
Uninstall followed by a second registry reopen showed empty inventory.
No real pasteboard, account data, Keychain, purchased app or third-party
extension was accessed. This proves the self-authored service lifecycle in a
scratch scope, not real app restart, shipping packaging, production Store
availability, actual SDK compatibility, or live in-flight revocation/timeout.
