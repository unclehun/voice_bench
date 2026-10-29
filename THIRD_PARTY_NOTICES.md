# Third-party components

VoiceBench uses these components solely for on-device evaluation:

| Component | Pinned version | License/source |
|---|---|---|
| sherpa-onnx | 1.13.8 | Apache-2.0; see licenses/sherpa-onnx-LICENSE |
| ONNX Runtime | 1.28.2 | MIT; see licenses/onnxruntime-LICENSE and bundled third-party notices |
| XcodeGen (build tool, not shipped inside App) | 2.44.1 | MIT; source: https://github.com/yonaskolb/XcodeGen |
| SenseVoice INT8 model | 2024-07-17 export | Model package LICENSE, copied during model preparation/import |
| Whisper Tiny multilingual INT8 (language ID only) | Hugging Face csukuangfj/sherpa-onnx-whisper-tiny revision 65176e2deb88badc814a94058666cadccc29b61c | OpenAI Whisper MIT; see licenses/whisper-LICENSE and Models/WhisperTiny_INT8/SOURCE.txt |
| Whisper large-v3-turbo multilingual INT8 ONNX (ASR) | Hugging Face csukuangfj/sherpa-onnx-whisper-turbo revision 2ca6ff69fc878651b770880507669577ac41c2ff | OpenAI Whisper MIT; see licenses/whisper-LICENSE and Models/WhisperLargeV3Turbo_INT8/SOURCE.txt |
| Qwen3-ASR 0.6B INT8 ONNX | Hugging Face csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25 revision 68818b2313fe77bd06f6a7c5068ff3ef59d02b8a | Apache-2.0; see licenses/qwen3-asr-LICENSE, licenses/qwen3-asr-NOTICE and model folder SOURCE.txt |
| Fun-ASR-MLT-Nano INT8 ONNX | luigi000/fun-asr-mlt-nano-onnx-int8 revision 932d7dbb98623bd31314015b3bc0dac0dcf80acc; publisher identifies base as FunAudioLLM/Fun-ASR-MLT-Nano-2512 | Apache-2.0; pinned exporter LICENSE and NOTICE in licenses/funasr-mlt-*; source in model SOURCE.txt |
| Silero VAD model | asr-models release asset, exact SHA-256 recorded on import | See model folder VAD_LICENSE |

Library licenses and model licenses are separate. The model weights are downloaded independently and excluded from source control and IPA. Original upstream license/notice files must accompany redistributed binaries and model folders. Inspect the exact downloaded model LICENSE before redistribution; this project does not grant additional rights to weights.

Static iOS libraries are pinned by URL and SHA-256 in config/dependencies.json. The ONNX Runtime Swift package at tag 1.28.2 currently points at 1.28.1 binaries; this project directly selects and checks the 1.28.2 iOS binary referenced by sherpa-onnx's build script instead.
