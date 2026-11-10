# 0.9.4 文件操作与结果快捷键

## 文件动作

主界面文件结果与文件搜索二级页面的动作菜单新增“打开方式…”和“分享…”。既有默认打开、Quick Look、Finder定位及路径复制保留。

“打开方式”在独立原生窗口列出Launch Services推荐应用并标明默认项；可通过系统选择面板选择其他应用，取消不改变所选项。仅改变本次打开，不修改默认文件关联。NSWorkspace异步执行，成功仅表述“已交给所选应用”；文件/应用失效和启动失败给出反馈。

“分享”使用NSSharingServicePicker原生选择器，不自行发送资料。独立文件操作窗口提供稳定的锚点，避免启动器点击外部隐藏时关闭分享界面。取消、完成及服务失败回调显示对应状态；旧文件的迟到回调不覆盖新目标。

## 快捷键反馈

按住Command时，前十项显示1～9、0单个数字键帽，对应Command+1～Command+9、Command+0。不显示重复的Command键帽，没有包住整组快捷键的外层容器。保留淡入淡出和原属性文字的轻微模糊；松开后恢复正常属性。

## 验证

- 28项核心测试及应用构建通过。
- `scripts/verify-file-actions.sh`通过：使用生成的中文文本文件和临时自建应用，通过真实NSWorkspace指定应用打开；测试应用收到文件路径并写出回执，原文件内容不变。
- 系统返回19个兼容应用；原生分享菜单项成功创建，没有向任何服务、账号或联系人分享文件。
- 文件删除及应用不存在的错误反馈通过。
- 真实系统分享选择、取消、第三方服务完成/失败，以及文件操作窗口和数字键帽的物理操作仍待用户验收，不能把菜单初始化等同于完整分享实测。

## 后续范围

快捷链接、文字片段、补充检索三模块已按用户要求移入 [TODO.md](TODO.md)，后续再做；便笺继续单独延期。

Apple接口：
https://developer.apple.com/documentation/appkit/nsworkspace/open(_:withapplicationat:configuration:completionhandler:)
https://developer.apple.com/documentation/appkit/nssharingservicepicker
