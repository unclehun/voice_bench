# Qwen3-ASR 4 位接入与手机导入

0.8.0 将已验证的 `Qwen3ASR_0_6B_WeightOnly4` 作为独立识别配置。设置、录音卡片、详情、CER、纠错和导出中统一显示 **Qwen3-ASR 4 位**。其引擎 ID 为 `qwen3_asr_0_6b_weight_only4`，模型版本为 `qwen3-asr-0.6b-w4a32-block32-2026-10-30-v1`。

## 手动导入手机

1. 编译并覆盖安装当前 0.8.0 Demo，保持 App 身份以保留已有数据。
2. 将工程 `Models/Qwen3ASR_0_6B_WeightOnly4` 的**整个文件夹**传入 **文件 → 在我的 iPhone → 语音对比 → Qwen3ASR_0_6B_WeightOnly4**，保留 `tokenizer` 子目录。
3. 打开 **设置 → Qwen3-ASR 4 位 → 从默认目录载入 Qwen 4 位**。启动和“检查状态”也会在完整传入后自动校验载入。如果模型放在其他位置，用 **选择其他 Qwen 4 位目录…** 选择整个文件夹。
4. 显示“4 位模型已就绪”后，点击录音卡片“识别”，会依次运行已经配置的引擎，4 位模型有独立结果。只运行它可进入 **详情 → 调试运行 → 仅 Qwen3-ASR 4 位**。

目录结构：

```text
Qwen3ASR_0_6B_WeightOnly4/
  conv_frontend.onnx
  encoder.int8.onnx
  decoder.weight4.onnx
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

七个必需文件合计 **916,915,569 字节，约 917 MB**；解码器固定 SHA-256 为 `fa1dd896ad8105e06a8b9659e34a233c1b094759e2279c8f1374152e771cb593`。App 使用内置 `qwen-weight-only-model-manifest.json` 校验配套文件，文件损坏、目录未传完或混入其他版本时拒绝导入。

导入会复制到 App 私有目录 `Library/Application Support/VoiceBench/QwenWeightOnlyModels`，需给传入目录及内部副本预留约 **1.84 GB**；替换已有模型时还需额外临时空间。校验通过才替换内部目录，失败保留已安装模型。重启及保留数据的覆盖更新无需重新选择目录。清除全部本机数据或删除 App 会清除该模型及其默认传入目录；手动选择的 App 外部源目录保留。

## 实际使用的已验证方式

- **模型**：保留原版音频前端、INT8 编码器及 tokenizer，解码器使用 ORT `MatMulNBits` 的 **4 位权重、分块 32、accuracy_level=1**。中间计算保持 Float32，词嵌入为官方 BF16 存储并转 Float32 使用。
- **识别**：与原 Qwen 使用同一个 `QwenSpeechEngine`，通过显式 `.weightOnly4` 分支选择 `decoder.weight4.onnx` 和独立模型目录。CPU 两线程，原生自动语言、greedy、temperature=0、top_p=1、seed=0、max_total_len=1024、max_new_tokens=512。无前置 Whisper 语言检测，不受 Apple 默认语言设置影响。
- **输入**：同一份原始录音转换为 16kHz、单声道 Float32；Silero VAD 阈值 0.5、窗口 512、最短静音 0.6 秒、最长语音 20 秒，首尾最多各加 200ms，后段起点裁剪到上一段末尾。
- **区间读取**：使用已修复并逐字节验证的 `exact-float32-loop-v1`，循环读满目标帧数，提前 EOF 报错，避免一次 `AVAudioFile.read` 少读导致输入变化。
- **结果**：4 位模型有独立 engine ID、版本、文件哈希、运行记录、CER 和纠错结果。原 INT8 历史记录保持可读，导入 4 位模型不会替换原 INT8。

模型文件和推理配置对应已完成的 [官方原始模型对照](QWEN_REFERENCE_VALIDATION.md)及 [4 位／8 位十段受控比较](QWEN_WEIGHT8_COMPARISON.md)。本机为 macOS Command Line Tools 环境，没有 iPhoneOS SDK，因此本地检查与原生 Mac 推理不能代替 iOS 编译及手机验收。

## 手机验收

先在录音 4 单独运行“Qwen3-ASR 4 位”，核对英文后紧接的中文及 `fifteen` / `fifty`，再运行全部十段、计算 CER 并导出 JSON。记录每条耗时、失败和取消情况，测试重启后继续识别。手机结果可能与 Mac 不同，应保留原始转写评测后再运行纠错。
