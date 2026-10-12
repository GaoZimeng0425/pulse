# 不启用 App Sandbox

产品的全部前提是对同用户其他进程调用 proc_listallpids / proc_pidinfo / KERN_PROCARGS2 / PROC_PIDVNODEPATHINFO(已在 docs/probe.swift 验证),App Sandbox 会让这些 API 对其他进程失效。本应用定位自用 sideload、本地构建 ad-hoc 签名、不上 App Store,因此保持沙盒关闭。Xcode 任何时刻提示开启沙盒都应拒绝;系统级全量视角(root 进程)将来的方案是 v2 的 root helper(SMAppService + XPC),与沙盒无关。
