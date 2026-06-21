# 每日 22:00 自动推送计划配置

> 你在 Codex 桌面应用中启用以下自动化，即可每晚 10 点自动收到次日计划。

---

## 自动化名称：RK3588 项目每日计划推送

### 触发条件
- **时间**：每天 22:00（Asia/Shanghai）
- **重复**：每天

### 执行动作
发送以下消息到你：

---

## 每日推送内容模板

### 当日进度回顾
请检查以下事项：
1. GitHub Issues 是否有新的测试反馈需要处理
2. 查看 PROJECT_PLAN.md 中今日目标是否完成
3. 更新 DAILY_PLAN.md 中今日任务的状态

### 明日任务

#### 你的任务
[根据 PROJECT_PLAN.md 当天的内容动态生成]

#### Cursor 应该在做
[根据模块依赖和 PR 状态推断]

---

## 手动检查清单（每天打开 GitHub 必看）

### 早上 9:00
- [ ] 查看 GitHub Notifications
- [ ] 检查是否有新 PR 需要测试
- [ ] 看 Cursor 的 PR 进度

### 晚上 21:30
- [ ] 上板卡跑今天的测试
- [ ] 把测试结果贴到 GitHub Issue/PR
- [ ] 更新 HARDWARE_REFERENCE.md 中的测试记录

### 晚上 22:00
- [ ] 收到自动化推送 → 确认次日计划
- [ ] 如果需要调整计划，在 DAILY_PLAN.md 更新

---

## 快速参考链接

| 用途 | 链接 |
|------|------|
| 仓库首页 | https://github.com/yicechuhai/rk3588-industrial-toolkit |
| Issues | https://github.com/yicechuhai/rk3588-industrial-toolkit/issues |
| Pull Requests | https://github.com/yicechuhai/rk3588-industrial-toolkit/pulls |
| Projects | https://github.com/yicechuhai/rk3588-industrial-toolkit/projects |
| 项目规划 | PROJECT_PLAN.md |
| 每日计划 | DAILY_PLAN.md |
| 硬件档案 | HARDWARE_REFERENCE.md |
| Cursor 启动命令 | CURSOR_START_PROMPT.md |
