# 数据保存、清理与删除 App

## 可保证的边界

VoiceBench 的录音、识别结果、纠错结果、模型文件和 DeepSeek API Key 保存在 iOS App 私有沙箱中。系统执行 **“删除 App”** 时会删除这些私有文件，清理不依赖 App 在删除时继续运行，也没有虚构卸载回调。API Key 只使用 `Library/Application Support/VoiceBench/Credentials/deepseek-api-key.json`，不存于缓存 / 临时目录。重启自动读取，同一 App 保留数据的覆盖更新继续使用，无需人工设置。

配置文件排除后续设备备份，使用 iOS 完整文件保护、目录 0700 / 文件 0600 权限，不写入录音 metadata 或导出报告。读取仅访问该文件；文件缺失即未配置，不创建额外状态文件。保存和删除都只操作配置文件，写入采用原子替换。

配置 Key 后手动触发纠错，会通过 HTTPS 将目标转写、相邻文字和纠错背景发送到 DeepSeek；音频与人工参考稿不发送。请求使用不保留磁盘缓存和 Cookie 的 ephemeral URLSession，不记录响应错误正文。外部服务收到的数据不属于本机清理范围。

在 **设置 → 通用 → iPhone 储存空间 → 语音对比** 中：

- **删除 App**：删除 App 和相关数据。
- **卸载 App**：仅移除程序，保留文稿与数据，以便重新安装。不能用此选项达到清空目的。
- 从主屏幕移除图标同样不代表删除 App。

来源：[Apple 储存空间说明](https://support.apple.com/en-us/108429)、[iOS 文件目录](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html)。

## 文件清单

文件路径均相对于 App 容器。

| 内容 | 位置 | 清理时机 |
|---|---|---|
| 安装代码、图标、内置许可和配置 | App bundle | 系统删除 App |
| 已保存录音及导入副本 | `Library/Application Support/VoiceBench/Audio` | 删除单条录音、清除全部或删除 App |
| 转写、参考稿、背景、纠错和运行状态 | `Library/Application Support/VoiceBench/Records` | 与对应录音一起删除，或清除全部 / 删除 App |
| 已导入 SenseVoice / VAD 模型及 receipt | `Library/Application Support/VoiceBench/Models` | 替换模型、清除全部或删除 App |
| 已导入 Whisper Tiny / 独立 VAD 及 receipt | `Library/Application Support/VoiceBench/LanguageIDModels` | 替换 Whisper 模型、清除全部或删除 App |
| 已导入 Qwen / tokenizer / 独立 VAD 及 receipt | `Library/Application Support/VoiceBench/QwenModels` | 替换 Qwen 模型、清除全部或删除 App |
| 已导入 Fun-ASR-MLT / tokenizer / VAD 及 receipt | `Library/Application Support/VoiceBench/FunASRModels` | 替换 Fun-ASR 模型、清除全部或删除 App |
| Fun-ASR 默认源目录（文件 App 可见） | `Documents/FunASR_MLT_Nano_INT8` | 清除全部或删除 App |
| Qwen 默认源目录（文件 App 可见） | `Documents/Qwen3ASR_0_6B_INT8` | 清除全部或删除 App |
| Whisper 默认源目录（文件 App 可见） | `Documents/WhisperTiny_INT8` | 清除全部或删除 App |
| 默认模型源目录（文件 App 可见） | `Documents/SenseVoiceSmall_INT8` | 清除全部或删除 App |
| 模型导入中间目录 | `Library/Application Support/VoiceBench/Import-UUID` | 导入结束，不论成功与否；异常退出则下次启动清理 |
| 录制中的音频 | `tmp/VoiceBench/录音-UUID.m4a` | 保存流程结束，不论成功与否；录制失败也清理 |
| 语言检测格式转换音频 | `tmp/VoiceBench/Recording-录音UUID/LanguageID-UUID.caf` | 检测完成、失败或取消；冷启动兜底清理 |
| Fun-ASR 格式转换音频 | `tmp/VoiceBench/Recording-录音UUID/FunASR-UUID.caf` | 成功、失败或取消后清理；冷启动兜底清理 |
| Qwen 格式转换音频 | `tmp/VoiceBench/Recording-录音UUID/Qwen-UUID.caf` | 成功、失败或取消后清理；冷启动兜底清理 |
| 原有两引擎格式转换音频 | `tmp/VoiceBench/Recording-录音UUID/UUID.caf` | 转写结束、失败或取消；转换失败自身也清理部分输出 |
| 待分享 JSON / Markdown | `tmp/VoiceBench/Recording-录音UUID/Report-UUID` | 分享面板关闭后清理；生成失败立即清理 |
| DeepSeek API Key | `Library/Application Support/VoiceBench/Credentials/deepseek-api-key.json` | 设置中删除 API Key、清除全部或删除 App；重启 / 覆盖更新保留 |

冷启动会清空 `tmp/VoiceBench`，处理进程被终止时未能执行的清理；也清理旧版直接写在 `tmp` 下的已知命名临时文件。成功读取全部 metadata 后，会删除没有对应记录的音频副本。若 metadata 读取出错，不冒险删除可能仍有用的录音。

运行中不清空整个临时目录，避免删除仍在识别或分享的文件。临时文件清理接口拒绝删除私有临时目录之外的路径。导入操作只读取用户选中的原件，并在结束时释放 security-scoped access。

## 清除全部

**设置 → 数据管理 → 清除全部本机数据与模型** 经过确认后：

1. 删除 VoiceBench 私有录音、metadata、模型、`Documents/SenseVoiceSmall_INT8`、`Documents/WhisperTiny_INT8`、`Documents/Qwen3ASR_0_6B_INT8`、`Documents/FunASR_MLT_Nano_INT8` 中的模型源文件和临时工作文件；随后仅重建空的固定目录。
2. 清空界面中的记录、评测和分享引用，阻止旧的异步保存重新生成已删除记录。
3. 调用 `AssetInventory.release(reservedLocale:)` 释放本 App 的苹果语音资源预留。
4. 删除 API Key 配置文件和所在 Credentials 目录。配置文件与其他数据清理独立尝试；失败明确提示。刷新状态及重新打开 App 均显示未配置。

该按钮在录音、识别、纠错、下载和分享期间不可用。App 私有文件的删除由 iOS 管理；主动清除会移除 API Key 配置及全部录音、结果和模型。

## 无法随 App 一并保证删除的内容

- **苹果 SpeechTranscriber 系统资源**：苹果在系统侧管理，多个 App 共享。释放预留不等于立即删除模型，实际回收时间由系统决定。
- **Foundation Models 系统模型**：属于 Apple Intelligence 系统资源，不是 Demo 私有模型，Demo 不能删除。
- **手工选择的导入原件及主动导出副本**：例如 iCloud Drive 中用于手工导入的模型目录、ZIP、源音频，或主动保存和分享出去的报告；这些是用户或接收方持有的独立文件，需到保存位置手动删除，必要时清空“最近删除”。默认的 `在我的 iPhone → 语音对比（或 VoiceBench）→ SenseVoiceSmall_INT8` 属于本 App 容器，会随“删除 App”删除。
- **已有设备备份**：新版将整个 VoiceBench 持久目录及子目录设为不参与后续系统备份，但无法追溯删除此前由旧版本产生的备份，也不能删除用户手动复制的内容。
- **Mac / GitHub 文件**：IPA、源代码、构建产物以及 Sideloadly 的签名与续签缓存不在手机 App 沙箱中，删除手机 App 不会清理它们。
- **DeepSeek 已收到的数据及 API Key**：本机清理不删除第三方服务上的数据，也不撤销 DeepSeek 平台上的 Key；需要撤销时应到开放平台操作。

因此，本项目保证使用可随“删除 App”移除的私有存储方案，并主动清理工作文件；不声称能抹除外部副本、共享系统资源或进行底层存储取证意义上的安全擦除。

来源：[Apple AssetInventory](https://developer.apple.com/documentation/speech/assetinventory)。

## 验证

`bash scripts/check_audio.sh Models/VoiceBenchModels` 使用独立临时测试目录，验证真实音频转换、取消无输出、备份排除属性、失败导入、报告生成失败和分享清理、模拟异常退出后恢复、全部清理与迟到保存、保留外部文件、清理后重新使用存储。已纳入 GitHub Actions（云端默认运行不需大模型的部分）。

`bash scripts/check_local.sh` 另外使用真实临时文件与实际 `LocalStore.removeAllData()` 验证 API Key 文件 / 目录删除、清除后重新读取为空，以及模拟删除整个 App 容器后重新安装仍未配置。测试不使用个人密钥。

这些是文件生命周期测试，并不等于已经执行 iPhone 删除 / 重装或系统模型回收测试。真机可录音、识别、导出后清理，再确认列表为空、API Key 未配置、SenseVoice 和 Whisper 需重新导入；随后用系统“删除 App”并重新安装，确认没有原先的录音、结果和 API Key。


## 录音卡片的删除边界

每条录音有独立的 `tmp/VoiceBench/Recording-录音UUID` 工作目录，SenseVoice、Whisper 语言检测、Apple、Qwen、Fun-ASR 的派生音频与待分享报告均归属于该目录。识别结束、失败或取消时清理本轮目录；删除卡片时再次删除整个目录、源音频内部副本及该录音的 metadata JSON。JSON 同时包含全部历史轮次、纠错、参考稿、背景和语言检测计划，因此删除覆盖整条录音的历史，而不只屏幕当前显示的结果。旧版本临时文件由升级后的首次冷启动统一清理。

Fun-ASR 上下文重试直接读取同一派生音频的区间，不另存子段音频或被拒绝的文字；预算诊断最多 256 条，保存在该录音 metadata 中，沿用上述删除范围。

识别、纠错、导入、分享期间禁用删除，避免仍有任务向已删除目录写文件；播放中的删除会先停止播放并释放播放器。删除按录音 ID 执行，重试可安全处理已不存在的文件，并阻止迟到保存重建该录音。共享 SenseVoice / Whisper / Qwen / Fun-ASR 模型和其他录音的工作目录保持不变。

新增真实文件测试覆盖两条录音：删除一条后，其多引擎历史结果、纠错、评测资料、派生音频和待分享报告全部消失；另一条录音、其工作文件、共享模型与外部原件保留。也验证重复删除、迟到保存与分享回调不会重建文件。


## 0.2.1：路径校验与完整清理修复

清理路径改用 `realpath` 得到一致的物理路径，目标不存在时从最近的已存在祖先补全路径，再按路径组件检查边界。这样 `/private/var/...` 与 `/var/...` 等别名不会因目标目录已被清理而误判。根目录本身、外部路径、同名前缀的兄弟目录及经中间符号链接越界的路径仍被拒绝。目标是本目录内的符号链接节点时只移除链接本身，不删除外部目标；断开的链接也不会被 `fileExists` 漏掉。权限及其他 I/O 错误不会被当成“文件不存在”。

删除单条录音允许临时目录已经不存在，仍继续删除其音频和完整 metadata。识别后的临时清理、失败导入、分享回调均复用该安全清理逻辑，重复执行不报错、不重建已删数据。

“清除全部”逐项尝试内部数据根目录、四类 Documents 默认模型目录、临时工作目录以及旧版已知命名的临时残留；一个步骤失败也继续处理其他独立步骤。随后重建空目录、恢复备份排除属性，并检查内容为空及内部根目录没有未知残留，只有全部通过才报告成功。失败会保留具体原因并支持重试；界面读取剩余数据失败时也不会伪装成空列表。测试布局将 Documents 与数据根目录分开，模拟 iOS 真实目录结构。
