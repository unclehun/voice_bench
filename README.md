# VoiceBench · 语音对比

iPhone 原生语音识别 Demo，当前版本 **0.10.1**，仅保留三个识别引擎：

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

每段录音下，各模型的识别文字、纠错按钮与纠错结果放在同一独立框块内。点击文字下方“纠错此结果”，仅针对该模型的这次识别，同时运行可用的 Apple 本地纠错与已配置的 DeepSeek 公网纠错。两路结果分别保存，在文字下方向右缩进并以竖线标示层级；首页与历史记录使用相同布局。查看／收起只切换展示，重新运行放在该框块的独立菜单。DeepSeek 仅接收文字及纠错背景，不接收音频或人工参考稿；API Key 不进入报告。

0.10.0 使用整段语义和逐条建议：两路模型共用语义规则，按句子边界划分目标，短文携带全文；长文先读取各部分生成辅助语义摘要，再附相关原文校对。摘要不作为事实证据。每条建议必须能在原文准确定位，引用原文或用户背景，并通过修改范围、语言、读音／拼写及关键事实检查。

有充分语境依据的局部错词、专名、明确指代和格式调整可自动应用；实际修改数字、时间、单位、否定含义或人物关系，以及证据不足的建议，进入待确认；疑似翻译、整句删改、补写内容、整理口语或位置冲突的建议不采用。仅段落其他位置出现数字或否定词不再阻止纠错。读音或拼写差异较大的语义替换需要确认。

展开“查看修改与建议”可接受、保留或撤销单处修改；选择落盘并随覆盖更新保留。界面分别统计已应用、格式调整、待确认和未采用；部分失败／中断保留已完成部分，其余位置保留原文。旧纠错结果继续可读，不按新规则自动重新采用，请手动重新纠错。JSON／Markdown 导出包含逐条建议、依据与最终选择；CER 使用实际采用文字。

纠错后段落将已采用修改的原文以红色删除线显示，紧接绿色修正文；待确认或保留原文的建议不标记，撤销后恢复普通原文。显示标记不写入实际采用文字和 CER。任务状态在底部独立显示，保存选择、识别、纠错、导出和模型配置不再在滚动内容顶部插入／删除状态行。首页保留录音卡片的实际高度和展开状态，纠错结果展开／收起直接更新布局。

核心回归测试运行 `swift test`（需要完整 Xcode）；界面回归步骤见 [按钮与滚动位置检查](docs/UI_REGRESSION.md)。

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
