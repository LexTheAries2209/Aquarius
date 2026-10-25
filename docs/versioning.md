# Version And Build Rules / 版本与构建号规则

## 中文

### 已发布基线

2026-10-25 核对 Aquarius 的正式 GitHub Releases，共 5 个：`v1.0.1`、`v1.0.2`、`v1.0.3`、`v1.1.1` 和 `v1.2.1`。最新的历史 V1.2.1 实际使用 Xcode `Version = 1.2`、`Build = 1`，其 App 名为 `Aquarius V1.2.1.app`。历史标签、安装包和发布说明保持原样。

以这 5 个可验证的正式发布作为一次性发布构建序号基线。V1.3.0 是迁移后首个发布构建，使用 `Build = 0006`；`0005` 是迁移序号，不代表历史 V1.2.1 安装包中实际写入了 `0005`。Sparkle 会把旧版 `CFBundleVersion = 1` 与新版本四位数字构建号按数值比较。

### 后续发布规则

- `MARKETING_VERSION` / `CFBundleShortVersionString` 使用完整语义版本号，例如 `1.3.0`；公开标签为 `v1.3.0`。
- `CURRENT_PROJECT_VERSION` / `CFBundleVersion` 使用独立、全局递增的四位十进制发布构建号，例如 `0006`、`0007`。换主/次版本时不归零，也不拼接进公开版本号。
- 构建号按实际准备对外分发的发布构建次数递增；普通 Debug 编译、单元测试、同一候选版本的重复验证不消耗新编号。已经分发或放弃的编号不得复用。
- 发布前同时核对 GitHub Releases、上一版 App 元数据以及 `Configuration/ReleaseBuilds.json`。新发布构建先在台账中记录为 `reserved`；发布后补齐版本、标签并改为 `published`。
- 同步 Aquarius target 的 Debug/Release 配置。测试工具和 Sparkle fixture 使用独立标识，不参与发布构建计数。
- 从 V1.3.0 起，App 文件名及 `CFBundleDisplayName` 固定为 `Aquarius.app` / `Aquarius`；版本号由 `CFBundleShortVersionString` 单独表达。Sparkle appcast 的 `sparkle:version` 必须与四位 `CFBundleVersion` 完全一致并保留前导零。
- V1.2.1 及更早版本不含 updater。用户需先从 GitHub Releases 手动安装 V1.3.0；之后的版本可由 Sparkle 更新。
- 发布前检查上一版实际写入的构建号。首次迁移的 ZIP 准备基线为 `--previous-build 0005`；公开 feed 探测则使用 V1.2.1 实际 `CFBundleVersion = 1`。后续发布根据已发布的全局构建台账设置准备基线，并用实际客户端版本验证更新发现。

Aquarius 使用独立的 Sparkle EdDSA 账户 `lex.Aquarius`。EdDSA 签名用于验证更新清单和 ZIP，不等同于 macOS 代码签名、Developer ID 或 Apple 公证。私钥只保存在发布者登录钥匙串中，不得导出、打印、重建或替换。

完整发布流程、稳定 App 包名、备份目录及签名资产布局见 [Sparkle 更新发布规则](sparkle-updates.md)。签名 ZIP 不得再修改；发布时先上传 ZIP，最后上传 `appcast.xml`。

## English

### Published baseline

The five stable Aquarius GitHub Releases were verified on October 25, 2026: `v1.0.1`, `v1.0.2`, `v1.0.3`, `v1.1.1`, and `v1.2.1`. The latest historical V1.2.1 App used Xcode `Version = 1.2` and `Build = 1`, with the name `Aquarius V1.2.1.app`. Existing tags, packages, and release notes remain unchanged.

These five verifiable releases form a one-time release-build sequence baseline. V1.3.0 is the first build after migration and uses `Build = 0006`. Historical ordinal `0005` is not metadata from the V1.2.1 App; Sparkle compares its actual `CFBundleVersion = 1` numerically with the new four-digit build.

### Future release rules

- `MARKETING_VERSION` / `CFBundleShortVersionString` contains the complete semantic version, such as `1.3.0`; its public tag is `v1.3.0`.
- `CURRENT_PROJECT_VERSION` / `CFBundleVersion` is an independent, globally increasing four-digit decimal release-build number, such as `0006` then `0007`. It does not reset for a new marketing version and is not appended to the public version.
- Increment Build for each release build prepared for distribution. Debug compilations, tests, and repeated validation of the same candidate do not consume a new number. Never reuse a distributed or abandoned allocation.
- Before a release, compare GitHub Releases, the actual previous App metadata, and `Configuration/ReleaseBuilds.json`. Record the new allocation as `reserved`; after publication, set its exact version and tag and mark it `published`.
- Keep the Aquarius target's Debug and Release settings synchronized. Test tools and Sparkle fixtures use separate identifiers and do not consume release-build numbers.
- Starting with V1.3.0, the App filename and `CFBundleDisplayName` are fixed as `Aquarius.app` / `Aquarius`; `CFBundleShortVersionString` carries the version separately. The appcast `sparkle:version` must exactly match the four-digit `CFBundleVersion`, including leading zeros.
- V1.2.1 and earlier lack the updater. Users must manually install V1.3.0 from GitHub Releases once; later versions can be delivered through Sparkle.
- Check the actual prior App build before publication. The initial ZIP-preparation migration baseline is `--previous-build 0005`, while the public-feed probe uses V1.2.1's actual `CFBundleVersion = 1`. For later releases, use the published global build ledger for preparation and verify discovery from the actual installed client version.

Aquarius uses its own Sparkle EdDSA account, `lex.Aquarius`. EdDSA signatures verify the update feed and ZIP; they are separate from macOS code signing, Developer ID identity, and Apple notarization. The private key remains in the publisher's login keychain and must never be exported, printed, regenerated, or replaced.

See the [Sparkle update release policy](sparkle-updates.md) for the complete release workflow, stable App name, backup layout, and signed assets. Never alter a signed ZIP; upload the ZIP first and `appcast.xml` last.
