# NPU 驱动管理

## 功能

自动检测、安装和升级 RK3588 NPU 驱动，解决最常见的部署卡点。

## 使用方法

```bash
# 检测当前 NPU 驱动状态
bash check_npu_driver.sh

# 升级 NPU 驱动（需 root）
sudo bash upgrade_npu_driver.sh
```

## 常见问题

| 症状 | 原因 | 解决 |
|------|------|------|
| `/dev/dri/renderD128` 不存在 | 驱动未加载 | 运行 upgrade_npu_driver.sh |
| RKNN 初始化失败 | 驱动版本不匹配 | 降级/升级驱动使版本与 Runtime 匹配 |
| 模型转换报错 | 算子兼容性 | 检查 rknn-toolkit2 版本与驱动版本对应关系 |

## 版本对应关系

| RKNN Toolkit | 驱动版本 | Ubuntu |
|--------------|---------|--------|
| 2.3.2 | 0.9.8 | 22.04 |
| 2.2.0 | 0.9.6 | 22.04 |
| 2.1.0 | 0.9.2 | 22.04 |

## 许可证

Apache 2.0
