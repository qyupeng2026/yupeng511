# 文件加密 · 手机原生 App（Flutter）

把网页版「文件加密工具」移植为手机原生 App，**完全兼容网页版的文件格式**：网页加密的文件可以在 App 解密，App 加密的文件也能在网页解密。加密全程在手机本地完成，文件不上传。

## 格式兼容性

| 版本号 | 算法 | 说明 |
|---|---|---|
| 1 | AES-256-GCM | 1 MiB 分块，每块 16 字节认证标签，末块 AAD=1 |
| 2 | AES-256-CTR | Cloudreve 同款信封加密：随机文件密钥 + 主密钥 AES-GCM 包装 + HMAC-SHA256 校验 |

公共参数：魔数 `FENC`、PBKDF2-HMAC-SHA256 250000 次派生 32 字节密钥、盐 16 字节。

`test/format_compat_test.dart` 使用网页实现生成的固定向量做回归测试，CI 中 `flutter test` 会验证 Dart 端能正确解密网页产物。

## 功能

- 选择任意文件，自动识别是否为加密文件及算法
- 加密（GCM/CTR，密码二次确认）与解密，实时进度
- 后台 Isolate 分块处理，大文件不卡 UI、内存占用稳定
- 结果保存到应用文档目录，支持系统分享 / 复制路径
- 深色 UI，适配安全区域

## 目录

```
lib/main.dart            界面与交互
lib/crypto/engine.dart   纯 Dart 加解密引擎（pointycastle，兼容网页格式）
test/                    格式兼容性与自解密测试
tools/gen_vectors.mjs    用 Node WebCrypto 生成兼容性测试向量
android/                 Android 工程（Flutter embedding）
.github/workflows/       CI：分析 + 测试 + 打包 APK
```

## 本地构建

需要 Flutter 3.24+、Android SDK、JDK 17：

```bash
cd file_encryptor
flutter pub get
flutter analyze
flutter test
flutter build apk --release --split-per-abi
```

产物在 `build/app/outputs/flutter-apk/`。

## 自动构建

推送到 `master`（或手动触发 `Build Android APK` workflow）即可，在 Actions 运行产物中下载 `file-encryptor-apk`（含 arm64-v8a / armeabi-v7a / x86_64 三种 APK）。

## 重新生成测试向量

```bash
cd file_encryptor/tools
node gen_vectors.mjs > vectors.json
```

把生成的 hex 写入 `test/vectors.dart` 即可。

## 安全说明

- 密码不落盘、不上传；忘记密码无法恢复
- 发布正式版请配置自己的签名证书（`android/key.properties`），当前 CI 用 debug 签名仅为便于直接安装
