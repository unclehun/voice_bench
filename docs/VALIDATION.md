# 验证记录

## 2026-10-30：Qwen 4 位独立模型接入（0.8.0）

- 设置页、结果卡片、详情单独运行和报告统一命名为 **Qwen3-ASR 4 位**；默认目录为 `Qwen3ASR_0_6B_WeightOnly4`，支持默认目录自动载入、手动选择完整目录和重启后读取。原 INT8 和 4 位使用独立目录、receipt、引擎 ID 与结果。
- `python3 scripts/prepare_qwen_weight_only_models.py --verify-only` 通过，七个必需文件与固定清单一致；解码器 SHA-256 为 `fa1dd896ad8105e06a8b9659e34a233c1b094759e2279c8f1374152e771cb593`。Xcode 工程及 `project.yml` 均包含对应的内置校验清单。
- `check_local.sh`：**34,598** 项核心检查、**50** 项纠错检查、**38** 项配置文件检查及工程静态检查通过。修改的 SwiftUI / ViewModel 文件通过 frontend parse；这些不代替 iOS SDK 类型检查。
- 真实模型导入与音频存储检查通过：SHA-256 拒绝损坏、原子替换、原版隔离、重启恢复、备份排除、完整模型实际导入和全部数据清除。测试使用 `QWEN_WEIGHT_ONLY_MODEL_DIR` 指向实际 917 MB 目录，没有删除工程模型源文件。
- 使用当前共享 `QwenSpeechEngine` 对原始录音 4 的 M4A 完成真实推理，显式指定 `.weightOnly4`。输出五段与此前十段受控测试中的 4 位录音 4 **文字、起止边界全部一致**；验证原始音频 SHA、W4A32 / 分块 32、官方 BF16 词嵌入、`exact-float32-loop-v1`、自动语言、CPU 两线程及解码参数。
- 预取消、真实解码后的取消及派生音频清理通过。报告为本机 `build/qwen-weight4-demo-smoke.json`，属于 **Mac 共享 App 引擎测试**；本轮没有重复十段性能测试，也没有操作手机。
- 沙箱内备份属性检查和 AAC 重采样分别受到本机环境限制；获准在沙箱外运行同一已编译测试后通过，未为通过测试而修改模型或音频算法。
- 本机仅安装 Command Line Tools，没有完整 Xcode / iPhoneOS SDK，尚未执行 0.8.0 iOS 编译和真机验收。手机导入与测试步骤见 [Qwen 4 位接入说明](QWEN_WEIGHT_ONLY4.md)。

## 2026-10-30：Qwen 官方基准与独立优化配置（0.8.0）

- 官方非 INT8 checkpoint、浮点 ONNX 和原生解码分层对照，定位当前动态量化解码器在混读场景的语言偏移；浮点实现可逐字复现官方同段结果。
- 优化版为原 INT8 编码器加 W4A32 分块 32 解码器；完整七份文件 916,915,569 字节，模型已在 `Models/Qwen3ASR_0_6B_WeightOnly4` 生成并校验。保留原版，增加独立引擎 ID、导入目录、receipt、结果和报告。
- 同一 Mac / 同一 PCM / 67 个固定区间的十段对照，CER 为原版 12.00%（329/2742）、优化版 4.70%（129/2742）；录音 4 为 46.91% → 7.00%。两段各回退两处编辑错误，已在报告列出；解码约慢两倍，不能据此推断手机性能。
- 实际共享 App 引擎对十条原始 M4A 的 20 次运行也完成：修复完整区间读取后总体 CER 为 11.52% → 4.85%，录音 4 为 80.66% → 7.00%；转写总时间 102.3 → 233.1 秒，仍是 Mac 结果，与前项 C API 探针分开报告。
- 共享音频区间读取发现并修复单次 AVAudioFile 短读：67 个真实区间由全部不完整变为逐字节一致；Qwen、SenseVoice、Whisper Turbo 使用新循环读取，并记录读取版本。新增可定位帧序列的 seek／尾部回归。Fun-ASR 独立读取器不变。
- 34,598 核心检查、50 纠错检查、38 配置文件检查通过。音频／存储检查覆盖优化版独立导入、损坏拒绝、失败保留旧模型、重启、备份排除、全部清除，以及真实完整候选导入和删除；系统备份属性检查在沙箱外运行通过。
- 优化版从空目录重复构建后七份文件 SHA-256 完全一致。共享 Qwen Swift 引擎实际推理、预取消、解码后取消及临时文件清理通过；共享读取变更后的 Whisper Turbo 真实推理／静音／取消清理也通过。App Swift 语法、真实 C API + targeted concurrency、XcodeGen 和项目检查通过。
- 本机仍无 iPhoneOS SDK，**未完成 0.8.0 iOS 编译和真机候选运行**。试验结果、完整参数与复现见 [Qwen 官方对照与优化版](QWEN_REFERENCE_VALIDATION.md)。

## 2026-10-29：Whisper 中文 BPE 字节恢复（0.7.1）

- 只读取得手机 0.7.0 / Build 13 的十段结果，Whisper 总体 CER 为 **18.67%（512 / 2742）**。核对固定版 sherpa 原生代码与其 Python ONNX 示例、OpenAI tokenizer、whisper.cpp 后，确认原生结果转换在拼接前逐 BPE token 清理不完整 UTF-8，导致跨 token 的中文字节被删除。原有“能运行”检查没有覆盖这种中文完整性问题。
- 增加 `WhisperByteTokens` 兼容层：原始 Base64 token 拼写经 ASCII 传输通过原生清理，取回 token 数组后先拼字节再统一解码。token ID、权重、原始词表、manifest 与 receipt 保持不变，已安装模型无需重新传输；新运行记录 `whisper_turbo_text_decoder=base64-ascii-join-bytes-v1`。临时传输词表成功、失败、取消和冷启动清理。
- 使用经原始 SHA-256 核对的手机录音 1、8，在同一台 Mac、相同权重和 VAD 参数下执行旧、新路径。项目实际 Swift CER 复核：录音 1 **10.50% → 2.94%**，删除数 **20 → 0**；录音 8 **23.26% → 7.64%**，删除数 **52 → 2**；两段加权 **17.49% → 5.51%**。两次分段区间完全一致。参考稿只用于事后计分，以上不是新版手机的十段成绩。
- **34,593 项核心断言、50 项纠错检查、38 项配置文件检查**通过。新增中文 / 日文 / 韩文 / 重音字母 / emoji / NUL 的 UTF-8 字节边界回归、ASCII 传输恢复及损坏输入拒绝；实际原生推理、预取消、解码后取消、纯静音、派生音频及临时词表清理通过。
- 对四个真实区间的同权重参考试验中，token 过滤开关没有改变输出，标准 30 秒补齐也没有一致改善，没有将这些差异误判为本次主因。没有下载额外 whisper.cpp 模型或使用其引擎计分。
- 已生成 0.7.1 工程并完成真实 C API 编译和 App Swift 语法检查；**本机没有 iPhoneOS SDK，尚未完成 0.7.1 iOS 编译或真机全量复测**。当前原生输出上限检查仍不能保证识别所有停止原因。审计证据、来源与兼容边界见 [Whisper 接入审计](WHISPER_TURBO_AUDIT.md)。

## 2026-10-29：Whisper large-v3-turbo 第五套引擎（0.7.0）

- 已下载固定 revision `2ca6ff69fc878651b770880507669577ac41c2ff` 的多语言 Turbo ONNX INT8 到 `Models/WhisperLargeV3Turbo_INT8`。四份必需文件共 **1,037,257,645 字节**，上游 LFS / Git blob 核对及 SHA-256 复验通过；许可证、来源与 manifest 随目录保留。权重不进 Git / IPA。
- 沿用 Qwen 的默认 / 手动导入、校验及原子替换、重启复用和清理生命周期。卡片加入第五套、详情支持独立运行；报告、评测与两路纠错按统一引擎列表工作。Core 历史 Codable 及前四套结果仍兼容。Apple、Qwen、SenseVoice、Fun-ASR 和共享音频实现未修改。
- 转写采用同一原始录音、16kHz 单声道、20 秒 Silero VAD、200ms 边缘保护、CPU 两线程及 sherpa-onnx 1.13.8 / ONNX Runtime 1.28.2。Whisper 专用参数为 128 维特征、`task=transcribe`、模型内部自动语言、`greedy_search`、300 帧内部尾部补齐。不依赖 Apple 默认语言或外部语言路由。
- 实际推理复现 sherpa 的按时长限制输出（约每秒 6 token）。短样例初次生成 35 token 达到上限；改为丢弃候选、末尾补静音至 29 秒重试一次，成功返回后才发布。原始 VAD 区间和展示时间不变。仍接近上限则明确失败，诊断记录重试数、补齐量及阈值，不冒充完整结果。
- **34,487 项核心断言、50 项纠错检查、38 项配置文件检查**通过；完整 `audio-checks` 验证五类模型（含历史 Tiny）的真实导入、SHA-256、替换隔离、重启、备份属性、删除录音、全部清理及外部原件保留。首次沙箱执行无法访问 macOS 备份属性服务；获准在沙箱外重跑后完整通过，没有跳过备份断言。
- 使用同版本 macOS 原生库运行共享 Swift Whisper 引擎：5.592 秒中文样例、6.230 秒预算重试样例、21.5 秒拼接压力音频、10.846 秒受控中英合成语音均完成。另以 32.539 秒受控混读长音频验证，6 个片段完整保留 3 轮中英内容，最后一段结束于原始时长，未受 30 秒窗口截掉后续。受控混读保留两种语言，但仍有误识，不能据此宣称准确率优于现有模型。预取消、实际解码后取消、纯静音与派生音频清理通过。报告保存在 `.build-local/whisper-turbo-*.json`，不进入源码包。
- 已生成 Xcode 工程并验证资源引用、全部 App Swift frontend parse、真实 C API 编译、plist / 脚本 / JSON 检查。**尚未进行 0.7.0 的 iOS SDK 编译、GitHub Actions 或 iPhone 测试**；Mac 推理不代表手机准确率、速度或内存结论。验收步骤见 [Whisper 接入说明](WHISPER_TURBO.md)。


## 2026-10-29：Apple 整段识别与默认语言（0.6.0）

- 移除 Apple 前置 Whisper 检测 / 分段路由、启动自动导入、就绪依赖、设置页模型入口及检测引擎实现。Apple 只转换系统要求的音频格式，在一个 analyzer 会话中输入完整录音；保留有界 PCM 拉取、真实 EOF、取消、结果流消费、临时文件清理与错误链。SenseVoice、Qwen、Fun-ASR 引擎未修改。
- [Apple 官方初始化接口](https://developer.apple.com/documentation/speech/speechtranscriber/init(locale:transcriptionoptions:reportingoptions:attributeoptions:)) 仍要求 locale。设置页新增默认识别语言，缺省 `zh-CN`，选项取自系统支持列表。仅检查 / 准备选定语言资源，异步状态检查不会把旧选择覆盖到新选择；运行开始时捕获所选 locale，忙碌时禁止修改。
- 语言保存在 App 私有 `Settings/apple-speech.json`，原子写入，重启 / 覆盖更新读取；清除全部恢复中文，并与 API Key 相互隔离。新报告记录 `requested_locale`、`apple_locale`、`pcm_full_recording_v3`、`configured_locale_full_recording_v1`、`apple_external_language_detection=false`、`apple_audio_scope=full_recording` 和会话数，不再填语言检测计划 / `lid_*`。旧记录和历史明细继续兼容，旧模型目录仍由全量清理覆盖。
- `bash scripts/check_apple_speech.sh` 通过 **34,479 项核心断言、50 项纠错检查、38 项配置文件检查**，以及真实 Int16 / Float32 完整 PCM 尾块 / EOF / 重采样、可选范围、取消、底层错误链和诊断报告检查。新增检查覆盖 locale 默认 / 规范化 / 非法值拒绝、完整录音配置、报告持久化和历史字段兼容、语言设置重启读取、损坏配置、无效保存保留旧值、与 API Key 隔离及实际清除全部恢复缺省。测试中修正了正则末尾锚点可接受尾随换行的问题。
- **尚未进行本次 iOS SDK 完整编译或 iPhone SpeechAnalyzer / 新 Picker / 中英混读验收**。之前十段真机报告针对旧路由链路，不代表新流程准确率；新流程不保证某个 locale 下自动获得多语最优结果。

真机验收：设置默认中文并准备资源 → 不配置 Whisper 运行“仅 Apple” → 复测十条录音，特别是原先误判 fi / ja / ko 的片段 → 检查新报告没有前置 LID 字段、时间范围覆盖整条、会话数为 1。再切换英文准备资源，确认重启 / 覆盖更新保留选择；验证取消、后台、空音频、长音频、清除全部恢复中文，并重新与其他三模型计算 CER。

## 2026-10-29：DeepSeek 并行纠错与配置文件（0.5.3）

此前的纠错功能修改尚未编译或在用户真机运行，本节按最终实现记录验证范围。

- 根据 2026-10-28 检索的 [DeepSeek 官方更新日志](https://api-docs.deepseek.com/updates/)，使用 DeepSeek-V4.1-Flash-1017 的 API 别名 `deepseek-flash`。非思考模式、temperature=0、JSON 输出；按 400 字分块，仅传目标、相邻只读上下文和用户背景。提示词要求最小修改、保留语言和口语、不执行输入中的指令，并沿用敏感事实及改动幅度检查。
- 每份识别原文通过结构化 `async let` 同时运行 Apple / DeepSeek，两路各自更新及保存；某路缺失配置或不可用不阻止另一路。API Key 无效、余额不足、限流、超时等单独展示。网络 / HTTP 失败不自动重试，部分失败保留相关片段原文。取消同时传递到两路任务和正在等待的 URLSession 请求。
- API Key 只保存在 App 私有配置文件 `Library/Application Support/VoiceBench/Credentials/deepseek-api-key.json`。原子写入、目录 0700 / 文件 0600、iOS 完整文件保护、排除设备备份；不写入 metadata、UserDefaults 或报告。配置文件缺失直接返回未配置，不创建其他状态文件。启动 / 保留数据的覆盖更新自动读取；删除 Key、清除全部或删除 App 会移除配置。
- 查看结果改为整行 44pt 以上按钮，重新执行移入独立的“更多操作”菜单，避免一次点击误触重跑。报告格式 v2 保留 Apple 字段，新增 `deepSeekCorrection` / `deepSeekCER` / `deepSeekDeltaCER`。
- `bash scripts/check_local.sh` 通过 **34,467 项核心断言、50 项纠错检查和 29 项配置文件检查**。纠错检查使用 URLProtocol 模拟响应，覆盖请求格式、分块、数字保护、非法 / 空 / 截断响应、401 / 402 / 403 / 429 / 503、超时、部分失败、取消、独立 CER 与持久化。配置检查使用真实临时文件，覆盖文件权限、保存 / 替换 / 无效保存保护、重启及模拟覆盖更新读取、损坏文件错误脱敏、删除 App 数据容器、重装读取为空、实际 `LocalStore.removeAllData()` 和重复清除。配置保存没有额外目录或状态文件。
- 凭据代码 targeted concurrency 类型检查、全部 App Swift frontend parse、XcodeGen 工程生成及 plist / 工程 / 脚本检查通过。既有音频清理回归保留 API Key 配置文件删除断言，供云端执行。
- **未执行本次 iOS SDK 完整编译、真实 DeepSeek API 调用或 iPhone 界面、文件保护、删除 / 重装验收**。本机只有 Command Line Tools，模拟响应与文件测试不能替代真机验收。

真机验收：保存 Key → 退出并重开 App → 运行纠错并检查两路结果 → 同一 App 身份覆盖安装新版后继续调用。反复查看结果不产生新请求，更多操作才触发重跑；验证未配置 Key、Apple 不可用、无效 Key、断网、取消、后台、导出及 CER。最后删除 Key / 清除全部后重开应为未配置，系统删除 App 并重装也应为未配置。

## 2026-10-28：Fun-ASR 512 上下文审计与修复（0.4.1）

- 确认原生 sherpa-onnx 1.13.8 在 KV 容量耗尽时也会停止生成，结果接口未返回停止原因；原来只拒绝生成数达到 256 的逻辑不能识别这类截断。用同版本 C++ tokenizer 核对现有提示为音频前 18 / 后 5，共 23 token。读取固定模型元数据及原生特征实现，按音频长度计算保守 prefill 上界，联合输出数检查并预留 16 token；不使用原文本骨干的 40960 容量。
- 优先 20 秒自然语音段，合并相邻短尾；仅超预算时按低能量边界递归细分，拒绝保存父段可疑文字，重试深度及最小子段长度均有界。实际采用区间不丢帧、不重复。max_new_tokens 改为 512，不增加导出容量。模型及默认目录不变，已有手机模型无需重传。
- **34,467 项核心断言通过**：包含采样长度穷举预算、原生 KV 提前停止的反例、超过原 256 但仍安全的输出、低能量边界、短尾合并及停止条件。Fun-ASR 专用 AVAudioFile 循环读取通过真实 CAF 逐采样校验、seek / 尾块 / 取消 / 非法区间检查；修复单次读取可能少于请求且尚未 EOF 的情况。原有完整四套模型导入、删除及清除全部检查通过。
- 在本机实际运行共享的 FunASRSpeechEngine，使用 sherpa-onnx **1.13.8** 与 ONNX Runtime **1.28.2** 的 macOS 库。短中文、连续绕口令及快速语音通过。21.5 秒高密度拼接压力样例触发 **3 次尝试 / 1 次细分**：父段生成 131 token，超过安全输出预算 112，未发布；两子段生成 79 / 67，接受结果最小保守余量 230。验证子区间完整覆盖父段、预取消及临时音频清理。拼接样例仅测试容量路径，没有参考稿，不能据此声称识别准确率或手机性能。
- 本机报告在 `.build-local/funasr-budget-{short,fast,dense,stress}.json`，最终重编后复验为 `funasr-budget-short-final.json` / `funasr-budget-stress-final.json`，均不进入 Git / 源码包。可选复现脚本 `scripts/check_funasr_native.sh`；要求外部提供同版本 macOS 库，不改变 iOS 原生依赖。
- Apple PCM / 语言区间 / 取消 / 诊断回归、全部 App Swift 语法、真实 C API + targeted concurrency 编译、XcodeGen 工程生成、plist / 工程 / 脚本检查通过。SenseVoice、Apple、Whisper、Qwen、共享 Audio 和纠错实现与 HEAD 一致。本次只改变 Fun-ASR 推理策略及相关校验；版本为 **0.4.1**。
- **尚未执行 0.4.1 的 iOS SDK 编译、GitHub Actions 或 iPhone 验证**。没有手机 CER、峰值内存或能耗结论；预算保护不证明模型自身无漏字或分段边界对语义无影响。

以下保留 0.4.0 的历史记录，其中 10 秒 / 256 参数及未完成 Mac 推理的状态已被上述 0.4.1 结果取代。

## 2026-10-28：Fun-ASR-MLT-Nano 第四套引擎（0.4.0）

- 下载社区 MLT ONNX INT8 转换版本 `luigi000/fun-asr-mlt-nano-onnx-int8`，固定 revision `932d7dbb98623bd31314015b3bc0dac0dcf80acc`。三份权重、六份 tokenizer 文件、独立 Silero VAD 共 **1,010,411,868 字节**。LFS SHA-256、普通文件 Git blob、完整 manifest、许可证及来源记录均验证通过；三份权重与 sherpa 普通常见 Nano 包不同，无 `.part` 残留。
- 读取真实 ONNX protobuf 元数据，确认 LLM 的 **512-token KV / 28 层 / float32 IO / hidden 1024** 与 encoder **LFR 7:6**。引擎使用约 10 秒最大 VAD 段及 256 个最大生成 token，给音频、提示及输出共同留空间；准备脚本包含该导出契约验证。该检查不等于实际推理验收。
- 新增独立 FunASRSpeechEngine、LocalStore 导入扩展、默认 / 手选目录配置、单跑入口及第四套卡片结果。SenseVoice、Apple、Whisper、Qwen 的原引擎文件、音频 / 纠错代码、Qwen 导入扩展及 `runBoth` 方法与本轮 Git HEAD 一致；原生依赖及最低 iOS 版本不变。
- **11,970 项核心断言通过**；新增第四套批次归属、纠错候选、结果持久化、无 Whisper 语言计划和导出检查。原有 11,965 项继续通过。
- 全量真实模型存储检查通过，包含 SenseVoice / Whisper / Qwen / Fun-ASR 的文件导入与删除；新 MLT 检查覆盖未传完、tokenizer 缺失、哈希不匹配、失败替换保留旧模型、其他模型集隔离、冷启动复用、备份排除和保留外部原件。录音删除包含第四套全部历史结果及 FunASR 派生音频；清除全部同时验证四个默认源目录（包括断链）及内部模型目录为空。macOS 备份属性检查需在工具沙箱外运行已编译的临时测试程序。
- `bash scripts/check_apple_speech.sh` 通过原有 PCM / 区间 / 取消 / 诊断回归。真实 sherpa C 头文件、targeted concurrency、存储、新引擎和 FunASRSmoke 类型检查通过；全部 App frontend parse、XcodeGen 工程生成、pbxproj / plist、脚本及 Git 文件检查通过。iOS 静态库包含 FunASR 原生实现符号。
- 尝试链接 Mac Fun-ASR 真实推理检查程序，旧 SDK 仍缺少 ONNX Runtime 所需 `MLComputePlan` / `MLOptimizationHints`，未得到实际推理输出。**本次尚未完成 iOS SDK 编译、GitHub Actions、新版 iPhone 运行、准确率或峰值内存测试。** 复测步骤见 [Fun-ASR 接入说明](FUNASR_MLT.md)。

## 2026-10-28：Qwen3-ASR 第三套识别引擎（0.3.0）

- 已下载固定 Hugging Face revision `68818b2313fe77bd06f6a7c5068ff3ef59d02b8a` 的 Qwen3-ASR 0.6B INT8、tokenizer，并配套 Silero VAD；七份必需文件共 **987,659,201 字节**。`python3 scripts/prepare_qwen_models.py --verify-only` 再次验证全部 SHA-256；许可证、来源、manifest 和 tokenizer 子目录完整，没有 `.part` 文件。
- 新增独立 Qwen 引擎、模型导入扩展、配置区、默认目录及第三套结果展示；版本 0.3.0。原有 SenseVoiceEngine、AppleSpeechEngine、WhisperLanguageDetector、AppleSpeechDiagnostics、AppleTextCorrector、Audio 目录及 `runBoth` 方法与当前 Git HEAD 完全一致。原生依赖版本与最低 iOS 26.0 不变，iOS 静态库已确认含 Qwen 实现符号。
- 核心 **11,965** 项断言通过，新增三引擎批次持久化、失败结果不纠错、单引擎运行不混入旧 Qwen 结果及导出兼容检查。
- `bash scripts/check_audio.sh Models/VoiceBenchModels Models/WhisperTiny_INT8 Models/Qwen3ASR_0_6B_INT8` 编译通过；初次执行在工具沙箱中无法读取 macOS 备份属性，获准在沙箱外运行已编译校验程序后三套实际模型全部通过导入、校验与清理。新增合成文件检查覆盖 tokenizer 缺失 / 未传完、失败替换保留旧权重、独立模型集、启动复用、备份排除、外部原件保留；真实删除检查覆盖三套历史结果、Qwen 派生音频、共享模型保护、默认目录断链与清除全部。
- `bash scripts/check_apple_speech.sh` 通过原有 PCM 尾块、格式转换、语言区间、取消、底层错误和诊断报告检查。未运行 SpeechAnalyzer 或苹果系统资源下载。
- 真实 sherpa C API + targeted concurrency 类型检查通过，包括新增 Qwen、存储和现有 SenseVoice。全部 App Swift frontend parse、XcodeGen 工程生成、pbxproj / plist、脚本及 Git 文件检查通过。
- 尝试链接真实 Mac Qwen 推理程序，旧 macOS SDK 缺少 ONNX Runtime 所需的 `MLComputePlan`、`MLOptimizationHints`，未能完成链接。**没有得到本次 Qwen 的实际推理输出、手机准确率或内存数据。** 可选真实样例验证程序为 `scripts/QwenSmoke.swift`。
- 尚未执行本次更新的 iOS SDK 编译、GitHub Actions 或 iPhone 安装测试。模型未放入 Git / IPA，云端沿用原有手动构建流程。手机配置和验收步骤见 [Qwen 接入说明](QWEN_ASR.md)。

以下为历史版本的验证记录。

日期：2026-09-24。执行环境：MacBook Pro，M1 Pro，16GB，macOS 13.7.8，Apple Swift 5.8.1 / Command Line Tools。未安装 Xcode，未连接 GitHub 仓库，未连接 iPhone。

## 已实际完成

| 检查 | 结果与范围 |
|---|---|
| 核心 Swift 编译 | `swiftc` 编译真实 `VoiceBenchCore`，通过 |
| 核心逻辑 | 11,930 项断言通过；含短字符串穷举编辑距离交叉验证、diff 双向重建、Unicode、空参考稿、RTF、失败状态、纠错保护、报告 JSON |
| 音频转换 | 真实 AVAudioConverter 将 48kHz 双声道合成 WAV 转为 16kHz 单声道；49,123 输入帧得到 16,374 输出帧，尾部误差小于 2 帧 |
| 取消与哈希 | 取消标记中止转换；SHA-256 及导入元数据验证通过 |
| 本地存储 | 音频导入、保存、读取、旧 revision 拒绝、删除后阻止旧保存复活记录，通过 |
| 模型导入 | 完整指定模型的导入与再次替换通过；缺失 / 损坏文件被拒绝，失败导入不破坏原模型 |
| 模型准备 | 已下载指定 INT8 模型、tokens、Silero VAD，生成 manifest 并锁定哈希；目录位于 `Models/VoiceBenchModels` |
| iOS 二进制依赖 | sherpa-onnx 1.13.8 与 ONNX Runtime 1.28.2 下载完成，SHA-256 与固定发布值匹配 |
| 原生 C API 类型检查 | 使用真实 sherpa-onnx 头文件，对 SenseVoiceEngine、AudioFiles、LocalStore 在本机 SDK 下类型检查，通过；这不是 iOS 链接测试 |
| 全部 App Swift 语法 | 本机编译器执行 frontend parse 通过；不包含新版 Apple API 类型检查 |
| 工程生成 | XcodeGen 2.44.1 生成 `VoiceBench.xcodeproj` 与共享 scheme，通过 |
| 工程 / 脚本格式 | pbxproj / plist、Python 语法、shell 语法、JSON、部署版本静态检查通过 |

音频合成样例仅用于转换和存储测试，不含真人语音，也没有伪造 ASR 文本。报告格式样例中的文本明确标为合成测试数据。

测试中发现并修复了 AVAudioFile 到达 EOF 后再次读取引起的错误；转换回调现先检查实际读取位置，并显式排空转换器尾部。文件内存格式与落盘格式的交错设置也已分开处理。

## 尝试过但未通过 / 无法执行

- `swift test`：本机只有 Command Line Tools，缺少完整平台路径，无法运行 XCTest。独立 Swift 校验程序已实际执行；正式 XCTest 留给云端 Xcode 环境。
- Mac SenseVoice 端到端烟雾测试：下载并校验了相同版本的 Mac 库和官方中文样例，尝试链接共享的推理代码；旧 macOS SDK 缺少 `MLComputePlan`、`MLOptimizationHints`，链接未通过。**没有获得真实 ASR 输出，不算识别测试成功。**不为这个辅助测试安装 Xcode 或替换手机目标版本。
- iOS SDK 编译、IPA 生成：本机没有 iPhoneOS SDK，且用户要求暂不连接 GitHub，因此未执行。
- iPhone 安装、麦克风、SpeechTranscriber、Foundation Models、飞行模式和手机性能：全部待真机验证。

## 下一步验收顺序

1. 用户允许连接 GitHub 后，运行准备好的手动构建工作流，处理 iOS SDK 编译器实际报告的问题。
2. 免费签名安装到 iPhone 17 Pro / iOS 27，验证启动、录音和持久化。
3. 导入指定模型并准备苹果中文资源，确认两引擎实际就绪。
4. 同一条中文录音分别运行两引擎，再在飞行模式且 Wi-Fi 关闭的情况下复测。
5. 验证取消、后台中断、长录音、空白录音和多次运行，导出报告核对。
6. 单独验证可选 LLM 纠错与 CER，再补 iOS 26 旧机测试。

## 可重复执行的本机命令

```sh
bash scripts/check_local.sh
bash scripts/check_audio.sh Models/VoiceBenchModels
swiftc -frontend -parse VoiceBench/App/*.swift VoiceBench/Audio/*.swift \
  VoiceBench/Storage/*.swift VoiceBench/Engines/*.swift VoiceBench/Correction/*.swift
swiftc -typecheck -module-cache-path .build-local/module-cache \
  -I .build-local -F Vendor/sherpa-onnx.xcframework/ios-arm64 \
  VoiceBench/Audio/AudioFiles.swift VoiceBench/Storage/*.swift \
  VoiceBench/Engines/SenseVoiceEngine.swift
.tools/xcodegen/bin/xcodegen generate --spec project.yml
plutil -lint VoiceBench.xcodeproj/project.pbxproj VoiceBench/Info.plist
```

只包含已经发生的检查；没有手机 CER、手机 RTF、内存或能耗的测试结论。

## 后续：数据生命周期审计

用户已反馈首版云端 IPA 构建成功并下载。本节记录后续清理修复，与首版本地验证分开。

- 修复临时报告未及时删除、录音保存失败残留、音频复制失败残留；统一私有临时目录，增加冷启动残留清理和无 metadata 音频清理。
- 录音、结果和模型目录全部排除后续设备备份；新增主动清除全部数据及释放本 App 的苹果语音资源预留入口。
- 真实本地文件测试通过：备份属性、无效音频导入、失败报告生成、分享清理、异常退出恢复、完整模型导入与替换、全量清除、旧保存拒绝、外部原件 / 导出副本保留。
- 本机执行备份属性读取需要访问 macOS 备份服务，初次在工具沙箱内被拒绝；获准在沙箱外仅运行临时测试后通过。
- 新版界面、Speech 资源释放调用、分享回调和 iPhone 删除 / 重装仍需新一轮云端编译和真机验证；未声称已验证苹果共享模型立即回收。
- 新增固定模型目录 `Documents/SenseVoiceSmall_INT8`：本机真实文件测试已验证首次自动导入、重复启动不覆盖已安装模型、完整性 / SHA-256 校验、备份排除属性以及“清除全部”后模型源目录为空；仍需新的云端构建与 iPhone“文件”App 路径真机确认。

## 2026-10-27：Apple Speech 输入与诊断

- USB 实时日志捕获到此前版本两次相同失败：成功加载本地语音模型并输入 35 块共 283,946 字节（16 kHz 单声道 Int16，141,973 帧），在 2,709 帧尾块后出现 `Foundation._GenericObjCError Code=0`。该现象支持排查文件末尾处理，但尚不能证明系统缺陷。
- Apple 输入改为按需读取的 `AnalyzerInput` 序列，显式处理剩余帧数及结束时间；保留系统返回的兼容格式。新增带运行 ID 的阶段日志，并将成功 / 失败诊断保存到现有 JSON 报告。
- `bash scripts/check_apple_speech.sh`：实际执行并通过核心 11,930 项检查，以及 Int16 / Float32、交错 / 非交错、1 / 4096 / 8192 / 141973 帧等 16 组 PCM 文件读取、真实 48 kHz 双声道到 16 kHz 单声道 Int16 转换、独立缓冲区、空输入拒绝、取消、底层错误与报告导出检查。
- 全部 App Swift 源码的 frontend parse、工程生成、pbxproj / plist 检查和 Git 文件检查通过。GitHub Actions 已增加相同 PCM 和诊断检查。
- 本机仍为 Swift 5.8.1 / Command Line Tools，没有 iOS 26 SDK；上述结果不包含新版 Speech API 的 iOS SDK 编译、SpeechAnalyzer 执行或修改后的真机识别结果。详细复测方法见 [Apple Speech 调试](APPLE_SPEECH_DEBUG.md)。


## 2026-10-27：方案 B / Whisper Tiny 自动语言检测

用户已反馈上一版 SenseVoice 和 Apple Speech 均能在 iPhone 上识别。本节仅记录新的自动语言检测修改，不把上一版真机成功当作本次集成验证。

- 已将多语种 Whisper Tiny INT8 下载到 `Models/WhisperTiny_INT8`，encoder、decoder、独立 Silero VAD 总计 **103,437,027 字节**。按固定 Hugging Face revision 和内置 manifest 验证三份 SHA-256，并再次运行准备脚本验证已有文件。MIT 许可、VAD 许可与来源记录随目录保留。
- 新模型未进入 Git / IPA；工程新增的资源仅为小型校验清单和许可。最低系统仍为 iOS 26.0。
- 11,949 项核心断言通过，新增后段语言切换、混说主要语言、并列选择、静音 / 未知、短输入、相邻语音保护区、合并时长上限、计划编码和旧版本记录兼容检查。均为合成标签逻辑测试，不是准确率结论。
- `bash scripts/check_audio.sh Models/VoiceBenchModels Models/WhisperTiny_INT8` 通过真实文件测试：两套完整模型导入、Whisper 默认自动发现、重复启动复用、手工替换、损坏文件拒绝、模型集隔离、备份排除、清除全部和外部原件保留。云端不依赖大模型的合成 manifest 测试也已纳入该脚本。
- `bash scripts/check_apple_speech.sh` 通过，新增区间起止、从零开始的 analyzer 时间、源录音偏移、非整数帧边界一致舍入、尾部夹取和非法区间拒绝；原有 EOF、格式、取消与诊断序列化继续通过。
- 使用真实 sherpa-onnx 1.13.8 C 头文件，对 WhisperLanguageDetector / SenseVoiceEngine 做 targeted concurrency 类型检查通过。现有 iOS 静态库导出了语言检测所需符号，不升级原生依赖。
- 已重新生成 Xcode 工程；全部 App Swift 语法、pbxproj / plist、脚本 / JSON / Git 文件检查通过。
- 本机仍没有 iOS SDK；**本次更新尚未完成 iOS 编译、Whisper 原生推理或新流程的 iPhone 运行测试**。先云端构建，再用纯中文、纯英文、句间切换、句内混说、短语音、静音各试一次，核对检测明细、实际 Apple locale、原文、耗时与资源缺失提示；下载资源后断网复测。

可重复验证：

```sh
python3 scripts/prepare_language_models.py
bash scripts/check_audio.sh Models/VoiceBenchModels Models/WhisperTiny_INT8
bash scripts/check_apple_speech.sh
swiftc -typecheck -strict-concurrency=targeted -module-cache-path .build-local/module-cache \
  -I .build-local -F Vendor/sherpa-onnx.xcframework/ios-arm64 \
  VoiceBench/Audio/AudioFiles.swift VoiceBench/Storage/AppTemporaryFiles.swift \
  VoiceBench/Engines/SenseVoiceEngine.swift VoiceBench/Engines/WhisperLanguageDetector.swift
```


## 2026-10-27：按草图重构录音卡片界面（0.2.0）

- 主界面改为录音卡片列表；左上 + 打开录音浮层，圆形开始 / 方形停止互斥，停止后自动保存关闭；设置为独立可返回页面。新录音使用简短序号名称，导入音频保留原文件显示名。
- 每次点击卡片识别，会先保存同一 `batchID` 的两条排队记录，再依次运行两套引擎。卡片显示最新一轮；旧版数据无 batch ID 时保持可读。取消也关闭尚未运行的排队项。
- 卡片纠错依次处理本轮成功且非空的识别结果。完成后才显示展开 / 收起三角；历史结果、评测、导出、纠错明细及单引擎调试保留在详情页。
- 全部卡片操作使用明确的录音 ID；播放状态可切换，播放完成复位，删除先释放播放器。忙碌、录音或分享期间禁用删除，避免任务与清理交错。
- 三条音频处理路径与临时报告均使用每条录音独立工作目录。删除同时移除音频内部副本、含全部历史结果的 metadata 与整个工作目录；共享模型和其他录音不受影响。
- `bash scripts/check_audio.sh Models/VoiceBenchModels Models/WhisperTiny_INT8`：通过真实音频转换、简短显示名保存、两录音删除隔离、全部历史识别 / 纠错删除、临时 CAF / 报告清理、重复删除、迟到保存与分享回调、模型集导入及备份属性检查。
- `bash scripts/check_apple_speech.sh`：通过。核心断言增加到 **11,958** 项，新增本轮结果选择、排队时不混入旧纠错、失败结果不可纠错、进行中的纠错不冒充完成、批次持久化和旧数据兼容检查。
- 全部 App Swift frontend parse、真实 sherpa C API / 存储类型检查、XcodeGen 工程生成和 plist 校验通过。上述结果不包含新 SwiftUI 界面的 iOS SDK 类型检查、实际布局截图或交互自动化；本机没有完整 Xcode / iPhoneOS SDK。

真机验收：新建两条录音并分别识别 / 纠错；确认两种录音按钮不同时出现、停止后新增卡片；进入设置后返回；两套结果逐个更新；纠错三角出现并能反复收放；新一轮识别不展示旧纠错；播放完成图标恢复；删除一条后重启 App，另一条音频 / 结果 / 模型仍能使用。再验证取消、后台中断、导入、历史详情和导出。


## 2026-10-27：0.2.1 清理修复

- 上一版对存在 / 不存在路径分别调用 Foundation 规范化，导致 `/private` 别名处理不一致。本机用上一版真实 `AppTemporaryFiles.remove` 稳定复现：根目录存在、带 `/private` 前缀且目标已不存在时，内部合法目录被拒绝。
- 路径验证改为一致的物理路径与组件边界，缺失目标允许重复清理；保留越界拒绝，正确处理最终符号链接节点及断开链接，不跟随外部目标。
- 新增 `scripts/CleanupChecks.swift`，由已有 `check_audio.sh` 和 GitHub Actions 自动运行：真实文件覆盖物理 / 别名路径交叉组合、目标及根目录缺失、重复删除、父目录越界、同名前缀兄弟目录、非 file URL、中间符号链接越界、安全内部符号链接、最终链接安全删除、临时根被替换为链接，以及完整单条录音删除。
- 清除全部测试将 Application Support、Documents、临时目录分开；填入两类模型、未知残留、未完成导入、音频、多引擎历史结果及纠错、嵌套 CAF、临时报告和旧版残留，确认清理后各拥有目录为空、外部原件仍在。另验证断开模型目录链接、迟到保存、分享回调、重复清理和重启后重新使用。
- 模拟临时目录父节点变成普通文件：清除全部继续删除录音及默认模型目录，但明确报错；修复该节点后重试完成。失败不虚报清理成功。
- 核心 11,958 项逻辑检查、完整 SenseVoice / Whisper 模型导入与存储生命周期测试继续通过。新存储代码的主机类型检查、App Swift 语法检查和工程配置检查通过；没有声称已完成本次 iOS 编译或 iPhone 运行验证。


## 2026-10-28：0.2.2 设置简化

- 移除设置页的系统配置区域及对应的手工语言、低内存模式、运行顺序切换状态和逻辑。
- SenseVoice 原生识别接口固定 `language=auto`，不再接收手工语言参数；SenseVoice / Whisper 沿用原默认 2 线程、25 秒 VAD 上限。双引擎识别顺序固定为 SenseVoice → Apple Speech。
- 同步修改调用接口、运行报告配置与原生烟雾测试脚本，保留模型导入、苹果语言资源准备、纠错状态及全部数据清理入口。
- `check_local.sh` 的 11,958 项核心检查通过；全部 App Swift 语法检查，以及真实 sherpa C API 下 SenseVoice / Whisper 与烟雾测试脚本的 targeted concurrency 类型检查通过。已检查没有残留的可调状态引用。未执行本次 iOS SDK 编译或真机识别。
