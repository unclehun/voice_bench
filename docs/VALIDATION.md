# 验证记录

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
