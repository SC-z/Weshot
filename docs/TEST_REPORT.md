# WeShot 1.2.6 测试报告

- 平台：macOS 15.2+，Apple Silicon
- 工具链：Swift 6.1，Xcode Command Line Tools
- 产物：`WeShot.app` 1.2.6（build 12）

## 自动化结果

| 门禁 | 结果 | 覆盖范围 |
|---|---:|---|
| Swift Testing | 40/40 PASS | 选区、窗口吸附、移动/缩放、快捷键、工具栏、标注、取色、翻译图层、文件输出、钉图、隐私规则和长图拼接 |
| 严格 Release 构建 | PASS | `-warn-concurrency -warnings-as-errors` |
| Bundle 与签名 | PASS | arm64、AppIcon.icns、Info.plist、ad-hoc 签名、严格校验 |
| 进程自测 | PASS | 几何、工具栏、标注、合成和 PNG 编码 |
| 离屏渲染 | PASS | 固定图片和编辑器布局均可生成有效 PNG |

## 系统测试范围

`scripts/test_system.sh` 在已授权且未锁屏的图形会话中覆盖：

- ScreenCaptureKit 真实桌面捕获
- 自定义选区、剪贴板跨进程读取、原子保存和钉图
- 框选区域滚动采样、实时拼接和结束流程
- 可见 Overlay、保存面板取消/确认和窗口恢复
- Carbon 快捷键事件与 HID 全局快捷键
- 系统翻译英文到中文、中文到英文
- 进程退出和残留检查

屏幕录制权限由 macOS 按 Bundle 身份管理。换机、重新签名或移动应用后，应重新授权再运行系统测试。

## 已验证产品约束

- 启动截图后默认自由框选，不自动选择全屏。
- 长截图只采集选区，单帧也可完成。
- 翻译结果直接进入原图半透明图层，不打开结果窗口。
- 工具栏不包含独立文字识别、系统分享或演示入口。
- 真实桌面内容和测试生成物不进入源码仓库。
