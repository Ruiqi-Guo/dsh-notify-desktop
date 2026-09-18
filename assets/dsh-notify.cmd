@echo off
rem dsh-notify.cmd —— 给 DSH 钩子/插件用的分离启动器
rem
rem 为什么需要它：卡片脚本会阻塞到卡片关闭，而钩子是同步执行的 ——
rem 直接调用会把 agent 的收尾卡住十几秒甚至更久。用 start 分离后立即返回。
rem
rem 用法： dsh-notify.cmd -Title "会话完成" -Session "api-service" -Tag tb
start "" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-notify.ps1" %*
exit /b 0
