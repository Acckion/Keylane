# Python 缓存目录改用默认匹配规则

`__pycache__` 加入 `FileSearchOptions.defaultIgnores`，通过普通忽略规则跳过任意层级的同名目录，不再由 `FileIndexExclusionPolicy` 识别为自动排除目录。设置中可直接查看或移除此规则。

已有设置首次加载时补入规则，保留其他自定义模式，并从持久化自动排除列表移除 basename 为 `__pycache__` 的历史条目。迁移只补入一次；用户之后移除规则，重启也不会重新添加。此修改不删除磁盘目录或文件。

验证范围：

- `FileIndexExclusionPolicyTests`：默认匹配、目录内事件忽略、移除规则后重新允许事件、普通名称不误匹配；4 项通过。
- `FileIndexTests`：索引、通配规则和继承忽略规则等 6 项通过。
- 应用随 Swift 测试完整编译通过；版本检查及发布 Python 测试 27 项通过。
- `Tests/Integration/files-main.swift` 新增隔离偏好设置迁移与临时目录索引检查。当前基线的 `scripts/verify-files.sh` 缺少 AI 文件工具来源依赖，直接运行无法编译；本轮使用同样的编译步骤额外传入 `AIToolRuntime.swift`、`AIChatProject.swift` 和 `AIFileToolProvider.swift` 进行验证，不修改脚本。专项及完整文件控制器回归均通过，覆盖迁移、规则删除后索引、正文搜索、暂停恢复、文件事件、离线目录保留与移除等场景。可设置 `KEYLANE_VERIFY_PYCACHE_ONLY=1` 只运行缓存专项。

本轮未安装到 /Applications，未操作用户的索引或搜索设置。
