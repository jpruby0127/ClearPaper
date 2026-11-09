# Windows 版 / Windows build

Windows 端是**免安装便携包**：内置嵌入式 CPython 与全部依赖，解压即用，不写注册表、不联网。

## 用现成的（推荐）

到 [Releases](https://github.com/jpruby0127/ClearPaper/releases) 下载 **`ScanClean-Windows-portable.zip`**：

1. 解压整个 `ScanClean` 文件夹；
2. 把 PDF 拖到 `ScanClean.bat` 上（可多个）；
3. 结果出现在原文件旁：`<原名>-清晰版.pdf`。

> 首次运行若提示「Windows 已保护你的电脑」：更多信息 → 仍要运行。

## 目录结构

```
ScanClean/
├─ ScanClean.bat          拖拽入口（ASCII，避免中文编码问题）
├─ README-Windows.txt     使用说明
├─ app/
│  ├─ scanpdf.py          命令行入口 + 质量闸门
│  ├─ engine.py           清晰化引擎
│  ├─ clean_scan.py       图像算法
│  └─ verify.py           独立质量校验
└─ python/                嵌入式 CPython + win_amd64 轮子
   ├─ python.exe
   ├─ pythonXY._pth       已配置好 site-packages
   └─ Lib/site-packages/  pymupdf · numpy · pillow · scipy
```

## 自己构建便携包

在 macOS / Linux 上（需 `python3`、`curl`、`zip`）：

```bash
./windows/build_portable.sh
# 产出：dist/ScanClean-Windows-portable.zip
```

原理：下载 python.org 的 Windows 嵌入式 Python，用
`pip install --target ... --platform win_amd64 --only-binary=:all:`
把 Windows 轮子解包进 `Lib/site-packages`，再配 `._pth` 与拖拽 bat。
全程无需在 Windows 上编译。

## 为什么不是 .exe？

PyInstaller / Nuitka 都不能跨平台交叉编译，在 macOS 上产不出 Windows 的 `.exe`。
便携包方案的好处是：**可复现、可审计、不依赖任何打包器**，而且用户能直接看到是脚本在跑。
如果你想要单文件 exe，可在 Windows 上执行：

```bat
python -m venv venv
venv\Scripts\pip install pymupdf numpy pillow scipy pyinstaller
venv\Scripts\pyinstaller --onefile --name ScanClean windows\scanpdf.py --paths python\scanpdf
```
