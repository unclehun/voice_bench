# VoiceBench · 语音对比

iPhone 原生语音识别 Demo，当前版本 **0.9.0**，仅保留三个识别引擎：

- **Qwen3-ASR 4 位**：0.6B，W4A32／分块 32，本地自动多语识别。
- **SenseVoiceSmall INT8**：本地自动多语识别。
- **Apple Speech**：iOS SpeechTranscriber，按设置的默认语言直接识别整段录音。

支持录音、导入音频、播放、逐模型识别、人工参考稿 CER、JSON／Markdown 导出，以及 Apple 本地／DeepSeek 公网文字纠错。三种识别结果独立保存；参考稿不进入纠错接口。

## 手机配置

最低 iOS 26。打开设置，载入两个本地模型，并准备 Apple 默认语言资源。已有模型和设置可随同身份的覆盖更新继续使用。

| 引擎 | 工程中保留的模型源 | iPhone“文件 → 在我的 iPhone → 语音对比”中的目录 |
|---|---|---|
| SenseVoice | `Models` 下包含 `model.int8.onnx` 的 SenseVoice 文件夹 | `SenseVoiceSmall_INT8` |
| Qwen 4 位 | `Models/Qwen3ASR_0_6B_WeightOnly4` | `Qwen3ASR_0_6B_WeightOnly4` |

将完整文件夹传入手机，保留子目录。SenseVoice 源目录名称不决定量化精度，实际使用的是配套 `model.int8.onnx`。设置中可从默认目录载入，也可选择其他完整文件夹；导入时按 App 内置 SHA-256 清单校验，通过后复制到私有目录。模型不打包进 IPA，也不提交 Git。

SenseVoice 必需文件：`model.int8.onnx`、`tokens.txt`、`silero_vad.onnx`。

Qwen 必需文件：`conv_frontend.onnx`、`encoder.int8.onnx`、`decoder.weight4.onnx`、`silero_vad.onnx`，以及 `tokenizer` 下的 `vocab.json`、`merges.txt`、`tokenizer_config.json`。完整目录约 917 MB。

Qwen 固定使用已部署的 4 位权重、分块 32、Float32 中间计算及原始 BF16 词嵌入存储；CPU 两线程、自动语言和 greedy 解码。音频转换为 16kHz 单声道 Float32，VAD 最长语音段 20 秒，首尾最多各补 200ms，区间循环读满目标采样。不会通过其他识别模型做前置语言路由。

Apple 默认中文（中国大陆）；可在设置中选择系统支持的语言并准备资源。语言和 API Key 都保存到 App 私有配置文件，重启及覆盖更新继续使用。

## 使用

点击录音卡片“识别”运行已配置的引擎；详情中可单独运行任一引擎。设置、结果卡片和导出仅显示上述三种识别模型。CER 去除标点、空白并统一 ASCII 大小写，保留数字、简繁及拼写差异。

点击“开始纠错”会同时运行可用的 Apple 本地纠错与已配置的 DeepSeek 公网纠错。结果分别保存；查看／收起只切换展示，重新运行放在独立菜单。DeepSeek 仅接收文字及纠错背景，不接收音频或人工参考稿；API Key 不进入报告。

更新到 0.9.0 时，自动清除已移除引擎的历史识别、纠错、语言检测数据及模型目录。录音、参考稿、当前三种引擎的结果和配置保留。旧的实验代码、评比材料和临时数据不再随工程交付。

## 构建

本机没有完整 Xcode／iPhoneOS SDK。iOS 编译使用 Xcode 26+ 的 Mac，或仓库中手动触发的 GitHub Actions。

```sh
python3 scripts/prepare_dependencies.py
.tools/xcodegen/bin/xcodegen generate --spec project.yml
```

构建机配置好 `DEVELOPER_DIR` 后执行：

```sh
bash scripts/build_unsigned.sh
```

输出 `build/VoiceBench-unsigned.ipa`，需用自己的签名工具签名后安装。工程配置来源为 `project.yml`。构建依赖固定版本与 SHA-256 位于 `config/dependencies.json`。

源码交付包：

```sh
python3 scripts/package_source.py
```

生成 `build/VoiceBench-source.zip`，不包含模型、二进制依赖、录音或实验数据。构建说明见 [GitHub Actions](docs/GITHUB_ACTIONS.md)，数据删除范围见 [数据生命周期](docs/DATA_LIFECYCLE.md)。
