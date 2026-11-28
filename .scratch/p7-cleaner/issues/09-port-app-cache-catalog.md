# p7-cleaner/09:规则表搬运一——应用缓存说明库全量

Status: done(2026-11-28 合 develop @cabbce1;目验待用户)
Blocked by: 无(可立即开始)

## 目标

把 purge-app 的应用缓存说明库全量搬进我们的应用缓存知识库:每条带规范目录名、标题、档位、中文说明、出处。改之前:知识库 34 条,本机缓存目录里 48 项被标「未识别」;改之后:其中大部分带上说明,认识的可自动勾选(按档位),剩下的才归通用发现兜底。

## 范围

1. 搬运范围:purge-app 说明库全部条目(上次核实约 285 条;实施时以当时的上游为准)。与现有 34 条重叠的合并——同路径以现有条目的说明为准,缺的别名补上。
   *实施时这条落成「每一条都有明确下落」,不是「每一条都进知识库」——上游现行 311 条,带目录名的 260 条里 179 个目录名进了知识库,其余的去向逐笔记在搬运账本里;缘由见 Comments「实施」。*
2. 文案:按两档口径中文重写,不是逐条直译;每条说明非空;出处注明 purge-app(MIT,可移植)。
3. 档位:对齐上游的安全 / 先检查,逐条过目;拿不准的落「先检查」。
4. 登记完整性:每条一个正例(路径可由目录名推导,允许脚本生成后人工粘入);相似名、`-old` 变体等反例同步补。
5. 与通用发现的交界:新搬来的条目从「未识别」变成认识,02 票的去重自动生效。
6. 分批提交:每 60–80 条一次提交,登记完整性用例随批跑。*实施时按类别分了三批(54 / 26 / 18 条),每批都小于 60 条;登记完整性用例随批跑。*
7. 脚本批量改文件时,每处替换先断言锚点再替换——pattern 与格式化后的代码失配会静默跳过;零散几处用编辑工具,失配会大声失败。

## 验收

- [x] 知识库条数 = 现有 + 新增(合并后的数量记在票面);每条正例命中、说明非空、出处注明——**34 条 → 131 条**(撤 1、新增 98);登记的目录名 64 个 → 196 个。每个目录名一条正例(`AppCacheCatalogTests` 一次扫出);账本逐名对上游原件核过(两位评审各用独立脚本对账,逐行相等)。
- [x] 夹具:搬运前被通用发现标「未识别」的样例目录,搬运后按规则表档位出现、不再带「未识别」(`AppCacheCatalogTests.testPortedDirectoriesMoveFromUnidentifiedToRuleTier`,样例取自本票新搬的条目)
- [x] 组内排序、组序、总览聚合的既有断言不受影响(全量检查 1592 绿)
- [x] ~~目验:本机缓存目录下「未识别」条目明显减少,大部分带上了说明~~ **按实测改写**(见 Comments「本机实测」):本机缓存目录下非空的一级目录 88 个,「未识别」36 个 → 31 个;新出现 21 个带说明的苹果缓存(约 41 MB,全在「先检查」)。立票时预期的「大部分带上说明」在这台机器上**兑现不了**——剩下的 31 个(约 2.7 GB)上游本来就不认识。其中 3 个是开发工具缓存(ms-playwright 572 MB、pulse-swiftpm 399 MB、bun 47 MB),归票 10;其余 28 个(约 1.7 GB)要另写一批。
- [ ] 目验(用户):清理页重新扫描 →「应用缓存」组多出二十来行带说明的苹果缓存(帮助系统、App Store 后台下载这些),全在「先检查」,悬停能看到「清了会怎样」;「先检查」里不再有 CloudKit

## 测试

接缝 1;先例:知识库登记用例、规则表登记完整性用例。全量检查与真机验证由用户发起。

## 依据与纪律

spec `p7-cleaner/spec.md`;GLOSSARY「安全白名单」「应用缓存」。上游许可 MIT,可移植,逐条注明出处。本票与 02 票并行时:后合的票核对先合票新改的调用面。

## Comments

**2026-11-28 实施(分支 `feat/p7-app-cache-catalog`,四个提交 b952a0f / 1037cfc / e749a35 / 6dc8710,合 develop @cabbce1;已推送已装机)**

- **范围核实**:上游 `purge/Resources/explanations.json`(提交 ceacaf8,2026-11-28 读取)共 **311 条**(立票时记「约 285」)。带目录名的 260 条、不带目录名的 51 条(开发工具的固定路径与项目产物)。上游那张表把应用缓存、开发工具缓存、项目产物三种东西混在一起,而且**表里的条目不等于上游会列出的东西**——它另有一道安全策略(`DeletionSafetyPolicy`),把表里一部分条目挡成「永不列出」。所以「全量搬」落成:每一条都有明确下落。
- **结果**:知识库 **34 条 → 131 条**(撤 1、新增 98:浏览器 1 / 第三方应用 49 / 苹果自家 48);登记的目录名 64 个 → 196 个。四摞的条数:浏览器 11(可安全清理 10 / 先检查 1)、第三方应用 68(60 / 8)、苹果自家 49(全部先检查)、Pulse 自定 3。上游 404 个目录名的下落:**179 个进了知识库**(含并入现有条目的 4 个)、27 个已由现有规则担保、131 个交给票 10、30 个留给通用发现、21 个不列、16 个不属于任何在办票——每一笔记在 `AppCacheCatalogPortLedgerTests` 的搬运账本里,覆盖与形状都有断言钉住。
- **结构**:知识库从一个数组重排成 `browsers` / `apps` / `apple` / `custom` 四摞,`entries` = 四摞相加;规则生成、匹配、去重、界面、历史都不变(零新机制)。新条目的 key 直接用上游 key(出处即标识);p6 首批的 key 不变。
- **搬运口径(写在 `AppCacheCatalog.swift` 文件头)**:
  1. 只有「确实是缓存目录下一级目录名」的才进知识库。开发工具与项目产物(Homebrew、VS Code、node_modules、DerivedData 这类)归开发工具规则与票 10。
  2. 上游自己的安全策略「永不列出」的条目不搬——照表搬会比上游更松。
  3. 上游登记的应用显示名只搬证实是缓存目录名的:反域名包名、独造词(撞不上别的软件)。普通英文单词(Sketch、Loom、Fork、Maps)没证实的不搬,真有那个目录也由通用发现以「先检查」列出。
  4. 上游不分大小写,我们字面精确匹配(实测时本机 104 个目录,两种认法结果相同)。
- **条目由脚本生成后粘入**:目录名从上游 JSON 原样取出(生成器写出前逐名对照上游),自检当场抓到一处手抄错字(Claude 更新器的目录名多了一个字母——照那个写进代码,规则永远匹配不上真目录)。账本行同样由脚本从上游文件生成。生成器不入库;入库的 Swift 是唯一真相,账本测试逐名钉住它与上游的关系。

**实施时自己拍的默认项(逐条过目的结论;要改都是一处档位 / 一行账本的事)**

1. **苹果自家的缓存恒「先检查」,不自动勾。** 49 条里 33 条上游标「安全」。理由:这些服务常驻,没有可靠的「在运行」信号(票 02 定「苹果自家缓存不列」时的同一条理由;在用保护按路径内的活动判定,常驻守护进程不产生这种活动,所以兜不住);上游对苹果后台服务缓存的「安全」判断有过反例——`com.apple.e5rt.e5bundlecache` 上游标安全,而对齐对象的用户报告是守护进程在跑时清了识别功能会坏(票 02 已因此进保护名单)。想放开哪一条,把那一行的 `.checkFirst` 改成 `.safe`;`AppCacheCatalogTests` 钉住「苹果的目录名不许出现在安全档」,改了要连测试一起改。
2. **撤掉现有的 CloudKit 条目**(p6 时列在「先检查」,本机 216 MB)。它是 iCloud 同步的元数据库(`CloudKitMetadata` / `CloudKitOperationInfo` 两个带 WAL 的 SQLite 库),不是可丢弃缓存;上游安全策略明确永不列出(它的注释说 macOS 自己会拒绝移走——这一句只有上游注释为证,没实测)。票面只写了「重叠的合并、同路径以现有条目为准」,这条超出字面授权;方向是更严(现在谁都不列,账本测试钉住),**等用户点头**。
3. **三条上游会列、我们「逐条过目」否决**:`com.apple.cache_delete`(上游标安全;本机看过内容是系统清理守护进程的记账文件——清理历史、哨兵,不是缓存)、`com.apple.dataaccess.dataaccessd`(联系人与日历的同步代理,与受保护的日历缓存同类)、`com.apple.passd`(钱包卡票;同类的 PassKit 上游永不列出)。
4. **上游标安全、我们落先检查的三条**:`RevenueCat`(订阅与内购工具的缓存;没联网时订阅状态可能暂时显示不对;Spokenly 条目里那个 RevenueCat 的目录名一并挪到这条)、Yab 浏览器(上游的安全档以「目录里只有浏览器缓存」为条件,我们不做形状核对)、**Spotify**(p6 首批就有,原在「可安全清理」且说明写「离线歌曲不受影响」;上游只要用户下载过离线歌曲就不提供这个缓存,注释写明对齐对象的用户实测是清它会连离线歌曲一起带走;我们查不了有没有离线歌曲)。
5. **开发类应用进「应用缓存」组,不进「开发工具」组**:接口调试、数据库客户端、Git 客户端是普通应用;编辑器、IDE、SDK 相关的(VS Code、Cursor、Zed、Android Studio、模拟器)交给票 10,与现有的 `vscode.cache` / `cursor.cache` 放一处。
6. **保护名单补两处**(票 02 的产物,只收窄):「屏幕使用时间」的裸名字(`screentime`;原先只挡带苹果前缀的写法,`ScreenTime` 会被通用发现列出来——是账本测试先红时暴露的);苹果守护进程缓存名单补三个不带前缀的名字(`ssu` / `SiriTTS` / `AMSDataMigratorTool`)。
7. **新条目的 key 用上游 key 原样**(kebab-case),与 p6 首批的 camelCase 并存:出处即标识,账本按 key 对账;不为 98 条另起名字。
8. **CleanMyMac 条目补一个版本号**(`com.macpaw.CleanMyMac5`,本机实测;上游只登记到 4),条目旁注明是 Pulse 补的。
9. **更正两条 p6 条目的出处**:`chromium`、`edge` 原标「来自上游说明库」;拉上游自建仓(2026-06-26)到今天的全史,这两个目录名从没在说明库里出现过,是比照同内核的 Chrome / Brave 自己登记的——出处改成「Pulse 自定」并写明缘由。同理,p6 首批里还有 8 个目录名上游没有(Arc、company.thebrowser.browser、Zen、Safari、zoom.us、Raycast、Microsoft AutoUpdate、com.google.Keystone),保留(p6 的决定),在账本测试里点名。
10. **豆包输入法条目的说明补一句**(Pulse 自定,上一期就有):上游一律不提供输入法的缓存(学到的词和个人词典常放在缓存旁边);档位不动,仍是「先检查」。
11. **新增一条宿主测试**:规则表登记的行首图标必须是系统里真有的 SF Symbol(名字写错不报错,只是那一行没有图标;本票新增 26 个图标名)。
12. **账本的 `.rule` 下落同时查两张规则表**(安全白名单规则表与项目产物规则表——Pods 在后者)。

**测试(先红后绿)**

- 先写测试再写实现:首轮 28 条里 158 处失败,红的原因逐条看过——新条目不存在(账本与登记正例)、样例目录搬运后不被认领、CloudKit 仍被旧条目列出、`ScreenTime` 被通用发现列出(保护名单漏词)、Safari 条目的「Safari」撞个人数据名单(闸门里写明是两处地方)。
- 新增与扩充:`AppCacheCatalogPortLedgerTests` 7 条(账本覆盖上游每一条并钉住形状 / 搬了的目录名真在、档位不放宽 / 每个目录名都能从账本走到 / 现有规则真在、不放宽 / 不列的谁都不列 / 未证实的别名不被认领 / 交给票 10 的没提前进知识库);`AppCacheCatalogTests` 从 5 条到 10 条(逐目录名正例、相似名不认领、保护名单闸、苹果恒先检查、搬运前后夹具);登记正例 98 行;宿主图标校验 1 条。
- 变异验证三轮,每处都被对应的测试抓到后还原:把一条苹果条目改成「可安全清理」(两处闸门同时红);往现有条目里塞一个账本外的目录名;把账本里一条上游档位改掉;把 Spotify 改回「可安全清理」。
- 门禁:全量检查 1592 绿(核心包 + 特权助手包 1054、app 538;评审修正之前那一轮),lint 本票文件零告警。评审修正之后的终版复跑 1591 / 1592:挂的一条是负载敏感的真机验收用例(`AcceptanceAnchorEndToEndTests`,起 3 个忙循环求 CPU 之和,当时机器负载平均值 84——别的进程的风暴,与本票零关联),单跑复验通过;没有在负载风暴里再压一轮全量。修正那一笔只动了知识库数据与测试,依赖它们的宿主测试在终版里全过。

**本机实测(只读探针,2026-11-28;验收第 4 条按此重记)**

- 缓存目录下一级目录 105 个,非空(会进清单的)88 个。搬运前标「未识别」的 36 个 → 搬运后 **31 个**,少 5 个(Claude Code 日志 7.7 MB、CleanMyMac 0.3 MB、Sentry 与 Datadog 的三个目录不到 0.1 MB)。
- 搬运新出现的是 **21 个苹果后台服务的小缓存,合计约 41 MB**(最大是帮助系统 23 MB),都在「先检查」;CloudKit(216 MB)从清单里消失。
- **票面立票时写的「本机未识别明显减少、大部分带上说明」在这台机器上兑现不了**:剩下 31 个未识别目录合计约 2.7 GB,上游本来就不认识它们。其中 3 个是开发工具缓存,归票 10:`ms-playwright` 572 MB、`pulse-swiftpm` 399 MB(Pulse 自己的 SwiftPM 构建缓存)、`bun` 47 MB。其余 28 个(约 1.7 GB)是本机的应用长尾,要靠另写一批:`MyGo Music` 943 MB、`dotslash` 363 MB、`ReactNative` 250 MB、`Doubao` 37 MB、`com.onevcat.Kingfisher.ImageCache.default` 33 MB、`dev.curator.Curator` / `Curator` 22 MB、`SwiftLint`、`com.charcoaldesign.swiftformat`、`Tern` / `stencil-term` / `so.stencil.tern`、`com.runjuu.Input-Source-Pro`、`Citro Labs` / `com.citrolabs.EgoUpdater`、`com.nemo.BrightnessApp.*`(本机自己的应用)。

**两轴评审(只读评审员并行;均「有条件通过」,无 P0 / P1)**

- 规范轴:亲手核实账本对上游 311 条逐条一致、63 条「先检查」无一升档、196 个目录名对上游四张保护名单零命中。意见六条全部处理:①账本的反向检查只查条目 key、往现有条目加名字就绕过(13 个账本外的名字)→ 改成逐个目录名核对,p6 遗留的 10 个点名保留;②Spotify 说明说轻、还恒列在安全档 → 降「先检查」;③`testLedgerMirrorsUpstreamOneForOne` 名不副实、档位是抄的 → 改名并钉住账本形状;④保护名单闸门的「google」豁免按词不按条目、还重写了匹配逻辑 → 改成逐个点名、直接用保护名单的判定;⑤与上游的差异没逐处标注(Chromium / Edge 出处、Google SDK 事件拆条、ToDesktop 收窄、保护名单注释漏了 Safari 例外)→ 逐处补;⑥两处文案、Spokenly 里的 RevenueCat 目录名与 RevenueCat 条目不同档 → 改。它另报一条 diff 外的(豆包输入法:上游按词片段一律不提供)→ 说明里补一句。
- 需求轴:独立脚本对账(上游 311 个 key = 账本 260 行 + 无目录名 51 条;目录名与档位逐行相等)、131 条中文说明与英文原文并排读完无说反、前后夹具与生产拼装同形。意见:①Spotify(同上);②票面没回写、账本三处指向的 Comments 不存在 → 即本节;③验收 4 字面兑现不了 → 已按实得数字改写;④`checkpoint-nodejs` 与同类的 `prisma-nodejs` 下落不一致 → 统一交给票 10;⑤撤 CloudKit 超出字面授权 → 记在默认项第 2 条,等用户点头;⑥分批 54 / 26 / 18 与票面的「每 60–80 条」不符、前两批的工程文件引用了第三批才入库的测试文件 → 合入前把分支历史理顺(测试文件并进第一批,每一笔都能独立构建);分批偏小照实记。
- 评审员注记、未动的:规范轴在 purge-app 源码里没搜到保护名单注释说的「对齐对象对 Google 七次清理失败」——那条注释说的是另一个对齐对象(Mole,票 02 的产物),不是本票的上游,注释无误。

**交接(都从账本里原样导出,逐条带上游的档位与原名;机器可读的版本是账本测试本身,这里是便于阅读的副本)**

**交给票 10(带目录名的 83 条;另有无目录名的 51 条)**

**其中本机在场、值得票 10 先看的**:`ms-playwright`(medium;本机 572 MB——清了测试会失败,要重新 `npx playwright install`)、`bun-cache`(`.bun` / `bun-install`;本机有个 `bun` 目录 47 MB)、`typescript-type-cache`(`typescript`)、`cypress-cache`、`mise-cache`、`pre-commit-cache`(`pre-commit`)、`puppeteer-browsers`(`puppeteer`)。另:本机 `pulse-swiftpm`(399 MB)是 Pulse 自己的 SwiftPM 构建缓存,上游表里没有,也归开发工具规则。

**带目录名的 83 条**(格式:上游 key(上游档位;上游标题):目录名):
- `checkpoint-nodejs`(safe;「Node.js Dev Tool」):`checkpoint-nodejs`
- `ms-playwright`(medium;「Playwright Browsers」):`ms-playwright-go`
- `node-modules`(safe;「Node.js Packages」):`node_modules`
- `prisma-nodejs`(safe;「Prisma Database Tool」):`prisma-nodejs`
- `dart-tool`(safe;「Flutter Dev Tool」):`.dart_tool`
- `xcode-itunes-service`(medium;「Xcode Device Support」):`com.apple.dt.Xcode.ITunesSoftwareService`
- `gitworktrees`(medium;「Git Worktree Checkouts」):`worktrees`
- `vscode`(safe;「VS Code Cache」):`Code`, `CachedData`, `CachedExtensionVSIXs`
- `cursor`(safe;「Cursor Cache」):`Cursor`
- `zed`(safe;「Zed Editor Cache」):`zed`, `Zed`
- `maven`(medium;「Maven Package Cache」):`maven`, `.m2`
- `sbt`(medium;「Ivy Dependency Cache」):`sbt`, `.ivy2`
- `rubygems`(safe;「Ruby Gem Downloads」):`rubygems`, `.gem`
- `bundler`(safe;「Bundler Cache」):`bundler`, `.bundle`
- `composer`(safe;「Composer Cache」):`composer`, `.composer`
- `cargo`(safe;「Rust Package Cache」):`cargo`, `.cargo`
- `terraform`(safe;「Terraform Plugin Cache」):`terraform`, `.terraform.d`
- `githubactions`(safe;「GitHub Actions Cache」):`act`, `github-actions`
- `vagrant`(medium;「Vagrant Box Cache」):`vagrant`, `.vagrant.d`
- `zsh`(safe;「Zsh Session Cache」):`zsh_sessions`, `.zsh_sessions`, `zcompdump`
- `electron`(safe;「Electron App Cache」):`Code Cache`
- `iossimulators`(medium;「iOS Simulators」):`CoreSimulator`, `iossimulators`
- `bun-cache`(safe;「Bun Package Cache」):`.bun`, `bun-install`
- `turbo-cache`(safe;「Turborepo Build Cache」):`.turbo`, `turbo-cache`
- `mise-cache`(safe;「Mise Cache」):`mise`, `rtx`
- `vite-cache`(safe;「Vite Build Cache」):`.vite`, `vite-cache`
- `parcel-cache`(safe;「Parcel Build Cache」):`.parcel-cache`, `parcel-cache`
- `eslint-cache`(safe;「ESLint Cache」):`.eslintcache`
- `jest-cache`(safe;「Jest Test Cache」):`jest-cache`, `.jest-cache`, `jest_cache`
- `vitest-cache`(safe;「Vitest Test Cache」):`.vitest-cache`, `vitest-cache`
- `cypress-cache`(medium;「Cypress Test Binaries」):`Cypress`, `cypress`, `cypress-cache`
- `python-cache`(safe;「Python Bytecode Cache」):`__pycache__`, `.pyc`, `pycache`
- `uv-cache`(medium;「uv Package Cache」):`uv`, `uv-cache`, `.uv`
- `ruff-cache`(safe;「Ruff Linter Cache」):`.ruff_cache`, `ruff-cache`
- `mypy-cache`(safe;「Mypy Type Check Cache」):`.mypy_cache`, `mypy-cache`
- `kotlin-build`(safe;「Kotlin Build Cache」):`.kotlin`, `kotlin-build`
- `gradle-cache`(safe;「Gradle Build Cache」):`.gradle`, `gradle-cache`
- `gradle-global-cache`(medium;「Gradle Dependency Cache」):`Gradle Dependency Cache`
- `swift-build`(safe;「Swift Build Artifacts」):`swift-build`
- `rust-target`(safe;「Rust Build Output」):`target`, `rust-target`
- `flutter-cache`(safe;「Flutter Build Cache」):`.flutter-plugins`, `.flutter-plugins-dependencies`, `flutter_cache`
- `pub-cache`(safe;「Dart Pub Cache」):`pub-cache`, `.pub-cache`
- `nvm-cache`(medium;「nvm Node.js Versions」):`.nvm`, `nvm`
- `volta-cache`(safe;「Volta Tool Cache」):`volta`
- `npm-cache`(safe;「npm Package Cache」):`npm-cache`, `npm`
- `husky-cache`(safe;「Husky Git Hooks」):`_husky`
- `storybook-cache`(safe;「Storybook Cache」):`.storybook-cache`, `storybook-static`
- `nx-cache`(safe;「Nx Monorepo Cache」):`nx-cache`
- `moon-cache`(safe;「Moon Build Cache」):`moon-cache`
- `simulator-cache`(safe;「iOS Simulator Cache」):`com.apple.iphonesimulator`
- `android-studio`(safe;「Android Studio」):`com.google.android.studio`, `Android Studio`, `AndroidStudio`
- `npm-logs`(safe;「npm Logs」):`npm-logs`, `_logs`
- `xcode-docs-cache`(safe;「Xcode Documentation Cache」):`xcode-docs-cache`, `DocumentationCache`
- `corepack-cache`(safe;「Corepack Cache」):`corepack-cache`, `corepack`
- `elixir-build`(safe;「Elixir Build Output」):`_build`, `elixir-build`
- `elixir-deps`(safe;「Elixir Dependencies」):`elixir-deps`
- `hex-packages`(safe;「Hex Package Cache」):`Hex Package Cache`
- `rebar3-cache`(safe;「Rebar3 Cache」):`Rebar3 Cache`, `rebar3`
- `next-build`(safe;「Next.js Build Output」):`.next`
- `nuxt-build`(safe;「Nuxt Build Cache」):`.nuxt`
- `nuxt-output`(safe;「Nuxt Output」):`.output`
- `sveltekit-build`(safe;「SvelteKit Build Cache」):`.svelte-kit`
- `astro-build`(safe;「Astro Build Cache」):`.astro`
- `angular-cache`(safe;「Angular Build Cache」):`.angular`
- `pytest-cache`(safe;「pytest Cache」):`.pytest_cache`
- `tox-environments`(safe;「tox Environments」):`.tox`
- `stack-work`(safe;「Stack Build Output」):`.stack-work`
- `cabal-dist`(safe;「Cabal Build Output」):`dist-newstyle`
- `zig-cache`(safe;「Zig Build Cache」):`.zig-cache`
- `terraform-plugins`(safe;「Terraform Plugins」):`.terraform`
- `godot-cache`(safe;「Godot Project Cache」):`.godot`
- `nuget-packages`(medium;「NuGet Package Cache」):`NuGet Packages`
- `stack-global`(medium;「Stack Global Cache」):`Stack Cache`
- `cabal-packages`(medium;「Cabal Package Cache」):`Cabal Packages`
- `bazel-cache`(medium;「Bazel Build Cache」):`Bazel Cache`
- `swiftpm-cache`(safe;「Swift Package Cache」):`Swift Package Cache`
- `venv`(safe;「Python Environment」):`venv`, `.venv`
- `typescript-type-cache`(safe;「TypeScript Type Cache」):`typescript`
- `cursor-compile-cache`(safe;「Cursor Startup Cache」):`cursor-compile-cache`
- `apple-python-cache`(safe;「Apple Python Cache」):`com.apple.python`
- `pre-commit-cache`(safe;「pre-commit Environments」):`pre-commit`
- `puppeteer-browsers`(medium;「Puppeteer Browsers」):`puppeteer`
- `swift-frontend-cache`(safe;「Swift Compiler Cache」):`swift-frontend`

**无目录名的 51 条**(开发工具固定路径与项目产物,整批交给票 10):

`android-sdk`, `playwright-unused-builds`, `archives`, `go`, `nextjs-cache`, `android-build`, `cocoapods-spec-repos`, `orphaned-editor-workspace-storage`, `spotlight-profiles-cache`, `swiftpm-build`, `maven-target`, `gradle-build`, `sbt-target`, `dotnet-bin`, `dotnet-obj`, `composer-vendor`, `bundler-vendor`, `zig-out`, `dune-build`, `cmake-build`, `unity-library`, `unity-temp`, `unreal-intermediate`, `unreal-derived-data`, `old-cli-versions`, `cursor-agent-install-leftovers`, `claude-code-downloads`, `android-ndk-version`, `android-system-images`, `old-figma-profiles`, `prek-cache`, `expo-cache`, `version-manager-downloads`, `oh-my-zsh-cache`, `opam-download-cache`, `conda-packages`, `dart-analysis-cache`, `hermes-agent-cache`, `opencode-cache`, `antigravity-browser-cache`, `nvm-download-cache`, `nvm-node-version`, `vite-plus-node-version`, `vite-plus-node-install-leftovers`, `pyenv-python-version`, `rustup-toolchain`, `uv-python-version`, `giget-cache`, `firebase-emulators`, `gradle-leftovers`, `clang-module-cache`

**别名没证实是缓存目录名、留给通用发现的(30 个名字)**

真有那个目录,由通用发现以「先检查」列出(格式:上游 key:目录名):
- `openai-codex`:`Codex`
- `image-cache`:`ImageCache`
- `jetbrains`:`JetPackCache`
- `applogs`:`applogs`
- `crashreports`:`crashreports`
- `cocoapods-cache`:`pod-cache`
- `homebrew-cache`:`homebrew`, `homebrew-cache`
- `yarn-cache`:`yarn-cache`
- `iterm2`:`iTerm`
- `zoom`:`Zoom`
- `loom`:`Loom`
- `microsoft-teams`:`Teams`
- `granola`:`Granola`
- `ollama`:`Ollama`
- `sketch`:`Sketch`
- `xcode-app`:`Xcode`
- `simulator-cache`:`Simulator`
- `insomnia`:`Insomnia`
- `paw-rapi`:`Paw`
- `fork-git`:`Fork`
- `tower-git`:`Tower`
- `screenshot-app`:`Screenshot`
- `apple-maps`:`Maps`
- `apple-photos`:`Photos`
- `apple-mail`:`Mail`
- `apple-music-app`:`Music`
- `network-cache`:`NetworkCache`
- `npm-npx-cache`:`npm-npx-cache`
- `app-installation-binary-deltas`:`AppInstallationBinaryDeltas`

**不列(17 条,21 个名字)**

- `cloudkit`(medium;「iCloud Data Sync」):`CloudKit`
- `accountsd`(medium;「Apple Accounts Service」):`com.apple.accountsd`
- `akd`(medium;「Apple Key Service」):`com.apple.akd`
- `amsaccountsd`(medium;「App Store Accounts」):`com.apple.amsaccountsd`
- `appleaccountd`(medium;「Apple ID Service」):`com.apple.appleaccountd`
- `authentication-services`(medium;「Sign In with Apple」):`com.apple.AuthenticationServicesCore.AuthenticationServicesAgent`
- `cache-delete`(safe;「System Cache Manager」):`com.apple.cache_delete`
- `dataaccessd`(medium;「Contacts & Calendar Sync」):`com.apple.dataaccess.dataaccessd`
- `e5bundlecache`(safe;「Apple ML Model Cache」):`com.apple.e5rt.e5bundlecache`
- `icloud-notification-agent`(medium;「iCloud Notifications」):`com.apple.iCloudNotificationAgent`
- `itunes`(medium;「iTunes & Apple Music」):`com.apple.itunescloudd`
- `passd`(medium;「Apple Wallet Passes」):`com.apple.passd`, `PassKit`
- `safari`(safe;「Safari Browser」):`com.apple.Safari.SafeBrowsing`
- `family-circle`(medium;「Family Sharing Service」):`FamilyCircle`
- `container-managerd`(safe;「App Sandbox Manager」):`com.apple.containermanagerd`
- `1password`(medium;「1Password」):`com.1password.1password`, `1Password 7`, `1Password 8`
- `screen-time`(medium;「Screen Time」):`com.apple.ScreenTimeAgent`, `ScreenTime`

**不属于任何在办票(16 条;去向见下)**

- `macos-installer`(medium;「macOS Installer」):`macOS Installer`
- `macos-install-data`(medium;「Leftover macOS update files」):`macOS Install Data`
- `crashpad-pending`(medium;「Unsent Crash Reports」):`Unsent Crash Reports`
- `telegram-media-cache`(medium;「Telegram Media Cache」):`Telegram Media Cache`
- `cursor-agent-leftover`(medium;「Cursor Agent Leftovers」):`cursor-agent-leftover`
- `orphaned-git-worktree`(medium;「Orphaned Git Worktrees」):`orphaned-git-worktree`
- `stale-browser-framework`(medium;「Old Browser Framework」):`stale-browser-framework`
- `link-thumbnail-cache`(safe;「Link Thumbnail Cache」):`LinkThumbnail`
- `chat-media-cache`(safe;「Chat Media Cache」):`ChatMedia`
- `electron-updater-downloads`(safe;「App Update Downloads」):`Electron Updater Downloads`
- `device-software-updates`(safe;「iPhone and iPad Software Updates」):`Device Software Updates`
- `davinci-cacheclip`(safe;「DaVinci Resolve Render Cache」):`CacheClip`
- `aerial-wallpaper-videos`(medium;「Aerial Wallpaper Videos」):`Aerial Wallpaper Videos`
- `messages-previews`(safe;「Messages Previews」):`Messages Previews`
- `mail-downloads`(medium;「Mail Attachment Copies」):`Mail Downloads`
- `unfinished-downloads`(medium;「Unfinished Downloads」):`Unfinished Downloads`

合计:进知识库 179 个名字、现有规则担保 27、交给票 10 131、留给通用发现 30、不列 21、不属于任何在办票 16。

**留给后续 / 待用户**

- **待用户点头**:撤 CloudKit(默认项第 2 条)、Spotify 降「先检查」(默认项第 4 条)、Chromium / Edge 更正出处(第 9 条)——三条都是往更如实 / 更严的方向,不合意各是一行的事。
- **待用户目验**:见验收最后一条。再找一个装了第三方应用的机器(Adobe、Office、Affinity、Teams 这类),对应的缓存会带着说明出现在「可安全清理」。
- **本机长尾手写批(建议并入票 12 的起步批,或单立一小票)**:上面 28 个目录。每条要先只读看清目录里是什么、谁写的,再定档。
- **保护名单的已知缺口(未动,建议并入票 13 收口或单立一小票)**:上游按词片段拦「账号 / 认证 / 密码」类(account、icloud、appleid、authkit、authentication、authorization、identityservice、authy、yubico、inputmethod),我们只挡了带 `com.apple.` 前缀的写法和密码管理器的一部分;上游还把 `com.docker.docker` / `.helper` / `.backend` 三个缓存目录整个跳过,我们会把它们列进通用发现的「先检查」。通用发现不会自动勾,所以不是紧迫问题。
- **上游 `.shipit` 后缀规则、按目录形状认的规则**(Electron 更新器的 `pending`、还没上报的崩溃报告、旧浏览器框架、Cursor / Codex 的临时检出)不是目录名,本票没碰;账本里记为「不属于任何在办票」,留给票 10 / 12 判断。
