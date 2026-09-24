# VoiceBench · 语音对比

简洁的 iPhone 原生 Demo，针对同一份录音比较 **SenseVoiceSmall INT8** 与 **Apple SpeechTranscriber**。最低 iOS **26.0**，不接入替代引擎或云端 ASR。

当前交付包含 Swift 源码、生成的 Xcode 工程、锁定依赖、模型准备脚本、手动触发的 GitHub Actions 工作流和本地逻辑校验。云端仓库为 [unclehun/voice_bench](https://github.com/unclehun/voice_bench)，操作步骤见 [GitHub 云端编译](docs/GITHUB_ACTIONS.md)。**本地验证尚不包含 iOS SDK 编译或 iPhone 测试，实际云端构建状态以 Actions 为准。**验证边界见 [验证记录](docs/VALIDATION.md)。

## 功能

- 录音、M4A / WAV 导入、播放、录音选择和删除。
- 两套引擎各自执行或依次执行；每轮可交替先后顺序。
- 同一源文件的 SHA-256、原始文本、分段时间、初始化时间、转写时间及 RTF。
- 模型文件校验、苹果中文资源准备、可用性检查、错误和取消状态。
- 原文及完成片段落盘，重启后把未完成任务标记为中断。
- 私有目录保存数据，清理临时文件与异常退出残留；提供“清除全部本机数据与模型”。
- 人工参考稿计算 CER；JSON 和 Markdown 系统分享导出。
- 可选 Foundation Models 本地纠错：独立执行、分块、差异高亮、保守修改检查。参考稿不进入纠错接口，失败不覆盖 ASR。

界面使用系统 Form 和四个区域：音频、引擎、结果、评测与导出。不需要登录 App 账号，也不需要配置服务端。

## 运行条件

手机必须运行 iOS 26+。系统版本满足要求后，还要通过 `SpeechTranscriber.isAvailable`、中文 locale 和系统资源检查。模型准备完成后，两引擎在手机上离线运行；“安装成功”不等于两引擎均可用。

主测试目标为用户的 iPhone 17 Pro / iOS 27。旧机只有通过两引擎实际离线转写后才列入兼容清单。Foundation Models 另受 Apple Intelligence 设备资格、地区、启用状态与语言限制，不能用它是否可用来决定 SpeechTranscriber 是否可用。

本地 Mac 13.7.8 + Command Line Tools 可以编辑代码和运行部分校验；无法编译 iOS App。完整构建在有 Xcode 26+ 的另一台 Mac / 云端 macOS 上进行。本机无需安装 Xcode。

## 已准备的本地文件

- `VoiceBench.xcodeproj`：实际生成的原生工程。
- `project.yml`：工程配置的来源，变更后重新生成。
- `Vendor/`：已下载、验证 SHA-256 的 iOS 静态 XCFramework（不提交 Git）。
- `.tools/xcodegen/`：项目内的 XcodeGen 2.44.1，不是 Xcode。
- `Models/VoiceBenchModels/`：准备好的手机模型导入目录，含权重、tokens、VAD、许可证和 manifest（不提交 Git）。

各工作目录是否存在取决于当前机器是否已执行准备脚本；新克隆可用以下命令重新准备。

`build/VoiceBench-source.zip` 是本轮源码交付包，包含工程、脚本和文档，不含模型、二进制依赖或个人录音。解压后先运行依赖准备脚本。源码变更后可执行 `python3 scripts/package_source.py` 重新打包；这不是可安装的 IPA。

## 本机可执行的检查

在项目根目录执行：

```sh
bash scripts/check_local.sh
```

该命令用系统 `swiftc` 编译实际核心代码，再检查 CER、Unicode、空参考稿、字符 diff、取消和报告；不依赖 XCTest 或 iOS SDK。正式 XCTest 保留在 `Tests/VoiceBenchCoreTests`，有完整 Xcode 的机器运行 `swift test`。

音频转换 / 保存测试使用真实 AVFoundation，不录制麦克风：

```sh
bash scripts/check_audio.sh
```

这些检查不是手机识别准确率或手机性能测试。完整测试状态与局限见 `docs/VALIDATION.md`。

## 依赖准备与工程生成

```sh
python3 scripts/prepare_dependencies.py
.tools/xcodegen/bin/xcodegen generate --spec project.yml
```

依赖固定在 `config/dependencies.json`，包括下载 URL、版本和 SHA-256：

- sherpa-onnx 1.13.8，静态 iOS XCFramework。
- ONNX Runtime 1.28.2，静态 iOS XCFramework。
- XcodeGen 2.44.1，仅用于工程生成。

此处显式引用二进制，避免上游 Swift Package 的版本号与其实际引用的二进制不一致。校验失败时脚本停止，不自动接受新版本。`--offline` 仅使用已经下载并通过校验的归档。

## 云端生成 IPA（尚未执行）

仓库使用普通 Git 管理源码、工程、配置、脚本、图标和许可证；不提交 `Vendor/`、`.downloads/`、`.tools/`、`Models/` 或个人录音。无需 Git LFS，依赖在构建时下载并校验。详细启用步骤和大文件策略见 [GitHub 云端编译](docs/GITHUB_ACTIONS.md)。

工作流 `.github/workflows/ios.yml` 仅接受手动触发：

1. 使用标准 `macos-15` runner，验证 `/Applications/Xcode_26.3.app` 存在。
2. 运行核心 XCTest。
3. 下载并校验固定依赖，生成工程，构建真机 Release。
4. 打包完整 `.app` 到 `Payload/VoiceBench.app`，上传未签名 IPA、SHA-256、dSYM 和日志，保留 3 天。

默认只使用标准 runner；私有仓库受账号免费额度与存储配额限制。工作流不使用 Apple 账号、签名证书或付费开发团队。工具链镜像会变动，缺失时明确失败，需选择仍包含所需 Xcode 的镜像。

在已有完整 Xcode 的构建机上也可执行：

```sh
export DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer
bash scripts/build_unsigned.sh
```

输出 `build/VoiceBench-unsigned.ipa`。**未签名 IPA 不能直接安装到手机；它需要下一步签名。**

## 免费侧载到 iPhone

1. 在现有 Mac 安装 [Sideloadly](https://sideloadly.io/)，USB 连接并信任 iPhone。
2. 下载云端生成的未签名 IPA，拖入 Sideloadly。
3. 在本机工具内使用自己的免费 Apple 账号登录、完成双重认证并签名安装。无需把密码交给代码或 GitHub。
4. 按系统提示信任开发者并开启开发者模式，打开“语音对比”。
5. 更新时保持相同账号与最终 Bundle ID，覆盖安装，避免先删除 App 丢失数据。

免费签名通常 7 天到期，需续签；同一 IPA 可重新签名，无需每周重新编译。自动刷新仍需 Mac 和手机满足连接条件。当前这台旧 Mac 与 iOS 27 的实际侧载组合尚未验证。

## 模型导入

已准备好的目录为 `Models/VoiceBenchModels`。新环境执行：

```sh
python3 scripts/prepare_models.py
```

脚本下载指定的 INT8 模型及 VAD，保留模型 LICENSE，对照固定哈希校验，生成 `manifest.json`。现有输出目录不会被覆盖；可用 `--output` 选择新目录。

将**完整文件夹**传到 iPhone“文件”App 可访问的位置，然后在 Demo 点“导入模型目录”。应直接选择包含下列文件的目录：

```text
VoiceBenchModels/
  model.int8.onnx
  tokens.txt
  silero_vad.onnx
  manifest.json
  LICENSE
  VAD_LICENSE
```

如果传输方式需要 ZIP，可先压缩目录，在 iPhone“文件”App 解压后选择文件夹。App 不解析 tar.bz2 / ZIP，也不会误把压缩包当模型。

App 在导入时校验所选内容与内置 `model-manifest.json` 一致；验证通过后替换模型目录。只支持本 Demo 指定的模型版本，损坏文件或其他同名模型会被拒绝。

苹果模型单独点“准备苹果中文资源”，首次需要联网。模型就绪后，开启飞行模式并关闭 Wi-Fi，重启 App，再验证同一音频的双引擎转写。

## 评测方法

先不做纠错，分别测试安静普通话、专名 / 数字 / 否定词、中英混说、噪声和长录音。点击“依次运行两套引擎”会自动为下一轮交换顺序，减少固定先后次序偏差。

- `RTF = transcriptionMS / 1000 / audioDurationSeconds`；转写包括格式转换、VAD（如适用）、推理和拼接。首次模型下载不计入 RTF，初始化单独记录。
- CER 使用 Unicode scalar 编辑距离，移除标点和空白、统一 ASCII 英文字母大小写；不统一简繁、数字写法或语义。
- 没有参考稿时 CER 为 null；规范化后空参考稿保留字数和编辑计数、rate 为 null。
- 未完成 ASR 不计为完整 CER / RTF。纠错不可用、取消或失败时不复制原文冒充成功结果。
- 录音和运行结果按文件保存；删除录音时会删除其全部关联结果。

原始转写、纠错建议与实际采用文字分开保存。差异展示红色删除和绿色新增。纠错器对涉及数字、否定及人物关系词的修改采取整块保留原文策略；这只是保守规则，不代表能自动证明语义正确，需人工复核。

## 当前明确的限制

删除与备份行为见 [数据清理说明](docs/DATA_LIFECYCLE.md)。在 iPhone 设置中须选择 **“删除 App”**；**“卸载 App”会保留数据**。App 私有录音、结果和模型随删除移除；导出副本、导入原件及苹果共享系统模型不属于 App 私有数据。

- **还没有通过 iOS SDK 编译；Apple Speech / SwiftUI / Foundation Models 的集成仍需云端编译与真机验证。**本地语法和跨平台类型检查不能替代它。
- 前台任务为主。后台或系统音频中断会结束任务，保留已完成片段；重新运行会创建新记录，没有断点续跑。
- 原生 SenseVoice 取消在片段边界生效，当前片段推理期间可能要等待。
- 低内存配置为 1 线程 / 12 秒上限；默认 2 线程 / 25 秒。VAD 使用模型自身的最长时长切分，没有另实现“在附近低能量点搜索”的算法。
- 为避免边界重复，后段保护区裁剪到前段结束，记录真实采用范围；尚无精确逐字时间戳或语义去重。
- LLM 纠错按 400 字分块，附相邻上下文；没有实现上下文超限后的自适应缩块重试。失败块保留原文并记录错误，可单独重试整次纠错。
- 内存 / CPU / 整机耗电未测，不用 App 自身内存推断苹果系统模型资源占用。

## 参考

- [Apple SpeechAnalyzer 示例与说明](https://developer.apple.com/videos/play/wwdc2025/277/)
- [SpeechTranscriber 可用性](https://developer.apple.com/documentation/speech/speechtranscriber/isavailable)
- [Foundation Models](https://developer.apple.com/documentation/foundationmodels)
- [SenseVoice 模型](https://k2-fsa.github.io/sherpa/onnx/sense-voice/pretrained.html)
- [第三方许可](THIRD_PARTY_NOTICES.md)
