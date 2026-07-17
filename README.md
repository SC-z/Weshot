# WeShot

WeShot 是一个独立、原生、开源的 macOS 截图应用。它使用 Swift 与 AppKit 构建，截图、文字提取、隐私检测和图片合成都在本机完成。

## 功能

- 默认全局快捷键 `⌃⌘A`，支持在菜单栏自定义并持久化
- 全屏暗化、窗口悬停吸附、自定义框选、移动与八向缩放
- 像素放大镜、RGB/HEX 取色，按 `C` 复制色值
- 矩形、椭圆、箭头、画笔、文字、表情和马赛克标注
- 框选区域长截图，滚动时实时生成预览
- 本地文字提取与系统翻译，译文直接覆盖在原图的半透明图层中
- 人脸、姓名、手机号和邮箱隐私打码
- PNG 保存、剪贴板复制和置顶钉图

独立文字识别窗口、系统分享按钮和演示模式不属于当前产品范围。

## 隐私

- 屏幕图像仅在本机内存中处理，除非用户主动保存
- 文字提取和隐私检测使用 macOS Vision
- 翻译使用 macOS Translation；首次使用某个语言组合时，系统可能下载语言包
- 应用不接入第三方截图、识别或翻译服务

## 环境要求

- macOS 15.2 或更高版本
- Apple Silicon
- Swift 6.1 或兼容的 Xcode Command Line Tools

首次截图需要在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许 WeShot，并重新启动应用。

## 构建

```zsh
git clone https://github.com/SC-z/qsnap.git
cd qsnap
./scripts/build_app.sh
open build/WeShot.app
```

构建结果位于 `build/WeShot.app`。

## 使用

1. 按 `⌃⌘A`，或点击菜单栏图标后选择“截取屏幕”。
2. 拖动鼠标建立选区，也可以吸附普通窗口。
3. 使用浮动工具栏标注、翻译、滚动截图、保存或钉图。
4. 按 `Return` 完成并复制，按 `Esc` 取消。

## 测试

```zsh
./scripts/test_all.sh
./scripts/test_system.sh
```

- `test_all.sh`：运行 Swift 测试、严格 Release 构建、Bundle 签名、自测和离屏渲染。
- `test_system.sh`：在已授权且未锁屏的图形会话中验证真实捕获、输出、滚动截图、可见界面、全局快捷键和双向翻译。

## 项目结构

```text
Sources/WeShotCore/   核心几何、渲染、文字检测和长图拼接
Sources/WeShotApp/    AppKit 应用、覆盖层、快捷键和系统服务
Tests/                Swift Testing 测试
Resources/            应用配置
scripts/              构建与测试脚本
docs/                 测试报告和脱敏开发记录
```

产品行为和验收标准见 [SPEC.md](SPEC.md)，贡献方式见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证与贡献者

本项目使用 [MIT License](LICENSE)。贡献者名单见 [CONTRIBUTORS.md](CONTRIBUTORS.md)。
