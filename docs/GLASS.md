# 原生 Liquid Glass

0.4 使用当前 Xcode macOS 27.2 SDK 构建，最低 macOS 26。

- 主面板：NSGlassEffectView，contentView 承载 NSHostingView；regular 风格与 28pt 圆角。
- macOS 27：通过可用性检查明确关闭 effectIsInteractive（按用户要求，主面板不产生整窗按压回弹）。macOS 26 使用原生 regular 玻璃。
- 左下角：Button.buttonStyle(.glass)，圆形标准按钮。
- 右下角：ControlGroup 与标准 .glass 按钮样式。
- 两个展开菜单：原生 SwiftUI glassEffect 材质，面板内分别锚定左下与右下，动作筛选和键盘上下选择。
- 设置：独立 NSWindow 与 NavigationSplitView，系统侧栏、窗口控制和按钮。
- 内容卡片仍用低对比背景，避免每层内容叠加玻璃影响可读性。

来源：
https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
https://developer.apple.com/videos/play/wwdc2026/289/
本机 NSGlassEffectView.h（27.2 SDK），effectIsInteractive 标注 API_AVAILABLE(macos(27.0))。

验证状态：编译通过；原有解析器/搜索/存储 3 项测试通过。玻璃实际外观、辅助功能和多显示器仍需实机验证，测试通过不等于视觉验收。

0.4.1：启动器失去键盘焦点、点击其他应用或本应用其他窗口时自动隐藏；独立设置窗口不应用此规则。按钮仍保留标准交互。
