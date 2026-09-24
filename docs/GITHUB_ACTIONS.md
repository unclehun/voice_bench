# GitHub 云端编译

仓库：https://github.com/unclehun/voice_bench

## 首次运行

1. 用仓库所有者账号登录 GitHub，打开仓库的 **Actions**。
2. 如显示启用工作流提示，点击 **I understand my workflows, go ahead and enable them**。
3. 选择左侧 **Build unsigned iPhone demo**。
4. 点击 **Run workflow**，分支选 `main`，再次点击 **Run workflow**。
5. 打开本次运行查看日志。首次需要下载原生库；后续使用缓存。
6. 运行成功后，在运行详情页底部 **Artifacts** 下载 `VoiceBench-运行编号`，解压得到 `VoiceBench-unsigned.ipa`、校验文件和构建记录。

直接入口：https://github.com/unclehun/voice_bench/actions/workflows/ios.yml

如果找不到 Run workflow：确认已登录有写权限的账号，工作流在默认分支，且仓库 **Settings → Actions → General → Actions permissions** 允许 GitHub Actions。若采用允许列表，需要允许 `actions/checkout`、`actions/cache`、`actions/upload-artifact`。**Workflow permissions 保持只读即可**。

无需配置 Secrets、Variables、Apple ID、开发者证书或 provisioning profile。编译使用 GitHub 提供的 macOS，不在本机安装 Xcode。工作流只手动运行，推送不会自动产生构建。

## 工具链和费用

- 标准 `macos-15` runner；显式选择 `/Applications/Xcode_26.3.app/Contents/Developer`，避免系统默认 Xcode 版本过旧。
- App 最低 iOS 26.0；构建 SDK 版本与最低系统版本是不同设置。
- GitHub 官方目前对公开仓库的标准 runner 免计算时长费用；大型 runner 仍收费。本工作流不用大型 runner。
- Artifact 与缓存仍有存储配额。本工作流只保留构建产物 3 天，模型不进入缓存或 Artifact；下载后可删除旧运行产物。无需提高付费额度。

官方说明：[Actions 计费](https://docs.github.com/en/billing/concepts/product-billing/github-actions)、[macOS 15 工具链清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)。

## 大文件处理

GitHub 拒绝超过 100 MiB 的普通 Git 文件。本项目采用外部下载与校验，不需要 Git LFS：

| 内容 | 存放方式 |
|---|---|
| Swift 源码、工程、配置、文档、图标 | 普通 Git |
| sherpa-onnx / ONNX Runtime 二进制 | 构建时从固定的上游 Release 下载并验证 SHA-256 |
| SenseVoice INT8、tokens、VAD | 本机运行 `python3 scripts/prepare_models.py`，导入手机 |
| IPA、dSYM、构建日志 | GitHub Actions Artifact，保留 3 天 |

`Models/`、`Vendor/`、`.downloads/`、`.tools/`、`build/` 已被忽略。新增提交前可运行 `python3 scripts/check_git_files.py`，检查暂存区 / 已跟踪文件；CI 也会拒绝上述目录或超过 10 MiB 的单个 Git 文件，留出安全余量。不要使用 `git add -f` 把依赖或模型加入历史。官方：[大文件限制](https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github)。

## 安装和验证

IPA 未签名，不能直接点击安装。下载后在 Mac 上用 Sideloadly 和自己的免费 Apple 账号签名侧载；通常每 7 天续签一次。账号只在本机签名工具登录。

安装后按 README 导入完整模型文件夹、准备苹果中文资源，再对同一录音运行两个引擎。首次云端构建通过仅证明编译 / 链接成功，不等于 iOS 27 侧载或识别效果已通过真机测试。

## 构建失败时

- **Verify toolchain**：GitHub 镜像可能调整，核对官方清单中的 Xcode 路径，再修改工作流。
- **Core tests**：打开该步骤查看 Swift 测试错误。
- **Build device IPA**：优先定位第一条 `error:`；下载 Artifact 中 `build.log` 和 `toolchain.txt`。依赖哈希失败应核对上游，不能直接跳过校验。
- Artifact 上传提示存储配额不足：下载并删除过期产物后重试；无需上传模型到 Artifact。
