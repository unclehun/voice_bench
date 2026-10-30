# GitHub Actions 构建

工作流 `.github/workflows/ios.yml` 仅手动触发，使用 macOS runner 和 Xcode 26.3，准备固定 iOS 依赖、生成工程并构建 Release。

1. 推送当前源码与工程配置。
2. 在 Actions 中选择 “Build unsigned iPhone demo” 并运行。
3. 下载构建产物中的未签名 IPA，使用自己的签名工具签名并覆盖安装。

保持最终 Bundle ID 和签名身份，覆盖安装以保留录音、当前模型和设置。无需先删除旧 App。模型文件使用文件夹导入，不进入 Git 或 IPA。

工作流产物保留三天。构建需要的仓库内容包括 Sources、VoiceBench、project.yml、Package.swift、config、licenses 和 scripts 中的构建工具。Vendor、Models、下载缓存和构建产物均不提交 Git。
