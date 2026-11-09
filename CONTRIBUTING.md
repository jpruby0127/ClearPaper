# 贡献指南 / Contributing

欢迎 Issue 和 PR，一起把它打磨成真正的开源神器 🚀

## 提 Issue

- **Bug**：附上平台、现象、最好有处理前后的 PDF/截图。
- **功能建议**：说清想要什么能力、解决什么痛点。

## 本地开发

```bash
git clone https://github.com/jpruby0127/ClearPaper.git
cd ClearPaper
```

- **macOS App**：`cd macos && ./build_app.sh`（需 Xcode 命令行工具）
- **iOS App**：`cd ios && ./build_ios.sh out.ipa`
- **Python 参考引擎**：`cd python && pip install -r requirements.txt && ./bin/scanpdf 某试卷.pdf`

## PR 约定

1. 从 `main` 切一个清晰命名的分支；
2. 改动尽量小、可验证；算法改动请附「保留率未下降」的实证；
3. 提交信息用中文或英文均可，说清「为什么」；
4. 提交前确保两端能本地构建。

## 许可证

所有贡献默认以 [MIT](LICENSE) 协议授权。
