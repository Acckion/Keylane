# 0.6.3 界面修订与验收状态

## 本轮交付

- 应用设置详情使用中文；搜索范围、别名、快捷键和启用开关连接真实配置。自动退出、卸载保留未实现状态。
- 信息按钮与模块开关移入 NSWindow 原生右侧标题栏附属视图；安装版同步截图确认位于最右端。避免 SwiftUI primaryAction 在macOS靠左的语义差异。
- 快捷键行为菜单只显示系统提供的单个下拉箭头；添加和禁用导航入口使用标准玻璃控件。
- 设置侧栏使用浮动玻璃胶囊与 NSSearchField 原生输入/搜索/清除。列表前增加初始52点留白，避免静止时第一项被搜索框盖住；留白随列表滚走后，内容可经过搜索框后方。
- 主窗口上下渐变模糊：用户明确验收通过；保持现有实现。
- 菜单从固定底角原位扩张，用户评价动画良好；按要求由0.28秒缩短至0.20秒。
- 左右底部控件外框36点高；右侧为共享玻璃胶囊。上方返回使用相同左边距及中心线。
- 悬停沿用原生NSButton的accessoryBarAction及仅鼠标移入显示边框属性。此前去掉内层裁切导致圆角矩形被用户否定：已恢复28点内胶囊和4点边距，并将原生控件从large改为regular以容纳完整高亮。最新形状仍待用户最终实机确认。
- 键帽统一20×20点、5点圆角；14种控制键SF Symbols在本机存在。用户要求缩小后，符号字号由11改为10，普通字母数字仍为11。

## 验证

- 13项核心测试通过（work/ui-063-tests.log）；release构建和包签名校验通过。
- 已通过安装版AX和同步截图核对：中文详情、唯一菜单箭头、标准添加按钮、悬浮搜索、右侧标题栏控件、已有快捷键配置保留。
- 最新安全留白、缩小符号和恢复后的悬停区域需继续实机反馈；不把编译当作视觉验收。
- Hyperkey、双击修饰键、登录启动等未实测项继续保留，详见PHASE-2.md。

## 素材参考

research/raycast-assets、research/supercmd-v2-assets、research/supercmd-v1-assets分别保存静态资源、版本、哈希和预览，未进入Keylane源码资源或安装包。资源提取不等同于运行时效果还原。

## Apple接口

- https://developer.apple.com/documentation/appkit/nsbutton/bezelstyle-swift.enum/accessorybaraction
- https://developer.apple.com/documentation/appkit/nsbutton/showsborderonlywhilemouseinside
- https://developer.apple.com/documentation/appkit/nstitlebaraccessoryviewcontroller
- https://developer.apple.com/documentation/appkit/nssearchfield
- https://developer.apple.com/documentation/appkit/nsglasseffectview

## 最后安装版检查

同步AX与截图确认：右上角信息按钮和开关已在窗口最右端；浮动搜索框下方有初始留白，通用与应用程序等入口没有被覆盖。设置搜索输入的进一步自动交互被“用户正在操作应用”保护中断，未继续抢占输入，也未把这次搜索行为标为通过。悬停恢复及缩小符号保留用户后续视觉验收。
