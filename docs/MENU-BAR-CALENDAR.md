# 菜单栏与日历 0.11.0

2026-11-11。菜单栏公共能力已实现，现有Keylane菜单与日历使用同一注册和更新机制。设置「菜单栏」可管理可见项目，日历模块关闭时撤销条目，重新开启后恢复用户选择。

在启动器搜索「我的日程」进入日历。按日期查看、搜索与选择系统日历，选择日程可查看时间、来源、地点和备注。菜单栏可显示图标、日期或下一条有时间的日程，菜单展示接下来7天最多12条日程，提供刷新、日历设置与系统日历入口。

首次从日历页主动连接时，由macOS请求完整访问权限。本版使用EventKit读取，权限状态决定是否查询。日历变化、唤醒和定期刷新会重新检查结果。日程内容保存在运行时内存。系统入口打开Calendar应用，单条菜单项打开Keylane内对应日期与日程。

- 36项Swift测试通过，覆盖跨日、全天事件、夏令时、进行中事件和中文检索。6项版本工具测试通过。
- 真实AppKit菜单栏测试通过，覆盖重复注册、更新、菜单动作及子菜单、禁用动作、50次开关、偏好恢复、模块关闭与注销。
- 已签名安装版完成系统授权、真实日程读取和菜单栏显示验证。用户截图确认菜单内容。验收记录只核对数量和状态。
- 日历页日期编辑、拒绝/撤销权限、真实日程变化和跨日点击的完整交互仍待人工验收。首版范围为只读日程查看。

接口参考：[Apple EventKit访问说明](https://developer.apple.com/documentation/technotes/tn3152-migrating-to-the-latest-calendar-access-levels)、[日历变化通知](https://developer.apple.com/documentation/EventKit/updating-with-notifications)、[AppKit菜单栏项目](https://developer.apple.com/documentation/appkit/nsstatusitem)。

## 0.11.1 菜单样式调整

根据用户提供的参考截图，菜单栏默认显示下一条日程和倒计时，已有显示偏好继续生效。菜单顶部提供打开系统日历与忽略当前日程，列表按今天和明天分组并显示起止时间与日历颜色。点击日程在Keylane定位。忽略适用于当前运行期间的菜单摘要，可从菜单恢复。底部为日历设置与在Keylane中打开，支持⌘,和⌘O。

最终安装包签名与二进制核对通过，重启后再次确认系统日历读取和菜单栏项目有效。36项Swift测试、6项版本工具测试通过。原生集成测试增加分组标题、图标颜色、图标可见性、快捷键及纯文字状态摘要的验证。新菜单的视觉效果待用户确认。

macOS菜单图标可见性依据[Apple NSMenuItem文档](https://developer.apple.com/documentation/appkit/nsmenuitem/preferredimagevisibility)。
