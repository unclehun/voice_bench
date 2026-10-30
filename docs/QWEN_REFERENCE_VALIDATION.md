# Qwen 官方对照与优化版（0.8.0）

## 结论

同一段 19.710–36.976 秒 PCM，官方 0.6B 原始模型可以保留中英混读；由同一原权重导出的浮点 ONNX，经过当前 sherpa 原生解码器后也能逐字复现官方结果。保留 INT8 编码器、使用浮点解码器仍正确；反过来使用浮点编码器、保留原 INT8 解码器仍会将中文输出成英文。由浮点图重新执行原来的动态 UINT8 量化，也能复现本机原有的重复坍塌。

因此，本次证据指向 **当前解码器的动态量化路径**，不支持把 VAD 分段当作唯一根因，也不代表所有 INT8 模型都会发生同样问题。仅改变整数的有符号性、或只恢复词嵌入精度均未解决样本。

0.8.0 增加独立的 **Qwen3-ASR 4 位**：保留原 INT8 编码器、音频前端、tokenizer、Silero VAD 和自动语言策略；解码器改用分块 4 位权重，保持 Float32 中间计算，词嵌入保留官方 BF16 存储并转换成 Float32 使用。这里的“4 位”只描述解码器的大部分矩阵权重，不能理解为整套模型所有计算都是 4 位。

原版继续可用。优化版使用独立引擎 ID、模型目录、receipt、结果和评测，不覆盖旧运行。尚未完成新版 iOS 编译与真机准确率／性能验证，因此保持试验入口。

## 官方基准与输入控制

- 官方来源：[`Qwen/Qwen3-ASR-0.6B`](https://huggingface.co/Qwen/Qwen3-ASR-0.6B/tree/5eb144179a02acc5e5ba31e748d22b0cf3e303b0)，固定 revision `5eb144179a02acc5e5ba31e748d22b0cf3e303b0`；原始 `model.safetensors` 为 1,876,091,704 字节，SHA-256 `79d6cbd4c98c7bbffe9db2edac07f56cd6637d0d5944b27f6c2b8353840323ea`。
- 使用 Qwen 官方 `qwen-asr==0.0.6`、Transformers 4.57.6、PyTorch 2.5.1。BF16 checkpoint 在本机以 CPU / Float32 / eager attention 加载；这是本次兼容性选择，不冒充官方 CUDA/BF16 性能。完整依赖见 `config/qwen-reference-python-macos13.lock.txt`。
- 复用经原始音频 SHA-256 校验的 16kHz 单声道 Float32 PCM。主异常段 276,256 个采样点，SHA-256 `b52ec7f2c533a0ca87d09daa647ec6d98e2d8b5145d5d4fa24442644f4f595ae`。官方接口直接接收 `(numpy_array, 16000)`。
- 自动语言、空 context、greedy、batch=1、512 新 token；不传参考稿、不做文字纠错。额外指定 Chinese 仅用于诊断。
- 官方异常段实际前缀为 `language Chinese<asr_text>`，正常以 EOS 结束。返回标签不等于“所有输出必须是中文”；指定 Chinese 时的标签也不能当作自动检测证据。

官方输出保留 “We do not have to solve every problem in the same way. 如果把这件事放到今天……第一次是 fifteen，第二次却变成了 fifty”。仍有“称／沉”等识别误差。

采用 [Qwen 官方推理流程](https://github.com/QwenLM/Qwen3-ASR/blob/main/qwen_asr/inference/qwen3_asr.py)；原始语言前缀、生成 token、EOS 证据与包源码校验值都保存于本地实验报告。

## 分层对照

| 编码器 | 解码器 | 同一异常段的结果 |
|---|---|---|
| 官方浮点实现 | 官方浮点实现 | 中英保留 |
| FP32 ONNX | FP32 ONNX | 与官方同段及原五段输出逐字一致 |
| 原 INT8 | FP32 ONNX | 中英保留 |
| FP32 ONNX | 原动态 INT8 | 中文仍变为英文 |
| 原 INT8 | 从同一浮点图重新动态 UINT8 量化 | 复现重复坍塌 |
| 原 INT8 | 动态有符号 INT8 | 中文仍变为英文 |
| 原 INT8 | 原动态 INT8，仅恢复原始词嵌入 | 中文仍变为英文 |
| 原 INT8 | 仅量化权重，8 位／分块 64 | 中英保留，但本机 CPU 明显变慢 |
| 原 INT8 | 仅量化权重，4 位／分块 32 | 中英保留，进入十段回归 |

浮点导出审查参考 [sherpa 导出指南](https://k2-fsa.github.io/sherpa/onnx/qwen3-asr/export.html)引用的社区导出器 `Wasser1462/Qwen3-ASR-onnx@0829a577ee741e408e65763dfe01ff4fe75408e9`；它不是 Qwen 官方导出器。本次仍加载官方包的模型类，没有替换成导出仓库自带的模型副本。卷积、编码器和解码器的导出检查均通过；随后用真实语音核对完整转写，避免把随机张量通过当成准确率验证。

最终候选通过 `scripts/prepare_qwen_weight_only_models.py` 直接从原版固定图结构和官方原始权重生成，去掉 197 处矩阵乘法的中间激活动态量化，采用 ORT `MatMulNBits` 的权重分块量化。无需将社区导出器代码加入 App。最终候选在十段 67 个固定区间上的文本与先行浮点导出候选逐字一致。

这种方案的收益来自量化对象和粒度发生变化，不能概括成“4 位必然比 8 位准确”。量化本身有损，应按实际语音验证。[ORT 量化调试说明](https://onnxruntime.ai/docs/performance/model-optimizations/quantization.html#quantization-debugging)

## 十段受控 Mac 对照

只读复制并校验用户十条原始录音；两种模型读取相同 PCM 和同一组 67 个 VAD 区间。sherpa Git SHA `793c2405`、ONNX Runtime 1.28.2、CPU 两线程、自动语言、20 秒上限、最短静音 0.6 秒及 200ms 边缘保护相同。

| 录音 | 原动态 INT8 CER | 优化版 CER |
|---|---:|---:|
| 1 | 0.84% | 0.84% |
| 2 | 6.45% | 6.45% |
| 3 | 2.37% | 2.37% |
| 4 | 46.91% | 7.00% |
| 5 | 0.75% | 0.75% |
| 6 | 24.04% | 7.67% |
| 7 | 7.75% | 5.99% |
| 8 | 3.13% | 3.82% |
| 9 | 23.36% | 6.23% |
| 10 | 4.47% | 5.11% |
| 加权总体 | **12.00%（329 / 2742）** | **4.70%（129 / 2742）** |

使用项目实际 `Evaluation.cer`，忽略标点、空白与 ASCII 大小写。录音 8、10 各增加两处编辑错误，其余持平或改善。结果来自同一 Mac 的本地对照；不能与之前手机上的 Qwen 10.87% 或录音 4 的 70.37% 直接组成修复前后成绩，也不能据此重排手机所有模型的名次。

优化版完整必需文件 **916,915,569 字节**，原版为 987,659,201 字节，减少约 70.7 MB。受控 C API 回归中的解码时间约为原版两倍；这不是手机性能结论，仍需真机测量耗时、峰值内存及连续运行。

## 共享音频读取修复与 App 引擎复核

初次共享 App 引擎回归与固定 PCM 探针存在文本差异。逐字节检查发现原 `AudioFiles.samples` 在一次 `AVAudioFile.read` 后即返回，67 个区间都发生短读，少 64–1003 个采样点；录音 4 异常段少了 768 点。旧实现没有继续读取剩余帧。

0.8.0 将其改为有界缓冲循环读满，遇到提前 EOF 明确失败。修复后同样 67 个区间与固定 PCM **逐字节一致，0 处差异**，并加入合成可定位帧序列的 seek／尾部回归。Qwen、SenseVoice 和 Whisper Turbo 使用该共享方法，均获得读取修复并记录 `audio_region_reader=exact-float32-loop-v1`；Fun-ASR 已有独立的精确读取实现，本次未改其识别流程。

独立量化对照始终采用完整、相同 PCM，因此其根因证据仍成立。短读是本轮另外确认的输入完整性缺陷；修复前共享 App 的数值结果保存在 `app-regression-before-exact-reader.json`，不冒充最终 0.8.0 成绩。

最终共享 App 引擎对十条原始 M4A 的 20 次运行全部完成，包含实际转换、VAD、完整区间读取和每条临时数据清理。

| 最终共享 App 引擎 | 十段总体 CER | 录音 4 CER | 十段转写总时间 |
|---|---:|---:|---:|
| 原版 | 11.52%（316 / 2742） | 80.66%（196 / 243） | 102.3 秒 |
| 优化版 | 4.85%（133 / 2742） | 7.00%（17 / 243） | 233.1 秒 |

| 录音 | 原版 CER | 优化版 CER |
|---|---:|---:|
| 1 | 0.84% | 0.84% |
| 2 | 5.65% | 6.45% |
| 3 | 2.77% | 2.77% |
| 4 | 80.66% | 7.00% |
| 5 | 0.75% | 0.75% |
| 6 | 8.71% | 8.36% |
| 7 | 7.75% | 5.63% |
| 8 | 3.12% | 3.82% |
| 9 | 8.41% | 7.17% |
| 10 | 3.83% | 4.79% |

这是 **Mac 测试，不是 iPhone 成绩**。优化版录音 4 保留中文和 fifteen / fifty，仍有 “have the solve”“沉／称”等误识；录音 2、8、10 分别增加 2、2、3 处编辑错误。本机转写约慢 2.3 倍，不能仅报告准确率收益而忽略耗时。

实际原始 AAC 输入的 App 流程与固定 PCM 的 C API 探针仍存在文本差异，原版尤其敏感；全部区间边界一致。共享区间读取已证明字节完整，但尚未完全分离两种运行路径的底层数值差异。因此两组结果分别列出，不将其中最佳成绩拼成一次运行；真机准确率和稳定性仍需覆盖安装后验证。

## 使用与复现

已生成模型位于 `Models/Qwen3ASR_0_6B_WeightOnly4`。编译 0.8.0 后，将完整目录复制到 iPhone 的“语音对比”文件夹，进入设置的“Qwen3-ASR 4 位”载入。识别比较和详情中均有独立入口，操作见 [4 位接入说明](QWEN_WEIGHT_ONLY4.md)。

校验现有文件：

```sh
python3 scripts/prepare_qwen_weight_only_models.py --verify-only
```

重建需使用已验证的独立 Python 环境，以及原版 INT8 和官方 checkpoint。向一个新的空目录输出；生成结果必须与已提交的 manifest 一致：

```sh
.tools/qwen-official-venv/bin/python scripts/prepare_qwen_weight_only_models.py --output /tmp/Qwen3ASR_0_6B_WeightOnly4-rebuilt
```

官方基准及共享引擎检查入口：`scripts/qwen_reference_audit.py`、`scripts/check_qwen_native.sh`。模型来源／版本和校验清单位于 `config/qwen-reference-model-manifest.json`、`config/qwen-weight-only-model-manifest.json`。优化版完整文件及原始录音不进入 Git 或源码包。

## 验证边界

新增模型导入覆盖校验失败时的原子性、原版与优化版隔离、重启后的 receipt、备份排除、清除全部本机数据，以及真实完整候选模型导入和删除。原 API Key 配置路径和清除行为不变。共享 Qwen Swift 引擎完成真实推理、预取消、已解码后的取消和临时文件清理；Whisper Turbo 的真实转写、解码后取消及静音清理检查也通过。模型从空目录重复构建后，全部七份文件与固定 SHA-256 一致。

本机缺少 iPhoneOS SDK，未执行新版 iOS 编译或在手机上运行候选。随仓库提供的 iOS ORT 二进制含 `MatMulNBits`，这只核对了依赖符号，不能替代真机运行。新模型保持试验状态。

所有私有实验记录保存在本机 `build/qwen-official-audit-2026-10-30`，包括官方基准、浮点和各量化对照、67 区间回归、CER 输入与 Swift 计分输出、共享引擎报告及构建日志。
