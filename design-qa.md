# Token 花费展示 Design QA

## 对比对象

- 设计参考：`/Users/alight/.codex/generated_images/01a043cf-9a0e-7db2-9fa9-f6a220446171/exec-c895d12c-f0f3-4ce5-821f-3edf99ccedc9.png`（1436 × 1095）
- 最终紧凑状态：`/Users/alight/Documents/刘海屏软件/qa/token-cost-compact-final.jpeg`（364 × 474）
- 最终弹层状态：`/Users/alight/Documents/刘海屏软件/qa/token-cost-popover-final.png`（860 × 1000）
- 同屏对比：`/Users/alight/Documents/刘海屏软件/qa/token-cost-comparison.png`（1720 × 1000）

## 验证状态

- 原生 macOS 深色界面，展开 Codex 页签。
- 使用静态 QA 数据，覆盖任务 Token、今日 / 7 天 / 30 天周期 Token、费用估算和固定弹层。
- 周期 Token 卡固定为 50pt 高度；整卡仍是可点击、可悬停区域。
- 弹层展示输入（未缓存）、缓存输入、输出（含推理）、API 等价估算和订阅扣费提示。

## 迭代记录

1. P2：周期卡仅设置最小高度，内部按钮允许垂直无限拉伸，三张卡会吞掉面板剩余高度。改为固定 50pt，并同步收紧面板周期区预算。
2. P2：弹层被外部关闭后，鼠标仍停在触发区会立即重新打开。增加“离开后再恢复悬停”抑制状态。
3. P1：原生半透明弹层在浅色桌面背景上出现白字低对比。增加不透明深色内容底，恢复可读性并贴近参考稿。
4. 最终同屏复核：未发现 P0、P1 或 P2 视觉问题；窄屏下标题、金额和周期卡无溢出，弹层信息层级清晰。

## 结果

passed
