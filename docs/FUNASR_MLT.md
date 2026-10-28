# Fun-ASR-MLT-Nano ONNX INT8（0.4.1）

作为独立第四套识别引擎接入。保持 SenseVoice、Apple、Whisper、Qwen 的现有引擎实现及导入流程，继续使用 sherpa-onnx 1.13.8 / ONNX Runtime 1.28.2，最低系统 iOS 26.0 不变。

## 本机模型与手机放置

本机目录：`Models/FunASR_MLT_Nano_INT8`。来源为社区转换 [luigi000/fun-asr-mlt-nano-onnx-int8](https://huggingface.co/luigi000/fun-asr-mlt-nano-onnx-int8/tree/932d7dbb98623bd31314015b3bc0dac0dcf80acc)，固定 revision `932d7dbb98623bd31314015b3bc0dac0dcf80acc`。转换者声明基于 `FunAudioLLM/Fun-ASR-MLT-Nano-2512`。三份权重均不同于 sherpa 常见普通 Nano 包，未替换为普通三语 Nano。

十份必需文件共 **1,010,411,868 字节**，约 **1.01 GB / 964 MiB**。权重及 tokenizer.json 按上游 LFS SHA-256 验证；普通 tokenizer 文件及 LICENSE / NOTICE 首次准备时按固定 revision 的 Git blob 验证，再锁定全部必需文件 SHA-256 到 `config/funasr-mlt-model-manifest.json`。

```text
FunASR_MLT_Nano_INT8/
  encoder_adaptor.int8.onnx
  embedding.int8.onnx
  llm.int8.onnx
  silero_vad.onnx
  tokenizer/
    tokenizer.json
    vocab.json
    merges.txt
    tokenizer_config.json
    config.json
    generation_config.json
  manifest.json
  LICENSE
  NOTICE
  VAD_LICENSE
  SOURCE.txt
  EXPORT_METADATA.json
```

使用 Finder 文件共享或“文件”App，把整个目录复制到 **在我的 iPhone → 语音对比（或 VoiceBench）→ FunASR_MLT_Nano_INT8**。避免出现双层同名目录，保留 tokenizer 子目录，不直接选择 ZIP。

与 Qwen 相同：

- 首次打开新版创建空的默认目录；文件传完后，重开 App 或设置中“检查状态”自动导入一次。
- “从默认目录载入 Fun-ASR-MLT-Nano”可主动重新载入。
- “选择其他 Fun-ASR-MLT-Nano 目录…”经系统选择器授权读取；复制并验证后使用内部副本，重启无需重新选择。
- 未传完不自动导入；缺文件或校验不通过时明确报错，失败替换保留原有模型，导入中间目录及时清理。

默认源目录及内部副本合计约 2 GB；替换时还有暂存副本，可能约 3 GB。模型不打入 IPA、不上传 Git，未引入 Git LFS。相同账号及最终 Bundle ID 下，Sideloadly 覆盖安装可保留现有数据；先删除 App 会移除沙箱及默认模型文件。

## 识别与限制

载入后主卡片“识别”依次运行 SenseVoice、Apple、已载入的 Qwen、已载入的 Fun-ASR，各自保存结果、耗时和失败。详情 → 调试运行 → **仅 Fun-ASR-MLT-Nano** 可独立测试，不要求 Apple、Whisper 或 Qwen 就绪。任一引擎失败继续下一套，取消停止本轮；纠错、参考稿评测、历史及导出沿用现有流程。

Fun-ASR 使用自身多语转写，空语言提示，不经过 Whisper。原生提示仅为 `You are a helpful assistant.` / `语音转写：`，不加入用户参考稿、背景或热词。启用 ITN 以匹配原生默认文本规整；后续 Foundation Models 纠错仍为独立步骤。CPU 2 线程，16 kHz 单声道，80 维特征，LFR 7:6，temperature 0.000001 / top_p 1 / seed 0。

实际 ONNX 元数据为 **512-token KV，包含音频、提示和文字**；不能用原文本骨干配置中的 40960 代替此导出的容量。0.4.0 只检查是否达到 256 个生成 token，无法发现音频已占满大部分 KV、输出提前在 256 以下停止的情况。0.4.1 改为联合预算与按需重试：

1. 保留短提示，原生 tokenizer 实测音频前 18、音频后 5，共 **23 token**。不传入前段转写、参考稿或热词占用窗口。
2. 使用固定导出的 10 ms 特征帧和 LFR 7:6 契约，按实际输入采样数计算音频 token 的保守上界；加上 23 个提示 token，再预留 **16 token** 安全空间。可用输出不足 64 时直接细分，不运行该段推理。
3. 原生 `max_new_tokens` 设为 512，消除原先人为的 256 输出限制；总容量仍是 512。推理结束后，只有生成计数不超过上述安全预算，才接受该段文字。原生接口未提供 EOS / KV 耗尽的停止原因，因此接近上限时一律重试，不能把“少于 max_new_tokens”当作完整结束的证明。
4. Silero VAD 优先按自然停顿切分，最长约 **20 秒**，两侧最多补 200 ms；相邻极短尾段可合并保留上下文（合并范围最多 32 秒）。正常段一次完成，仅超预算的段在中部附近低能量处二分，最多重试 4 层，每个子段至少 2 秒。先销毁可疑推理流并丢弃其文字，再按源音频次序重跑子段。子段采样区间首尾相接，没有跳帧、重复拼接父结果或按文字猜测去重。
5. 无法安全细分、原生返回无效计数或语音段无文字时明确失败，保留已通过检查的片段。Fun-ASR 专用读取器循环读取至区间的最后一帧，处理 AVAudioFile 单次读取不足但尚未 EOF 的情况；其他引擎的音频实现保持原样。

预算契约绑定当前十份模型哈希与 sherpa-onnx 1.13.8，更换导出必须重新验证 tokenizer 和 encoder 长度。此策略避免接受因已知 KV 上限而可能截断的结果，**不等于保证 ASR 无漏字、无幻觉或分段边界对语义完全无影响**。仍须用手机上的快语速、长句和混说录音对照参考稿。

只记录 VAD / 重分段的音频区间，忽略原生均匀分配的 token 时间戳，不提供伪造逐字对齐或语言标签。诊断日志前缀 **VoiceBenchFunASRMLT**，含 run ID、阶段、片段区间和错误码；不输出录音及转写正文。报告保存配套文件哈希、实际参数、错误阶段、临时清理结果，以及每次尝试的输入上界、生成数、接受 / 重试决策，详见 [报告格式](REPORT_FORMAT.md)。

同步原生推理期间不能立即打断，取消在当前片段推理返回后生效。模型 / VAD / stream / result 均在结束时销毁；无需同时加载多套本地大模型。

## 数据清理

工作模型在 `Library/Application Support/VoiceBench/FunASRModels`，默认源文件在 `Documents/FunASR_MLT_Nano_INT8`。派生音频为 `tmp/VoiceBench/Recording-录音UUID/FunASR-UUID.caf`。成功、失败、取消及下次冷启动清理，删除录音再次删除其整个工作目录及全部历史结果。

删除单条录音保留共享模型与其他录音。“清除全部本机数据与模型”同时清空内部 Fun-ASR、receipt、默认源目录及临时文件，仅重建空目录。手选 App 外原件保留。默认目录及内部副本排除系统备份，系统“删除 App”会删除私有沙箱。

## 验证与构建

```sh
python3 scripts/prepare_funasr_models.py --verify-only
bash scripts/check_audio.sh Models/VoiceBenchModels Models/WhisperTiny_INT8 Models/Qwen3ASR_0_6B_INT8 Models/FunASR_MLT_Nano_INT8
bash scripts/check_apple_speech.sh
```

本次用同版本 macOS sherpa-onnx 与 ONNX Runtime 动态库完成实际 Fun-ASR 推理：短中文、连续绕口令、快速语音及 21.5 秒高密度拼接样例通过。压力样例实际触发一次预算重试，父段 131 个生成 token 超过 112 的安全预算，被丢弃；两子段分别生成 79 / 67 个 token，完整覆盖父段采样区间且通过检查。它是上下文压力测试，不是准确率评测。

可选复现命令（需自行准备匹配版本的 macOS 库，脚本不下载依赖，也不改变 iOS 链接）：

```sh
FUNASR_MAC_FRAMEWORK_DIR='/绝对路径/sherpa-onnx.xcframework/macos-arm64_x86_64' \
FUNASR_MAC_ORT_DIR='/绝对路径/包含libonnxruntime.dylib的目录' \
bash scripts/check_funasr_native.sh Models/FunASR_MLT_Nano_INT8 /路径/语音.wav /路径/报告.json
# 对已知会触发重试的高密度样例，可在最后加 --require-retry 验证此路径。
```

要求 sherpa-onnx 1.13.8 / ONNX Runtime 1.28.2；本次测试用后者的 macOS 动态库，绕开旧 SDK 无法链接部分 CoreML 静态符号的限制。本机没有 iPhoneOS SDK，**尚未完成 0.4.1 的 iOS 编译、手机准确率、速度及峰值内存测试**。

云端沿用既有手动工作流，无需额外 Secrets 或在 CI 下载权重。推送后手动触发 Actions，取得新版 IPA，用相同账号 / 最终 Bundle ID 的 Sideloadly 覆盖安装，已载入的相同模型可继续使用。先单独验证中文、英文、混说、快速语音及超过 20 秒的连续语音，检查段落首尾和预算记录；再验证四套对比、取消、后台中断、删除单条后重启和清除全部。
