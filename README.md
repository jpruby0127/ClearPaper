<p align="right"><a href="README_EN.md">English</a> · 中文</p>

<p align="center">
  <img src="docs/screenshots/logo.png" width="120" alt="ClearPaper 图标">
</p>

<h1 align="center">ClearPaper</h1>

<p align="center">
  <b>把模糊、发黑、带扫描边框的试卷 PDF，一键变成能直接打印的清晰 A4 版。</b><br>
  原生 macOS / iOS / Android App + Windows 免安装版，<b>全离线、零依赖、不联网、无服务端</b>。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20iOS%20%7C%20Android%20%7C%20Windows-000000" alt="platform">
  <img src="https://img.shields.io/badge/language-Swift%20%2F%20Java%20%2F%20Python-orange" alt="language">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="license">
  <img src="https://img.shields.io/badge/author-jpruby-black" alt="author">
  <img src="https://img.shields.io/badge/engine-100%25%20on--device-green" alt="on-device">
</p>

---

## ✨ 为什么要做这个

老师发来的扫描件 / 手机拍照 PDF，经常有这些毛病：

- 页面尺寸离谱（28×41 英寸），打印被缩到 25%；
- 四周一圈扫描黑框、纸边卷影；
- iPhone 备忘录导出的「白画布」，浪费了 25% 幅面；
- 照片和文字混排，文字发灰、笔画断断续续；
- 原始分辨率低，放大就糊。

**ClearPaper 就是专门收拾这些的。** 它自动判断问题、分区域处理，输出标准的 **210×297mm A4 清晰版**，并且带着一道「质量闸门」——任何真实笔画都不许被抹掉。

> 实测：物理卷 7 页 A4，笔画保留 **100%**；生物卷 8 页 A4，纸面 190mm，保留 **100%**。

## 📸 效果

<p align="center">
  <img src="docs/screenshots/mac-ui.png" width="760" alt="macOS 界面">
  <br><sub>ClearPaper：侧边栏 + 卡片式布局，处理 / 设置 / 帮助</sub>
</p>

同一页试卷，左边是参考用的 Python 引擎、右边是编译进 App 的 Swift 端上引擎——**两者输出一致**，说明手机/电脑里跑的就是同一套算法：

<p align="center">
  <img src="docs/screenshots/compare-physics.png" width="640" alt="物理卷效果对比">
  <br><sub>物理卷：Python 引擎（左） vs Swift 端上引擎（右）</sub>
</p>

<p align="center">
  <img src="docs/screenshots/compare-biology.png" width="640" alt="生物卷效果对比">
  <br><sub>生物卷：Python 引擎（左） vs Swift 端上引擎（右）</sub>
</p>

纸张背面透印（双面卷最常见）：浅灰虚影会被清掉，真实笔画和灰色底纹一律不动。

<p align="center">
  <img src="docs/screenshots/deghost.png" width="620" alt="背面透印抑制对比">
  <br><sub>同一页同一区域：上=处理前（可见背面文字虚影），下=处理后</sub>
</p>

iOS 端是四页式界面（全离线，导入 / 拍照 → 本机处理 → 合并 / 打印 / 分享 / 存到文件）：

<p align="center">
  <img src="docs/screenshots/ios-ui.png" width="290" alt="iOS 处理页">
  <img src="docs/screenshots/ios-about.png" width="290" alt="iOS 关于页">
  <br><sub>左：处理页（拍照扫描、去透印开关、任务卡片）　右：关于页（by jpruby · 版本 1.5.0 (10)）</sub>
</p>

Android 版沿用同一套四页界面、暖灰配色与同一套算法，直接安装 APK 即可，不用自签、不用电脑。

## 🚀 快速开始（不用编译）

### macOS · 拖进应用程序即可用

1. 到 [Releases](https://github.com/jpruby0127/ClearPaper/releases) 下载 **`ClearPaper-macOS-1.5.0.dmg`**；
2. 打开 DMG，把 **ClearPaper** 拖进「应用程序」；
3. 首次打开若被拦截：右键 App → 「打开」→「打开」。

App 自带清晰化引擎，**朋友电脑不需要 Python、venv 或任何配置**。把 PDF 拖进窗口（或拖到 Dock 图标，可一次多个）即可。输出默认在 `文稿/试卷清晰版`，可在「文件 › 选择输出文件夹…」改到任意位置并记住。

> **新增：多份合并。** 把多份 PDF 按添加顺序合并成一个完整 PDF，可选「完全合并」或「合并（间隔·双面）」——后者会在每份文档后补空白页，双面打印时不同试卷不会落在同一张纸上。列表可直接拖动调整顺序。
>
> **已修复：横向 PDF。** 横向排版的页面会输出横向 A4（297×210mm），竖横混排逐页匹配方向，不再被裁掉。
>
> **新增：背面透印抑制。** 双面扫描最常见的「背面文字透过来」虚影会被单独识别并抹回纸白；判断依据是「浅灰 + 远离真实笔画 + 不成片」，所以灰底横幅、表格底纹、照片都不会被误删。

### iPhone / iPad · 自签一次，永久可用

1. 到 [Releases](https://github.com/jpruby0127/ClearPaper/releases) 下载 **`ClearPaper-iOS-1.5.0-unsigned.ipa`**；
2. 电脑装 [Sideloadly](https://sideloadly.io/)（或 AltStore），连上 iPhone，选这个 IPA，填你的 Apple ID 自签；
3. 手机：「设置 → 通用 → VPN 与设备管理」信任该开发者；
4. 微信里收到试卷 →「用其他应用打开」→ 选 **ClearPaper**；或在 App 内点「导入试卷 PDF」。

> 个人免费账号签名 **7 天**有效，到期重签一次即可；文件都在手机本机，不会丢。

**iOS 端现在有什么（1.5.0 / build 10）**

- 四个标签页：**处理 / 合并 / 文件 / 关于**，暖灰配色跟随系统深浅色（也能手动锁定）；
- **关于**页有 Logo、**by jpruby**、从 `Info.plist` 读取的真实版本号与构建号、开源地址；
- **处理**页：导入 PDF、系统文档相机拍照扫描、相册多选；去透印与「导入后自动开始」开关；任务卡片显示页数 / 纸面宽度 / 笔画保留率 / 透印处理状态 / 耗时 / 拍照件的找边矫正与完整流程，可预览、打印、分享、存到文件、重试、删除；
- **合并**页：完全合并 / 间隔·双面（每份后补空白页，双面打印不跨卷）/ 分别保存，顺序可上下调整，与 macOS 端共用 `engine/Merge.swift`；
- **文件**页：输出 PDF 与 OCR 文字稿统一列出，按时间排序，可预览、打印、分享、复制、加入合并、删除；
- **拍照扫描 + 检查拍摄页 + OCR**：见下一节。

### Android · 下载 APK 直接装

1. 到 [Releases](https://github.com/jpruby0127/ClearPaper/releases) 下载 **`ClearPaper-Android-1.5.0.apk`**（约 161 KB，Android 8.0+，纯 Java 无 so、armeabi / arm64 / x86 通用）；
2. 手机允许「安装未知来源应用」后点开 APK 安装即可；
3. 微信里收到试卷 →「用其他应用打开」→ 选 **ClearPaper**；或在「处理」页导入 PDF、拍照扫描、从相册选。

> 与 iOS 版一致：四个标签页（处理 / 合并 / 文件 / 关于）、Logo 与 `by jpruby`、真实版本 1.5.0 (11)、检查拍摄页（删页 / 旋转 / 调序 / 重复页剔除与恢复）、三种合并模式、预览 / 打印 / 分享 / 存文件、外观设置。输出在 App 自己的「清晰版」目录，通过「分享 / 存文件」导出到系统文件。
>
> 平台没有的两块系统能力换成了等价实现，见下方「Android 版说明」：Android 无系统文档相机、无系统离线 OCR，分别用「**App 内置 Camera2 相机** + 手动快门 + 几何找边矫正 + 检查页」和「可选 Xiaomi-OCR-0 桥接」补齐。**没有相机硬件的设备会自动隐藏拍照入口、直接走相册**，功能不打折；相机权限被拒绝或被占用时也会说明原因并给出退路。

### Windows · 解压即用（免安装）

1. 到 [Releases](https://github.com/jpruby0127/ClearPaper/releases) 下载 **`ClearPaper-Windows-portable.zip`**；
2. 解压整个 `ClearPaper` 文件夹（别只拖出单个文件）；
3. 把试卷 PDF 拖到 `ClearPaper.bat` 上（可一次多个），结果出现在原文件旁：`<原名>-清晰版.pdf`。

内置 Python 与全部依赖，**不写注册表、不联网、删文件夹即卸载**；首次运行若被 SmartScreen 拦，点「更多信息 → 仍要运行」。支持 Win10 / Win11 64 位。

## 🧠 它自动判断并处理了什么

| 检测到的毛病 | 处理方式 |
|---|---|
| MediaBox 尺寸离谱（如 28×41 英寸） | 重建为标准 A4，打印不再被缩到 25% |
| 四周扫描黑框 / 纸边卷影 | 连通域 + 边缘条带剔除，只删贴边伪影，不动填空下划线 |
| iPhone 备忘录白画布 | 裁回纸面，找回被浪费的 25% 幅面 |
| 照片与文字混排 | 分区处理：文字强加深，照片保留层次 |
| 原始分辨率偏低 | 整卷统一比例放置，DPI 不足 230 时重采样到 ~300 |
| 横向排版的页面 | 输出横向 A4（297×210mm）；竖横混排逐页匹配方向，不再裁切 |
| 纸张背面透印（浅灰虚影） | 只清除「远离真实笔画、不成片」的浅灰，纸白归位；灰底块与照片保留 |

gamma 不是写死的：从小到大试，直到「原图真实笔画在输出里确实黑」（笔画亮度中位 ≤105）。

### 质量闸门（每次输出都跑）

- 四个阈值下逐页比对，**任何真实墨迹都不许被裁掉**；
- **笔画保留率 ≥97%**（连通域级，只认成片的笔画，不被 JPEG 噪点骗）；
- 页面必须是 **210×297 mm**；
- 页数与原件一致。

踩过的两个坑都已解决：平场校正由加法改为**乘法白点归一化**（淡笔画不再被推成纯白）；非锐化掩模改为**只加深不提亮**的单向锐化（笔画丢失从 7.9% 降到 0–1%）。

## 📷 拍照扫描 + OCR：检查完再整理

<p align="center">
  <img src="docs/screenshots/capture-rectify.png" width="620" alt="拍照件找边矫正前后对比">
  <br><sub>同一张带桌面背景的歪斜试卷：左＝原帧直接进引擎的旧结果，右＝补上找边矫正后</sub>
  <br><br>
  <img src="docs/screenshots/ios-review.png" width="300" alt="检查拍摄页">
  <br><sub>拍完先检查：逐页缩略图、删页 / 旋转 / 调序、重复页自动剔除与一键恢复，「补裁边」标出裁边失败的页</sub>
</p>

iOS 端除了导入 PDF，还能直接拍，而且拍完先过一遍检查页：

1. **只用系统文档相机**（`VisionKit / VNDocumentCameraViewController`）：多页拍摄时自动找边、透视矫正、画质增强，成像质量是最好的一档。原先那套自研「翻页自动拍」相机裁边不准，已彻底移除；系统的自动快门苹果不给外部关闭，所以重复页改在下一步解决。
2. **拍完先检查，再处理**：新增「检查拍摄页」——逐页缩略图可点开看大图、删除、旋转 90°、调整顺序；来不及翻页造成的重复页按 64 位 dHash + 灰度均差自动剔除（相邻宽松 / 非相邻严格，避免误删版式相近的不同页），并且**能一键恢复**，绝不静默丢页。原图逐页落在 Application Support，检查页只持有缩略图，多拍几页也不会爆内存。
3. **按需补一道找边矫正**：相册照片是带桌面、阴影、歪斜的原帧，逐页走 `VNDetectDocumentSegmentationRequest` + `CIPerspectiveCorrection`（Vision 找不到边时退到 Otsu + 拟合纸边的几何兜底）；系统相机偶尔裁边失败、仍带背景的页也会被逐页检测出来、标上「补裁边」，只对这些页补裁。已经裁好的纸面图原样保留，绝不做二次裁剪。这一步很关键——直接把带背景的原帧喂给扫描引擎，平场归一化会把桌面当成纸白、裁边会把整帧当内容，出来的就是瑕疵品。
4. **完整清理流程**：矫正后的页合成 PDF，走**和导入 PDF 完全相同**的 ScanCore —— 乘法白点归一化 → 背面透印抑制 → 自适应 gamma → 单向锐化 → 裁边 → 横竖 A4 → 笔画保留率闸门，不通过会明确报错，不静默出坏结果。
5. **本机 OCR**：系统 `Vision` 识别中英文（离线、零额外体积），导出 `<标题>-文字.txt`，并用首页最像标题的一行自动给文件命名。文字稿可查看、全选复制、分享，在「文件」页与 PDF 一起管理。

> PDF 本身仍是图像，不叠加文字层，避免破坏打印效果与笔画质量闸门。
> 拍摄原稿逐页落到 Application Support，App 被系统挂起、临时目录被清理后仍可重试重建。

### Android 版说明

Android 版把上面的界面与流程逐一搬了过来，平台没有的两块系统能力换成了等价实现：

| 能力 | iOS | Android |
|---|---|---|
| 多页拍摄 | VisionKit 系统文档相机（自动快门） | **App 内置 Camera2 相机**（不调用系统相机 App）：手动快门逐页拍、可开补光，天然不会因来不及翻页重复拍同一张；检查页仍做 dHash 去重与一键恢复 |
| 找边 / 透视矫正 | Vision 文档分割 + 几何兜底 | 纯几何找边（Otsu + 亮段拟合 + 最小二乘 + 单应性逆映射）；找不到可靠纸边就用原图，绝不猜测式裁剪 |
| OCR 文字稿 | 系统 Vision，离线零体积 | 默认完全离线；在「关于 → OCR 服务」填自己部署的 Xiaomi-OCR-0 地址后，按官方协议生成 Markdown 文字稿并用首页标题自动命名 |
| PDF 合并 | PDFKit 原样插入页面 | `PdfRenderer` 按 200dpi 逐页重绘后拼接，顺序 / 横竖 / 双面补空白一致；纯矢量文字稿会变成图像页 |
| 清理引擎 | `engine/Core.swift`（Swift） | `GrayMath.java` 逐行等价移植 + `PdfWrite.java` 手写灰度 Flate 图像 XObject；`android/test/run_test.sh` 可在 Mac 上跑 JVM 回归测试 |

其余完全一致：白场归一 → 去透印 → 自适应 gamma → 单向锐化 → 裁边 → 横竖 A4 → 笔画保留率闸门。拍照件也必须走完这条链路，绝不绕过。

**关于「当前设备没有可用的相机」**：早期 build 10 用 `MediaStore.ACTION_IMAGE_CAPTURE` 拉起系统相机 App，在 Android 11+ 上会同时踩两个坑——Manifest 没有 `<queries>` 声明导致包可见性过滤后解析不到相机 App，以及声明了 `CAMERA` 权限却没动态申请导致相机 App 拒绝——于是明明有摄像头的手机也会弹这句误报。build 11 起改为 **App 内置相机**（`CameraActivity.java`：Camera2 + `TextureView` 预览 + `ImageReader` 出片，动态申请 `CAMERA` 权限、方向与限长边自己归一，不依赖设备写不写 EXIF），不再依赖任何外部相机 App；Manifest 补上 `<queries>` 作为系统相机兜底。真正没有相机硬件的设备（模拟器 / 部分平板 / 云手机）会隐藏「拍照扫描」入口并直接转相册，权限被拒绝或相机被占用时也会分别提示原因、给出「从相册选 / 用系统相机」两条退路。

### 进阶：小米开源的 Xiaomi-OCR-0

[Xiaomi-OCR-0](https://github.com/xiaomi-research/Xiaomi-OCR-0)（0.8B，Apache 2.0，2026-10-30 开源）能把整页解析成**结构化 Markdown**（表格 OTSL、公式 LaTeX），还能做字段抽取（JSON）与文档问答。`python/ocr_xiaomi.py` 是它的轻量桥接后端，按官方 `DOC_PROMPT` 和请求格式调用**本机**的 OpenAI 兼容服务：

```bash
# 先起服务（任选其一，权重约 1.8–2GB，需要 GPU 或较快的 CPU）
vllm serve SeerRay-Lab/Xiaomi-OCR-0 --host 127.0.0.1 --port 8000 --max-model-len 16384

cd python
python ocr_xiaomi.py 某试卷.pdf                 # → 某试卷-OCR.md
python ocr_xiaomi.py 表格.png --task kie --fields "姓名,学号,总分"
```

服务地址只接受 `127.0.0.1 / localhost`，**不会把文档发到外网**；环境变量 `XIAOMI_OCR_LOCAL_URL` / `XIAOMI_OCR_MODEL` 与官方 Demo 同名。Ollama（社区 BF16 GGUF）或 SGLang 也能直接用。

**为什么模型不塞进 IPA**：0.8B 的 Qwen3.5 多模态权重约 1.8GB，需要 Core ML / GGUF 转换与专有推理运行时；塞进去会让现在 450KB 的 IPA 膨胀几千倍，还会拖慢启动与处理。所以 iPhone 上用系统 Vision 做「即开即用」的文字识别，Xiaomi-OCR-0 留给桌面 / 服务器做结构化整理，两者产物（`.txt` / `.md`）都能在「文件」页查看。追求最佳解析质量时，用小米官方的 Demo / MCP 服务（含版面分析与后处理）。

## 🛠 从源码构建

仓库克隆后，四个平台都能在本机直接编译，**无需任何第三方依赖**（Swift 标准库 + Android SDK build-tools + 系统框架即可）。

```bash
git clone https://github.com/jpruby0127/ClearPaper.git
cd ClearPaper
```

### macOS App

```bash
cd macos
./build_app.sh                 # 非沙盒 + 强化运行时，装到 ~/Applications/ClearPaper.app
# SANDBOX=1 ./build_app.sh     # 上架版：开启 App Sandbox
# SIGN_ID="你的证书" ./build_app.sh   # 指定签名身份
```

### iOS App（未签名 IPA，供自签）

```bash
cd ios
./build_ios.sh ../ClearPaper-iOS-unsigned.ipa
```

跑模拟器看效果：

```bash
./build_sim.sh shot.png        # 构建、安装、启动模拟器，并可截图
```

> 需要 Xcode 命令行工具与 iOS SDK（`xcode-select --install`）。图标与 `ios/Logo.png` 已随仓库提交；`Core.swift`（引擎）、`Merge.swift`（合并）、`Capture.swift`（文档相机 + 找边矫正 + OCR）、`ScanReview.swift`（检查拍摄页）都是源码直编，只链接系统框架，不依赖 Python 或任何第三方库。

### Android App（签名 APK）

```bash
cd android
./build_apk.sh        # aapt2 → javac → d8 → zipalign → apksigner，产出 ../dist/ClearPaper-Android-1.5.0.apk
./test/run_test.sh    # 纯 JVM 回归测试：引擎 + PDF 写出，不需要模拟器
```

> 只需 Android SDK 的 `build-tools` 与任一 `platforms/android-3x/android.jar`，**不需要 Gradle / AndroidX / Maven / 联网**。全部 UI 用原生 View 自绘，扫描引擎是 `GrayMath.java`，PDF 由 `PdfWrite.java` 直接写灰度 Flate 图像 XObject，合并用系统 `PdfRenderer`。签名用本机生成的自签 keystore（v1 + v2 + v3）。相机由 `CameraActivity.java` 用系统 Camera2 API 自己实现，没有引入任何相机 SDK 或 so。

## 🐍 Python 参考引擎（可选）

macOS / iOS App 走的是**编译进包的 Swift 引擎**（可分发、零依赖）。`python/` 里是同一套算法的**参考实现**，方便你研究、批处理或在服务器上跑：

```bash
cd python
pip install pymupdf numpy pillow scipy
./bin/scanpdf 某试卷.pdf          # 输出 <名字>-清晰版.pdf
./bin/scanpdf --check            # 自检
# 可选：接本机 Xiaomi-OCR-0 做结构化 Markdown（见「拍照 + OCR」一节）
python ocr_xiaomi.py 某试卷.pdf   # 输出 <名字>-OCR.md
```

## 🗺 路线图

- [x] 多页拼接 / 双面试卷自动合并（macOS 1.3 / iOS 1.5）
- [x] 拍照扫描 + 检查拍摄页 + OCR 文字稿（iOS 1.5 · 系统文档相机 / 重复页剔除与恢复 / 按需找边矫正 / 可选 Xiaomi-OCR-0）
- [ ] 自定义输出纸张（B5 / Letter）与 DPI
- [ ] 批量文件夹监视（桌面端常驻）
- [ ] 可搜索 PDF 文字层（目前导出 `.txt` 旁文件，不改动打印用 PDF）
- [x] Android 原生 APK（v1.5.0 · 四页 UI / 检查拍摄页 / 三种合并 / 同一套引擎）
- [x] Windows 免安装版（v1.1.0）
- [ ] Linux 命令行版

欢迎提 Issue 和 PR，一起把它打磨成真正的「开源神器」。

## 📦 发布说明

| 版本 | 平台 | 产物 | 说明 |
|---|---|---|---|
| v1.5.0 | macOS | `ClearPaper-macOS-1.5.0.dmg` | 新 Logo + 品牌更名 ClearPaper；侧边栏 UI |
| v1.5.0 | iOS | `ClearPaper-iOS-1.5.0-unsigned.ipa` | build 10：只用系统文档相机，新增拍完「检查拍摄页」（删页 / 旋转 / 调序 / 重复页剔除与一键恢复）、裁边失败页自动标记并补矫正、图像方向与尺寸归一；彻底移除实验性自研相机；拍照件仍强制走完整 ScanCore 清理流程；四页 UI、by jpruby 与真实版本信息、本机 OCR 文字稿、多份合并、文件管理、外观设置；可选 Xiaomi-OCR-0 后端 |
| v1.5.0 | Android | `ClearPaper-Android-1.5.0.apk` | 首个 Android 版：四页 UI 与 iOS 对齐、暖灰配色 / Logo / `by jpruby` / 版本 1.5.0 (10)；拍照 + 检查拍摄页 + 几何找边矫正 + 重复页剔除与恢复、完整清理引擎、三种合并、文件管理、预览 / 打印 / 分享 / 存文件、外观设置；可选 Xiaomi-OCR-0 桥接，默认完全离线；**build 11** 改为 App 内置相机，修复「当前设备没有可用的相机」误报，并让无相机设备完整走相册 |
| v1.2.0 | Windows | `ClearPaper-Windows-portable.zip` | 品牌更名 ClearPaper；免安装便携包，拖拽即用 |

> Android APK 为自签名发布包，安装时系统会提示「未知来源」，允许一次即可；不依赖 Google Play 服务，也不需要 Google 账号。
>
> 当前分发用的是本机 **Apple Development** 证书：Mac DMG 在本人/同账号下双击即开；发给他人建议用 **Developer ID** 重签并 `notarytool` 公证（命令已就绪，无需改代码）。iOS 个人账号签名 7 天有效。

## 📄 许可证

[MIT](LICENSE) — 随便用、随便改、随便上架，留个名就行。

---

<p align="center">
  ClearPaper · by jpruby · 用 Swift / Java / Python 写的离线试卷清晰工具<br>
  数据不出本机 · 打开即印
</p>
