# VoiceBench · 语音对比

简洁的 iPhone 原生 Demo，针对同一份录音比较 **SenseVoiceSmall INT8**、**Apple SpeechTranscriber**、**Qwen3-ASR 0.6B INT8**、**Fun-ASR-MLT-Nano INT8** 与 **Whisper large-v3-turbo INT8**。最低 iOS **26.0**，全部本地识别。当前版本 **0.7.0**。

当前交付包含 Swift 源码、生成的 Xcode 工程、锁定依赖、模型准备脚本、手动触发的 GitHub Actions 工作流和本地逻辑校验。云端仓库为 [unclehun/voice_bench](https://github.com/unclehun/voice_bench)，操作步骤见 [GitHub 云端编译](docs/GITHUB_ACTIONS.md)。**本地验证尚不包含 iOS SDK 编译或 iPhone 测试，实际云端构建状态以 Actions 为准。**验证边界见 [验证记录](docs/VALIDATION.md)。

## 功能

- 录音、M4A / WAV 导入、播放、录音选择和删除。
- 五套引擎各自识别同一份原始录音；Apple 不再使用外部语言检测。载入 Qwen / Fun-ASR / Whisper Turbo 后，每轮加入已配置的引擎，最多依次运行五套，详情页可单独测试任一引擎。
- 同一源文件的 SHA-256、原始文本、分段时间、初始化时间、转写时间及 RTF。
- 模型文件校验、Apple 默认识别语言设置及对应资源准备、可用性检查、错误和取消状态。
- 原文及完成片段落盘，重启后把未完成任务标记为中断。
- 私有目录保存数据，清理临时文件与异常退出残留；提供“清除全部本机数据与模型”。
- 人工参考稿计算 CER；JSON 和 Markdown 系统分享导出。
- Foundation Models 本地纠错与可选 DeepSeek Flash 公网纠错：同时处理同一份原始转写，独立保存状态、耗时、建议和输出，分块、差异高亮并执行保守修改检查。参考稿不进入纠错接口，失败不覆盖 ASR。

主界面按录音显示卡片，左上角 **+** 打开录音浮层，右上角 **设置** 进入模型配置与数据管理。无需登录 App 账号或配置服务端。

- 录音浮层显示计时器：红色圆形开始录音，绿色方形停止并保存，两种按钮互斥。停止后自动返回列表，新录音按“录音 1、录音 2…”命名；浮层也保留音频文件导入入口。
- 卡片点击 **识别**，依次运行 SenseVoice、Apple，再运行已载入的 Qwen、Fun-ASR、Whisper Turbo，展示本轮结果；未载入这些可选模型时继续原有双引擎流程。每轮结果归为一个 batch，新一轮排队时不会拼上旧一轮的文字或纠错；历史记录在 **详情** 中保留。
- 点击卡片 **开始纠错**，依次处理本轮成功识别的非空文本；每份文字同时交给 Apple 本地与 DeepSeek 公网模型。结果区域自动展开，按识别引擎及纠错模型分别显示文字、状态、耗时和错误。整行 **查看纠错结果与状态 / 收起纠错结果** 只控制展示，重新执行放在独立的 **更多操作 → 重新运行两路纠错** 菜单中。
- 卡片可播放 / 停止音频、删除整条录音。删除会清理该录音的音频、全部历史识别与纠错、参考稿、背景和内部临时工作文件，保留其他录音与共享模型。
- **设置** 集中管理 SenseVoice / Qwen / Fun-ASR / Whisper Turbo 默认目录及手工导入、Apple 默认识别语言与资源、纠错可用性、DeepSeek API Key 和全部数据清理，可通过系统返回按钮回主界面。
- **详情** 保留参考稿、纠错背景、CER、JSON / Markdown 导出、历史运行明细和单引擎调试入口。

### DeepSeek 公网纠错

在 **设置 → DeepSeek 公网纠错** 输入并保存 API Key，随后在录音卡片点击 **开始纠错**。支持更新和删除 Key；Key 只保存在 App 私有配置文件 `Library/Application Support/VoiceBench/Credentials/deepseek-api-key.json`，使用原子写入、设备文件保护和仅所有者可读写权限，不进入录音文件、UserDefaults 或报告。启动时自动读取，退出 / 重开或保留数据的覆盖更新无需重新填写；更新应保持同一 App 身份，避免先删除 App。手动删除 Key、清除全部数据或删除 App 会移除该配置，文件缺失时直接显示未配置，不创建额外状态文件。未配置 Key 时 Apple 纠错照常运行；Apple 模型不可用也不阻止 DeepSeek 运行。

2026-10-28 查阅 [DeepSeek 官方更新日志](https://api-docs.deepseek.com/updates/)，选择最新 **DeepSeek-V4.1-Flash-1017**，API 使用官方别名 `deepseek-flash`。按 [Chat Completions 文档](https://api-docs.deepseek.com/api/create-chat-completion/) 调用 `https://api.deepseek.com/chat/completions`，关闭思考、temperature=0、JSON 输出；按 400 字分块，附前后各最多 120 字上下文。网络 / HTTP 失败不自动重试，避免重复计费；取消会中止正在等待的网络请求。

提示词要求仅修正有充分依据的误识、错别字和必要标点，保留语言、简繁体和口语，不润色、翻译或补充事实；数字、日期、否定和人物关系保持不变。背景、词条及转写均作为数据，不执行其中的指令。返回片段 ID、目标块全文和简短依据，再经过与 Apple 相同的保守检查。提示词版本及 SHA-256 随结果保存。

公网纠错需要互联网并由 DeepSeek 按用量计费，仅发送本次原始转写、相邻文字和用户填写的纠错背景，不发送音频、参考稿或其他引擎结果。Apple 本地纠错继续离线运行。JSON / Markdown 报告分别包含两路纠错结果和 CER；详情中的 **计算 / 更新 CER** 可重新计算。

## 运行条件

手机必须运行 iOS 26+。系统版本满足要求后，还要通过 `SpeechTranscriber.isAvailable`、对应语言 locale 和系统资源检查。模型准备完成后，各引擎在手机上离线运行；“安装成功”不等于各引擎均可用。

主测试目标为用户的 iPhone 17 Pro / iOS 27。旧机只有通过两引擎实际离线转写后才列入兼容清单。Foundation Models 另受 Apple Intelligence 设备资格、地区、启用状态与语言限制，不能用它是否可用来决定 SpeechTranscriber 是否可用。

Apple Speech 重复报 `Foundation._GenericObjCError Code=0` 时，新版采用逐块 PCM 输入，并将阶段、帧数、格式和错误链写入运行报告。构建后的真机复测与 USB 日志步骤见 [Apple Speech 调试](docs/APPLE_SPEECH_DEBUG.md)。

本地 Mac 13.7.8 + Command Line Tools 可以编辑代码和运行部分校验；无法编译 iOS App。完整构建在有 Xcode 26+ 的另一台 Mac / 云端 macOS 上进行。本机无需安装 Xcode。

## 已准备的本地文件

- `VoiceBench.xcodeproj`：实际生成的原生工程。
- `project.yml`：工程配置的来源，变更后重新生成。
- `Vendor/`：已下载、验证 SHA-256 的 iOS 静态 XCFramework（不提交 Git）。
- `.tools/xcodegen/`：项目内的 XcodeGen 2.44.1，不是 Xcode。
- `Models/FunASR_MLT_Nano_INT8/`：完整 MLT 版 ONNX INT8、tokenizer、VAD、许可证及 manifest，约 1.01 GB（不提交 Git，也不进入 IPA）。
- `Models/WhisperLargeV3Turbo_INT8/`：完整 Turbo 多语言 ONNX INT8、词表、VAD、许可证和 manifest，约 1.04 GB（不提交 Git，也不进入 IPA）。
- `Models/Qwen3ASR_0_6B_INT8/`：完整 Qwen、tokenizer、VAD、许可证和 manifest，约 988 MB（不提交 Git，也不进入 IPA）。
- `Models/WhisperTiny_INT8/`：旧流程准备的语言检测模型（约 103 MB，不提交 Git）；0.6.0 不再载入或调用，新设备不需要准备。
- `Models/VoiceBenchModels/`：准备好的手机模型导入目录，含权重、tokens、VAD、许可证和 manifest（不提交 Git）。

各工作目录是否存在取决于当前机器是否已执行准备脚本；新克隆可用以下命令重新准备。

`build/VoiceBench-source.zip` 是本轮源码交付包，包含工程、脚本和文档，不含模型、二进制依赖或个人录音。解压后先运行依赖准备脚本。源码变更后可执行 `python3 scripts/package_source.py` 重新打包；这不是可安装的 IPA。

## 本机可执行的检查

在项目根目录执行：

```sh
bash scripts/check_local.sh
```

该命令用系统 `swiftc` 编译实际核心代码，再检查 CER、Unicode、空参考稿、字符 diff、取消和报告，以及使用 URLProtocol 模拟响应的 DeepSeek 请求 / 错误 / 取消和持久化测试，并用真实临时文件验证 API Key、Apple 默认语言配置、新实例读取及实际完整数据清除；不使用真实密钥或访问真实 API，不依赖 XCTest 或 iOS SDK。正式 XCTest 保留在 `Tests/VoiceBenchCoreTests`，有完整 Xcode 的机器运行 `swift test`。

音频转换 / 保存测试使用真实 AVFoundation，不录制麦克风：

```sh
bash scripts/check_audio.sh
```

这些检查不是手机识别准确率或手机性能测试。完整测试状态与局限见 `docs/VALIDATION.md`。

## 依赖准备与工程生成

```sh
python3 scripts/prepare_dependencies.py
.tools/xcodegen/bin/xcodegen generate --spec project.yml
```

依赖固定在 `config/dependencies.json`，包括下载 URL、版本和 SHA-256：

- sherpa-onnx 1.13.8，静态 iOS XCFramework。
- ONNX Runtime 1.28.2，静态 iOS XCFramework。
- XcodeGen 2.44.1，仅用于工程生成。

此处显式引用二进制，避免上游 Swift Package 的版本号与其实际引用的二进制不一致。校验失败时脚本停止，不自动接受新版本。`--offline` 仅使用已经下载并通过校验的归档。

## 云端生成 IPA（尚未执行）

仓库使用普通 Git 管理源码、工程、配置、脚本、图标和许可证；不提交 `Vendor/`、`.downloads/`、`.tools/`、`Models/` 或个人录音。无需 Git LFS，依赖在构建时下载并校验。详细启用步骤和大文件策略见 [GitHub 云端编译](docs/GITHUB_ACTIONS.md)。

工作流 `.github/workflows/ios.yml` 仅接受手动触发：

1. 使用标准 `macos-15` runner，验证 `/Applications/Xcode_26.3.app` 存在。
2. 运行核心 XCTest。
3. 下载并校验固定依赖，生成工程，构建真机 Release。
4. 打包完整 `.app` 到 `Payload/VoiceBench.app`，上传未签名 IPA、SHA-256、dSYM 和日志，保留 3 天。

默认只使用标准 runner；私有仓库受账号免费额度与存储配额限制。工作流不使用 Apple 账号、签名证书或付费开发团队。工具链镜像会变动，缺失时明确失败，需选择仍包含所需 Xcode 的镜像。

在已有完整 Xcode 的构建机上也可执行：

```sh
export DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer
bash scripts/build_unsigned.sh
```

输出 `build/VoiceBench-unsigned.ipa`。**未签名 IPA 不能直接安装到手机；它需要下一步签名。**

## 免费侧载到 iPhone

1. 在现有 Mac 安装 [Sideloadly](https://sideloadly.io/)，USB 连接并信任 iPhone。
2. 下载云端生成的未签名 IPA，拖入 Sideloadly。
3. 在本机工具内使用自己的免费 Apple 账号登录、完成双重认证并签名安装。无需把密码交给代码或 GitHub。
4. 按系统提示信任开发者并开启开发者模式，打开“语音对比”。
5. 更新时保持相同账号与最终 Bundle ID，覆盖安装，避免先删除 App 丢失数据。

免费签名通常 7 天到期，需续签；同一 IPA 可重新签名，无需每周重新编译。自动刷新仍需 Mac 和手机满足连接条件。当前这台旧 Mac 与 iOS 27 的实际侧载组合尚未验证。

## 模型导入

已准备好的目录为 `Models/VoiceBenchModels`。新环境执行：

```sh
python3 scripts/prepare_models.py
```

脚本下载指定的 INT8 模型及 VAD，保留模型 LICENSE，对照固定哈希校验，生成 `manifest.json`。现有输出目录不会被覆盖；可用 `--output` 选择新目录。

将完整模型文件夹传到 iPhone 后，把文件夹命名为 **`SenseVoiceSmall_INT8`** 并放入 **“文件”App → 在我的 iPhone → 语音对比**（少数系统会显示为 **VoiceBench**）。App 启动时会自动校验并载入；之后不需要重复选择目录。首次启动 App 会创建这个空目录。

也可以点“选择其他模型目录…”从 iCloud Drive、网盘或任意文件位置手工选择，App 会复制并校验模型到私有目录。两种方式都应使用包含下列文件的完整文件夹：

```text
SenseVoiceSmall_INT8/
  model.int8.onnx
  tokens.txt
  silero_vad.onnx
  manifest.json
  LICENSE
  VAD_LICENSE
```

如果传输方式需要 ZIP，可先压缩目录，在 iPhone“文件”App 解压后移动或改名为 `SenseVoiceSmall_INT8`。App 不解析 tar.bz2 / ZIP，也不会误把压缩包当模型。

App 在导入时校验所选内容与内置 `model-manifest.json` 一致；验证通过后替换模型目录。只支持本 Demo 指定的模型版本，损坏文件或其他同名模型会被拒绝。

### Apple Speech 整段直接识别

0.6.0 移除 Apple 前置的 Whisper Tiny 语言检测与语言区间路由。Apple 和其他模型各自接收同一份原始录音；Apple 仅做系统所需音频格式转换，通过逐块 PCM 将完整录音送入一个 SpeechAnalyzer 会话。没有外部语言识别、没有按猜测语言切换模型，也无需准备 Whisper 文件。

[SpeechTranscriber 官方初始化接口](https://developer.apple.com/documentation/speech/speechtranscriber/init(locale:transcriptionoptions:reportingoptions:attributeoptions:)) 仍要求 locale。因此在 **设置 → Apple Speech → 默认识别语言** 选择语言，缺省为 **中文（中国大陆）/ zh-CN**，选项从系统支持列表读取。点击 **准备默认语言的苹果资源**，只准备该语言；资源就绪后支持本地识别。多语言支持不等于无需 locale 的自动识别，中英混读在同一 locale 下的表现需要真机实测。

设置保存到 App 私有目录 `Library/Application Support/VoiceBench/Settings/apple-speech.json`，重启及保留数据的覆盖更新继续使用；清除全部后恢复中文。切换语言立即重新检查资源状态，识别期间禁用修改。每次运行开始时捕获 locale，报告同时记录请求值与系统实际选择值。

原有历史识别与语言检测明细仍能读取和导出；已有 Whisper 文件不会自动删除，“清除全部”仍覆盖旧目录。旧版的模型准备脚本、存储兼容方法和校验样例仅用于历史资源维护，不在新识别流程调用。

用现有十条录音重新运行“仅 Apple”，重点比较中英混读、短标题、空白录音、长录音、取消和后台恢复，再与其他三套重新计算 CER。旧评比报告反映的是外部语言路由链路，不能当作新流程的准确率结果。

### Qwen3-ASR 0.6B INT8（第三套识别引擎）

模型已放在 `Models/Qwen3ASR_0_6B_INT8`，七份必需文件共 **987,659,201 字节**（约 988 MB）。重新下载或校验：

```sh
python3 scripts/prepare_qwen_models.py
python3 scripts/prepare_qwen_models.py --verify-only
```

把完整文件夹传到 **文件 → 在我的 iPhone → 语音对比 → Qwen3ASR_0_6B_INT8**，保留 `tokenizer` 子目录。打开 App 或点设置中的“检查状态”自动载入；也可“从默认目录载入 Qwen3-ASR”或“选择其他 Qwen3-ASR 目录…”。文件树、空间要求和真机验收见 [Qwen 接入说明](docs/QWEN_ASR.md)。

Qwen 独立直接转写多语言，不使用 Apple 的语言资源。载入后卡片“识别”自动加入第三套；详情 → 调试运行 → “仅 Qwen3-ASR”可独立测试。默认语言选项只影响 Apple，其他四套引擎仍使用各自模型的自动多语能力。

### Fun-ASR-MLT-Nano INT8（第四套识别引擎）

模型已下载到 `Models/FunASR_MLT_Nano_INT8`，十份必需文件共 **1,010,411,868 字节**。准备与复核：

```sh
python3 scripts/prepare_funasr_models.py
python3 scripts/prepare_funasr_models.py --verify-only
```

将完整目录放在 **文件 → 在我的 iPhone → 语音对比 → FunASR_MLT_Nano_INT8**，保留 tokenizer 子目录。与 Qwen 一样，支持启动 / 检查状态自动载入、从默认目录重新载入，以及系统文件选择器手动选目录。载入后卡片识别增加第四套；详情 → 调试运行 → “仅 Fun-ASR-MLT-Nano”可独立测试。

此处是多语言 MLT 版本，使用社区 ONNX INT8 导出，固定 revision 和十份 SHA-256。0.4.1 针对 512-token KV 增加输入 / 输出联合预算：优先保留最长约 20 秒的自然语音段，接近容量时丢弃本次文字、在附近低能量位置细分后重跑，最终采用的结果保留至少 16 token 余量。另修复 Fun-ASR 音频读取可能少读采样的问题。模型文件不变，无需重新传输。详细边界及真机验收见 [Fun-ASR 接入说明](docs/FUNASR_MLT.md)。

## 评测方法

先不做纠错，分别测试安静普通话、专名 / 数字 / 否定词、中英混说、噪声和长录音。点击卡片“识别”后依次运行各套引擎，并分别保存结果。

- `RTF = transcriptionMS / 1000 / audioDurationSeconds`；转写包括各引擎所需格式转换、切分、推理和拼接。Apple 新流程不再包含 Whisper 时间；旧报告仍保留历史口径。首次模型下载不计入 RTF，初始化单独记录。
- CER 使用 Unicode scalar 编辑距离，移除标点和空白、统一 ASCII 英文字母大小写；不统一简繁、数字写法或语义。
- 没有参考稿时 CER 为 null；规范化后空参考稿保留字数和编辑计数、rate 为 null。
- 未完成 ASR 不计为完整 CER / RTF。纠错不可用、取消或失败时不复制原文冒充成功结果。
- 录音和运行结果按文件保存；删除录音时会删除其全部关联结果。

原始转写、纠错建议与实际采用文字分开保存。差异展示红色删除和绿色新增。纠错器对涉及数字、否定及人物关系词的修改采取整块保留原文策略；这只是保守规则，不代表能自动证明语义正确，需人工复核。

## 当前明确的限制

删除与备份行为见 [数据清理说明](docs/DATA_LIFECYCLE.md)。在 iPhone 设置中须选择 **“删除 App”**；**“卸载 App”会保留数据**。App 私有录音、结果和模型随删除移除；导出副本、导入原件及苹果共享系统模型不属于 App 私有数据。

- **本次 Apple 整段识别更新尚未通过 iOS SDK 编译或真机验证。**之前十段实测基于旧语言路由流程，不能用于评价新流程。本地语法和跨平台类型检查不能替代真机验证。
- 前台任务为主。后台或系统音频中断会结束任务，保留已完成片段；重新运行会创建新记录，没有断点续跑。
- 原生 SenseVoice 取消在原生推理调用之间生效，当前调用期间可能要等待。
- SenseVoice 使用原默认配置：2 线程 / 25 秒分段上限、自动检测语言。Fun-ASR 使用独立的上下文预算与低能量重分段策略，见接入说明。
- 为避免边界重复，后段保护区裁剪到前段结束，记录真实采用范围；尚无精确逐字时间戳或语义去重。
- LLM 纠错按 400 字分块，附相邻上下文；没有实现上下文超限后的自适应缩块重试。失败块保留原文并记录错误，可单独重试整次纠错。
- 内存 / CPU / 整机耗电未测，不用 App 自身内存推断苹果系统模型资源占用。

## 参考

- [Apple SpeechAnalyzer 示例与说明](https://developer.apple.com/videos/play/wwdc2025/277/)
- [SpeechTranscriber 可用性](https://developer.apple.com/documentation/speech/speechtranscriber/isavailable)
- [Foundation Models](https://developer.apple.com/documentation/foundationmodels)
- [DeepSeek 模型更新](https://api-docs.deepseek.com/updates/)
- [DeepSeek Chat Completions](https://api-docs.deepseek.com/api/create-chat-completion/)
- [SenseVoice 模型](https://k2-fsa.github.io/sherpa/onnx/sense-voice/pretrained.html)
- [第三方许可](THIRD_PARTY_NOTICES.md)


### Whisper large-v3-turbo INT8（第五套识别引擎，0.7.0）

模型已下载到 `Models/WhisperLargeV3Turbo_INT8`，四份必需文件共 **1,037,257,645 字节**。准备与复核：

```sh
python3 scripts/prepare_whisper_turbo_models.py
python3 scripts/prepare_whisper_turbo_models.py --verify-only
```

将完整目录放在 **文件 → 在我的 iPhone → 语音对比 → WhisperLargeV3Turbo_INT8**。与 Qwen 一样，支持启动 / 检查状态自动载入、从默认目录重新载入、文件选择器导入、SHA-256 校验、重启复用和清除全部。载入后卡片识别加入第五套；详情 → 调试运行 → **仅 Whisper large-v3-turbo** 可独立测试。

沿用 Qwen 的 CPU 两线程、16kHz 单声道和 20 秒 Silero VAD 分段，使用 `transcribe` 和模型内部自动语言，无外部语言路由；Apple 默认语言仅影响 Apple。输入窗口和原生输出上限受保护，接近上限先补静音重试一次；仍疑似截断时明确失败并保留已完成片段。完整参数、模型来源和验收见 [Whisper 接入说明](docs/WHISPER_TURBO.md)。
