# Apple Speech 调试

针对真机重复出现的 `Foundation._GenericObjCError Code=0`，Apple 输入路径改为 `pcm_chunks_v1`。此次修改是绕过文件输入辅助路径并补充诊断，是否解决真机错误需要新 IPA 验证。

## 输入与结束方式

- 保留系统选出的兼容格式，不强制改成 16 kHz 或 Float32。
- 继续使用同一份原始录音生成临时 CAF；记录源格式、选定格式、CAF 存储格式和读取格式。
- 用按需拉取的异步序列向 `SpeechAnalyzer.analyzeSequence(_:)` 提交 `AnalyzerInput`。每块最多 4096 帧，每次分配独立缓冲区，时间戳从派生文件的累计帧数计算。
- 读取前检查文件长度，最后一块仅请求剩余帧数，到达 EOF 后直接结束序列，不额外读取一次文件。
- 确认输入全部读完并取得有效末尾时间后，调用 `finalizeAndFinish(through:)`，继续等待结果流结束。
- 取消、中途失败和完成时关闭读取器并清理临时 CAF；失败的清理会记录错误，冷启动仍会清理私有临时目录中的残留。

## USB 日志

统一日志 subsystem 为 `com.voicebench.demo`，category 为 `AppleSpeech`，消息固定带 `VoiceBenchAppleSpeech` 前缀和本次运行 ID。这是运行记录中的 `run.id`，便于对应多次重试。

连接并解锁手机后，在已有 libimobiledevice 的 Mac 上开始实时采集，再点击“仅 Apple”：

```sh
idevicesyslog -p 'VoiceBench|localspeechrecognition' -o /tmp/voicebench-apple-speech.log
```

报错后按 Ctrl+C 停止。用下面的命令提取本 App 增加的诊断事件：

```sh
rg 'VoiceBenchAppleSpeech' /tmp/voicebench-apple-speech.log
```

正常事件主要为 `check_support` → `check_assets` → `select_format` → `prepare_analyzer` → `inspect_source` → `convert_audio` → `open_pcm` → `analyze_audio` → `input_eof` → `input_consumed` → `finalize_analysis` → `collect_results` → `cleanup_audio` → `completed`。并发的 `results_ended` 可能更早出现。

`input_progress` 只在首块、每 256 块及不足 4096 帧的尾块记录，不逐块刷屏。统一日志公开阶段、格式、计数和错误 domain/code，不记录音频样本或识别文字。

## 导出报告

无论成功或失败，导出的 JSON 都会在 `recording.runs[].configuration` 保存诊断。报告 schema 仍为 v1，原有记录可以继续读取。主要字段如下：

| 字段 | 用途 |
|---|---|
| `apple_input_pipeline` | 应为 `pcm_chunks_v1`，确认安装了新构建 |
| `apple_run_id` / `apple_stage_events` | 关联 USB 日志；保留最近 64 个阶段事件及相对时间 |
| `apple_selected_format` / `apple_file_format` / `apple_processing_format` | 比较系统要求、存储和实际输入格式 |
| `apple_total_frames` / `apple_read_frames` / `apple_input_eof` | 验证是否完整读取，不能把已读帧数单独当成系统已完成分析 |
| `apple_input_chunks` / `apple_last_chunk_frames` | 检查尾块和重现的边界 |
| `apple_last_sample_seconds` / `apple_final_segments` | 系统返回的结束时间和最终结果段数 |
| `apple_error_stage` / `apple_error_domain` / `apple_error_code` | 保留最先观察到的具体失败；若结果流先传播 CancellationError，优先保留随后到达的具体输入错误，清理错误不覆盖先前取消 |
| `apple_error_swift_type` / `apple_error_reflection` | 原始 Swift 错误类型与反射描述 |
| `apple_error_user_info.*` / `apple_error_underlying.*` | NSError 的 userInfo 和底层错误链；最多 5 层、每层 16 个字段、单值约 2048 字符，二进制只记录长度 |
| `apple_error_at_*` | 传播到各阶段的错误摘要，例如读取、分析、结果流 |
| `apple_temporary_audio_removed` | 本次创建的临时 CAF 是否已清理 |

完整错误描述保存在 App 私有运行记录及用户主动导出的 JSON，不公开写入统一日志。系统未提供 userInfo / 底层错误时仍可能为空；阶段和读取计数用于继续定位。

## 真机复测

使用此前失败的同一条录音运行“仅 Apple”，导出 JSON，核对 pipeline 和运行 ID，再运行一条新录音。取消和再次运行各做一次，检查临时文件清理标记。

- 新路径成功：支持文件输入辅助路径与该系统版本之间存在兼容问题的判断。
- `read_audio` 失败：结合位置和总帧数检查派生文件读取。
- `input_eof=true` 后在 `analyze_audio` / `receive_results` / `finalize_analysis` 失败：继续检查系统 Speech 处理和错误链；EOF 本身不能证明识别已完成。
- `open_pcm` 失败：比较三份格式及派生文件帧数。

不把 `Code=0` 当作成功或正常 EOF，不丢弃尾部音频，不自动切到其他识别引擎。

## 本机检查

```sh
bash scripts/check_apple_speech.sh
```

检查真实 AVAudioFile／AVAudioConverter 的 Int16 和 Float32 读写，包含 141,973 帧的重现边界、精确整块末尾、独立缓冲区、空文件、取消，以及错误链和报告序列化。该命令可在当前仅安装 Command Line Tools 的 Mac 上运行；它不包含 SpeechAnalyzer 或 iPhone 测试。GitHub Actions 已加入同一检查，之后仍会用真实 iOS SDK 编译 App。


## 方案 B：自动语言检测的新增诊断

新版 `apple_input_pipeline=pcm_language_regions_v2`，在原有逐块 EOF 处理之上按语言片段运行。先完成独立 Whisper Tiny 语言检测，并释放原生模型，再创建 Apple 会话。同一兼容格式的派生音频在本次运行内复用，所有会话结束或失败后统一清理。每个 PCM 区间使用从零开始的帧时间，保存文字时加回源音频偏移。

语言检测 category 为 `LanguageID`、日志前缀 `VoiceBenchLanguageID`。窗口日志只含 run ID、起止秒数、语言代码、窗口数和耗时，不记录语音或转写文本。可同时过滤两类事件：

```sh
rg 'VoiceBench(LanguageID|AppleSpeech)' /tmp/voicebench-apple-speech.log
```

先核对 `languageDetection.spans[].windows` 与 `regions` 是否符合实际语言，再查 `apple_locale_routes`、`apple_range_first_frame` / `apple_range_end_frame` 和 `apple_read_frames`。新版本 `apple_read_frames` 是当前区间内读到的帧数；`apple_total_frames` 仍为整份派生文件长度。`apple_final_segments` 在会话内记录当前会话结果数，完成时记录合计。多区间时通用格式 / 帧字段保留最后处理区间，全部区间路由见计划和 `apple_locale_routes`。

缺资源的错误不应反复重新导入模型：点击“准备苹果语言资源”，下载当前录音最后一次 Apple 检测计划涉及的语言后再运行。Whisper 初始化或检测错误会保存 `lid_error_stage/domain/code`、完成窗口数和已用时间。
