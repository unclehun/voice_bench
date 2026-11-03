# 全文纠错设计 · 0.12.1

## 请求与模型职责

每个识别结果由 DeepSeek 独立接收一个对象：

```json
{"document":"完整且未经截断的识别原文","background":"用户确认的背景"}
```

模型先理解全文，再一次返回整篇的 `edits` 和 `has_more`。没有 target、segment_id、mode、overview，没有句子窗口或摘要请求。一次成功的模型调用覆盖整篇；只有格式异常可在同样全文输入上重试一次。原文只出现一次，不同时重复为全文与目标。

返回精确 original、replacement、唯一 anchor、全文或背景 evidence 等信息。程序按全文原始偏移验证建议并重建完整采用文字，不让模型的自由重写破坏逐条复核。红色删除线原词与紧随的绿色修正文来自相同位置数据；CER 和导出采用文字只包含实际采用内容。

DeepSeek 使用 `/beta/chat/completions`、强制单个 `submit_document_corrections` 工具与 strict schema。根对象两个字段及建议对象的八个字段全部 required，均禁止额外字段；从工具 arguments 解码，校验 finish_reason 和工具名称。API 外层错误与业务解码错误分别记录；字段错误包含路径，合法 UUID 响应 ID 可供定位，不暴露远端错误正文或凭据。

模型一次可返回最多 128 条建议，取代旧的每片段八条上限。若模型声明仍有未返回建议，状态为 partial，保留已校验建议并明确说明完整性不足，不发新目标片段请求、不声称全部完成。截断、空白或格式无效不会尝试猜补 JSON；最多重试一次，鉴权／余额／上下文容量错误不重试。

## 存储与兼容

新版本标记：`policyVersion=semantic-document-v3`、`promptVersion=whole-document-proofread-v3`。`Correction.document` 保存一份不可变完整原文、整篇 changes 与 isComplete，attemptCount 记录实际尝试次数。新结果 blocks 为空。

旧版 blocks、semanticOverview 等字段保留用于读取历史数据，运行新流程时清空。DeepSeek v2 的人工选择不会在升级时重算或失效，仍允许逐条复核。历史分段说明明确标为旧版；新结果只展示全文状态和错误。

全文失败、取消及中断时保留完整原文。只有已完成／明确部分完成的结果进入纠错 CER；失败时显示的原文不能伪装成一份纠错成功结果。报告 schemaVersion 升为 5，仅保留原文与 DeepSeek 评测字段，JSON 包含 document；Markdown 注明处理范围及建议完整性。

## 验证

新增两组测试覆盖全文工作流和 DeepSeek 实际客户端（URLProtocol 模拟接口），连同展示及旧数据清理测试共 40 组：长文一次完整传入、背景保真、远处证据、重复词全文偏移、20 条建议一次返回、同全文重试、取消、失败保留原文、不完整输出、逐条复核、存储、旧版兼容、CER、schema 必需字段、缺字段与无效 JSON、空白／截断／错误工具、鉴权及上下文错误等。

完整核心模块已在本机由 swiftc 编译通过；测试方法使用独立断言驱动通过。标准 `swift test` 受当前 Command Line Tools 缺少 Xcode PlatformPath／XCTest 阻塞，CI 保持运行标准测试。SwiftUI 源码通过语法解析；完整 iOS 类型检查及安装仍需完整 Xcode。

实际 DeepSeek 验证使用生产版 `DeepSeekTextCorrector.correct`，将从手机读取的录音 10 原文完整传入：

| 识别结果 | 全文字数 | 请求次数 | 状态 | 返回建议数 |
|---|---:|---:|---|---:|
| Qwen3-ASR 4 位 | 379 | 1 | completed，完整返回 | 6 |
| SenseVoice | 368 | 1 | completed，完整返回 | 7 |

测试调用没有修改手机的纠错记录；本地证据位于 build/diagnostics/whole-document-v3，未包含在源码包中。临时凭据副本在测试后删除。

## 移除的数据与升级

0.12.0 的 Run 不再定义旧本地纠错属性，序列化与报告不再包含 `correction`、旧本地纠错 CER／增量字段。加载录音时，RetiredDataCleanup 在解码前删除该历史对象及专属配置，覆盖全部保留引擎的所有历史运行；不改写或挪用 DeepSeek 结果。清理只在确有残留时增加 revision，重复执行不再修改数据；LocalStore 随后原子落盘。冷启动仍清理 App 自有临时报告，防止旧报告继续残留。

移除不影响 Apple Speech 语音识别；其模型、语言、配置与识别结果保留。App 没有自有的被移除文字模型权重目录。

## 官方依据

- [DeepSeek strict 工具调用](https://api-docs.deepseek.com/guides/tool_calls/#strict-mode-beta)

## 0.12.1 返回诊断与兼容

官方工具调用的解析位置仍为 choices[0].message.tool_calls[0].function.arguments。实际抓到的响应却出现了 arguments={"function_calls":{"edits":[...],"has_more":false}}，与请求根 schema 不同。新版只对这个精确、无歧义的单层包装解包，并继续执行全部字段与原文语义校验；混合根结构、缺字段、无效类型均不默认成无修改。

每次尝试单独记录请求正文、完整 HTTP body 和 arguments 原文，收到响应后先落盘再解码。解析错误被反馈到唯一一次全文重试，请求原文不变；再次手动纠错产生新的操作 ID，前次日志仍保留。每次运行保留最近20次 HTTP 尝试，JSON 报告携带日志。App 提供日志详情、复制、分享，系统 Logger 以带编号的小段打印完整内容；已知 API Key（含多层 JSON 转义形式）与鉴权头不写入日志。

手机旧版在二次成功后没有原始失败包，无法恢复此前被覆盖的记录。本次复现包及错误分析保存于 build/diagnostics/deepseek-raw-logs，修改后的解码器可从同一真实响应直接读出六条建议，无须重发。另一次对照确实捕获到服务把 has_more 错写成工具名的非法根对象：保持严格拒绝、留存原文，并通过带具体错误反馈的重试成功，不猜测或静默补写字段。
