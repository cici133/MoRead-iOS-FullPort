# Android → iOS 功能等价矩阵

状态含义：`源码已接入` 表示 iOS 工程存在实际数据层、业务调用链与 UI 入口；`平台等价` 表示底层机制必须用 Apple API 替换；`需 Xcode/真机验收` 表示 Linux 环境无法证明 Apple SDK 编译或硬件交互。

| Android MoRead 功能域 | iOS 实现 | 状态 |
|---|---|---|
| Room schema 32 | SQLite schema 32，保持书籍/章节/批注/会话/统计/插图/有声书等表语义 | 源码已接入 |
| DataStore | JSON / UserDefaults 风格设置仓储，按模块持久化并纳入备份 | 源码已接入 |
| EncryptedSharedPreferences | Keychain 保存 API Key / WebDAV 密码 | 平台等价 |
| WorkManager | BGTaskScheduler 自动备份 + 启动恢复调度 + 状态账本 | 平台等价；需真机验收 |
| TXT 导入 | 编码质量探测、Legado 同源规则、预览、自定义正则、AI 规则、重新分章 | 源码已接入 |
| 批量/文件夹导入 | 多选 TXT/EPUB；目录递归扫描、500 本/8 层限制、垃圾目录过滤 | 源码已接入 |
| 局域网传书 | Network.framework 本机 HTTP 上传，上传后走正式导入链 | 源码已接入；需真机网络验收 |
| EPUB | OPF/spine/toc、XHTML/CSS、图片/SVG/字体、本地 URI 桥接、特殊文件名 | 源码已接入 |
| 自绘/分页阅读 | WKWebView 排版 + 原生控制层；分页/滚动、横/竖排、双页、5 种翻页效果 | 平台等价；需真机视觉验收 |
| UTF-16 坐标体系 | `text.mz` 原文坐标为唯一真值；DOM 用 quote/anchor 回映 | 源码已接入 |
| 书签/批注/搜索 | 快捷书签、三种批注、全书搜索、原文定位、批注讨论 | 源码已接入 |
| 阅读排版 | 主题、日夜槽、按书覆盖、字体、背景、章首样式、净化、高亮、繁简 | 源码已接入 |
| 英语学习/双语 | 音标、短释义、生词标注、Bionic、单段/当前页/当前章翻译、缓存管理 | 源码已接入 |
| MDX/MDD | v1/v2 读取、索引解密、zlib/LZO、MDD 资源、WKWebView 富释义 | 源码已接入 |
| 系统/云 TTS | AVSpeechSynthesizer + OpenAI/MiniMax/Gemini，逐句/跨章/睡眠定时 | 平台等价 |
| MediaSession/通知控制 | MPRemoteCommandCenter + Now Playing + AVAudioSession | 平台等价；需真机验收 |
| 有声书 | 角色/脚本/状态机/费用估算/AI 缓存生产/混合播放器 | 源码已接入 |
| Voice Design | Gemini Voice Design 创建/试听/草稿删除/用户确认入库 + AI 辅助 | 源码已接入 |
| AI 四协议 | OpenAI Chat / Responses / Claude / Gemini，SSE 流式、reasoning、usage | 源码已接入 |
| 多 Provider / 模型分配 | Provider/Model/Role、能力校验、角色专属 CHAT 覆盖 | 源码已接入 |
| Embedding / Rerank | BM25 + embedding + cosine + 可选 `/rerank`，失败保留原排序 | 源码已接入 |
| 防剧透 | ReadingScope 固定已读边界；工具、检索、大纲/讨论共享范围 | 源码已接入 |
| 书内伴读 | 流式、历史、编辑/删除/分支/reroll/retry/停止残段、附件、Token | 源码已接入 |
| 书库伴读 | 跨书最多 4 本正文、来源记录、历史操作、整理方案预览确认 | 源码已接入 |
| SillyTavern / 世界书 | JSON/PNG V1/V2/V3、头像、世界书、示例对话、工具白名单 | 源码已接入 |
| 用户面具/全局提示词 | 面具隔离长期记忆；四位置预设注入请求副本 | 源码已接入 |
| 长期记忆 | rolling summary、ADD/UPDATE/DELETE 固化、向量/词法召回、跨书开关 | 源码已接入 |
| 章节大纲 | 全章节折叠、未读锁定、单章/批量生成、并发上限 2 | 源码已接入 |
| 全书人物 | 明确确认未读扫描、停止/断点缓存、搜索、证据回跳 | 源码已接入 |
| 随读段评 | 全局/单书额度、队列、断点、去重、角色、语音/图片媒体、提醒 | 源码已接入 |
| AI 创作/笔记 | 改写/续写多版本、普通笔记更新、滚动单份剧情梗概 | 源码已接入 |
| 插图工作室 | 画风/模板/人物形象/三视图/参考图/章节计划/队列/重试 | 源码已接入 |
| 生图后端 | OpenAI Images/edits、Chat 多模态出图、NovelAI Vibe/角色参考 | 源码已接入 |
| 书架管理 | 搜索/筛选/分组/标签/合集/置顶/状态/拖放/批量/文字封面 | 源码已接入 |
| iPad | 书架 SplitView、常驻详情、阅读+伴读并排、详情+有声书分栏、双页 | 平台等价；需 iPad 验收 |
| 回顾 | 卡片/全屏、AI/用户筛选、媒体、角色共创、Markdown/PNG 分享模板 | 源码已接入 |
| 阅读统计 | 总/年/月/周/日、热力、封面月历、时间线、时段、书/作者云、组件排序 | 源码已接入 |
| WebDAV | PROPFIND/MKCOL/PUT/GET/DELETE、完整/轻量、进度、staging 校验恢复 | 源码已接入；BG 调度需真机验收 |
| 存储管理 | 分类占用、按书缓存、孤儿清理、软删除、永久删除、资产引用保护 | 源码已接入 |
| 外部打开 | TXT/EPUB/MDX/MDD UTType；MDD 选择目标 MDX | 源码已接入 |
| 应用语言/外观 | 系统/简中/English、明暗/配色/强调色/导航/密度/App 字体 | 源码已接入；英文覆盖与 Android 一样仍非 100% |
| GitHub IPA | XcodeGen + macOS runner + unsigned `Payload/*.app` + 包内容验证 | 构建链已接入；需 GitHub runner 实编译 |
