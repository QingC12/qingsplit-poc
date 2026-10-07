# QingSplitPOC — First Floating Window POC

**唯一问题**：QingSplit 能不能把一个真实 App Scene 作为第一个浮动窗口稳定显示在自己的 UIWindow 中，同时 SpringBoard 不崩溃？

**版本**：v0.1.0（第一版最小闭环）

## 最小闭环

```
目标 App FBScene
  → FBSceneLayer / CA Context
  → QingSplit 自有 UIWindow (LEVEL=999.0)
  → 浮动显示目标 App
  → _setActivePrioritizedPresenter:（最小写，失败不阻断）
  → 控制前后顺序
```

## 第一版明确不包含

拖动 / 缩放 / 多窗口 / 手势系统 / 设置界面 / Keyboard Settings / License / Activation / Stheno 授权机制 / SBAppLayout

## 安全设计

- 注入 SpringBoard（ellekit，Filter=com.apple.springboard）
- 延迟 5s 启动，等待 SB 稳定
- **崩溃闸门**：`/var/mobile/qsp_poc_state` 连续启动计数，上次无 POC_OK 且 ≥3 次 → SAFE_MODE（本启动不做任何写操作，只打日志）
- 渲染路径阶梯（全部 @try，失败顺延）：
  1. `_UIContextLayerHostView initWithSceneLayer:`
  2. `_UISceneLayerHostContainerView` + KVC `_scene`
  3. `CALayer _setContentsContextID:`（纯 CA context attach）
- 所有动作独立 @try/@catch + DBG 检查点
- 日志：`/var/mobile/QingSplitPOC.log`
- **回滚**：`dpkg -r com.qingsplit.poc` 即完全卸载

## 目标 App 选择

- `/tmp/qsp_target` 文件内容 = bundle id 前缀（如 `com.tigisoftware.Filza`），最优先
- 未指定 → 自动选第一个非 `com.apple.*` 的 app scene（排除 Stheno/QingSplit 自身）
- 注入后每 3s 重试枚举，最多 60s（等待用户打开目标 App）

## 真机测试步骤（Phase 0 验收）

```sh
# 1. 安装（root）
sudo -i
dpkg -i /tmp/QSPPOC.deb

# 2. 清日志 + 指定目标（可选，默认自动选第一个非系统 app）
cd /var/mobile && rm -f QingSplitPOC.log qsp_poc_state
echo com.tigisoftware.Filza > /tmp/qsp_target

# 3. 重启 SpringBoard
killall SpringBoard

# 4. 等待注入启动（约 10s），打开目标 App（如 Filza）

# 5. 检查结果
sleep 30
cat /var/mobile/QingSplitPOC.log
```

**PASS 标准**：
- 日志出现 `POC_OK sid=... path=N`（N=1/2/3 为实际渲染路径）
- 屏幕出现目标 App 的浮动画面（实时内容）
- SpringBoard 30s 无崩溃

**FAIL 判断**：
- `RENDER_FAIL` → 三条路径均失败，记录 ctx，回报
- `SAFE_MODE` → 连续崩溃，先 `dpkg -r com.qingsplit.poc` 回滚，回报
- 无日志 → 注入未生效，检查 deb 安装与 ellekit

## 日志关键行速查

| 行 | 含义 |
|----|------|
| `SAFE_MODE boot=N` | 崩溃闸门触发，本启动不动作 |
| `TARGET sid=... pid=... layer=... ctx=...` | 目标 scene 与 layer contextID |
| `RENDER_PATH=N ctx=...` | 实际渲染路径 1/2/3 |
| `WINDOW_OK class=... level=... host=...` | 浮窗窗口建立 |
| `ZORDER_RAISE_OK/SKIP/NONE` | Z-order 写操作结果（不影响画面判定） |
| `POC_OK sid=...` | 浮窗建立成功（闸门复位） |
| `TIMEOUT ...` | 60s 内无目标 scene，闲置 |
