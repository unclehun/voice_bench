# 语音识别对比 Demo 实施方案：本机免 Xcode、免费侧载、兼容旧设备

日期：2026-09-24。修订：v2，要求同一台设备真实支持两套指定 ASR。状态：本地工程与核心功能已实现，并已完成本机可执行检查；云端 iOS 编译、IPA 与真机验证待执行。当前实现与验证边界见 README.md 和 docs/VALIDATION.md。

本方案依据《语音转写Demo技术方案.md》分析，但以本次需求为准。本次重新确认两套指定 ASR 都必须可用，因此保留附件的最低 iOS 26；“默认开启 LLM 纠错”“使用 Instruments”仍按本次低环境要求调整。用户已确认：允许云端使用 Xcode，本机不安装；没有付费 Apple Developer 账号，优先免费安装。

## 1. 推荐决策

采用 **Swift + SwiftUI 原生 App，最低 iOS 26.0；GitHub Actions 云端编译；Mac 上使用 Sideloadly 和免费 Apple 账号签名安装**。

首轮在用户提供的 iPhone 17 Pro / iOS 27 上比较：

- A：SenseVoiceSmall INT8 + sherpa-onnx，手机 CPU 本地推理。
- B：Apple SpeechAnalyzer + SpeechTranscriber，苹果系统本地推理。

本轮仅实现这两套 ASR，不接入 SFSpeechRecognizer 或 DictationTranscriber 替代 B。兼容旧设备的范围限定为能够运行 iOS 26+ 且实际支持 SpeechTranscriber 的设备。两引擎在同一 App 中可分别运行，也可依次运行；不需要并发推理。Apple Foundation Models 纠错放到第二阶段，默认关闭，不成为安装或语音转写的前置条件。

开发与使用链路：

```text
现有 Mac：编辑 Swift / Git 提交
          ↓
GitHub Actions：macOS + Xcode → 编译 arm64 Release → 未签名 IPA
          ↓ 下载
现有 Mac：Sideloadly + 免费 Apple 账号 → 签名、USB 安装
          ↓
iPhone：准备模型 → 录音或导入 → 离线转写 → 导出比较报告
```

云端只参与构建。录音、参考稿、转写及纠错在手机内处理，不需要 ASR 服务器。免费侧载有续签周期，不能承诺一次安装永久使用。

## 2. 本机实测环境与影响

| 项目 | 检查结果 | 对方案的影响 |
|---|---|---|
| 电脑 | MacBook Pro，M1 Pro，16GB，arm64 | 足够编辑、处理音频和管理构建产物 |
| 系统 | macOS 13.7.8 | 不为本项目要求升级系统 |
| Apple 工具链 | Command Line Tools；Swift 5.8.1 | 不能编译新版苹果语音和 Foundation Models |
| SDK | 只有 macOS SDK；`xcrun --sdk iphoneos --show-sdk-path` 失败 | 当前不能本机生成 iPhone App |
| Git | 2.39.2 | 可以直接管理代码和推送 |
| Flutter | 缓存版本 3.32.5 / Dart 3.8.1 | 已安装，但 iOS 原生插件仍需云端 Xcode |
| 其他运行时 | Node 18.14.2、Python 3.14.4、.NET SDK 10.0.103 | 不作为手机 App 或构建的必要依赖 |
| 安装工具 | 未发现 Sideloadly、AltServer、Apple Configurator | 主路线需新增 Sideloadly |
| 项目目录 | 原为空目录，尚无 Git 仓库 | 没有需要迁移的既有代码 |
| 手机 | 型号和系统来自用户；本轮未建立真机连接 | 可用性、签名、速度及内存均待真机实测 |

没有选择 Flutter、React Native 或 .NET MAUI，是因为这个 Demo 的关键工作都在原生音频和苹果专用 API。跨平台框架会增加桥接、运行时及版本维护，并不能免去 iOS 构建工具链。后续 Android 项目可复用模型、配置、报告格式与测试录音，不必先复用 UI。

PWA 可以做录音和页面展示，但无法提供与原生 SpeechTranscriber、Foundation Models 等价的直接调用与评测控制；Web Speech 也不能保证使用指定苹果离线模型。因此不把网页作为本轮两方案验证 App。

## 3. 两套引擎共同要求的最低系统

**本 Demo 的最低系统设为 iOS 26.0（`IPHONEOS_DEPLOYMENT_TARGET=26.0`）。**

此前的 iOS 15 方案允许旧设备仅运行 SenseVoice 或改用旧苹果引擎，不能满足现在明确的“两套指定 ASR 都能真实运行”。把新 API 放在版本判断中，只能让 App 在旧系统启动，不能让旧系统获得 SpeechTranscriber。

| 项目 | 系统要求 | 对本 Demo 的影响 |
|---|---|---|
| SenseVoiceSmall INT8 + 候选 sherpa-onnx v1.13.8 Swift Package | 包声明最低 iOS 15 | 不构成两引擎组合的更高下限；仍需校验二进制依赖 |
| SpeechAnalyzer + SpeechTranscriber | iOS 26.0 起提供 | 决定共同最低系统为 iOS 26.0 |
| 两套引擎均真实可用 | iOS 26.0+，且硬件、语言、模型就绪 | 系统版本是必要条件，不是充分条件 |
| 可选 Foundation Models 纠错 | iOS 26+，另受 Apple Intelligence 可用条件限制 | 独立检测，不影响两套 ASR 的准入条件 |

依据：[Apple SpeechAnalyzer / SpeechTranscriber 官方介绍](https://developer.apple.com/videos/play/wwdc2025/277/)、[sherpa-onnx 固定版本 Package.swift](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.8/Package.swift)。

### 系统与硬件分别验收

iOS 26 可以安装到某台旧 iPhone，不代表 SpeechTranscriber 一定支持该硬件。Apple 为模块提供 `SpeechTranscriber.isAvailable` 检查设备硬件和能力；还需查询支持的 locale 并准备语音资源。不能只凭系统号，或将 Apple Intelligence 的硬件名单当作 SpeechTranscriber 名单。[Apple isAvailable 文档](https://developer.apple.com/documentation/speech/speechtranscriber/isavailable)

进入正式 A/B 评测前必须满足：

1. 运行 iOS 26.0 或更高版本。
2. `SpeechTranscriber.isAvailable == true`。
3. API 返回支持目标中文 locale，并已完成对应系统语音资源准备。
4. SenseVoice 模型完整，识别器可成功初始化。
5. 两套引擎都实际完成同一条中文音频的离线转写。

资源尚未下载时显示准备步骤；硬件或中文不支持时显示具体原因，该设备不计为完成双引擎验收。可以保留录音、导出和单引擎诊断入口，但不能以其成功冒充两套方案都可用。

### 设备与系统测试范围

- 主测试机：用户的 iPhone 17 Pro / iOS 27，系统版本满足要求；执行以上全部能力与离线测试。
- 旧机测试：从已经运行 iOS 26+ 的旧 iPhone 中借用一台，先运行能力检查，通过后才列入双引擎兼容清单。此次查询没有据以承诺完整最低机型名单，不把未经验证的机型写成保证支持。
- 最低系统验证：尽量取得运行 iOS 26.0 的真机；只有 iOS 27 真机时，iOS 26.0 只能标为部署目标，实际最低已测系统仍是 iOS 27。
- iOS 18 及更早版本不列入本 Demo 的双引擎支持范围。无需为本 Demo 使用 iOS 27 专属 API，也无需强制所有测试机升级到 iOS 27。

不要求为了测试降级现有手机。模拟器可检查 UI 和基础逻辑，不能证明真机上的语音模型、准确率和资源占用。

## 4. 免费构建、签名和安装

### 云端构建

首选 GitHub Actions 标准 `macos-15` runner，显式设置 `DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer`。查询时该镜像包含 Xcode 26.3 / iOS 26.2 SDK。所用新 API 起始于 iOS 26，先用该稳定工具链验证在 iOS 27 上的运行，不为手机系统版本机械追随最新 SDK。[GitHub 镜像清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md)

CI 首步验证 Xcode 路径、版本和 SDK，记录 runner 镜像版本；路径消失时明确失败，不能静默使用默认 Xcode。若实际遇到只能使用新版 SDK 修复的问题，再切换提供相应正式版的 runner。runner 标签会更新，不把镜像视为不可变环境。

工程使用固定版本 XcodeGen 从 `project.yml` 生成，或提交生成后的工程；生成器仅在云端运行。本机无需 XcodeGen、CocoaPods、Fastlane 或 Ruby 工具链更新。

流水线工作：

1. 检出代码、校验工具链。
2. 生成工程、校验固定的 iOS XCFramework；核心逻辑以本地 Swift Package 引用。
3. 执行纯逻辑测试及可用的模拟器基础检查。
4. 为真机 `arm64` 编译 Release，关闭本次编译的签名要求。
5. 从完整 `.app` 构建 `Payload/VoiceBench.app`，打包未签名 IPA；检查必要 Swift 运行库、资源及二进制最低系统版本。
6. 导出 IPA、符号文件、构建日志、依赖清单与 SHA-256；artifact 只短期保留。

工程已经创建。下面的核心构建命令须在具备完整 Xcode 的构建机执行；本轮尚未执行 iOS 构建：

```sh
export DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
xcodebuild \
  -project VoiceBench.xcodeproj \
  -scheme VoiceBench \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  IPHONEOS_DEPLOYMENT_TARGET=26.0 \
  CODE_SIGNING_ALLOWED=NO \
  build
```

**未签名 IPA 不能直接在手机上点击安装，也不能直接提交 TestFlight。**本方案由本机侧载工具完成签名，不在 CI 放 Apple 账号密码，不依赖付费团队证书或 App Store Connect。

### 费用边界

私有仓库可使用账号所含 Actions 免费额度，但 macOS 计算、artifact 和缓存都有额度约束。建议先用私有仓库、按需触发、限制并发、短期保留产物，控制在免费额度内。公开仓库的标准托管 runner 有免费政策，但公开源码应另行决定。[GitHub Actions 计费说明](https://docs.github.com/en/billing/concepts/product-billing/github-actions)

SenseVoice 权重不提交 Git，也不打进每次 IPA，减少构建下载、artifact 存储及每周续签负担。

### 本机安装步骤

1. 从 Sideloadly 官网安装 Mac 版本；官网当前标明 macOS 10.12+，本机 13.7.8 满足其声明要求。
2. USB 连接并解锁 iPhone，在手机确认信任此电脑，检查 Finder / Sideloadly 能否识别。
3. 下载云端 IPA，拖入 Sideloadly，使用自己的免费 Apple 账号完成登录和双重认证。
4. 按系统提示信任开发者，在 iOS 27 的“隐私与安全性”中开启开发者模式并完成重启确认。
5. 打开 App，授予麦克风权限，按两套引擎的实际 API 要求配置权限并检查模型资源。
6. 以后使用相同账号、相同最终 Bundle ID 覆盖安装。不要先卸载，以免清除录音、结果和模型。
7. 在有效期结束前续签；初期使用 USB 手动续签，成功后再配置 Wi-Fi 自动刷新。

免费账号通常有 7 天签名有效期和同时安装 3 个侧载 App 的限制。自动刷新需要 Mac、工具与手机连接条件满足，并非永久免维护。[Apple 免费开发账号限制](https://developer.apple.com/help/account/basics/about-your-developer-account)、[Sideloadly 安装与续签说明](https://sideloadly.io/faq.html)

Sideloadly 官网声明支持 iOS 26+，这不等于本轮已证实“macOS 13.7.8 + iPhone 17 Pro + iOS 27”组合。**先做最小验证包实际安装**，记录成功版本或完整错误；如涉及旧 Mac 配对支持，先按系统提供的设备支持更新排查，不默认要求安装 Xcode。[Sideloadly 官网](https://sideloadly.io/)

如 Sideloadly 不能完成，可尝试 AltServer / AltStore Classic；其 Mac 安装文档要求 macOS 11+，但同样要实测 iOS 27，且 AltStore 本身占用侧载名额。两个工具都失败时，安装链路应记录为阻塞，不能交付 IPA 后声称真机可运行。[AltStore 安装文档](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos)

## 5. App 实现范围与技术细节

### 工程结构与能力检查

```text
VoiceBench/
  App/                    SwiftUI 页面与状态管理
  Audio/                  录音、导入、播放、流式解码与哈希
  Engines/
    SenseVoiceEngine      A
    AppleModernEngine     B，iOS 26+
  Correction/             可选 Foundation Models，iOS 26+
  Evaluation/             CER、规范化、diff
  Storage/                音频、配置、运行结果与报告
  Diagnostics/            能力检查、阶段日志、错误导出
Tests/                    确定性逻辑和边界测试
.github/workflows/        云端构建
project.yml
```

工程与 App 的最低部署版本统一为 iOS 26.0，不再维护 iOS 15 的 API 隔离和旧引擎分支。仍保留 SpeechTranscriber 的硬件 / locale / 资源检查，以及 Foundation Models 的独立可用性检查；如果使用 26.0 之后新增的 API，需要额外版本保护。

UI 使用 iOS 26.0 可用的 SwiftUI API；持久化继续采用简单文件存储，分享使用系统分享面板。避免引入不必要的第三方 UI / 数据库依赖，不以 Apple Intelligence 启用状态限制 App 安装或两套 ASR 使用。

### 第一阶段必须具备

- 一页完成录音 / 停止、M4A/WAV 导入、播放、选择引擎、取消、查看结果、输入参考稿和导出。
- 先保存源音频，再转写；引擎共用同一文件和 SHA-256。
- 运行状态和失败原因可导出；已经完成的结果落盘。
- 每条结果显示实际引擎 ID：`sensevoice_int8`、`apple_speechtranscriber`。
- A/B 比较固定为 SenseVoiceSmall INT8 与 SpeechTranscriber；任何一套不可用时记录原因，不替换成其他引擎，不计为双引擎验收通过。
- 全部推理串行；录音完成后异步处理。前台可靠运行，后台中断有明确状态。

### SenseVoice 接入

实现锁定 sherpa-onnx v1.13.8 与 ONNX Runtime 1.28.2 的静态 iOS XCFramework，版本、下载 URL 和 SHA-256 保存在 config/dependencies.json。核查发现上游 ONNX Runtime 1.28.2 的 Swift Package 引用 1.28.1 二进制，因此直接使用与 sherpa 构建配置一致的 1.28.2 二进制。候选版本需通过云端构建及 iOS 26+ 真机启动后才称为已验证版本；检查全部传递依赖和 Mach-O 的最低 OS，不能只相信 App 配置。[sherpa-onnx 发布版本](https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.13.8)

模型使用附件指定的 `sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17`，包含 `model.int8.onnx`、`tokens.txt`，另配 `silero_vad.onnx`。首版选“从文件导入”，可在 Mac 下载解压后通过 AirDrop / 文件 App 导入，避免先做下载管理器。复制到 Application Support 并排除模型的备份，校验文件、版本、哈希及许可证。模型约 228MiB，不等于运行时内存。[模型与配置来源](https://k2-fsa.github.io/sherpa/onnx/sense-voice/pretrained.html)

初始参数沿用附件：16kHz 单声道 PCM、80 维特征、CPU、2 线程、ITN 开启、语言 auto；提供固定 zh 的单独实验配置。不加入未经验证的热词功能。

流式解码 → VAD → 逐段识别 → 拼接。先用约 25 秒上限和约 200ms 边界保护，保留分段及去重前输出。低内存模式可改为 1 线程、更短片段，但记录差异，不能将不同配置混为同一性能结果。禁止展开整段长音频到内存。

原生推理调用未必能中途抢占；至少在段间检查取消。若只能等当前片段完成，UI 显示“正在结束当前片段”，不承诺瞬间停止。

### 苹果现代引擎

按顺序检查 OS、`SpeechTranscriber.isAvailable`、受支持中文 locale、AssetInventory 资源；资源就绪后才开始计时转写。输入格式依据 API 查询转换，完整消费最终结果并正确结束输入，避免尾句丢失。

可用性与 Apple Intelligence 分开判断。记录 locale、OS build、日期；模型版本无法查询时写 `system-managed/unknown`。首版坚持使用附件指定的 SpeechTranscriber，不因 iOS 27 新增其他系统功能而默默替换实验对象。

### 第二阶段：可选 LLM 纠错

沿用附件的独立纠错设计：ASR 原文先落盘，人工参考稿永不进入 LLM；每个引擎独立会话、相同提示和词条；原文和纠错后文本分开保存。分块失败、不可用和取消不影响 ASR 成果；跳过时结果及纠错 CER 为 null。

通过 SystemLanguageModel.default.availability 和语言支持检查能力；只选系统设备端模型。Foundation Models 不可用就跳过，不加云端替代。[Apple Foundation Models 介绍](https://developer.apple.com/videos/play/wwdc2025/286/)

若手机属于中国大陆销售版本，或账号、地区等触发当前 Apple Intelligence 可用性限制，可能无法使用本地文字模型。以 App 运行时检查为准，不根据 iPhone 17 Pro 型号单独判断；语音识别仍独立检查。[Apple Intelligence 当前使用条件](https://support.apple.com/zh-cn/121115)

## 6. 评测与无 Xcode 诊断

首轮从 5 条录音开始：安静普通话、专名 / 数字 / 否定词、中英混说、噪声、一条 5 分钟连续讲话。链路稳定后扩展附件中的 20–30 条及 15–30 分钟长音频。

必须保存：音频哈希、时长、设备和 OS build、App / SDK / 依赖版本、实际引擎和配置、初始化耗时、转写耗时、RTF、原始文字、分段、错误及参考稿。长音频完成度单列，部分结果不能标记整篇成功。

- CER：统一字符规范化，计算替换 + 删除 + 插入，再除参考稿长度；空参考稿不除零。实现用 Unicode scalar 序列，记录规则版本，另测标点、数字、emoji 和简繁边界。
- 汇总：同时给每条 CER 和总编辑次数 / 总参考字符数，避免短录音与长录音等权平均误导。
- RTF：包含解码、重采样、分段、识别及拼接，不含下载和模型初始化；另列总等待时间。
- 公平性：固定同一音频；关闭纠错测 ASR；交替 A/B 顺序；分别记录冷 / 热启动、热状态及低电量模式。
- 离线：模型准备后启用飞行模式并关闭 Wi-Fi，重新启动 App，验证转写真实成功；续签联网与 ASR 离线是不同阶段。

本轮不把 Instruments 作为必须工具。App 内提供阶段日志、耗时、ProcessInfo 热状态和可取得的进程内存采样；异常退出可辅以手机“分析数据”的崩溃 / Jetsam 日志。保留 CI 的 dSYM 供后续符号化。

**App 内存采样不能代表苹果系统模型的整机资源占用。**报告只称“本 App 进程采样峰值”，不据此断言苹果引擎更省内存或更省电；缺少可靠 CPU / 能耗数据则写未测。

## 7. 分阶段交付与通过条件

| 阶段 | 交付 | 通过条件 | 估计开发量 |
|---|---|---|---|
| M0 安装与能力验证 | 小型未签名 IPA；录音、权限、SpeechTranscriber / LLM 状态页；中文短句转写 | 免费侧载成功，录音成功，SpeechTranscriber 完成中文短音频离线识别，并导出能力检查结果 | 0.5–1 天 |
| M1 核心 A/B | SenseVoice 导入及推理、现代苹果引擎、同音频运行、结果落盘和基础导出 | 17 Pro 上两套 ASR 真实完成，原文 / 时间 / 错误可查 | 2–3 天 |
| M2 最低系统与评测 | CER、长音频、取消、低内存配置、iOS 26 及旧机记录 | 两套引擎在符合准入条件的旧机上验证；缺少真机则明确待测 | 1–2 天 |
| M3 可选纠错 | 独立纠错、diff、四组 CER、失败处理 | 模型可用机上真实纠错；不可用机正确跳过 | 1–2 天 |

以上为工程工作量估计，不含账号、网络下载、CI 排队及无法预测的侧载 / 系统问题。可用于 ASR 对比的首版目标约 3.5–6 个工作日；完成可选纠错约 4.5–8 个工作日。

M0 是实施顺序上的第一个关口：先确认免费安装、中文离线能力，再投入较大的模型集成。若 iOS 27 侧载不通或苹果引擎在这台手机上不可用，先给出具体错误和调整路径。

最终交付应包括：Swift 源码及工程描述、固定依赖、CI 工作流、可侧载 IPA、模型导入说明、安装 / 续签 README、JSON / Markdown 报告、真机测试记录。仅构建成功不能替代真机验收。

## 8. 相对附件的明确调整

| 附件设定 | 本方案 |
|---|---|
| App 最低 iOS 26 | 保留 iOS 26.0，满足两套指定 ASR 的共同系统要求 |
| 两套引擎适用于所有测试设备 | 按硬件、中文、资源和实际离线结果准入；不使用替代引擎 |
| 纠错默认开启 | 首轮默认关闭，完成 ASR 独立评测后再测纠错 |
| Xcode 工程在本机运行 | 工程仍为原生工程，编译移到云端，本机只编辑及侧载 |
| Instruments 辅助分析 | 首版使用内建日志和采样，资源指标明确边界 |
| 开发后再安排真机验证 | 先完成免费安装与苹果语音能力验证包 |

本地源码、生成工程、模型、依赖、构建脚本和验证记录已交付；没有创建远程仓库、上传代码或录音，未安装 Xcode，也没有声称已跑通 iPhone。用户要求暂不连接 GitHub，下一项需要外部环境的工作是云端 iOS SDK 编译，再执行真机 M0 验证。
