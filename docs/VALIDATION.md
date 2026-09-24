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
