# 剪切板预览增强开发文档

## 目标

剪切板历史预览需要在当前实现上增强“识别准确、预览可读、降级明确”的能力。现有链路已经完成基础能力：

- `ClipboardHistoryController` 从 `NSPasteboard` 采集第一条 `pasteboardItem`，保存 `plainText`、`storedTypes` 和 `ClipboardContentMetadata`。
- `ClipboardHistoryStore` 将小内容内联存储，大内容写入 blob，并为图片生成缩略图。
- `ClipboardHistoryWindowController` 在按空格预览时生成临时 Quick Look URL，再用自定义 `NSPanel` 负责头部元信息、图片预览、文本预览和 HTML/RTF 富文本渲染。

增强目标是在不破坏这条主链路的前提下，把文本类内容细分为 JSON、Markdown、URL、代码、CSV/TSV；把图片、文件、本地路径和富文本预览补齐到可验收状态。最终效果：

- JSON 自动格式化，非法 JSON 不误判。
- Markdown 渲染为可读富文本，必要时保留原文降级。
- URL 展示卡片信息，至少包含域名、路径、标题占位和原始链接。
- 代码使用等宽字体和轻量语法高亮。
- CSV/TSV 以表格预览，控制列宽和横向溢出。
- 图片使用棋盘格背景，展示尺寸、格式和字节数。
- 多文件/本地路径展示文件列表、存在状态、类型和路径。
- HTML/RTF 使用系统富文本解析渲染，并隔离不可解析内容。

## 预览类型矩阵

| 类型 | 识别输入 | 主预览 | 头部信息 | 操作/限制 |
| --- | --- | --- | --- | --- |
| JSON | `plainText` 为合法 JSON object/array，或 pasteboard type 含 `json` | 格式化文本，高亮 key/string/number/bool/null | `JSON`、字符数、字节数、来源应用 | 只格式化 object/array；超大内容显示截断提示 |
| Markdown | `plainText` 命中 Markdown 结构信号，或 type 含 `markdown` | 渲染富文本：标题、列表、代码块、链接 | `Markdown`、字符数、字节数 | 渲染失败回退纯文本；代码块可用等宽字体 |
| URL | 单个 http/https URL，或 URL 列表 | URL 卡片：域名、路径、链接文本、可复制原链接 | `URL`、数量、来源应用 | 不在采集阶段发网络请求；可后续异步补标题 |
| 代码 | type/扩展名/文本信号命中代码 | 等宽文本，轻量高亮，保留缩进 | 推断语言、行数、字节数 | 不做复杂 AST；长行换行，不常驻横向滚动 |
| CSV/TSV | 多行分隔文本，分隔符一致，列数稳定 | 表格视图，表头、行号、单元格截断 | `CSV`/`TSV`、行列数、字节数 | 大表只渲染前 N 行，提示已截断 |
| 图片 | metadata 为 `图片`，或 type 含 png/tiff/jpeg/heic/image | 棋盘格背景上的 aspect-fit 图片 | 像素尺寸、格式、字节数 | 透明图片必须可辨；图片无效回退文件/空状态 |
| 文件/本地路径 | `file-url`/`filename` type，或纯文本每行是本地绝对路径/file URL | 文件列表或单文件详情 | 文件数、格式/类型、字节数、来源应用 | 路径不存在也要展示路径和“不存在”状态 |
| HTML | type 含 `html` | `NSAttributedString.DocumentType.html` 渲染 | `HTML`、字符数、字节数 | 禁止执行脚本；解析失败显示源码文本 |
| RTF | type 含 `rtf` | `NSAttributedString.DocumentType.rtf` 渲染 | `RTF`、字符数、字节数 | 解析失败显示纯文本/摘要 |
| 普通文本 | 以上都未命中 | 可选择、自动换行纯文本 | `纯文本`、字符数、字节数 | 保留当前行为作为最终兜底 |

## 路由策略

预览路由应集中在一个纯判定层，避免把识别逻辑散落在 UI 构造函数中。建议新增内部枚举，例如：

```swift
private enum ClipboardPreviewRoute {
    case image
    case fileList
    case richText(RichTextKind)
    case json
    case markdown
    case urlList
    case code(language: String?)
    case delimitedTable(separator: Character)
    case plainText
    case unsupported
}
```

路由入口以 `ClipboardHistoryItem` 为输入，优先使用已持久化的 `metadata` 和 `pasteboardTypes`，必要时读取 `storedTypes`：

1. 强类型优先：文件、图片、HTML、RTF 由 pasteboard type 和 metadata 决定，优先级高于纯文本启发式。
2. 结构化文本其次：JSON、CSV/TSV、URL、Markdown、代码从 `plainText` 或临时文本内容识别。
3. 可渲染优先于可摘要：能完整渲染时使用专用视图；不能完整渲染时展示摘要和降级原因。
4. Quick Look URL 保留为文件/图片预览入口；文本增强不依赖 Quick Look 文件后缀，否则 JSON/Markdown/CSV 都会被 `.txt` 弱化。

当前 `makeQuickLookURL(for:)` 会按“存在的源路径 -> 图片临时文件 -> 文本 `.txt` 临时文件”生成 URL。增强后建议把“数据准备”和“UI 路由”分离：

- 文件和图片仍可复用 URL。
- HTML/RTF 优先从 `storedTypes` 解析，不依赖临时 `.txt`。
- JSON/Markdown/URL/代码/CSV/TSV 从标准化文本生成 view model。
- 预览头部通过 route 输出统一的 `PreviewHeaderInfo`，避免每种 view 自己拼 chip。

## UI 规范

剪切板预览属于 macOS 工具型浮层，视觉应延续现有 `MacAssistantUI`：

- 主容器继续使用 `LayerBackedView(backgroundColor: MacAssistantUI.Color.window, cornerRadius: 14)`，头部高度保持紧凑。
- 颜色、边框、圆角、字号优先复用 `MacAssistantUI.Color`、`MacAssistantUI.separator()` 和现有 chip 样式。
- 交互控件必须使用自绘 `NSControl` 子类；不要把原生 `NSButton`、`NSSearchField`、`NSPopUpButton`、可编辑 `NSTextField` 直接放进主页面。
- `NSTextField(labelWithString:)` 只用于静态文字标签；可选择正文继续使用只读 `NSTextView`。
- 表格/列表不能暴露常驻横向滚动条：单元格按列宽截断，详情通过弹窗或展开区展示。
- 图片预览需要棋盘格背景，不使用纯白或纯黑底承载透明图片。
- 文本预览默认自动换行；代码可保留缩进但仍应避免横向滚动成为主要阅读路径。
- JSON、Markdown、URL、代码、CSV/TSV 等结构化文本预览必须先检查大小上限；超过上限时不执行解析/渲染，直接显示原始文本。
- 头部 chip 控制在 3-4 个以内，优先展示格式、规模、来源应用；长路径只展示末尾或文件名，完整路径放正文。

各类型建议视图：

- JSON：只读 `NSTextView`，等宽字体，缩进 2 空格，语法色轻量即可。
- Markdown：使用 `NSAttributedString` view model 渲染，不支持的语法以纯文本保留。
- URL：卡片列表，每条包含 favicon 占位图标、host、path、完整 URL；后续有网络标题时再补标题。
- 代码：只读 `NSTextView`，行距低于普通文本，关键字/字符串/注释基础高亮。
- CSV/TSV：自绘表格容器，固定表头行、行高、列宽上限，单元格尾部截断。
- 图片：棋盘格 `NSView` + `AspectFitImageView`，底部或头部展示像素和格式。
- 文件：列表行展示文件图标、文件名、路径、存在状态；多文件按数量限制首屏行数。
- HTML/RTF：富文本区域使用系统解析结果，统一覆盖默认字体、颜色、段落间距，保证深浅色可读。

## 数据识别规则

识别规则要保守，宁可回退纯文本，也不要误判后给出错误预览。

### 基础采集

- 单个 stored type 数据上限当前为 `2_000_000` 字节，超过会被跳过。增强预览不能假设所有原始类型都存在。
- `plainText` 来自 `.string`，可能为空；文件、图片、RTF 仍可能只有二进制 stored type。
- `contentByteCount` 是已保存 stored type 的总和，可作为预览规模信息，不代表原始剪切板完整大小。

### 文件/路径

- 继续支持 `file-url`、`filename` 相关 pasteboard type。
- 继续支持属性列表 `[String]` 反序列化为路径列表。
- 纯文本路径只接受每行独立的 `file://` 或 `/` 开头绝对路径。
- 去重使用标准化 path；展示时保留原始路径可读性。
- 路径存在性在预览时判断，不要在采集时过滤掉不存在路径。

### 图片

- type 命中 `image`、`png`、`tiff`、`jpeg`、`jpg`、`heic` 即可尝试。
- 像素尺寸优先使用 `CGImageSourceCopyPropertiesAtIndex`，失败再让 `NSImage(contentsOf:)` 兜底。
- 格式 chip 从 URL 扩展名或 pasteboard type 推断。

### HTML/RTF

- type 含 `html` 时按 UTF-8、UTF-16、无显式编码依次尝试。
- type 含 `rtf` 时按 `.rtf` 尝试。
- 解析结果去除首尾空白后为空则视为失败。
- 富文本优先级高于代码识别，避免 HTML 被当代码展示。

### JSON

- 只在 trim 后首尾为 `{}` 或 `[]` 时尝试解析。
- 使用 `JSONSerialization` 或 `JSONDecoder` 验证合法性；不要用正则判断。
- object/array 格式化输出；字符串、数字等顶层 JSON 标量不进入 JSON 专用预览。
- 解析失败直接回退后续文本类型。

### Markdown

- 命中多个 Markdown 信号才判定，例如标题 `# `、列表 `- ` 或 `1. `、代码围栏、链接 `[text](url)`、引用 `> `、表格分隔行。
- 单行带 `#` 或 `*` 不应判定为 Markdown。
- 如果同时满足代码和 Markdown，含代码围栏时优先 Markdown，否则按代码信号数量决定。

### URL

- 单 URL：trim 后完整匹配一个 http/https URL。
- 多 URL：每行一个 http/https URL，空行可忽略。
- 不把普通文本中的局部 URL 强行提升为 URL 卡片，避免长段落误判。
- 识别阶段不访问网络，保证剪切板打开速度和隐私边界。

### 代码

- 先看 pasteboard type 或文件扩展名：`swift`、`json`、`xml`、`html`、`css`、`javascript`、`typescript`、`python`、`shell` 等。
- 再看文本信号：`import`、`func`、`class`、`struct`、`let`、`var`、`=>`、`</`、`{}`、`;` 等。
- 当前实现使用至少 2 个信号判定 code-like；增强后应排除已命中的 JSON、Markdown、CSV/TSV、HTML/RTF。

### CSV/TSV

- 至少 2 行，非空行列数基本一致。
- TSV 优先检查 `\t`；CSV 检查逗号，并使用 CSV 解析器处理引号，不要简单 `split(separator: ",")`。
- 列数小于 2 不判定为表格。
- 对超大表格限制渲染行数和列数，保留总行列统计。

## 降级策略

降级要可预测，并尽量保留用户可复制的原始内容：

1. 专用解析失败：回退到纯文本预览，并在头部 chip 或空状态中显示原格式，例如 `JSON 解析失败`。
2. 富文本解析失败：优先显示 `plainText`，否则显示 `previewText`。
3. 图片数据无效：如果有源路径且文件存在，按文件预览；否则显示“无法预览此图片”并保留格式/字节数。
4. 文件路径不存在：仍展示文件列表，状态标记为“不存在”，不要隐藏。
5. stored type 因大小限制缺失：使用 `plainText`/`previewText`，头部不要承诺原格式完整可用。
6. CSV/TSV 太大：只渲染前 N 行和前 M 列，正文顶部或底部标注“已截断”。
7. URL 元信息不可用：展示本地解析出的 host/path 和原始 URL，不阻塞预览。
8. 所有内容为空：使用现有 empty state，不写入无意义历史记录。
9. 结构化文本超过设置中的“结构化预览上限”时：跳过 JSON/Markdown/CSV/代码等解析，按普通文本展示，并在头部显示“原文显示”。

## 测试/验收清单

### 单元测试

- JSON：合法 object/array 被格式化；非法 JSON、顶层字符串不进入 JSON route。
- Markdown：标题+列表、代码围栏、链接可识别；普通带符号文本不误判。
- URL：单 URL、多行 URL 可识别；段落中的局部 URL 不误判。
- 代码：Swift/JS/Python 片段识别；HTML/RTF stored type 不被代码规则抢走。
- CSV/TSV：带引号 CSV、TSV、多行列数一致可识别；单列或列数混乱回退文本。
- 文件：`file-url`、属性列表路径、纯文本绝对路径去重；不存在路径仍保留。
- 图片：PNG/TIFF/JPEG/HEIC type 推断和像素尺寸读取。
- 富文本：HTML UTF-8/UTF-16、RTF 解析成功；空解析结果回退。

### UI 验收

- 预览面板在主窗口和多屏环境中居中，尺寸不超过可见屏幕。
- 头部标题、chip、来源应用在长文本/长路径下不重叠。
- 文本、代码、JSON、Markdown 均可选择复制，且没有常驻横向滚动条。
- CSV/TSV 表格列宽可控，长单元格截断，行数多时只出现垂直滚动。
- 透明 PNG 在棋盘格上可辨识，图片 aspect-fit 不变形。
- 多文件列表在 1 个、3 个、20+ 个文件下都能展示数量和路径。
- HTML/RTF 在浅色/深色系统外观下文字颜色可读。
- 空内容、解析失败、文件不存在都有明确但简短的状态文案。

### 回归验收

- 复制普通文本后仍能记录、搜索、粘贴。
- 复制图片后历史列表缩略图仍生成，删除记录后 blob 和缩略图仍清理。
- 复制同一内容仍按 content hash 去重，并保留收藏状态。
- 搜索仍覆盖 `previewText`、`plainText`、文件路径和来源应用。
- 空格打开/关闭预览、方向键切换选中项、复制回剪切板行为不回退。
- 已存在的 HTML/RTF/图片/文件历史记录在迁移后仍可预览或降级展示。
