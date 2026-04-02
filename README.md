# call

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## 本项目说明（局域网聊天室原型）

我已为局域网聊天室搭建了一个最小原型：

- 客户端（Flutter）：位于 `lib/`，包含登录入口 `lib/src/screens/lobby.dart` 和一个简单的 `SignalingService`（`lib/src/services/signaling.dart`）。
- 局域网信令服务器（Dart）：`server/signaling_server.dart`，运行后在本局域网内通过 WebSocket 端口 8080 转发信令消息，便于快速实现 P2P WebRTC 通话（音视频）。

快速开始：

1. 在仓库根目录运行依赖安装：
```bash
flutter pub get
```
2. 在一台机器上启动信令服务器（Dart SDK 已安装）：
```bash
dart run server/signaling_server.dart
```
3. 在另一台（或同一台）机器上运行 Flutter 客户端：
```bash
flutter run -d edge    # 或 -d windows
```

接下来我可以：
- 完善聊天室消息 UI 与持久化；
- 集成 `flutter_webrtc` 完成音视频通话，并使用信令服务器交换 SDP/ICE；
- 清理/删除你不需要的平台文件（我会先备份并列出将删除的目录）。

要我现在做哪一步？（例如：启动信令服务器、集成 WebRTC、删除平台目录）
