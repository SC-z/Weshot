# Changelog / 更新日志

## 2.0.3 - 2026-11-12

- Add a menu beside the translation icon to save separate target languages for Chinese and other source languages.
  翻译图标旁新增菜单，可分别保存中文和其他语言的翻译目标。
- Exclude the previous translation layer when recognizing text for another translation.
  重新翻译时，文字识别跳过上一次的译文图层。

## 2.0.2 - 2026-11-05

- Reuse display metadata, capture displays concurrently, and capture scrolling regions directly.
  复用显示器元数据、并发采集多屏，长截图直接采集选区。
- Reject sparse-text and near-ambiguous scrolling matches; align against the last accepted viewport and remove repeated fixed footers.
  拒绝白底文字误匹配和近似歧义，使用上一张原始画面定位，并移除接缝中的重复固定页脚。
- Fix text-draft cancellation, pen clicks and release endpoints, and oversized pinned images moving offscreen while zooming.
  修复文字草稿取消、画笔单点及松手末端遗漏、超高钉图缩放离屏的问题。
- Pin the signing certificate across updates, limit repeated permission requests, and add a signed DMG packaging script.
  固定更新签名证书、限制重复授权请求，新增固定签名 DMG 打包脚本。

## 2.0.1 - 2026-07-22

### Fixed / 修复

- Fixed scrolling capture failing to stitch while the source page continued to scroll.
  修复源页面已经滚动，但长截图预览和结果没有拼接的问题。
- Capture the first scrolling frame live through the same ScreenCaptureKit path as every later frame.
  长截图首帧与后续帧统一使用同一条 ScreenCaptureKit 实时采集链路。
- Removed low-resolution frame deduplication that could discard valid page changes before stitching.
  移除可能在拼接前误丢有效滚动帧的低分辨率去重。
- Improved overlap matching for pages with fixed toolbars or sticky headers.
  改进包含固定工具栏或吸顶标题页面的重叠识别。
- Fixed application icon generation on current macOS toolchains.
  修复当前 macOS 工具链无法从 SVG 生成应用图标的问题。

### Changed / 变更

- Scrolling capture now returns focus to the source application and reports live capture and stitching status.
  长截图开始后会将焦点还给源应用，并实时显示采集与拼接状态。

## 2.0.0 - 2026-07-17

- Released the native macOS screenshot editor with annotation, scrolling capture, translation, privacy redaction, and pinned images.
  发布原生 macOS 截图编辑器，支持标注、长截图、翻译、隐私打码和钉图。

## 1.2.7 - 2026-07-17

- Fixed the first click being ignored when starting a screenshot selection.
  修复开始截图选区时第一次点击不生效的问题。

## 1.2.6 - 2026-07-17

- Initial open-source release.
  首个开源版本。
