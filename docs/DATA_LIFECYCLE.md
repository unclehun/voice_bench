# 数据生命周期

- 原始录音：`Library/Application Support/VoiceBench/Audio`。
- 识别、DeepSeek 纠错、参考稿和背景：同目录下的 `Records`，每条录音一个 JSON。
- 新版纠错保存逐条建议的原文位置、语境依据、采纳规则版本与人工接受／保留选择；撤销从不可变的原始识别重建，不覆盖原始识别。旧 DeepSeek 纠错保持原有结果，重新执行后才使用全文规则；新流程不生成全文语义摘要。
- SenseVoice 模型：`Models`；默认导入源为 `Documents/SenseVoiceSmall_INT8`。
- Qwen 4 位模型：`QwenWeightOnlyModels`；默认导入源为 `Documents/Qwen3ASR_0_6B_WeightOnly4`。沿用已部署目录和模型版本，覆盖更新无需重新导入。
- Apple Speech 识别语言设置：`Settings/apple-speech.json`。
- DeepSeek API Key：`Credentials/deepseek-api-key.json`，只使用配置文件，受文件保护及所有者读写权限限制，不写入识别数据或报告。
- 派生音频及待分享报告：App 私有 `tmp/VoiceBench`，按录音隔离；完成、取消、失败和冷启动清理。

0.9.0 启动时删除已移除模型的内部与默认源目录。加载旧记录时，先过滤掉已移除的引擎及其全部嵌套结果／纠错，删除旧语言检测计划，再解码为当前三模型数据。保留录音引用、用户文字和当前引擎结果，保存后旧结果不再留在 JSON 中。

0.12.0 加载全部录音时删除旧本地文字纠错的 `correction` 对象（含原文副本、结果、逐条建议、人工决定、错误和摘要），以及其专属配置；不迁入 DeepSeek、不保留兼容副本。清理后由 LocalStore 原子保存，重复启动不重复迁移。Run／评测模型和 JSON／Markdown 导出不再包含已移除功能的字段。App 自有待分享报告随冷启动清除，先前导出到外部位置的副本仍由用户自行管理。

删除一条录音会删除其音频、全部保留引擎的历史运行、参考稿、背景及临时工作文件，保留其他录音和共享模型。

“清除全部本机数据与模型”删除所有录音、结果、模型内部副本及默认源目录、临时文件和 API Key，并恢复默认语言。删除 App 也会删除这些 App 私有数据；系统“卸载 App”会保留数据。外部导入原件、已导出到其他位置的副本、Apple 系统共享资源不在清理范围内。
