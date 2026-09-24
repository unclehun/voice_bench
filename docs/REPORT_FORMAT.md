# 报告格式 v1

`VoiceBench.json` 为结构化报告，`VoiceBench.md` 为同次导出的阅读版。`report-example.json` 是合成的格式样例，不是真实 ASR 测试结果。

| JSON 路径 | 含义 |
|---|---|
| `schemaVersion` | 报告格式版本 |
| `environment` | 导出设备、OS、App build 等；每次运行自己的环境同时保存在 run configuration |
| `recording.sha256` | 原始音频文件哈希，两套引擎共用 |
| `recording.duration` | 原始音频秒数 |
| `recording.reference` | 人工参考稿，只用于评测 |
| `recording.runs[]` | 每次转写记录；反复运行会追加，原记录不覆盖 |
| `runs[].engine` | `sensevoice_small_int8` / `apple_speechtranscriber` |
| `runs[].status` | `running` / `completed` / `failed` / `cancelled` / `interrupted` |
| `runs[].preparationMS` | 本次模型初始化和准备耗时，不含资源下载 |
| `runs[].transcriptionMS` | 格式转换、切分、推理、拼接耗时；仅完成时记录完整值 |
| `runs[].rawText` | 原始识别文字，未做 LLM 修改 |
| `runs[].segments[]` | 片段文本、实际起止秒数；不是跨引擎统一逐字时间戳 |
| `runs[].configuration` | 实际引擎配置、模型文件哈希、当时设备环境 |
| `runs[].correction` | 独立纠错状态、提示哈希、用户背景、输出、分块建议与采用文字 |
| `evaluation[]` | 按 runID 关联的 CER、纠错 CER、ΔCER 和 RTF |
| `evaluation[].rawCER` | 替换、删除、插入、参考 / 输出字符数及 rate |

没有获得的数据使用 null，不填 0 冒充测量。无参考稿的 CER 为 null；规范化后空参考稿的 CER 对象仍记录编辑计数，但 rate 为 null。失败 / 取消 ASR 不计算完整 CER 或 RTF。

本地保存的 metadata JSON 使用内部 Codable 日期格式；面向用户的导出报告使用 ISO-8601 日期。导出报告包含参考稿和用户背景，用户通过系统分享面板决定保存位置。
