# cannon / sagit 内核项目经验记录

## 项目成果（2026-10-01 全部验证）

| 设备 | 内核 | ROM | 状态 |
|---|---|---|---|
| Redmi Note 9 5G (cannon, MT6853) | 4.14.336-perf-cus + KSU v0.9.5 + 容器功能 | LOS 19.1 (release 7) | ✅ 启动/Root/adb-wifi 模块全部正常 |
| Xiaomi Mi 6 (sagit, msm8998) | 4.4.302-perf + KSU v0.9.5 + 容器功能 (run #28) | LOS 19.1 | ✅ 启动/Root/adb-wifi 模块全部正常 |

KSU 模块系统前提：`/data/adb/ksu/bin/ksud`（管理器不会自动装；换 ROM 清 /data 后要手动装，
ksud 从官方管理器 APK 的 lib/arm64-v8a/libksud.so 提取）。模块 zip 必须用管理器安装
（无 TWRP META-INF 安装器）；管理器安装若缺文件，手动 push 补上即可。

## MTK lk_crash 根因（cannon，实机验证）

boot 镜像 tail（ramdisk 之后）里的 **DTB（fdt, d00dfeed）** 是 MTK LK 从 boot 镜像读设备树的
来源。清零它 = LK 在 Linux 启动前崩溃（bootreason=lk_crash）。烟雾弹（全部排除）：
- 内核大小：LOS 19.1 的 stock 内核膨胀后 42.5MB 照样启动，LK 无大小限制
- gzip 编码：三种编码（-6/-1/stored 风格）在 DTB 保留后全部能启动
- 头部 0x240 的 20 字节字段：清零照样启动（testF1）
- LK 的 DTB 位置约定：page_align(ramdisk_end) + 0x40（LOS 19.1: 0x11f7840，LOS 20: 0xce4040）
- cannon LOS 19.1 与 LOS 20 的 boot DTB 逐字节相同（165,696 字节，两个内核代共用）

mtk_boot_repack.py 的最终逻辑：小内核 blob 补零到源 kernel_size（gzip trailer 结束流，
tail 保持原位）；大内核把 DTB 搬到 ramdisk 后 page+0x40。大小闸已移除（基于错误理论）。

## vermagic（模块加载）

- cannon LOS 20 stock: 4.14.336-perf-cus-g61923102fe54；LOS 19.1 stock: 4.14.186-perf-gdb38108cbc23
  （小米内部 CI 构建，源码不公开，精确复刻不可能）
- cannon 的 EXTRA_DEFCONFIG 大部分选项 stock 已有（netfilter/namespaces/memcg/overlay 都是
  重复断言），净增量只有 KSU + 少量（88KB @ -O2；-Os 后省 743KB）
- sagit LOS 19.1: sagit_defconfig 自带 CONFIG_LOCALVERSION="-perf"、LOCALVERSION_AUTO 未启用
  → 构建出 4.4.302-perf 精确匹配 vendor 模块（不依赖构建 commit）
- KernelSU v0.9.5: CONFIG_KPROBES=n 是手动钩子 API 的编译前提（kprobes 开启时手动钩子的
  入口点不编译，vmlinux 链接报未定义符号）

## KernelSU v0.9.5 模块系统机制（KPROBES=n 下能工作）

内核手动 vfs_read 钩子（ksu_handle_vfs_read）拦截 init 读 /system/etc/init/atrace.rc，
把 KSU 的 rc（KERNEL_SU_RC）注入读缓冲 → init 解析后在 post-fs-data/services/
boot-completed 各阶段 exec /data/adb/ksu/bin/ksud → ksud 挂载模块并执行 service.sh。
钩子开关 bool（ksu_vfs_read_hook 等）默认 true。

## 流水线教训（Assen998/KernelSU_Action）

- EXTRA_CMDS 经 make_args 无引号展开：值不能有空格/引号（KCFLAGS="-Os ..." 会把命令行
  打碎）；-Os 走 CONFIG_CC_OPTIMIZE_FOR_SIZE=y（Makefile line 711，KCFLAGS line 1012 之前）
- 触发构建必须显式传 config：workflow_dispatch inputs {"config":"config-xxx.env"}
  （默认 config.env 是 sagit Android 15 配方！）；工作流文件 build-kernel.yml
- GitHub API 查 run 用 run id 不是 run_number；python 轮询脚本要显式 exit 非零否则循环
  第一轮就 break
- 改了本地脚本必须 commit+push——工作流用的是 GitHub 上的状态（run #26 的教训）

## 相关文件

- ksu-push/config-cannon.env — cannon 配置（LOS 19.1 目标，SOURCE_BOOT_IMAGE=boot/cannon-boot-los191.img）
- ksu-push/config-los191-sagit.env — sagit LOS 19.1 配置（4.4.302-perf）
- ksu-push/scripts/mtk_boot_repack.py — MTK repacker（DTB 保留）
- ksu-push/config.env — sagit Android 15 配置（lineage-22.2 分支）
- adb-wifi-boot/ + github.com/Assen998/adb-wifi-boot — ADB over WiFi 开机模块
- boot/cannon-boot.img（LOS 20）与 boot/cannon-boot-los191.img（LOS 19.1）— 重打包源

## Mi 6 (sagit, 4.4.302) 容器崩溃与修复（2026-10-03）

- 现象：Droidspaces 手动启动容器 → 卡死重启。pstore (console-ramoops) 里
  `Kernel panic - not syncing: Fatal exception`，崩溃点 sget_userns+0xcc：
  `ldaxr` 打在损坏指针（0x3e01... 而非 0xffffff...，未对齐）→ alignment fault。
  调用链 unshare(CLONE_NEWIPC) → create_new_namespaces → copy_ipcs → mq_init_ns
  → mqueue_mount → mount_fs → sget_userns。红米 4.14 同路径正常 → 4.4 独有 bug。
- 根因：stock sagit_defconfig 没有 POSIX_MQUEUE/USER_NS/IPC_NS，都是我们 EXTRA
  加的，把 4.4 的 mqueue 命名空间 bug 暴露了出来。
- 陷阱：init/Kconfig `config IPC_NS depends on (SYSVIPC || POSIX_MQUEUE)`。只关
  POSIX_MQUEUE=n 会连带把 IPC_NS 静默丢弃（SYSVIPC 也没开）→「IPC 命名空间不可用」。
- 最终配置：`CONFIG_SYSVIPC=y` + `CONFIG_POSIX_MQUEUE=n`（见 config-los191-sagit.env）。
  SYSVIPC 满足 IPC_NS 依赖（sem/msg/shm 正常），mqueue 走 include/linux/ipc_namespace.h
  的 inline 空桩、崩溃路径不触发。验证：ikconfig 里 CONFIG_IPC_NS=y / CONFIG_SYSVIPC=y /
  # CONFIG_POSIX_MQUEUE is not set。
- LOS 19.1 sagit 开机「内部错误」= vendor SPL (2019-09-01) 比 system SPL (2022-12-05)
  旧 3 年（logcat: `Build: Vendor interface is incompatible, error=1`），ROM 本身的老问题、
  无害，与内核无关，用户选择忽略。
