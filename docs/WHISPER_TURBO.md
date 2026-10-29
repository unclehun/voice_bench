# Whisper large-v3-turbo INT8（0.7.1）

0.7.1 修复 sherpa-onnx 1.13.8 在逐 BPE token 清理 UTF-8 时丢字的问题。运行时生成临时 ASCII 传输词表，保持 token ID 与权重，读取原生 token 数组后先拼接字节、再解码成文字。原始词表、manifest、receipt 与模型版本保持不变，已安装模型可继续使用；重新识别会记录 `whisper_turbo_text_decoder=base64-ascii-join-bytes-v1`。详见 [接入审计及真实录音对照](WHISPER_TURBO_AUDIT.md)。

## 模型与获取

使用 OpenAI Whisper large-v3-turbo **多语言**模型的 sherpa-onnx INT8 导出。固定仓库为 [csukuangfj/sherpa-onnx-whisper-turbo](https://huggingface.co/csukuangfj/sherpa-onnx-whisper-turbo/tree/2ca6ff69fc878651b770880507669577ac41c2ff)，revision `2ca6ff69fc878651b770880507669577ac41c2ff`。模型与 VAD 的 SHA-256 固定在 `config/whisper-turbo-model-manifest.json`；大文件校验值来自上游 LFS 元数据，词表另核对固定 Git blob。四份必需文件合计 **1,037,257,645 字节**，约 1.04 GB / 989 MiB。

```sh
python3 scripts/prepare_whisper_turbo_models.py
python3 scripts/prepare_whisper_turbo_models.py --verify-only
```

下载到工程 `Models/WhisperLargeV3Turbo_INT8`。文件夹包含：

```text
WhisperLargeV3Turbo_INT8/
  turbo-encoder.int8.onnx
  turbo-decoder.int8.onnx
  turbo-tokens.txt
  silero_vad.onnx
  manifest.json
  LICENSE
  VAD_LICENSE
  SOURCE.txt
```

下载中使用 `.part` 文件，通过 SHA-256 后才安装；支持断点续传，已有正式文件不匹配时明确报错。模型不提交 Git、不进入 IPA，CI 仅需源码、小型校验清单及许可证。

## 手机导入与操作

通过 Finder 文件共享或“文件”App，把完整文件夹传入 **在我的 iPhone → 语音对比（或 VoiceBench）→ WhisperLargeV3Turbo_INT8**。新版启动会创建空的默认目录，文件直接放在里面，避免同名文件夹多套一层。

- 首次启动或设置“检查状态”在未安装时自动载入完整目录，传输未完成时不会导入。
- 设置中可“从默认目录载入 Whisper Turbo”，或“选择其他 Whisper Turbo 目录…”。
- 导入先复制、逐文件验证 SHA-256 及可选传输 manifest，再原子替换内部目录；失败保留已安装模型及其他引擎。
- 加载成功后，卡片“识别”按 SenseVoice → Apple → 已载入的 Qwen → Fun-ASR → Whisper Turbo 顺序运行，最多五套。
- 详情 → 调试运行 → “仅 Whisper large-v3-turbo”可独立执行，不要求其他模型或 Apple 资源就绪。
- 原始结果、Apple / DeepSeek 两路纠错、CER、JSON / Markdown 导出、历史运行沿用统一流程。

这套完整 ASR 与旧版 Whisper Tiny 语言检测使用不同的模型标识、目录和 receipt；不会恢复 Apple 的前置语言检测。

## 转写参数与边界

沿用 Qwen 的输入方式：相同原始录音转成 16kHz、Float32、单声道；Silero VAD 阈值 0.5、窗口 512、最短静音 0.6 秒、最短语音 0、最大语音段 20 秒，每段首尾最多补 200ms，起点夹取到上一段末尾防止重复。使用 sherpa-onnx 1.13.8 / ONNX Runtime 1.28.2，CPU 两线程，VAD 一线程。

Whisper 使用 128 维特征、`greedy_search`、`task=transcribe`、空语言提示（模型内部自动检测）、300 帧内部尾部补齐。无外部语言检测、按语言切段、参考稿、热词或文字提示。Apple 的默认语言不影响它。

每个送入识别器的区间必须少于 29 秒，避免原生 30 秒窗口静默丢弃尾部。当前 sherpa 解码还按约每秒 6 个 token 和 `text_ctx/2` 限制生成长度；接近预算时丢弃该候选，将同一段末尾补静音到 29 秒后最多重试一次，增加原生生成预算；不改变 VAD 区间、展示时间或前后片段。重试仍接近上限时明确失败，保留此前完成片段及错误诊断，不能作为完整转写参加准确率排名。报告记录重试次数、原始 token 数和补静音采样数。这个保护仍可能对高密度语音保守报错，需要真机核对。

报告记录模型版本、文件哈希、输入和 VAD 参数、输出 token 数与保护阈值、预算重试次数、完成片段数、错误阶段和临时文件清理情况。段落时间是 VAD 区间，语言标签来自 Whisper 原生输出，不是逐字时间对齐或混读语言边界。日志筛选 `VoiceBenchWhisperTurbo`，只含 run ID、阶段、区间、错误码，不输出音频或转写内容。

## 数据生命周期

内部模型在 `Library/Application Support/VoiceBench/WhisperTurboModels`，默认源目录在 `Documents/WhisperLargeV3Turbo_INT8`，均排除系统备份。覆盖更新和重启复用内部模型。

派生音频在 `tmp/VoiceBench/Recording-录音UUID/Whisper-UUID.caf`，临时传输词表在同目录的 `WhisperTokens-UUID.txt`。成功、失败、取消、删除录音及冷启动清理。取消在原生同步推理的片段之间生效。传输词表只含公开模型 token，不包含录音、转写或 API Key。

删除一条录音清理其全部历史五套结果、纠错及工作目录，保留共享模型和其他录音。“清除全部本机数据与模型”同时清空内部模型、receipt、默认 Documents 源目录和临时文件。App 外部手选原件保留。系统“删除 App”删除该沙箱数据。

## 验证与构建

```sh
bash scripts/check_audio.sh Models/VoiceBenchModels Models/WhisperTiny_INT8 Models/Qwen3ASR_0_6B_INT8 Models/FunASR_MLT_Nano_INT8 Models/WhisperLargeV3Turbo_INT8
```

上述检查覆盖默认 / 手动导入、传输不完整、SHA-256 拒绝、替换隔离、重启复用、备份排除、完整清理，以及实际下载模型的导入与删除；不代表识别准确率评测。

具备匹配的 macOS 原生库时，可执行共享 Swift 引擎的实际推理检查：

```sh
WHISPER_MAC_FRAMEWORK_DIR='/绝对路径/sherpa-onnx.xcframework/macos-arm64_x86_64' \
WHISPER_MAC_ORT_DIR='/绝对路径/包含libonnxruntime.dylib的目录' \
bash scripts/check_whisper_turbo_native.sh Models/WhisperLargeV3Turbo_INT8 /路径/语音.wav /路径/报告.json
# 对已知触发预算重试的混读样例，追加 --require-retry；追加 --check-lifecycle 检查解码后取消和静音。
```

本次在 Mac 上实际通过中文、预算重试、21.5 秒拼接压力样例、10.846 秒受控中英混读、32.539 秒受控混读长音频（6 段、3 轮内容完整保留）、预取消、解码后取消、静音及临时音频清理检查。合成音频中仍有误识，这些检查验证运行路径，不是手机准确率或性能结论。

本机没有 Xcode / iPhoneOS SDK。iOS 编译沿用现有 GitHub Actions 手动工作流，无需在 CI 下载模型或增加 Secrets。新版手机验收应覆盖中文、英文、中英混读、数字、专名、超过 20 秒连续语音、静音、取消、后台中断、五套对比、纠错 / 导出及清理。对用户提供的 10 段录音保留全量主评分，不能预先宣称它优于现有模型。
