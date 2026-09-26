# MoRead iOS Full Port

这是 `ovo066/MoRead` 的 iOS / iPadOS 功能等价移植工程。目标不是把 APK 转成 IPA，而是保持 Android 版当前源码的功能边界、数据语义、隐私边界和主要交互，在 Apple 平台上使用对应系统 API 重建。

## 当前源码范围

当前工程包含 150+ 个 Swift 源文件，数据层使用与 Android schema 32 对齐的 SQLite 表结构；书籍正文继续使用 `book-text/<bookId>/text.mz` 和 UTF-16 原文坐标语义。阅读器、伴读、TTS、备份、词典、生图、有声书、统计、书架管理等均已接入真实 UI 与调用链，而不是占位页面。

已覆盖的主要功能域包括：

- TXT / EPUB 导入，多文件批量、文件夹扫描、局域网传书、Legado 同源分章规则、自定义正则与 AI 辅助分章、TXT 重新分章。
- EPUB XHTML/CSS/图片/SVG/字体资源、特殊资源路径桥接、横排/竖排、分页/滚动、双页、五种翻页模式、选择、书签、批注、全文搜索与原文 UTF-16 坐标回映。
- 阅读主题、日夜槽、按书主题、字体/图片资产库、章首样式、正文净化/永久应用、语法高亮、繁简转换、自动阅读、外接键盘、自定义点击区域、亮度/常亮、英语学习与中英对照。
- MDX / MDD 本地词典、MDD 资源协议、划词查词、生词本、音标、词下释义、段落翻译缓存。
- AI 四协议：OpenAI Chat、OpenAI Responses、Claude、Gemini；多 Provider / 多模型 / 角色分配、Embedding、Rerank、Web 搜索、流式消息、Token 用量、API 日志。
- 书内伴读与书库伴读：防剧透 ReadingScope、BM25 + embedding、grep 精确计数、工具调用、消息编辑/删除/重生成/分支/失败重试/停止残段保存、用户面具、全局提示词、SillyTavern 卡与世界书、角色工具白名单与模型覆盖、长期记忆与 rolling summary。
- 章节大纲、全书人物、随读段评、角色互动提醒、剧情梗概、AI 改写/续写、批注讨论、选词即问、AI 建议回复。
- 插图工作室：画风、跨书模板、人物形象版本、参考图、三视图候选、章节计划、批量队列、OpenAI Images / Chat 出图 / NovelAI、封面搜索/生成、图片导出与封面设置。
- 连续听书与有声书：AVSpeechSynthesizer、云 TTS、锁屏/控制中心、跨章、睡眠定时、句子高亮、角色音色、剧本确认、状态机、批量生产、系统实时 TTS + AI 缓存混合播放、Gemini Voice Design。
- 书架：搜索、状态/分组/标签 ANY/ALL 组合筛选、置顶、合集、根书架与合集拖拽、多选/全选可见项、批量管理、无封面文字封面、iPad 常驻详情栏。
- 回顾与统计：卡片/全屏回顾、媒体批注、角色共创、Markdown/图片分享模板、总/年/月/周/日、热力、封面月历、时间线、时段、按书/作者、连续阅读日期、组件显隐与拖拽排序。
- WebDAV 完整/轻量备份、真实上传/下载进度、恢复前校验、恢复 staging、启动时恢复自动调度；存储管理、软删除/永久删除、孤儿清理。
- iPhone / iPad 自适应：NavigationSplitView、阅读 + 伴读并排、书籍详情 + 有声书分栏、双页阅读；文件 App 外部打开 TXT / EPUB / MDX / MDD。

详细对应关系见 `PORTING_MATRIX.md`。

## Apple 平台等价适配

以下能力无法逐字复刻 Android 底层机制，但用户可见功能使用 iOS 对应能力实现：

- Android Foreground Service / MediaSession → `AVAudioSession` + `MPRemoteCommandCenter` + Now Playing。
- WorkManager → `BGTaskScheduler`。iOS 决定后台任务实际执行时刻，因此自动备份不能承诺精确到某一分钟。
- EncryptedSharedPreferences → Keychain。
- Android 物理音量键翻页 → 外接键盘/硬件按键映射；iOS 不提供第三方 App 全局拦截实体音量键的等价公开 API。
- Android 第三方 TTS 引擎枚举 → iOS 系统 Voice + 应用内云 TTS。

## GitHub Actions 生成 unsigned IPA

仓库已经包含 `.github/workflows/build-ios-unsigned.yml`。上传到 GitHub 后运行 **Build iOS unsigned IPA**：

1. XcodeGen 生成 `MoRead.xcodeproj`。
2. 解析固定版本的 Swift Package 依赖。
3. 在 `iphoneos` Release 配置下无签名编译 `MoRead.app`。
4. 验证 Bundle ID、iPhone/iPad 设备族、iOS 最低版本、后台模式、BGTask、TXT/EPUB/MDX/MDD 文档类型和本地化资源。
5. 封装为 `Payload/MoRead.app` → `MoRead-unsigned.ipa`。

下载 `MoRead-unsigned-ipa` artifact 后，用你自己的 Apple ID / 证书通过 SideStore、AltStore、Sideloadly 或其他合法自签工具签名安装。

## Mac 本地构建

```bash
brew install xcodegen
./scripts/build_unsigned_ipa.sh
```

产物：`build/MoRead-unsigned.ipa`。

如果直接用 Xcode：

```bash
xcodegen generate
open MoRead.xcodeproj
```

选择自己的 Team，并把 `PRODUCT_BUNDLE_IDENTIFIER` 改成属于你的唯一 Bundle ID 后即可连接 iPhone/iPad 运行。

## 验证边界

当前运行环境不是 macOS，没有 Xcode / iOS SDK，因此这里可以完成 Swift 语法解析、plist/YAML/shell 静态检查和源码级功能审计，但**不能替代真正的 `xcodebuild` 类型检查、链接、iOS 模拟器测试和真机交互测试**。GitHub macOS runner 是本工程的最终编译验收环境；若首次 Xcode 构建暴露 Apple SDK 类型差异，应以构建日志为准继续修复，而不是把“Swift parser 通过”误称为真机已验证。

## 许可

本移植工程是 MoRead 的修改版本，按 GNU GPL-3.0 发布。`LICENSE`、`THIRD_PARTY_NOTICES.md` 及 App 内“设置 → 开源许可”保留许可证和第三方说明。不要提交 API Key、Apple 证书、provisioning profile 或用户书籍/备份数据。
