# Changelog / 更新日志

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
