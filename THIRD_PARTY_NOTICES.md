# Third-party components

VoiceBench uses these components solely for on-device evaluation:

| Component | Pinned version | License/source |
|---|---|---|
| sherpa-onnx | 1.13.8 | Apache-2.0; see licenses/sherpa-onnx-LICENSE |
| ONNX Runtime | 1.28.2 | MIT; see licenses/onnxruntime-LICENSE and bundled third-party notices |
| XcodeGen (build tool, not shipped inside App) | 2.44.1 | MIT; source: https://github.com/yonaskolb/XcodeGen |
| SenseVoice INT8 model | 2024-07-17 export | Model package LICENSE, copied during model preparation/import |
| Silero VAD model | asr-models release asset, exact SHA-256 recorded on import | See model folder VAD_LICENSE |

Library licenses and model licenses are separate. The model weights are downloaded independently and excluded from source control and IPA. Original upstream license/notice files must accompany redistributed binaries and model folders. Inspect the exact downloaded model LICENSE before redistribution; this project does not grant additional rights to weights.

Static iOS libraries are pinned by URL and SHA-256 in config/dependencies.json. The ONNX Runtime Swift package at tag 1.28.2 currently points at 1.28.1 binaries; this project directly selects and checks the 1.28.2 iOS binary referenced by sherpa-onnx's build script instead.
