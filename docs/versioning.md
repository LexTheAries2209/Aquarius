# Version And Build Rules / 版本与构建号规则

## 中文

### 已发布基线

2026-10-25 核对 Aquarius 的正式 GitHub Releases，共 5 个：`v1.0.1`、`v1.0.2`、`v1.0.3`、`v1.1.1` 和 `v1.2.1`。最新的 V1.2.1 实际使用 Xcode `Version = 1.2`、`Build = 1`。历史标签、安装包和发布说明保持原样。

以这 5 个可验证的正式发布作为一次性序号基线，后续首个发布构建从 `0006` 开始。`0005` 是历史计数，不代表 V1.2.1 安装包中实际写入了 `0005`；Sparkle 会把旧版的 `CFBundleVersion = 1` 与新版本的四位数字构建号按数值比较。

### 后续发布规则

- `MARKETING_VERSION` / `CFBundleShortVersionString` 使用完整语义版本号，例如 `1.2.2`；公开标签为 `v1.2.2`。
- `CURRENT_PROJECT_VERSION` / `CFBundleVersion` 使用独立、全局递增的四位十进制发布构建号，例如首个新格式发布为 `0006`，之后为 `0007`。换主/次版本时不归零。
- 普通 Debug 编译、测试和同一候选版本的重复验证不消耗发布构建号。每次新分发构建分配新号；已对外分发或放弃的号不得复用。
- 发布前同时核对 GitHub Releases、实际上一版 App 元数据以及 `Configuration/ReleaseBuilds.json`。分配构建号时只新增未绑定版本/标签的 `reserved` 记录；发布后写入真实版本/标签并将状态改为 `published`。
- 同步 Aquarius target 的 Debug/Release 配置。测试工具和 Sparkle fixture 使用独立标识，不参与发布构建计数。
- `CFBundleDisplayName` 为 `Aquarius V<完整版本>`；更新 appcast 的 `sparkle:version` 必须与四位 `CFBundleVersion` 完全一致并保留前导零。
- 首个包含 Sparkle 的发行版不会覆盖历史包。V1.2.1 及更早版本不含 updater，用户需先手动升级；只有已经安装包含 updater 的版本后，才可通过 Sparkle 获取后续更新。

### 签名更新发布

Aquarius 使用独立的 Sparkle EdDSA account `lex.Aquarius`。它与 macOS Developer ID / ad-hoc 代码签名用途不同：EdDSA 必须验证 appcast 和下载 ZIP；代码签名、公证状态单独核实和描述。

生产公钥位于 `Configuration/Info.plist` 的 `SUPublicEDKey`。私钥只保存在发布者的登录钥匙串；不得导出、打印、重建或替换。若本机缺少该账户的既有密钥，停止签名发布并恢复备份密钥。

完整发版步骤、固定 `Aquarius.app` 包装、历史备份和发布资产目录见 [Sparkle 更新发布规则](sparkle-updates.md)。签名 ZIP 不得在签名后修改。先上传 ZIP，验证成功后最后上传 `appcast.xml`。

## English

### Published baseline

The stable Aquarius GitHub Releases were checked on October 25, 2026: `v1.0.1`, `v1.0.2`, `v1.0.3`, `v1.1.1`, and `v1.2.1`. The latest historical V1.2.1 App actually used Xcode `Version = 1.2` and `Build = 1`. Existing tags, packages, and release notes remain unchanged.

These five verifiable releases establish a one-time ordinal baseline. The first release build under the new scheme starts at `0006`. Historical ordinal `0005` is not a claim about the metadata shipped in V1.2.1; Sparkle compares its old `CFBundleVersion = 1` numerically with the new padded build.

### Future release rules

- `MARKETING_VERSION` / `CFBundleShortVersionString` contains the complete semantic version, such as `1.2.2`; the public tag is `v1.2.2`.
- `CURRENT_PROJECT_VERSION` / `CFBundleVersion` is an independent, globally increasing four-digit decimal release-build number. The first new-format release starts at `0006`, followed by `0007`; it never resets for a new marketing version.
- Debug builds, tests, and repeated validation of the same candidate do not allocate new release numbers. Allocate one for each new distributable build and never reuse a distributed or abandoned number.
- Before a release, compare GitHub Releases, the actual prior App metadata, and `Configuration/ReleaseBuilds.json`. Record a new allocation as `reserved` without inventing a version or tag; fill those fields and mark it `published` only after publication.
- Keep the Aquarius target's Debug and Release configurations synchronized. Test tools and Sparkle fixtures use separate identifiers and do not consume release build numbers.
- Set `CFBundleDisplayName` to `Aquarius V<complete-version>`. The appcast `sparkle:version` must exactly match the four-digit `CFBundleVersion`, including leading zeros.
- The first Sparkle-enabled release does not replace historical packages. V1.2.1 and earlier lack the updater and require a manual upgrade; Sparkle can deliver later updates only after an updater-enabled version is installed.

### Signed updates

Aquarius uses its own Sparkle EdDSA account, `lex.Aquarius`, separate from macOS Developer ID or ad-hoc code signing. EdDSA verification is required for both the appcast and downloaded ZIP; code-signing and notarization status are checked and reported separately.

The production public key is in `SUPublicEDKey` in `Configuration/Info.plist`. The private key remains in the publisher's login keychain. Never export, print, regenerate, or replace it. If the existing account key is unavailable, stop signed publication and restore the backed-up key.

See the [Sparkle update release policy](sparkle-updates.md) for the release procedure, stable `Aquarius.app` package root, historical backup, and asset layout. Never modify a ZIP after signing it. Upload the ZIP first, verify it, and upload `appcast.xml` last.
