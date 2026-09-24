# 数据保存、清理与删除 App

## 可保证的边界

VoiceBench 自己创建的持久文件全部存放在 iOS App 私有沙箱中。没有使用 Keychain、App Group、iCloud/CloudKit、相册或服务器来额外保存录音与结果。系统执行 **“删除 App”** 时会删除 App 及其私有数据，清理不依赖 App 在删除时继续运行，也没有虚构卸载回调。

在 **设置 → 通用 → iPhone 储存空间 → 语音对比** 中：

- **删除 App**：删除 App 和相关数据。
- **卸载 App**：仅移除程序，保留文稿与数据，以便重新安装。不能用此选项达到清空目的。
- 从主屏幕移除图标同样不代表删除 App。

来源：[Apple 储存空间说明](https://support.apple.com/en-us/108429)、[iOS 文件目录](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html)。

## 文件清单

以下均为 App 容器内相对路径，不会写入其他 App 的目录。

| 内容 | 位置 | 清理时机 |
|---|---|---|
| 安装代码、图标、内置许可和配置 | App bundle | 系统删除 App |
| 已保存录音及导入副本 | `Library/Application Support/VoiceBench/Audio` | 删除单条录音、清除全部或删除 App |
| 转写、参考稿、背景、纠错和运行状态 | `Library/Application Support/VoiceBench/Records` | 与对应录音一起删除，或清除全部 / 删除 App |
| 已导入 SenseVoice / VAD 模型及 receipt | `Library/Application Support/VoiceBench/Models` | 替换模型、清除全部或删除 App |
| 模型导入中间目录 | `Library/Application Support/VoiceBench/Import-UUID` | 导入结束，不论成功与否；异常退出则下次启动清理 |
| 录制中的音频 | `tmp/VoiceBench/录音-UUID.m4a` | 保存流程结束，不论成功与否；录制失败也清理 |
| 两引擎格式转换音频 | `tmp/VoiceBench/UUID.caf` | 转写结束、失败或取消；转换失败自身也清理部分输出 |
| 待分享 JSON / Markdown | `tmp/VoiceBench/Report-UUID` | 分享面板关闭后清理；生成失败立即清理 |

冷启动会清空 `tmp/VoiceBench`，处理进程被终止时未能执行的清理；也清理旧版直接写在 `tmp` 下的已知命名临时文件。成功读取全部 metadata 后，会删除没有对应记录的音频副本。若 metadata 读取出错，不冒险删除可能仍有用的录音。

运行中不清空整个临时目录，避免删除仍在识别或分享的文件。临时文件清理接口拒绝删除私有临时目录之外的路径。导入操作只读取用户选中的原件，并在结束时释放 security-scoped access。

## 清除全部

界面底部 **数据管理 → 清除全部本机数据与模型** 经过确认后：

1. 删除 VoiceBench 私有录音、metadata、模型和临时工作文件。
2. 清空界面中的记录、评测和分享引用，阻止旧的异步保存重新生成已删除记录。
3. 调用 `AssetInventory.release(reservedLocale:)` 释放本 App 的苹果语音资源预留。

该按钮在录音、识别、下载和分享期间不可用。它不必先于“删除 App”执行，App 私有文件的删除由 iOS 管理；它提供保留 App 时的主动清理入口。

## 无法随 App 一并保证删除的内容

- **苹果 SpeechTranscriber 系统资源**：苹果在系统侧管理，多个 App 共享。释放预留不等于立即删除模型，实际回收时间由系统决定。
- **Foundation Models 系统模型**：属于 Apple Intelligence 系统资源，不是 Demo 私有模型，Demo 不能删除。
- **导入原件及主动导出副本**：例如“文件”App / iCloud Drive 中用于导入的模型目录、ZIP、源音频，或主动保存和分享出去的报告；这些是用户或接收方持有的独立文件，需到保存位置手动删除，必要时清空“最近删除”。
- **已有设备备份**：新版将整个 VoiceBench 持久目录及子目录设为不参与后续系统备份，但无法追溯删除此前由旧版本产生的备份，也不能删除用户手动复制的内容。
- **Mac / GitHub 文件**：IPA、源代码、构建产物以及 Sideloadly 的签名与续签缓存不在手机 App 沙箱中，删除手机 App 不会清理它们。

因此，本项目保证使用可随“删除 App”移除的私有存储方案，并主动清理工作文件；不声称能抹除外部副本、共享系统资源或进行底层存储取证意义上的安全擦除。

来源：[Apple AssetInventory](https://developer.apple.com/documentation/speech/assetinventory)。

## 验证

`bash scripts/check_audio.sh Models/VoiceBenchModels` 使用独立临时测试目录，验证真实音频转换、取消无输出、备份排除属性、失败导入、报告生成失败和分享清理、模拟异常退出后恢复、全部清理与迟到保存、保留外部文件、清理后重新使用存储。已纳入 GitHub Actions（云端默认运行不需大模型的部分）。

这些是文件生命周期测试，并不等于已经执行 iPhone 删除 / 重装或系统模型回收测试。真机可录音、识别、导出后清理，再确认列表为空、SenseVoice 需重新导入；随后用系统“删除 App”并重新安装，确认没有原先的录音与结果。
