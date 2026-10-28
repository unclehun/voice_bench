# Qwen3-ASR 0.6B INT8 接入（0.3.0）

新增独立第三套引擎，使用项目原有 sherpa-onnx 1.13.8 / ONNX Runtime 1.28.2。原有 SenseVoice、Whisper 语言检测、Apple Speech 及 Foundation Models 纠错引擎源码保持不变，最低系统仍为 iOS 26.0。

## 模型与手机目录

本机目录：`Models/Qwen3ASR_0_6B_INT8`。固定来源为 [sherpa-onnx INT8 导出](https://huggingface.co/csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/tree/68818b2313fe77bd06f6a7c5068ff3ef59d02b8a)，revision `68818b2313fe77bd06f6a7c5068ff3ef59d02b8a`。七份必需文件 SHA-256 锁定在 `config/qwen-model-manifest.json`，共 987,659,201 字节，约 988 MB / 942 MiB。

```text
Qwen3ASR_0_6B_INT8/
  conv_frontend.onnx
  encoder.int8.onnx
  decoder.int8.onnx
  silero_vad.onnx
  tokenizer/
    vocab.json
    merges.txt
    tokenizer_config.json
  manifest.json
  LICENSE
  NOTICE
  VAD_LICENSE
  SOURCE.txt
```

使用 Finder 文件共享或“文件”App，把整个文件夹放入 **在我的 iPhone → 语音对比（或 VoiceBench）**。新版第一次启动会创建空的 `Qwen3ASR_0_6B_INT8`；目录内直接放上述文件，避免多套一层同名目录，也不要把 tokenizer 内文件移到根目录。

- App 启动或设置中“检查状态”会在未安装 Qwen 时自动检查并导入一次。
- “从默认目录载入 Qwen3-ASR”可主动重新载入。
- “选择其他 Qwen3-ASR 目录…”通过系统文件选择器授权读取，复制、验证到私有目录后不依赖外部目录；重启无需再次选择。
- 未传完的默认目录不自动导入；主动载入时显示缺失文件。完整目录按内置 SHA-256 校验，失败保留旧模型，中间副本在导入结束或下次冷启动清理。

与 SenseVoice 一样，默认 Documents 源目录与内部工作模型是两份副本。首次导入若源目录也在手机上，需要约 2 GB 空间；替换时源文件、旧副本和导入暂存可能共需约 3 GB，另留录音及系统空间。这是磁盘占用，不是推理内存测量。模型不上传 Git，也不打包入 IPA。

## 运行方式

主界面“识别”在 Qwen 已载入时依次运行 SenseVoice、Apple、Qwen；未载入时继续原有两套流程。每套结果、失败及耗时分别保存，前一个引擎失败仍可继续后面的引擎，取消会停止本轮并关闭排队状态。录音详情 → 调试运行 → **仅 Qwen3-ASR** 可独立测试，不要求 Apple 或 Whisper 就绪。

Qwen 不接受外部语言预判，不传固定语言、不翻译、不加入参考稿或热词。输入转成 16 kHz 单声道后，用独立 Silero VAD 找语音，以约 20 秒最大语音段顺序识别并拼接。每段两端最多补 200 ms，避免重复音频。长语音的分段可能影响上下文，混说效果须用自己的录音评测。

使用 CPU、2 线程、128 维特征、`temperature=0`、`top_p=1`、`max_total_len=1024`、`max_new_tokens=512`。输出接近上限时保守报错，语音片段返回空文字也明确报错，已完成片段仍保留。同步原生推理期间不能立即打断，取消会在该段推理返回后生效；资源通过 defer 销毁。

Qwen 只记录 VAD 区间，不提供逐字对齐或伪造语言标签。报告记录模型版本、文件哈希、参数、完成片段数、错误阶段及临时文件清理结果。系统日志可搜索 **VoiceBenchQwenASR**，含 run ID、阶段、区间和错误码，不输出录音内容或转写文字。

## 数据删除

内部模型在 `Library/Application Support/VoiceBench/QwenModels`；派生音频在每条录音工作目录 `tmp/VoiceBench/Recording-UUID/Qwen-UUID.caf`。成功、失败、取消后清理，冷启动兜底。

删除录音会移除音频、全部历史 Qwen / SenseVoice / Apple 结果、纠错及该条录音的整个临时目录，保留其他录音和共享模型。“清除全部本机数据与模型”也删除内部 Qwen 模型、receipt、默认 Documents 源文件，仅重建空目录；手动选择的 App 外原件保留。上述目录均排除系统备份。

## 验证与手机验收

```sh
python3 scripts/prepare_qwen_models.py --verify-only
bash scripts/check_audio.sh Models/VoiceBenchModels Models/WhisperTiny_INT8 Models/Qwen3ASR_0_6B_INT8
bash scripts/check_apple_speech.sh
```

云端现有工作流会自动编译新增文件和校验清单，无需下载 Qwen 权重或增加 Secrets。推送源码后手动触发 Actions，下载新 IPA，使用相同 Apple 账号及最终 Bundle ID 在 Sideloadly 覆盖安装，再传模型。

本机没有 Xcode / iPhoneOS SDK。Mac 原生推理烟雾测试因旧 SDK 缺少 ONNX Runtime 所需的 `MLComputePlan`、`MLOptimizationHints` 链接符号而未执行成功，不代表已完成真机识别。`scripts/QwenSmoke.swift` 保留为具备匹配 macOS 原生库与 SDK 时的可选验证入口。没有为此安装 Xcode 或修改原有引擎。

新 IPA 真机先验证默认载入、重启复用和仅 Qwen 转写；再测试中文、英文、句间切换、句内混说、静音、超过 20 秒连续语音、取消和后台中断。确认各段完整、不重复，导出报告核对耗时和错误。删除一条录音后重启，确认其他录音和三套模型可用；清除全部后确认列表为空、三套外部模型需重新导入。手机准确率、速度与峰值内存仍待测。


0.4.0 另增独立 Fun-ASR-MLT-Nano 引擎。Qwen 的权重、导入扩展与推理实现保持不变，卡片会在其后运行已载入的 Fun-ASR；配置及分段差异见 [Fun-ASR 接入说明](FUNASR_MLT.md)。
