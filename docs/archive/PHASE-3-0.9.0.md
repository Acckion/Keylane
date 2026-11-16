# Phase 3 本轮交付：0.9.0 / build 17

工程已迁移至 KeylaneProject/Keylane。源码与临时研究、构建记录分开；构建使用 .build-current，避免搬迁前的绝对缓存路径。便笺继续延期，既有资料不改写。

## 中文文件搜索与设置

用户提供的下载目录 PDF 用“作业”无法在旧安装版找到；系统 mdfind 可命中，安装版当时只返回其他目录的4项，尚不能把原因完全归结为中文分词。新实现增加本地 SQLite 文件索引、可授权的多个搜索范围和权限失败提示。相同控制器在隔离索引目录、关闭正文读取条件下，已实际命中用户指定文件；这不是安装版 TCC 与界面验收的替代。

- 文件名统一 Unicode、大小写及宽度，多个空白分隔关键词按 AND 匹配；LIKE/FTS 值使用参数绑定，通配符输入按字面值处理。
- 默认范围为个人目录、应用目录、iCloud Drive。个人目录中的 Library 不递归遍历，iCloud Drive 作为独立范围；额外位置通过选择面板添加并保存只读书签。
- SQLite WAL 的写入与读取分别在后台队列。列表最多200项；FTS5 trigram处理较长词，两字中文使用字面子串查询。文件未变化时只更新时间戳，不重复提取正文或写全文索引。
- Spotlight 保留为补充来源；开启忽略文件时使用自建索引作为权威，避免被忽略的文件从Spotlight重新混入。
- 可增删忽略规则、读取 .gitignore/.ignore/.rayignore/.git/info/exclude，支持目录继承、!例外、根锚定及简单通配符。跳过符号链接忽略文件；被排除的父目录不再遍历。全局Git配置、所有Git忽略语法细节及Git已跟踪例外尚未逐项兼容。
- 内容搜索默认关闭。开启后提取本机 UTF-8 文字及 PDF，单文件最大2MB，索引文字最多10万字；不下载iCloud占位文件、不跟随文件符号链接。关闭后清除正文列。索引不加密，清除不承诺物理介质取证级擦除。
- 隐藏文件、外部卷、移除卷保留、低空间暂停、重置、模块与命令开关均连接实际逻辑。低空间按下一目录的预计写入大小加128MB余量检查。
- FSEvents监听变更并合并刷新；恢复自动排除后重新扫描。构建依赖目录可自动排除，持续变化的构建/输出目录可按事件阈值排除；“跳过事件”统计实际事件数，不伪称精确节省的重建次数。
- 统计来自实际数据库与数据库/WAL/SHM文件大小，不是Spotlight全局统计。未验证大目录8小时性能目标。
- 二级页面仅保留左上返回按钮，移除重复放大镜。设置布局按用户截图组织中文范围、忽略、开关、命令、AI及统计分组；视觉尚待安装版验收。

## 剪贴板

借鉴v1与Raycast分发产物中的持久化边界，独立实现 SQLite/FTS5、完整SHA256去重、稳定置顶、图片附件、文件引用、来源/敏感标记过滤、保留时间与容量清理。未复制其反编译实现或品牌素材。研究资料保留在工程外。

文字、PNG/GIF/JPEG/TIFF/HEIC/WebP原始图像及文件引用可保存；仅选中时加载完整内容与缩略图，Vision OCR异步补充搜索，删除后迟到结果不重建记录。普通文字不保留富文本，多项混合表示及系统“保留所有格式”尚未完整兼容。文件清理不会删除原件。

持久化采集使用新开关，默认关闭，旧内存采集设置不会自动转为落盘授权。普通复制与自动粘贴分开；粘贴检查辅助功能、先前目标应用存活和最终焦点。通用剪贴板许可、跨应用粘贴与重启安装版仍待用户验收。

## 文件AI入口

“询问文件搜索”和“询问Finder”支持独立启用、别名、快捷键；从文件动作菜单可询问单个文件。独立窗口提供接口地址、模型、钥匙串密钥、上下文勾选、问答、取消、错误及用量反馈。

默认仅发送文件名；用户主动勾选后可附加路径、正文，最多20项/正文总量4万字。服务必须为HTTPS，本机接口可用HTTP；跨源重定向禁止转发。只有主动发送才请求接口，密钥按接口区分，不进入UserDefaults或源码。Finder选中项通过原生AppleEvents按使用时请求授权。

当前为OpenAI兼容Chat Completions的文件上下文问答，不等同于Phase 6完整代理、工具执行、语义索引或Raycast自有云服务。真实服务商账号、费用、钥匙串权限及Finder授权尚未实测；没有拿本地模拟响应冒充真实服务验收。

## 已通过的验证

- 26项核心测试：中文/Unicode/多关键词/字面符号、忽略/例外/锚定、外部标记、持久化、关闭搜索、剪贴板附件/删除竞态/保留上限/新版数据库保护等。
- `scripts/verify-files.sh`：真实生成的中文文件与PDF、正文开关、隐藏文件、忽略开关、FSEvents实际刷新、真实统计、移走目录保留/删除；低空间分支注入可用容量为0验证。
- `scripts/verify-clipboard.sh`：独立命名剪贴板，默认关闭、文字去重/置顶、敏感与回放排除、PNG原样复制、真实Vision OCR及搜索、文件引用复制、原件保留、重开资料库及清理。
- `scripts/verify-file-ai.sh`：本地URLProtocol模拟成功、用量、401、无效返回、取消/迟到响应、HTTPS校验。未联网、未使用真实密钥。
- 指定下载PDF元数据实测：`TARGET_FOUND=true CONTENT_READ=false`；不读取PDF正文、不记录其他下载文件名。

外接磁盘/网络共享硬件、真实AI账号、主剪贴板跨应用粘贴、界面像素及最终目录权限仍未验收。不得将本轮标记为Phase 3全部完成。

## 参考文档

- Apple NSPasteboard: https://developer.apple.com/documentation/appkit/nspasteboard
- Apple Vision文字识别: https://developer.apple.com/documentation/vision/vnrecognizetextrequest
- Apple FSEvents: https://developer.apple.com/documentation/coreservices/1443980-fseventstreamcreate
- Apple卷资源属性: https://developer.apple.com/documentation/foundation/urlresourcevalues
- OpenAI兼容请求结构参考: https://developers.openai.com/api/reference/resources/chat
