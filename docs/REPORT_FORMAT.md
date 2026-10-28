# 报告格式 v1

`VoiceBench.json` 为结构化报告，`VoiceBench.md` 为同次导出的阅读版。`report-example.json` 是合成的格式样例，不是真实 ASR 测试结果。

| JSON 路径 | 含义 |
|---|---|
| `schemaVersion` | 报告格式版本 |
| `environment` | 导出设备、OS、App build 等；每次运行自己的环境同时保存在 run configuration |
| `recording.sha256` | 原始音频文件哈希，各套引擎共用 |
| `recording.duration` | 原始音频秒数 |
| `recording.reference` | 人工参考稿，只用于评测 |
| `recording.runs[]` | 每次转写记录；反复运行会追加，原记录不覆盖 |
| `runs[].batchID` | 可选；同一次点击“识别”创建的各套引擎运行共用该 ID。主卡片只展示最新一轮；旧记录缺省时按引擎取最新结果 |
| `runs[].engine` | `sensevoice_small_int8` / `apple_speechtranscriber` / `qwen3_asr_0_6b_int8` / `fun_asr_mlt_nano_int8` |
| `runs[].status` | `running` / `completed` / `failed` / `cancelled` / `interrupted` |
| `runs[].preparationMS` | 本次模型初始化和准备耗时，不含资源下载 |
| `runs[].transcriptionMS` | 格式转换、切分、推理、拼接耗时；仅完成时记录完整值 |
| `runs[].rawText` | 原始识别文字，未做 LLM 修改 |
| `runs[].segments[]` | 片段文本、实际起止秒数；不是跨引擎统一逐字时间戳 |
| `runs[].languageDetection` | 可选；Whisper 模型版本、策略、初始化 / 检测时间、语音段的窗口标签与最终路由；旧记录没有此字段也可读取 |
| `runs[].segments[].language` | 可选；Apple 实际采用的语言或 SenseVoice 返回的标签，不是逐词语言标注 |
| `runs[].configuration` | 实际引擎配置、模型文件哈希、当时设备环境 |
| `runs[].correction` | 独立纠错状态、提示哈希、用户背景、输出、分块建议与采用文字 |
| `evaluation[]` | 按 runID 关联的 CER、纠错 CER、ΔCER 和 RTF |
| `evaluation[].rawCER` | 替换、删除、插入、参考 / 输出字符数及 rate |

没有获得的数据使用 null，不填 0 冒充测量。无参考稿的 CER 为 null；规范化后空参考稿的 CER 对象仍记录编辑计数，但 rate 为 null。失败 / 取消 ASR 不计算完整 CER 或 RTF。

本地保存的 metadata JSON 使用内部 Codable 日期格式；面向用户的导出报告使用 ISO-8601 日期。导出报告包含参考稿和用户背景，用户通过系统分享面板决定保存位置。

Apple Speech 的成功和失败记录现在都会在 `configuration` 中保存 `apple_*` 诊断字段，包含输入格式、帧数、阶段和底层错误；字段含义与 USB 采集步骤见 [Apple Speech 调试](APPLE_SPEECH_DEBUG.md)。


方案 B 的 Apple 路径：`preparationMS` 包含 Whisper 和各 Apple 会话初始化；`transcriptionMS` 包含语言检测格式转换、VAD、检测推理、Apple 格式转换与全部会话处理。`languageDetection.preparationMS` / `detectionMS` 可单独查看检测成本。若 Apple 在检测之后失败，计划和检测的部分耗时仍保留，但不计算完整 RTF。

`regions[].decision` 为 `detected` / `short_input` / `mixed_dominant` / `undetermined`，`observedLanguages` 是窗口标签集合，不是置信度候选。单个 VAD 段出现多种语言时，按窗口语音时长投票选主要语言；并列优先前段语言，否则最早窗口。相邻同语言可合并，Apple 会话最长约 120 秒。`spans[].windows[]` 保留所有窗口秒数和标签，用于诊断后段切换及误判。短于 1 秒的检测证据会警示，未确定语言会明确失败。静音没有路由。

`configuration.lid_model_sha256_*` 记录三份语言检测模型哈希，`lid_*` 记录检测参数及错误。`apple_input_pipeline=pcm_language_regions_v2`，`apple_locale_routes` 记录每段实际系统 locale 和源录音时间。送入每个 analyzer 的时间从零开始，保存的 segments 已加回源音频偏移。


卡片界面只改变展示方式；`recording.runs[]` 仍导出该录音的全部历史运行。`configuration.execution_state` 为 `queued` / `executing` / `finished`，排队行也使用 `status=running`，取消会同时关闭未执行的排队行。旧版无 `batchID` 的记录仍能读取。


Qwen 的 `modelVersion` 为 `qwen3-asr-0.6b-int8-2026-03-25-68818b2`。`qwen_model_sha256_*` 记录七份模型与 tokenizer 文件哈希；`qwen_*` 记录直接自动多语策略、128 维特征、1024 总序列长度、512 最大生成 token、496 保守输出长度检查、采样参数、已完成片段和错误阶段。`qwen_temporary_audio_removed` 记录派生音频清理结果。Qwen 不填写 `languageDetection` 或片段语言标签，其时间范围仅为 VAD 语音区间；不冒充逐字对齐。原有两套引擎的报告字段保持不变。


Fun-ASR-MLT 的 `modelVersion` 为 `fun-asr-mlt-nano-2512-int8-932d7db`。`funasr_mlt_model_sha256_*` 记录十份配套文件哈希；`funasr_mlt_*` 记录直接自动转写、空语言提示、ITN、80 维特征、导出 KV 上限 512、生成上限 512、20 秒 VAD 及按需预算重试和错误阶段。ITN 属于此 ASR 路径的文本规整，后续 Foundation Models 纠错仍独立记录。该引擎不消费 Whisper 计划，不使用原生均匀分配的 token 时间戳，只记录实际 VAD / 重分段区间，不伪造逐字对齐或语言标签。系统日志前缀为 `VoiceBenchFunASRMLT`，含运行 ID / 阶段 / 错误码，不写入语音和转写正文。

0.4.1 的 `funasr_mlt_context_policy=budget_retry_v2`。`funasr_mlt_prompt_tokens=23`、`funasr_mlt_budget_safety_tokens=16`；`funasr_mlt_attempt_count` / `retry_count` 是总尝试及重新细分次数，`min_accepted_headroom_tokens` 是最终接受片段的最小保守余量。`funasr_mlt_native_stop_reason` 明确原生接口不暴露停止原因，不能视作实测 EOS 状态。

`funasr_mlt_context_attempts_json` 为 JSON 数组字符串，逐项记录 `start_frame` / `end_frame`（16 kHz 源区间）、`depth`、`audio_tokens_upper_bound`、`prompt_tokens`、`prefill_upper_bound`、`safe_output_budget`、`generated_tokens`（预检未推理为 `not_decoded`）和 `decision`。决策为 `accepted` / `prefill_budget_retry` / `near_limit_retry` / `budget_exhausted`；仅 accepted 的文字会写入 segments。最多保存前 256 条，超出的数量记录在 `funasr_mlt_attempts_omitted`，汇总仍累计全部尝试。这些诊断属于录音 metadata，随单条删除或清除全部一起删除。
