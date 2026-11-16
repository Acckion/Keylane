# 0.6.1 界面修订

## 范围

1. 应用设置详情按用户截图重排：居中图标和标题，Search Scopes 卡片，单行 Commands 和 Applications，别名、录制、启用复选框列对齐。侧栏使用现有中文入口，详情标签按参考图。
2. 模块开关实际控制应用搜索及应用快捷键；关闭保留配置。应用快捷键支持激活或切换可见性，默认仍保留旧版激活行为。自动退出、卸载明确标为未实现。
3. 顶部使用系统设置工具栏的导航控件，后退/前进对应实际访问历史；信息按钮展示当前模块说明。文件夹和应用保持本机真实配置，没有为凑截图填入未配置路径。
4. 主窗口 AppKit 玻璃底层和完整 SwiftUI 内容一起裁圆角，刷新窗口阴影。保留 macOS 27 非交互主玻璃，避免整窗按压回弹。
5. 上下渐变模糊已获用户验收。右侧一体胶囊、同高控件、底角固定尺寸扩张为后续修订。

## 验证边界

- 13 项自动测试通过，release 编译和临时签名校验通过。自动测试覆盖核心逻辑，不替代视觉、按钮按压和动画验收。
- 安装版截图已检查渐变滚动内容与圆角；用户确认模糊效果通过。
- 新设置页与最终菜单修订需在安装版继续检查。Hyperkey、双击、登录启动等仍按 PHASE-2.md 中的实测状态处理。

## Apple 接口参考

- https://developer.apple.com/documentation/appkit/nsglasseffectview
- https://developer.apple.com/documentation/appkit/nsvisualeffectview/blendingmode-swift.property
- https://developer.apple.com/documentation/swiftui/glassbuttonstyle
- https://developer.apple.com/documentation/swiftui/view/glasseffecttransition(_:)

主窗口使用非交互 NSGlassEffectView；上下覆盖层使用窗口内 NSVisualEffectView。菜单尺寸扩张固定底角，禁用玻璃自动匹配位移动画，避免从上方滑入。
