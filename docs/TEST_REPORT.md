# WeShot 2.0.0 测试报告

- 平台：macOS 15.2+，Apple Silicon
- 工具链：Swift 6.1，Xcode Command Line Tools
- 产物：`WeShot.app` 2.0.0（build 14）

## 自动化结果

| 门禁 | 结果 | 覆盖范围 |
|---|---:|---|
| Swift Testing | 40/40 PASS | 自定义选区、移动/缩放、快捷键、工具栏、标注、取色、翻译图层、文件输出、原始尺寸钉图与滚轮缩放、隐私规则和长图拼接 |
| 严格 Release 构建 | PASS | `-warn-concurrency -warnings-as-errors` |
| Bundle 与签名 | PASS | arm64、AppIcon.icns、Info.plist、ad-hoc 签名、严格校验 |
| 进程自测 | PASS | 几何、工具栏、标注、合成和 PNG 编码 |
| 离屏渲染 | PASS | 固定图片和编辑器布局均可生成有效 PNG |

## 系统测试范围

`scripts/test_system.sh` 在已授权且未锁屏的图形会话中覆盖：

- ScreenCaptureKit 真实桌面捕获
- 自定义选区、剪贴板跨进程读取、原子保存和钉图
- 框选区域滚动采样、实时拼接和结束流程
- 可见 Overlay、保存面板取消/确认和窗口恢复
- Carbon 快捷键事件与 HID 全局快捷键
- 系统翻译英文到中文、中文到英文
- 进程退出和残留检查

屏幕录制权限由 macOS 按 Bundle 身份管理。换机、重新签名或移动应用后，应重新授权再运行系统测试。

## 已验证产品约束

- 启动截图后默认自由框选，不自动选择全屏。
- 截图启动路径不枚举或吸附窗口边缘。
- 钉图默认保持截图尺寸，并支持滚轮缩放。
- 长截图只采集选区，单帧也可完成。
- 翻译结果直接进入原图半透明图层，不打开结果窗口。
- 工具栏不包含独立文字识别、系统分享或演示入口。
- 真实桌面内容和测试生成物不进入源码仓库。

## 2026-11-05 截图延迟与长图冲突复验

上文是原版本报告，保留其历史记录；其中的 `40/40 PASS` 不代表本次重跑。本次环境为 macOS 15.8.1、Apple Silicon、Swift 6.2.3 Command Line Tools。

### 原因与修改

- 截图原来逐屏串行取图，全部完成后才显示选区。本次改为显示器绑定截图、多屏并发取图，并在启动时预热显示器元数据；失败时刷新元数据重试，普通截图保留 rect API 回退。没有常驻录屏流或屏幕图像缓存。
- 原长图采集每帧枚举显示器并捕获整屏后裁剪，与原报告的“只采集选区”不符。本次复用显示器 filter，通过 `SCStreamConfiguration.sourceRect` 直接请求选区。
- 旧算法把完全无重叠的白底文字图误接受为 48 像素重叠，误差为 2.8333；固定页脚样例的结果与正确图有 1,533 个通道差异。另一个带轻微噪声的周期样例，真实重叠为 125 像素，旧判断误选 21 像素。
- 新匹配同时限制整区误差和内容边缘误差；候选得分相差不超过一个 8 位通道等级时拒绝选择。增量拼接使用上一张已接受的原始视口定位，接缝替换旧固定页脚。失败保留当前图，并提示返回中断位置继续。

### 微信 REA 证据与边界

目标为本机微信 4.2.0。REA 识别出主程序是加载入口，随后定位到 `Contents/Resources/wechat.dylib`，SHA-256 为 `8180e3d032ca7e5e5136a17d117370143aae562686d37eec26af8215b3970cc2`。

- 包内字符串与元数据包含 `weshot::ScreenShoter`、`weshot::LongScreenShoter`、`SCScreenshotManager`，以及截图中断后返回中断位置继续的界面提示。这些是静态观察，不是运行时调用证据。
- 相邻 ARM64 `ADRP+ADD` 引用及局部反汇编复核了类型名称的代码引用；未恢复长图匹配算法、阈值或截图触发耗时。当前没有可用的 Hopper、Ghidra 或 IDA 深度分析引擎，未自动安装。
- 证据包：`work/rea/wechat-4.2.0-evidence.json`。主要记录为 `ev_cdce7894e604e1d4d81d8e6e41a33b2cc0d0103595dbdd8e7a28182f9b2e7771`（主程序结构）、`ev_be2add4eec8d16858702f62b85899d2cc79a892128f02e7898f540efdd199247`（包内字符串）、`ev_348f4424b4e8ff0116ef1f69e5ed30a636066e9c94c34ec71a8865a0d62b6235`（相邻指令引用复核）、`ev_bccdb894a935166a37d9e7847ceebd384a060e822137386f0404501af9a5c50c`（类型附近的元数据）。早期跨指令候选存在寄存器覆盖，已排除，不据此推断调用链。

本次算法修改依据本项目的失败复现与像素对照，不声称复刻了微信算法。

### 本次执行结果

| 命令 | 结果 |
|---|---|
| `swift test --disable-sandbox` | 环境阻断：现有测试在 `import Testing` 报 `no such module 'Testing'`；完整套件未运行 |
| `swiftc -O work/scroll-core-check/main.swift -o work/scroll-core-check/check`；`work/scroll-core-check/check` | 17/17 断言通过；使用当前 Core 源码及 13 项回归、4 项既有拼接测试，转换测试宏后执行，不等同于完整 Swift Testing 套件 |
| `swift build --disable-sandbox -c release --product WeShot -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors` | PASS |
| `WESHOT_DISABLE_SWIFTPM_SANDBOX=1 ./scripts/build_app.sh release` | PASS，生成 `build/WeShot.app` |
| `build/WeShot.app/Contents/MacOS/WeShot --self-test` | PASS，含选区坐标及非法几何检查 |
| `build/WeShot.app/Contents/MacOS/WeShot --render-fixture work/weshot-fixture.png` | PASS，920×540 |
| `build/WeShot.app/Contents/MacOS/WeShot --render-editor-fixture work/weshot-editor-fixture.png` | PASS，2560×1440，已目视核对选区、标注和工具栏 |
| `codesign --verify --strict --verbose=2 build/WeShot.app`；`plutil -lint build/WeShot.app/Contents/Info.plist` | PASS |
| `build/WeShot.app/Contents/MacOS/WeShot --permission-status`；`--capture-smoke work/capture-smoke.png` | 未获屏幕录制权限；真实捕获冒烟按预期拒绝执行 |
| `git diff --check` | PASS |

原始复现、修后断言与合成性能结果保留在 `work/scroll-core-check/`，不进入源码提交。1200×1400、滚动 300 像素的单个合成样例中，核心匹配耗时从约 42.3 ms 增至 94.7 ms；这是更严格校验的成本，不是热键或屏幕采集耗时。

### 尚未验收

- 未运行 `scripts/test_system.sh`：当前执行环境没有屏幕录制权限，不能验证单屏/多屏触发延迟、真实选区捕获、滚动和物理快捷键。现有捕获冒烟已加入 display/rect 各两次计时；物理快捷键冒烟已加入取图与建立覆盖层的分段计时。
- 未承诺“一秒卡顿已消除”。普通截图的主要取图路径已调整，实际收益需要在已授权图形会话中测量。
- 固定边缘只识别每侧不超过视口四分之一、两帧同位置像素不变的区域。更大的固定面板、动画、快速滚动或重复内容可能被拒绝；已有长图会保留。

## 2026-11-05 其余截图功能对照

结论：当前工具不是微信截图的 1:1 实现。部分范围由现有 SPEC 明确排除；其余同名工具也没有完成逐事件、逐像素的微信运行时对照。不能根据按钮名称或元数据计算“对齐率”。

本轮通过 REA 受控离线探针，按 Qt5 字符串表的引用计数、长度、相对偏移和终止符校验，在同一 ARM64 `wechat.dylib` 中解析出 16 个 `weshot` 类型的表。该探针由本次调查编写，不是反编译器恢复的源码。完整原始终端输出已保留；首次结果仅终端呈现副本被截断，后续定向结果没有截断。

证据：`work/rea/wechat-feature-evidence.json`，定向记录 `ev_1ffdfd3f7dbf6cb7121e6fb690bbf51a6e9d0e429e191dcb2e349c31dfc6fa6b`；解析产物 `work/rea/wechat-feature-tables.json`；可复跑探针 `work/rea/wechat-qt-tables.py`。本轮重新核对的载体 SHA-256 与上一轮相同。

| 对照项 | 微信静态证据 | WeShot 当前实现与判断 |
|---|---|---|
| 选区与多屏 | `ScreenShoter` 表含 `UpdateDPI`、`UpdateGeometry`、`VirtualGeometry`、`createItem`、`finishItem` | 自由框选、八点缩放、多屏坐标。窗口吸附属于 SPEC 非目标；微信的具体命中与缩放规则尚未恢复 |
| 图形与样式 | 编辑菜单/子菜单表含 `graphChanged`、`penChanged`、`fontChanged`、`fillChanged` | 矩形、椭圆、箭头、画笔及颜色/线宽；形状只描边，文字字号依赖线宽，未提供独立字体/填充控制。接口范围不同，微信实际呈现未验 |
| 表情 | `emoticonSelected` 参数类型为 `std::shared_ptr<mmui::EmoticonWrap>` | Unicode 表情作为文字标注，未实现微信表情对象；具体素材、缩放、动画行为未知 |
| 文字编辑与撤销 | `canUndo`、`undo`、键盘事件处理名称 | 当前为单次创建标注、按创建顺序撤销；未验证微信已建对象的再次选择、移动、文字再编辑与撤销粒度 |
| 马赛克与隐私 | `aimosaic_enter/leave`、`AiMosaicButton` | 原图采样马赛克，另有本地 Vision 隐私检测方法；尚未验证与微信算法相同，保留现有原图采样规范 |
| 翻译与 OCR | `translate_image`、`gen_pixmap_file_translate`、`OpenOcrPreview` | Vision + macOS Translation，整区译文图层，中英方向自动选择；独立 OCR 预览被 SPEC 排除。不能声称译文布局和语言策略相同 |
| 长截图完成 | 长图菜单表含 `signal_edit/save/close/copy`；另有 `GrabWorker`、`OpenCVWorker`、`SpliceWorker` 表 | 选区采集、后台匹配、实时预览；现有完成行为直接复制退出，没有长图编辑/保存菜单。元数据表不能证明微信内部匹配阈值 |
| 保存与剪贴板 | `save`、`copy`、`QMimeData`、`gen_pixmap_file` | 原子 PNG 保存，PNG/TIFF 剪贴板；微信具体文件格式、色彩空间、剪贴板类型未验证 |
| 钉图 | `pin`、`pinData` | 原尺寸、滚轮缩放、拖动、双击关闭；微信缩放锚点、菜单、透明度、快捷键尚未实测 |
| 完成/取消/双击 | `handle_keyboard_escape/enter/return`、`handle_mouse_dbclick` | Return/小键盘 Enter 完成、Esc 取消、选择工具内双击完成；文字输入中的按键路由需单独验证，不能由名称推断相同 |
| 分享/二维码/AI | `share`、`qrcode`、`handle_qr_code_result`、`ask_ai` | 没有对应入口；分享为 SPEC 非目标，其余未实现。本轮没有据此扩展功能 |

上述“微信静态证据”只说明包中存在相应类型或接口名称，不保证当前账户、平台设置下可见，也不证明端到端行为。当前仍没有深度反编译引擎或微信截图运行时回放证据；原生交互与像素级 1:1 验收保持未完成。

### 本轮已有功能修复与复验

- 文字取消：修复前，在实际 AppKit field editor 执行 `cancelOperation:` 后输入框仍在，随后点击会把草稿提交。现在通过文本控件委托处理取消；先清编辑状态再移除控件，并校验结束编辑通知的输入框身份。切换活动选区会取消草稿。自然 Return 原来即只提交一次，没有把重复提交记为已复现故障。
- 画笔：修复单击被丢弃、单点无法绘制，以及鼠标松开最终位置未进入笔迹的问题；保留撤销与选区裁剪语义，单点绘制沿用 Core 已有圆点处理。
- 钉图：超高长图围绕窗口中心缩小时会完全离屏。现在围绕滚轮事件的鼠标位置缩放，保留原尺寸上下限和比例。实际窗口测试中，旧结果与屏幕无交集；修后仍可见，鼠标所指图片位置误移小于 1 点。

| 命令/检查 | 结果与边界 |
|---|---|
| `swift build --disable-sandbox --product WeShot -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors` | 严格 Debug 构建 PASS |
| `work/editor-probes/editor-regression` | 4 用例、14 断言 PASS。由新增测试文件去除 Testing 宏后链接当前 App 对象，实际 AppKit 指令及构造事件执行 |
| `work/pin-zoom-check/regression` | 2/2 PASS，包含超高图、负坐标副屏和缩放锚点 |
| `work/pin-zoom-check/after` | 实际窗口滚轮方法 PASS，锚点位移 x=0.50、y≈0.87 点，包含 AppKit 窗口取整 |
| `swift build --disable-sandbox -c release --product WeShot -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors` | 最终严格 Release 构建 PASS |
| `WESHOT_DISABLE_SWIFTPM_SANDBOX=1 ./scripts/build_app.sh release` | 最终应用包生成、签名和 Info.plist 校验 PASS |
| `build/WeShot.app/Contents/MacOS/WeShot --self-test`；`--render-fixture work/weshot-fixture.png`；`--render-editor-fixture work/weshot-editor-fixture.png` | 最终应用自测及两种离屏渲染均 PASS |
| `git diff --check` | PASS |

新增测试位于 `Tests/WeShotAppTests/EditorInteractionRegressionTests.swift` 与 `PinZoomRegressionTests.swift`；修复前后探针、runner 源码和结果保留在 `work/editor-probes/` 与 `work/pin-zoom-check/`。这些是本工具的回归验证，不是微信行为对照。完整 Swift Testing 套件仍受前述 Testing 模块缺失阻断；真实物理键鼠、中文输入法和微信运行时尚未复验。马赛克仍按原 SPEC 从原图采样，没有为追求未经证实的一致性改变该语义。

## 2026-11-05 DMG 交付与清理

- 按当前 `Resources/Info.plist` 打包为 WeShot 2.0.1（build 15），Apple Silicon、macOS 15.2+。产物为 `build/WeShot-2.0.1-arm64.dmg`，691,410 字节；同目录保留 SHA-256 校验文件及可运行的 `WeShot.app`。
- DMG 仅包含 `WeShot.app`、指向 `/Applications` 的快捷入口及 MIT 许可证。临时打包目录已移除。
- 严格 Release 构建及 `scripts/build_app.sh release` 通过；`hdiutil verify build/WeShot-2.0.1-arm64.dmg` 通过；只读挂载后逐文件哈希与原应用一致，`codesign --verify --strict` 及包内应用 `--self-test` 通过，随后成功卸载。
- 清理 `.build/`、图标中间文件及 `work/` 下已识别的 Mach-O 调试可执行文件，释放约 868.7 MiB。源码、测试、探针源码、REA 证据、结果日志和验证图片保留。前文 runner 命令需要先重新编译对应可执行文件再运行。
- 应用为本地 ad-hoc 签名，未做 Developer ID 签名或 Apple 公证；未替换已安装应用、未提交或推送。此前完整测试套件与真实截图验收的限制保持有效。

## 2026-11-05 更新后反复请求录制权限

已确认根因：正在运行的进程位于 `/Applications/WeShot.app/Contents/MacOS/WeShot`，版本 2.0.1，使用 ad-hoc 签名，其 designated requirement 仅绑定本次构建的代码指纹。系统 TCC 日志明确返回 `Failed to match existing code requirement`，服务为 `kTCCServiceScreenCapture`；旧授权指纹为 `05d3742895acccd5a9dc5da2dacd653ae7a6aa3f`，当前指纹为 `0c724f3cf2d81fbcdfffdad8b53b4255b1ce92a3`。这解释了设置中已开启但当前版本仍被拒绝的现象。应用专属日志保留在 `work/permission-fix/tcc.log`。Apple 对这种更新后授权失效的原因也有[技术支持确认](https://developer.apple.com/forums/thread/819406)。

本轮修改：

- Release 应用包必须通过 `WESHOT_SIGNING_IDENTITY` 选择固定的代码签名证书；不指定时在构建前失败。只有显式设置 `WESHOT_ALLOW_ADHOC=1` 的本地验证才允许临时签名，不承诺跨版本保留授权。离屏测试脚本显式选择该测试模式；真实系统测试仍默认要求固定身份。
- 截图入口在一次进程生命周期中最多主动请求一次系统授权，并直接处理请求成功的返回值。再次触发仅复查状态，不重复调用系统授权请求；重新检测失败时说明当前副本、重启和身份变化的区别。
- 权限窗口及中英文构建说明同步更新。没有通过更改标识符、放宽签名要求、清空权限记录或修改系统权限数据库绕过授权。

验证：`zsh -n scripts/build_app.sh scripts/test_all.sh scripts/test_system.sh`、`git diff --check` 通过；未提供证书的 Release 打包拒绝检查通过；从当前截图入口提取的真实权限分支以模拟系统返回值执行，拒绝后重复触发、设置授权后重试、请求直接成功三个场景均通过。检查源码与结果位于 `work/permission-fix/`。严格 Release 编译通过。

现场只读查询 `security find-identity -v -p codesigning` 返回 0 个有效身份。稳定证书尚未配置，因而没有生成或安装新签名包，也没有验证真实授权跨版本保留。迁移到固定身份后仍可能需要授权一次；不能将本轮的请求次数限制称为已经解决跨版本授权问题。

## 2026-11-05 固定签名配置与 2.0.2 更新包

本节 supersedes 上节“稳定证书尚未配置”的状态。用户明确授权创建固定本地签名证书、配置后续复用并重新打包；未授权自动替换正在运行的安装版，因此安装版未变更。

- 固定身份：`WeShot Local Code Signing`，证书及私钥保存在登录钥匙串。证书有效期至 2036-11-02，RSA 3072 位，CA=FALSE，关键用途仅 Digital Signature / Code Signing；信任设置只写入用户域的代码签名策略，没有配置 SSL 或系统域信任。
- 项目只保留公开证书 `Resources/WeShotSigning.cer`。SHA-1 身份指纹为 `FA413A3E265DB375B5CC830BAAFA3905E31EC600`。临时私钥和加密导入容器已随临时目录清除；私钥没有放进源码或 DMG。
- `scripts/build_app.sh` 默认由公开证书指纹选择钥匙串签名身份，并验证 Bundle ID 与实际叶证书；缺少该身份会失败，不自动生成替代证书。显式临时签名只保留给本地测试。
- 新增 `scripts/build_dmg.sh`：构建后再次检查固定身份，签署 DMG、验证镜像并生成 SHA-256。即使调用方显式选择临时签名，也无法通过更新包检查。同版本 DMG 存在时拒绝覆盖。
- 本次更新为 2.0.2（build 16），supersedes 2.0.1 临时签名交付；原 DMG 保留。新包：`build/WeShot-2.0.2-arm64.dmg`，696,051 字节；SHA-256 为 `a61ae2180c4d130dfdba34e7c9fa54c637365bcdf105569a77f9a94a175a989a`。

| 命令/检查 | 结果 |
|---|---|
| `security find-identity -v -p codesigning` | 固定身份可用，指纹与项目公开证书一致 |
| `WESHOT_DISABLE_SWIFTPM_SANDBOX=1 ./scripts/build_app.sh release` | 默认选择固定证书，构建、签名及证书约束验证 PASS |
| `WESHOT_DISABLE_SWIFTPM_SANDBOX=1 ./scripts/build_dmg.sh` | 应用与 DMG 固定签名、镜像校验 PASS |
| `python3 work/signing-check/verify_identity.py` | 跨版本身份及拒绝临时签名包检查 PASS。临时副本改为 2.0.3/build 17 后，代码指纹由 `0c149507d7040ef288d31355ec6dc010436d751c` 改为 `a47f610cf9bfd191afcad03493323099a74a9665`，但 designated requirement 完全相同。该副本仅用于检查，未发布 |
| 只读挂载 DMG，逐文件哈希对照原 App；`codesign --verify --strict -R` 验证包内 App 和 DMG 的固定证书；包内 `--self-test` | 全部 PASS；镜像已成功卸载 |
| `zsh -n scripts/build_app.sh scripts/build_dmg.sh`；`git diff --check` | PASS |

签名要求已从逐构建的 cdhash 改为 Bundle ID + 固定证书指纹。验证结果保留于 `work/signing-check/results.json` 与 `dmg-results.json`。这验证了跨版本身份稳定，不等同于已完成真实 TCC 授权后的更新回放；首次从临时签名迁移仍可能需要重新授权一次。本地签名不属于 Apple Developer ID 或 Apple 公证，其他 Mac 的首次安装信任也不由本次配置保证。请保留登录钥匙串中的签名身份；换机前由用户通过钥匙串访问备份该身份。

## 2026-11-05 旧授权迁移后的现场恢复验证

用户安装 2.0.2 并开启权限后仍被拦截。再次核对时，安装版已匹配固定证书，但系统日志仍拿最初的 `05d374...` 临时代码指纹与固定证书要求比较。该问题为旧授权记录未迁移，不是证书再次变化。

用户明确确认“允许，仅修复 WeShot 旧授权”后，以当前用户执行 `tccutil reset ScreenCapture local.codex.WeShot`，返回成功；只重置该 Bundle ID 的录屏服务，没有重置 All 或其他应用。随后重启安装版、通过 `--capture-now` 正常入口重新发起请求。用户确认已开启并重新打开。

验证特意通过 LaunchServices 正常启动安装版：直接在 Codex 后台执行 `WeShot --permission-status` 时，TCC 日志将 responsible process 归为 `com.openai.codex`，此时的 NOT_GRANTED 不能代表独立启动的 WeShot，不能据此继续要求用户重置权限。

| 检查 | 现场结果 |
|---|---|
| `codesign --verify --strict -R`，验证 `/Applications/WeShot.app` 的 Bundle ID 与固定证书 | PASS，仍为 2.0.2、固定证书身份 |
| `open -n -g -W -a /Applications/WeShot.app --stdout ... --stderr ... --args --capture-smoke <临时 PNG>` | PASS，2 个显示器、返回 2560×1440 图像；本次全部屏幕取图 56.0 ms，不代表通用延迟承诺 |
| 正常启动独立安装版验证实例 `--capture-now`，运行 `work/permission-fix/overlay-window-check <PID>` | PASS，2 个显示器对应 2 个实际可见 screenSaver 级覆盖层；仅查询该 PID 的窗口元数据，没有保存覆盖层截图 |
| 验证实例清理 | PASS，仅关闭测试实例，原用户实例保留运行；捕获检查的临时桌面图已随私有目录删除 |

实际捕获结果见 `work/permission-fix/live-capture-result.json`，覆盖层结果见 `overlay-window-result.json`，新旧授权日志见同目录 `fixed-signer-stale-grant.log`、`migration-after-reset.log`、`authorized-verification.log`。当前安装版的权限拦截已恢复验证；未运行完整 `test_system.sh`，未把本次检查扩大为所有功能验收，也未实际安装下一版本做授权保留回放。

## 2026-11-06 提交前检查与清理

重写中文首页和英文 README，中文旧入口保留跳转；同步 2.0.2 更新日志和规范中的版本、增量拼接描述。公开签名证书经 `openssl x509 -inform DER -outform DER` 重新编码后与原文件逐字节一致，不含附加数据；证书和构建脚本可以提交，私钥仍留在登录钥匙串。新增 `*.key`、`*.pem`、`*.p12`、`*.pfx` 忽略规则；这些规则不能替代提交内容检查。

提交前严格 Release 构建及程序 `--self-test` 通过；脚本 `zsh -n`、README 本地链接、证书与敏感格式忽略检查、`git diff --check` 均通过。此前的完整 Testing 模块限制保持原记录，本轮没有重跑完整测试套件或操作系统权限。

删除可再生成的 `.build/`、剩余验证可执行文件和本轮创建的临时 REA 二进制副本/脚本，清理约 445.7 MiB。正式源码、回归测试、探针源码、REA 证据、结果日志以及 2.0.2 DMG 与校验文件保留；`build/` 和 `work/` 不进入源码提交。
