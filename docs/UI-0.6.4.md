# 0.6.4 提交前界面修订

- 页面导航指示改为单独的行尾 SF chevron.forward，不再画成圆形玻璃按钮。自动退出未实现，保持说明状态，不产生可执行的假入口。
- 应用快捷键行为由 Menu 包裹 Picker 改为独立的系统菜单式 Picker，采用 borderless 标准样式。安装版AX确认为原生pop up button，截图确认上下双箭头，无重复箭头。
- 键帽去除灰色填充，保留透明底、20点正方形、5点圆角、细描边及10点控制键SF符号。
- 修复高亮裁切的尺寸依据：本机NSButton regular accessoryBarAction在108×28点控件中，cellSize高24点，drawingRect为(12,2,84,24)。旧SwiftUI胶囊按28点高度裁切，与原生24点高亮相交导致弧线出现上下水平截面。
- 改由原生按钮layout依据cellSize居中计算24点绘制区域，并以该区域高度生成胶囊mask；移除外部28点SwiftUI胶囊裁切。颜色、悬停与按压继续由AppKit绘制。左侧圆按钮不受该宽按钮mask影响。
- release构建、签名校验及安装通过；安装版菜单进入/退出、键帽透明底、标准选择器和行尾箭头已查看。CUA未能可靠重现物理鼠标移入新建按钮后的高亮，因此最终悬停弧线仍保留用户视觉复验，不以静态尺寸检查替代该实测。

Apple接口参考：
- https://developer.apple.com/documentation/appkit/nscell/cellsize
- https://developer.apple.com/documentation/appkit/nscell/drawingrect(forbounds:)
- https://developer.apple.com/documentation/appkit/nsbutton/showsborderonlywhilemouseinside
- https://developer.apple.com/documentation/swiftui/picker
- https://developer.apple.com/documentation/appkit/nspopupbutton
