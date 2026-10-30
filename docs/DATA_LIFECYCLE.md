# 数据生命周期

- 原始录音：`Library/Application Support/VoiceBench/Audio`。
- 识别、纠错、参考稿和背景：同目录下的 `Records`，每条录音一个 JSON。
- SenseVoice 模型：`Models`；默认导入源为 `Documents/SenseVoiceSmall_INT8`。
- Qwen 4 位模型：`QwenWeightOnlyModels`；默认导入源为 `Documents/Qwen3ASR_0_6B_WeightOnly4`。沿用已部署目录和模型版本，覆盖更新无需重新导入。
- Apple 语言设置：`Settings/apple-speech.json`。
- DeepSeek API Key：`Credentials/deepseek-api-key.json`，只使用配置文件，受文件保护及所有者读写权限限制，不写入识别数据或报告。
- 派生音频及待分享报告：App 私有 `tmp/VoiceBench`，按录音隔离；完成、取消、失败和冷启动清理。

0.9.0 启动时删除已移除模型的内部与默认源目录。加载旧记录时，先过滤掉已移除的引擎及其全部嵌套结果／纠错，删除旧语言检测计划，再解码为当前三模型数据。保留录音引用、用户文字和当前引擎结果，保存后旧结果不再留在 JSON 中。

删除一条录音会删除其音频、全部保留引擎的历史运行、参考稿、背景及临时工作文件，保留其他录音和共享模型。

“清除全部本机数据与模型”删除所有录音、结果、模型内部副本及默认源目录、临时文件和 API Key，并恢复默认语言。删除 App 也会删除这些 App 私有数据；系统“卸载 App”会保留数据。外部导入原件、已导出到其他位置的副本、Apple 系统共享资源不在清理范围内。
