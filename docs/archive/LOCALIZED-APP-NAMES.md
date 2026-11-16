# 应用名称本地化修复 — 0.5.3

用户澄清：中文支持缺少的是系统语言下的应用名称，例如 System Settings 应显示并支持搜索“系统设置”。其他语言同理。此问题与输入法候选词是否可提交分别验证。

## 实现

- 新增 ApplicationIdentity，在应用发现阶段读取目标 Bundle 的本地化显示名称，缓存后用于结果和动作菜单。
- 使用 CFBundleCopyLocalizedStringForLocalizations 与 Locale.preferredLanguages 显式选择目标应用提供的语言，不依赖启动器自身当前支持的语言。
- 支持系统 .loctable 与常规 Bundle 本地化资源，无硬编码应用名翻译表。
- 未提供本地化名称时使用系统显示名/文件名回退，不编造翻译。
- 文件原名、Bundle 原名、英文名与 CFBundleAlternateNames 保留为搜索别名；英文查询命中后显示本地化名称，不产生重复应用条目。
- 显示保留原始排版，搜索统一空白并去除软连字符等不可见排版字符，支持普通键盘输入。

## 验证

7 项 XCTest 通过。新增测试使用本机真实 System Settings Bundle：

- zh-Hans-CN：系统设置。
- fr：Réglages Système（系统原文使用不换行空格）。
- de：Systemeinstellungen（系统原文含软连字符）。
- 三种语言均可用对应名称及英文 System Settings 搜索。
- 中文名称可通过完整拼音 xitongshezhi 搜索。
- 无本地化的测试应用保留原名。

0.5.3 已安装并通过临时签名校验，CUA 实机验证：

- 中文文本“系统设置” → “系统设置”条目（通过粘贴输入，不等于真实候选词组合测试）。
- Command+A 后输入 System Settings → 同一“系统设置”条目。
- 再次 Command+A 后输入 Terminal → “终端”条目。
- 再次替换为 xitongshezhi → “系统设置”条目。
- 输入完整保留，查询替换和结果刷新正确，没有残留 AppCleaner。

法文、德文是元数据与搜索测试，未改变用户系统语言；其他语言使用相同系统接口，尚未逐种实测。应用自身所有界面的多语言翻译仍属于后续本地化工作。

参考 Apple 官方接口：
https://developer.apple.com/documentation/corefoundation/cfbundlecopylocalizedstringforlocalizations(_:_:_:_:_:)
