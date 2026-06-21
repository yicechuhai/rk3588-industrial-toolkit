# 贡献指南

感谢你对 RK3588 Industrial Toolkit 的关注！

## 如何贡献

### 报告问题

提交 Issue 时请包含：

1. **板卡型号**（如 NanoPC T6 8GB）
2. **系统版本**（`lsb_release -a`）
3. **内核版本**（`uname -r`）
4. **NPU 驱动版本**（`cat /sys/class/misc/rknpu/version` 如果有）
5. **运行的命令和完整错误日志**
6. **复现步骤**

### 提交 PR

1. Fork 本仓库
2. 创建特性分支：`git checkout -b feature/xxx`
3. 提交代码：`git commit -m 'feat: 添加 xxx 功能'`
4. 推送到你的仓库：`git push origin feature/xxx`
5. 提交 Pull Request

### Commit 规范

- `feat:` 新功能
- `fix:` 修复 Bug
- `docs:` 文档更新
- `test:` 测试相关
- `refactor:` 代码重构
- `chore:` 构建/工具链变更

### 代码风格

- Shell 脚本：遵循 Google Shell Style Guide
- Python：遵循 PEP 8
- C++：遵循 Google C++ Style Guide

## 验证你的改动

```bash
# 在 RK3588 板卡上运行环境检测
sudo bash deploy_scripts/env_check/check_env.sh

# 运行 Demo 验证
sudo bash deploy_scripts/demo/run_yolov5_demo.sh

# 运行诊断
bash tools/diagnose/diagnose.sh
```

## 文档

中文文档在 `deploy/docs/zh/`，英文文档在 `deploy/docs/en/`。

如果你添加了新功能，请同时更新对应的文档。

## License

所有贡献均以 Apache 2.0 协议授权。
