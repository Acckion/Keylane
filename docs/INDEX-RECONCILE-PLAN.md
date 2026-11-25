# 真实后台高能耗追踪与局部对账执行计划（2026-11-25）

FILE-01 / BASE-11，追加 PR #247。用户的新 12 小时窗口已排除旧安装版重叠，不能用历史指标滞后解释。本轮先保留运行现场，不重启、清库或修改功能设置；本地修改始终在独立工作树。

## 安装版现场

二进制 91151e2f6ffe2660ffd3c228b3417de6e0b67e12bbd7d3621b353dd8bb7ad575，对应 #247 的 2f05ab8，PID 20180；现场已运行约 14.5 小时，系统累计 CPU 约 69 分钟。schema=3，统计 383434 条。58 项正文待办均为事件等待（55 permission、3 changed），没有到期可执行正文任务，因此不能把此刻高负载归因于正文定时重试。

59.30 秒完全后台样本，读取增加 185.26 MB、写入增加 6.82 MB，正确换算平均 CPU 约 11.22%。系统 ps 瞬时曾为 98.2%，截图约 60%；短区间均值和瞬时值不同，不互相取代。另一校正后 29.17 秒样本 CPU 约 9.39%。

聚合扫描日志返回的实际覆盖区间约 96 秒，含 24 个成功增量扫描，扫描墙钟合计约 22.91 秒。虽然请求的是最近 20 分钟，不能把返回不足的覆盖当作完整 20 分钟或整个夜间。睡眠日志存在多次实际 DarkWake（排除 Wake Requests），但没有证据证明 Keylane 主动唤醒设备；只能确认它在后台可运行的窗口仍做大量工作。

## 已确认的执行计划退化

调用栈反复落在 FileSearchIndex.removeUnseen(root:subtree:epoch:) 的 SQLite B-tree 遍历。对真实库仅执行 EXPLAIN QUERY PLAN（没有执行 DELETE）：原 SQL 外层 root 条件导致选择 files_name_search(root=?) 的整根索引遍历，即使目标是一个不存在的子树。

此前“先按路径构造 rowid 候选就不会遍历整根”的假设不成立，测试只验证结果与小数据耗时，遗漏了实际优化器计划。独立扫描标记没有修复这个退化，不能把先前 WAL 的改善当作整机节能验收。

修复把归属/标记条件移入 rowid 候选选择，外层只按 rowid 删除；内层 NOT INDEXED 仍允许 INTEGER PRIMARY KEY 查询，防止 root 次级索引再次优先。真实库的只读 EXPLAIN 已核对两层均为 rowid 定位。保护不可读路径的分批查询也避免 root 索引排序/重复全根遍历，沿 rowid 游标推进。根归属、路径边界、代次和不可读保留规则不变，无 schema 升级。

新增每条局部对账的 SQLite VM 步数累计诊断，扫描日志增加本轮处理条目数、递归目标数；只记数字，不记私有路径或正文。回归在无关根条目 100→10000 时验证不存在子树的 VM 步数不增长，并检查执行计划及小子树删除。479 项 Core 已通过，真实文件事件与重启/权限恢复集成通过。

## 必须更正的 CPU 采样错误

此前临时 proc_pid_rusage 采样器把 ri_user_time/ri_system_time 的 Mach tick 错标为纳秒。本机 mach_timebase_info 为 125/3，导致这条采样链的 CPU 百分比低估约 41.67 倍。此前来自该脚本的“后台 CPU 很低”结论作废；例如 2026-11-24 的约 0.062% 实际约 2.6%，早期后台约 2.06% 的原始样本重算为约 85.735%，2026-11-24 的另一原始样本重算为约 2.573%，不可继续引用旧值。

磁盘字节、footprint、WAL 字节没有用该 CPU 换算，不受此错误影响。现有使用 clock()/CLOCKS_PER_SEC 或 getrusage timeval 的基准已经是正确的时间单位，也不应再乘 125/3。

新增 scripts/sample-process-resources.swift 统一换算，--self-check 用本进程短时负载对比 getrusage 独立接口；本机 0.199900 秒对 0.199886 秒通过。CI 加入该自检，不能只验证字段名字或公式。Apple 原始实现参考：https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/osfmk/kern/bsd_kern.c 的 fill_task_rusage 与 fill_task_io_rusage，以及 bsd/kern/kern_resource.c 的时间换算。

## 验收边界

本轮局部查询计划修复不改变模块开关、权限、用户数据库结构或设置，未触碰真实库数据。真实安装版后续对照、持续后台 I/O、12 小时能耗与平均内存小于 100 MB 均仍待验证，不能仅凭合成数据结果宣称已解决。


最终五轮交替 Release 对照：相同 30000 条索引、30 个不存在子树，CPU 中位数 0.027548→0.000804 秒（约 -97.08%），墙钟 0.027535→0.000796 秒；无关 30000 条记录全部保留。代码见 Tests/Integration/file-reconcile-benchmark.swift，CPU 用正确的 getrusage timeval，不使用 Mach tick 原始值。该局部 CPU 改善不等于整机能耗或 12 小时指标改善。
