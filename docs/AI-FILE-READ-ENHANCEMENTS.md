# AI-13-b：Office、显式扫描 PDF OCR 与 Grep 正则

基线 dev `37dac2e`，独立分支 `feat/ai-file-read-enhancements`。本批补齐读取能力；不增加写入权限，也不改变 #215 的不覆盖创建、#224 的每页确认或 #217 的请求域搜索引用。未安装、未调用真实提供商，未读取用户资料。

## 公共读取架构

- `AIFileOfficeText` 只接收已核实句柄读取的 Data，供基础文件工具、显式附件和 `keylane_read_searched_file` 共用。原入口的文件/文字额度、来源版本与授权检查保留。工具正文按 4096 UTF-8 字节分页，续读使用原来的私有结果缓存，不重新解析 Office。
- DOCX 提取正文段落及表格单元格文本；XLSX 按工作簿顺序输出工作表、单元格地址、共享/内联字符串和已有缓存值；PPTX 按演示顺序提取幻灯片段落。隐藏工作表/行中的文本也会提取。数字与日期使用底层值，不重现 Excel 显示格式。
- 不执行公式/宏，不读取外部链接，不启动 Office 或导入进程，不向磁盘解压文件。不提取批注、备注、页眉页脚、图表、嵌入对象或图片文本，不保证还原视觉布局。旧 `.doc/.xls/.ppt` 不支持。
- OOXML 是有界格式子集：仅 UTF-8 XML、stored/deflate ZIP；拒绝加密、ZIP64、重复/穿越名称、重叠数据、损坏 CRC、DTD/实体和外部工作表/幻灯片关系。仅校验所需部件，并非完整 Office 格式验证器。

## 显式本机 OCR

`keylane_read_file` 新增可选 `ocr: true`，默认 false。仅在授权目录内读取 PDF 时使用，对没有文字的页调用公共本机 Vision OCR；有文字页保留原提取结果。附件和搜索引用读取仍不自动 OCR，也没有新增 OCR 开关 UI。

`LocalImageTextRecognition` 与原截图/剪贴板 OCR 共用一个引擎；原应用接口以别名保留，取消和语言选择一致。识别输出仍会按原文件工具的接收方确认发送给所选模型；“本机 OCR”只表示识别阶段不使用云端 OCR。

| 限制 | 上限 |
| --- | --- |
| PDF | 8 MiB、100 页、2 MiB 提取文字 |
| 扫描 PDF | 最多 10 个无文字页；总识别预算 15 秒，每页最多 5 秒 |
| 栅格化 | 每页最长边 2000 像素、最多 400 万像素 |
| Office | 8 MiB 原文件、2 MiB 提取文字、最多 100 个工作表/幻灯片 |
| ZIP/XML | 最多 2048 项、32 MiB 声明总解压量；单个解析 XML 4 MiB、累计处理 XML 32 MiB；150000 XML 节点、128 层深度、10 秒解析预算 |

取消会中断活动 Vision 请求；读取期间撤权/来源变化则不能披露结果。识别完成后续读缓存，不再次 OCR。本机合成验证中，首次 Vision 初始化曾耗时约 38 秒，随后因超时拒绝；初始化后的同一合成扫描件可正常识别。自动化将原生引擎初始化与受限读取分开验证，不保证首次冷启动能在额度内成功。时间限制通过原生进度回调和阶段检查协作执行，并非进程级硬隔离。PDFKit/Vision 原生解析、绘制的最坏内存与耗时仍依赖系统实现；超额扫描文档需先拆分。

## Grep

增加可选 `regex`、`case_sensitive`，均默认 false，原字面匹配和忽略大小写行为保留。正则使用行级 ICU 语法，不跨行；CRLF 行号与原分页一致。表达式最多 512 UTF-8 字节，整个搜索操作共用一秒正则预算。进度回调检查取消、期限及引擎错误；失败时不发布已经收集的半页，不自动切回字面匹配。此预算也是协作式限制。

## 验证

合成 DOCX/XLSX/PPTX、内存生成扫描 PDF、异常 ZIP/XML、正则回溯、取消和原文件版本变化由 `AIFileReadEnhancementTests` 覆盖。`verify-ai-file-tools.sh` 的合成运行层用例增加 Office 首读/续读独立确认、拒绝后重试及正则参数/错误传播。本机验证结果：

- 全量 414 项核心测试及 3 项提供方配置测试通过；最终 ZIP 头一致性、名称空间前缀与栅格角度修正后，11 项读取增强测试及完整应用构建再次通过。
- 9 组基础文件工具隔离集成通过，包含 Office 续读独立确认与正则入口。
- 使用 Apple Development 签名的隔离引用测试通过，新增 Office 附件版本/文字额度验证；原临时引用、撤权、接收方和授权检查保留。只使用独立测试剪贴板和合成目录，未启动原应用主入口或安装应用。
- 27 项 ReleaseTests、版本检查与差异空白检查通过。

准确提交与远端 Checks 在 PR 中记录；自动化结果不代表真实服务或安装版验收。

实现依据：[Microsoft OOXML 概览](https://learn.microsoft.com/en-us/office/open-xml/about-the-open-xml-sdk)、[Word 结构](https://learn.microsoft.com/en-us/office/open-xml/word/structure-of-a-wordprocessingml-document)、[工作簿结构](https://learn.microsoft.com/en-us/office/open-xml/spreadsheet/structure-of-a-spreadsheetml-document)、[Apple Vision 文字识别](https://developer.apple.com/documentation/vision/recognizing-text-in-images)、[正则进度回调](https://developer.apple.com/documentation/foundation/nsregularexpression/matchingoptions/reportprogress)。
