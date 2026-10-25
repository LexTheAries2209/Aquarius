# Sparkle Update Release Policy / Sparkle 更新发布规则

## 中文

本流程只适用于 Aquarius，bundle ID 为 `lex.Aquarius`。Sparkle 2.10.0 固定在 `Aquarius.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`；升级依赖需单独评估、测试并更新许可证信息。

### 安全与升级边界

- Appcast 必须通过 Sparkle EdDSA 验签，更新 ZIP 必须在解压前通过 EdDSA 验签。`SURequireSignedFeed` 和 `SUVerifyUpdateBeforeExtraction` 保持为 `true`，失败时不得回退到无签名下载。
- EdDSA 私钥账户为 `lex.Aquarius`，私钥只在发布者登录钥匙串中。`SUPublicEDKey` 固定在 `Configuration/Info.plist`。不导出、不打印、不重新生成或替换现有私钥；账户密钥缺失时停止，不得用新 key 发布破坏升级链。
- 自动检查默认关闭；可由用户在“设置 > 更新”中开启。自动下载和无确认安装保持关闭。手动检查、启动检查、下载开始、准备安装和退出安装各自经过更新安全门。
- 已有视频识别、批处理或文件处理任务时，不开始下载；任务在下载期间启动则取消下载。已下载/解包的更新若遇到任务冲突或用户取消，必须用 Sparkle 的 skip/cancel 路径取消安装，不能用 dismiss 保留“退出时继续安装”。
- 用户确认安装后先预留应用操作，暂停媒体播放并阻止新任务，再让 Sparkle 退出、替换和重启应用。普通退出若碰到待确认的预备安装，先取消安装，再完成退出。
- V1.2.1 及更早已发布版本没有 Sparkle。它们不会收到此 feed 的更新；首个包含 updater 的新版需手动安装，此后的版本才可使用 Sparkle 链路。
- V1.3.0 是首个包含 updater 的发布版本。其 Finder/App 名称为稳定的 `Aquarius.app` / `Aquarius`，完整语义版本与独立四位 Build 分别保存在版本元数据中。
- Sparkle EdDSA 签名不等于 Developer ID 代码签名，也不证明 Apple notarization 或 Gatekeeper 信任。逐项报告实际状态，不得互相替代。
- 发布 App 的代码签名仍须通过 `codesign --verify --deep --strict`；有效的 ad-hoc 签名可以满足本链路，不代表 Developer ID 或公证。Sparkle 包和清单必须再独立通过 EdDSA 签名验证。

### 发布物布局

Aquarius 始终以稳定名称 `Aquarius.app` 打包，目录形态与 Capricorn 相同，但使用 Aquarius 自己的 key、版本台账和路径：

```text
Aquarius旧版软件/
  Aquarius VX.Y.Z/
    Aquarius.app
    README.md
    Aquarius VX.Y.Z/
      Aquarius.xcodeproj
      source files...
    update/
      Aquarius-vX.Y.Z-macOS.zip
      Aquarius-vX.Y.Z-macOS.md
      appcast.xml
```

完整 Xcode `.xcarchive` 和匹配 dSYM 独立保留，不放进公开 ZIP。ZIP 顶层必须是 `Aquarius.app`。目标发布目录必须全新；已存在时停止，不覆盖。

### 发版顺序

1. 读取 [versioning.md](versioning.md) 和 [ReleaseBuilds.json](../Configuration/ReleaseBuilds.json)，核实当前最新正式 Release、实际上一版 App 的 `CFBundleVersion` 以及本次已预留编号。
2. 使用确切版本更新 Aquarius Debug/Release 元数据和双语发布说明；发布构建号独立递增为四位数，并记录预留状态。不要根据 patch 版本推算构建号。
3. 通过 Xcode `Release` archive 构建，验证产物名、bundle ID、版本、四位构建号、arm64 架构、Sparkle framework、Info 配置、代码签名有效性和 dSYM。保留完整 `.xcarchive`。
4. 先更新 README、累计日志、双语发布说明和旧版 App/源码备份。保留稳定 App 包名 `Aquarius.app`。
5. 使用 `scripts/prepare-sparkle-update.py` 从已验证的 archive App 生成新 ZIP 和签名 `appcast.xml`。脚本必须验证 public key 与 `lex.Aquarius` account 一致、版本/构建号、签名 feed、ZIP 长度和 ZIP EdDSA 签名。任何失败都停止发布。
6. 在 staging feed 上运行 `scripts/test-sparkle-update.py`，验证真实 Sparkle 从旧 fixture 检出新版本、验证签名、下载、解包、等待确认、替换并重启；也验证取消、退出、签名篡改和 feed 缺失失败时不替换。fixture 私钥临时生成，仅用于隔离测试，不得接触生产账户。
7. 将不可变 ZIP 和 release notes 上传到 GitHub Release draft，核对文件名/大小/内容后最后上传 `appcast.xml`；验证两个资产后再发布 draft。固定 feed URL 为 `https://github.com/LexTheAries2209/Aquarius/releases/latest/download/appcast.xml`。不要让已发布的 latest Release 缺少 appcast；不要修改已经签名的 ZIP。
8. 发布后通过只读 Sparkle probe 检查公开签名 feed：上一构建可以发现当前版本，当前构建显示无更新。核对 GitHub asset 存在、appcast 指向预期 ZIP，并把台账状态改为 `published`。

本地打包入口：

```sh
python3 scripts/prepare-sparkle-update.py \
  --app "/path/to/verified/archive/Products/Applications/Aquarius.app" \
  --sparkle-bin "/path/to/Sparkle/bin" \
  --output "/path/to/Aquarius旧版软件/Aquarius VX.Y.Z/update" \
  --download-url-prefix "https://github.com/LexTheAries2209/Aquarius/releases/download/vX.Y.Z/" \
  --release-notes "docs/releases/vX.Y.Z.md" \
  --previous-build 0005
```

准备 ZIP 时，`--previous-build` 使用分配台账中的前一发布构建序号；迁移首版基线为 `0005`，实际 V1.2.1 安装包元数据仍是 `1`。公开 feed probe 则使用真实上一版 App 的 `CFBundleVersion`（首版迁移时为 `1`）。`--output` 必须不存在。对私钥/keychain 或 GitHub 的认证要求由本机处理；不要把凭据写入脚本参数或日志。

发布后只读核验命令示例：

```sh
python3 scripts/test-published-sparkle-feed.py \
  --app "/path/to/current/Aquarius.app" \
  --sparkle-root "/path/to/Sparkle" \
  --previous-build 1
```

## English

This policy is specific to Aquarius (`lex.Aquarius`). Sparkle 2.10.0 is pinned in `Aquarius.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. Evaluate, test, and update notices separately when changing the dependency.

### Security and migration boundary

- Require Sparkle EdDSA verification for the appcast and for the update ZIP before extraction. Keep `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` true; never fall back to unsigned downloads.
- The private key belongs to the `lex.Aquarius` account and remains in the publisher's login keychain. `SUPublicEDKey` is fixed in `Configuration/Info.plist`. Never export, print, regenerate, or replace the key. Stop if it is unavailable; publishing with a new key would break the update chain.
- Automatic checks are off by default and user-controlled in Settings > Updates. Automatic downloads and install-without-confirmation remain disabled. Gate manual checks, launch checks, download start, prepared installation, and application termination independently.
- Do not begin a download while media recognition, batch, or file processing is active. Cancel an in-progress download if work starts. If work conflicts with a downloaded/prepared update or the user cancels, use Sparkle's skip/cancel path; do not dismiss and leave install-on-quit armed.
- After explicit install confirmation, reserve app operations, pause playback, and block new work before Sparkle terminates, replaces, and relaunches the App. If the user quits with an unconfirmed prepared update, cancel the update before completing the quit.
- Published V1.2.1 and earlier lack Sparkle. They cannot receive this feed; install the first updater-enabled version manually. Later versions can use the Sparkle flow.
- V1.3.0 is the first release with the updater. Its Finder/App name is the stable `Aquarius.app` / `Aquarius`; the complete semantic version and independent four-digit Build are stored separately in bundle metadata.
- Sparkle EdDSA signatures are separate from Developer ID code signing and do not establish Apple notarization or Gatekeeper trust. Report each status accurately.
- The release App's code signature must pass `codesign --verify --deep --strict`. A valid ad-hoc signature is acceptable for this flow but does not establish Developer ID identity or notarization; the package and feed still require their independent Sparkle EdDSA signatures.

### Artifact layout

Keep the packaged app name stable as `Aquarius.app`, using the same layout shape as Capricorn but with Aquarius-specific keys, ledger, and paths:

```text
Aquarius旧版软件/
  Aquarius VX.Y.Z/
    Aquarius.app
    README.md
    Aquarius VX.Y.Z/
      Aquarius.xcodeproj
      source files...
    update/
      Aquarius-vX.Y.Z-macOS.zip
      Aquarius-vX.Y.Z-macOS.md
      appcast.xml
```

Retain the full Xcode `.xcarchive` and matching dSYM separately, outside the public ZIP. The ZIP root must be `Aquarius.app`. Require a new output directory; stop rather than overwrite an existing one.

### Release sequence

1. Read [versioning.md](versioning.md) and [ReleaseBuilds.json](../Configuration/ReleaseBuilds.json). Verify the latest stable Release, the actual previous App's `CFBundleVersion`, and the current build reservation.
2. Set the exact requested version in Aquarius Debug/Release metadata and bilingual notes. Allocate an independent, increasing four-digit build and record it as reserved. Never infer the build number from the patch version.
3. Create an Xcode Release archive. Verify product name, bundle ID, version, four-digit build, arm64 architecture, embedded Sparkle framework, Info settings, valid code signature, and dSYM. Retain the complete `.xcarchive`.
4. Update README, cumulative release log, bilingual release notes, and the old-version App/source backup. Keep the packaged App name `Aquarius.app`.
5. Run `scripts/prepare-sparkle-update.py` on the verified archive App to create the ZIP and signed `appcast.xml`. It must verify the account public key, version/build metadata, signed feed, ZIP length, and ZIP EdDSA signature. Stop on any failure.
6. Run `scripts/test-sparkle-update.py` against a staging feed. Exercise real Sparkle discovery, signature verification, download, extraction, confirmation, replacement, and relaunch, plus cancellation, quit, tampered-signature, and missing-feed cases. Generate an isolated fixture key; never use or expose the production key in tests.
7. Upload the immutable ZIP and release notes to a GitHub Release draft first; verify their names, sizes, and contents, then upload `appcast.xml` last. Publish the draft only after both assets are ready so the latest published Release never temporarily lacks its feed. The fixed feed URL is `https://github.com/LexTheAries2209/Aquarius/releases/latest/download/appcast.xml`. Never alter a signed ZIP.
8. After publication, use a read-only Sparkle probe against the public feed: the previous build must discover the current build and the current build must report no update. Verify the GitHub asset and enclosure URL, then mark the ledger allocation `published`.

Example local packaging command:

```sh
python3 scripts/prepare-sparkle-update.py \
  --app "/path/to/verified/archive/Products/Applications/Aquarius.app" \
  --sparkle-bin "/path/to/Sparkle/bin" \
  --output "/path/to/Aquarius旧版软件/Aquarius VX.Y.Z/update" \
  --download-url-prefix "https://github.com/LexTheAries2209/Aquarius/releases/download/vX.Y.Z/" \
  --release-notes "docs/releases/vX.Y.Z.md" \
  --previous-build 0005
```

For package preparation, use the previous allocated release-build sequence for `--previous-build`. The migration baseline is `0005`; the old App's actual bundle metadata is still `1`. For the public-feed probe use the actual last App's bundle build (`1` for the initial migration). `--output` must not already exist. Handle keychain/GitHub authentication locally; never put credentials in script arguments or logs.

After publication, probe the public feed without installing an update:

```sh
python3 scripts/test-published-sparkle-feed.py \
  --app "/path/to/current/Aquarius.app" \
  --sparkle-root "/path/to/Sparkle" \
  --previous-build 1
```
