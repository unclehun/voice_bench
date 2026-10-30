# Qwen 录音 4 中英混读诊断（2026-10-29）

后续已完成官方原权重与量化路径对照，并在 0.8.0 接入独立优化配置，见 [官方对照与优化版验证](QWEN_REFERENCE_VALIDATION.md)。本文保留 0.7.1 当时的诊断证据和假设。

## 结论与范围

手机 0.7.1 / Build 14 的最新原始 Qwen 结果，确实把录音 4 一段中文的语义输出成了英文，并丢失问句含义。当前最有证据支持的判断是：生成式 ASR 在混读片段中发生输出语言偏移，独立分段的边界和段首语言可能触发或放大这一现象。分段敏感性已由本地对照支持，但还没有证明唯一成因，不能归结为“模型一定把该段语言检测成 English”。

未修改 Qwen 引擎、默认参数、手机数据或历史结果。以下方案用于讨论，不是已经部署的修复。已有 Whisper 字节解码修复不属于本次 Qwen 对照。

## 手机读取与具体错误

2026-10-29 通过 USB HouseArrest 只读复制该录音 metadata 及原始音频，核对 metadata 内的 SHA-256。原音频 53.332 秒、713,577 字节，哈希为 `2afbf04d405e12c2ec002f27a438de619b5525cb90eacdb7d7a7ec1c4dcf0102`。最新 Qwen run 为 `59981E16-C84B-415A-954C-07489DAEECE9`，状态 completed。

异常区间 **19.710–36.976 秒** 长 17.266 秒：英文 “We do not have to solve every problem in the same way” 之后接中文，再夹有 fifteen / fifty。手机把这一整段输出成英文。

| 用户参考稿 | 手机 Qwen 输出 |
|---|---|
| We do not have to solve every problem in the same way. | We do not have the slow area problem in the same way. |
| 如果把这件事放到今天，我还想多问几句 | If we put this thing into the present, I want to ask a few questions. |
| 船上的人有没有变化，水位记得准不准 | The people on the ship have changed. The water level is accurate. |
| 石头称了几次？第一次是 fifteen，第二次却成了 fifty | The stone was supported fifteen times. The second time became fifty. |

不仅是文字语言改变，“有没有”“准不准”的疑问变成肯定陈述，第一次 / 第二次的关系也受损。整条录音的最新原始结果 CER 为 **70.37%（171 / 243）**，其中 S=57、D=3、I=111。中文被较长英文替代会产生大量字符插入；CER 不等于语义错误百分比。计分包含标题，使用项目 `Evaluation.cer`，忽略标点、空白、ASCII 大小写，保留数字与简繁差异，参考稿不传入识别。

## 接入代码与官方资料

当前 `QwenSpeechEngine.swift` 使用 16kHz 单声道、128 维特征、Silero 最短静音 0.6 秒、最大语音段 20 秒、每端最多 200ms 保护。每个 VAD 区间新建独立 stream，不传前一段文字或语言；`language` 留空，temperature=0，1024 总序列长度、512 新 token。没有主动请求翻译，也没有外置语言识别路由。手机记录的七份模型 / tokenizer 文件 SHA-256 均与本地权重一致。

- [Qwen 官方推理代码](https://github.com/QwenLM/Qwen3-ASR/blob/main/qwen_asr/inference/qwen3_asr.py#L278)允许自动语言或指定一个语言。指定 Chinese 是增加 `language Chinese<asr_text>` 生成前缀；[sherpa 实现](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.8/sherpa-onnx/csrc/offline-recognizer-qwen3-asr-impl.cc#L422)没有通过词表屏蔽把输出强制限制为中文。它不是可靠的“禁止翻译”开关。
- [官方仓库 Issue #16](https://github.com/QwenLM/Qwen3-ASR/issues/16)报告了相似的中英混读整段变英文现象。仓库 Collaborator 建议试 Chinese；提问者反馈英文又变成中文。未找到维护者确认的通用修复。Issue 标题是用户描述，不能当作官方“不支持混读”的规格。
- [官方长音频处理](https://github.com/QwenLM/Qwen3-ASR/blob/main/qwen_asr/inference/utils.py#L230)在超过 1200 秒时才寻找低能量边界切段，与本项目适配有界 ONNX KV 容量的 20 秒独立 VAD 流程不同。不能将官方长音频容量直接套到当前手机导出模型。
- [Qwen 技术报告 §2.2](https://arxiv.org/html/2601.21337v2#S2.SS2)将 ASR 训练为不遵循自然语言指令的模型，context 用于背景信息。没有依据把“不要翻译、保留中英原文”塞进 hotwords 当作可靠修复。
- [sherpa 自动语言解析](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.8/sherpa-onnx/csrc/offline-recognizer-qwen3-asr-impl.cc#L1014)会删除语言前缀，而当前结果没有保存原始前缀。仅凭手机正文，无法确认它生成了什么 language 标签。该实现每次重新建立 KV；本次没有发现前一个 stream 的语言或缓存串入下一个 stream 的路径。

因此，“以英文开始的独立混读片段使后续生成保持英文”是合理且受实验支持的触发解释，仍属于推断。模型本身、INT8 导出、数值运行环境各占多少影响，当前尚未分离。

## 本地受控对照

使用已校验的同一原录音，通过项目共享音频转换器得到 16kHz Float32 PCM。在 Mac 通过 C API 使用与项目 iOS 静态库相同的 sherpa 源码提交 **793c2405**、ONNX Runtime 1.28.2 和现有 INT8 权重，参数与 app 一致。最终分段也使用该 C API 的 Silero 实现；0.6 秒设置的五个区间与手机记录一致。

| 对照 | 本地观察 |
|---|---|
| 原异常区间，自动语言 | 出现重复坍塌，被原生循环检测截短，仅剩“我们不，有这个滑轨问题。以”。没有重现手机完全相同的英文文本。 |
| 同区间，指定 Chinese | 仍输出整段英文，包含中文内容的英文转述。 |
| 同区间，指定 English | 仍输出整段英文，保留相似语义错误。 |
| 自动语言，最短静音 0.3 秒 | 原异常区间对应音频分成两段，但第二段仍以 “In the same way” 开头，后续中文仍输出为英文。 |
| 自动语言，最短静音 0.2 秒 | 24.736 秒附近形成独立中文片段，恢复“如果把这件事放到今天……水位记得准不准”，并保留 fifteen / fifty。仍有“称/沉”等识别错误。 |

0.2 秒是实际声学 VAD 设置，边界由算法生成，没有用参考稿或人工语言标签指定分割点。

| 同一 Mac 上整条录音的配置 | 段数 | CER | S / D / I |
|---|---:|---:|---:|
| 自动语言，0.6 秒静音 | 5 | 46.91%（114 / 243） | 9 / 94 / 11 |
| 自动语言，0.2 秒静音 | 12 | 12.76%（31 / 243） | 13 / 5 / 13 |

两行可作为同机同输入对照。**不能把手机 70.37% 与 Mac 12.76% 当成已完成的真机修复前后成绩。** 即使提交和参数一致，当前 Mac 与手机在原异常段的自动解码仍不同；尚未取得手机转换后的逐样本 PCM 进行比对，也没有用官方未量化模型作同段对照。

0.2 秒的副作用也已观察到：后面的 “A clever idea needs careful checks” 被部分识别成“一个 clever idea，你 is careful checks”。分得更细能隔开部分语言切换，也会削弱短句的声学和语言上下文。不能据这一条录音直接替换全局默认值。

## 建议讨论的实施顺序

1. 保留当前原始模式，另增“短停顿分段”实验配置：自动语言，最短静音 0.2 秒，其余参数先保持一致。结果单独保存并记录分段参数，不自动覆盖旧结果，也不依靠参考稿选取两种结果中的正确片段。
2. 在同一台手机、同一模型文件上跑全部十段，并补纯中文、纯英文、无明显停顿的中英切换。比较整体 CER、英文 WER、语言转换错误、漏字及耗时；检查录音 4 的第二句英文是否退化。作为 Qwen 配置对照报告，避免把不同分段配置的收益直接解释为模型排名变化。
3. 增加诊断记录：原生库 Git SHA、每段 token 数、实际 VAD 区间、语言设置、重试理由；如需原始 language 前缀及停止原因，需要扩展当前原生接口。当前只检查接近输出上限，不能识别所有循环截短或错误翻译。
4. 若细分仍不稳定，再以同一异常音频对照官方未量化 0.6B 实现，区分模型能力与导出 / 量化 / 前端差异。此项尚未执行，不预先宣称更换权重能解决。

当前推荐先试第 1–2 步；固定 Chinese 或增加自然语言提示词均缺少本次样本的正向证据。暂不把语言识别路由重新加入公平对比流程，也不自动使用其他模型的文本补写 Qwen 结果。

可追溯本地证据位于 `build/qwen-codeswitch-audit-2026-10-29`：`acquisition.json`、`record-4.json`、音频及派生 PCM、`NativeProbe.swift`、`native-vad-regions.json`、`native-ablation.json`、`verified-cer.json`。初步 Python 探针使用同版本但不同提交 11afbd00；最终上表以 793c2405 C API 结果为准。以上私有录音和实验产物不进入 Git 或源码交付包。
