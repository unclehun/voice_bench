# Third-party components

VoiceBench uses the following components for its three on-device recognizers:

| Component | Version | License/source |
|---|---|---|
| sherpa-onnx | 1.13.8 | Apache-2.0; licenses/sherpa-onnx-LICENSE |
| ONNX Runtime | 1.28.2 | MIT; licenses/onnxruntime-LICENSE and onnxruntime-ThirdPartyNotices.txt |
| XcodeGen (build tool) | 2.44.1 | MIT; https://github.com/yonaskolb/XcodeGen |
| SenseVoiceSmall INT8 | 2024-07-17 export | Keep the model folder's original LICENSE and SOURCE.txt |
| Qwen3-ASR 0.6B W4A32 | block32, 2026-10-30-v1 | Derived from Qwen/Qwen3-ASR-0.6B; Apache-2.0; licenses/qwen3-asr-LICENSE and qwen3-asr-NOTICE; keep the model folder's LICENSE, NOTICE and SOURCE.txt |
| Silero VAD | SHA-256 pinned in the model manifests | Keep the model folder's VAD_LICENSE |
| Apple Speech / Foundation Models | System-managed | Apple system frameworks; no model weights bundled |

Model licenses and library licenses are separate. Model weights are distributed independently and excluded from Git and IPA. Retain all upstream license and notice files when redistributing binaries or model folders. Build dependency URLs, versions and SHA-256 are fixed in config/dependencies.json.
