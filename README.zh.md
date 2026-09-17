# Atlas SDK for Apple platforms

[English](README.md) · [한국어](README.ko.md)

[App Atlas](https://appatlas.dev) 的 iOS·macOS 客户端。
Objective-C，核心只依赖 Foundation，零依赖。支持 **iOS 12 / macOS 10.13**，
以源码分发，因此更低的部署目标也能构建。

## 安装

<!-- tabs:start -->
#### Xcode

1. 打开项目，选择 File > Add Package Dependencies…
2. 把仓库地址粘贴到搜索框。
3. Dependency Rule 保持 Up to Next Major Version，从 0.1.0 起。
4. 点击 Add Package，把 AppAtlasSDK 产品添加到应用目标。

```
https://github.com/pjy0509/atlas-sdk-apple.git
```

#### Package.swift

```swift
.package(url: "https://github.com/pjy0509/atlas-sdk-apple.git", from: "0.1.0")
```

#### Podfile

```ruby
pod 'AppAtlasSDK'          # Links（会一并引入 Core）
pod 'AppAtlasSDK/Core'     # 仅传输那一半
```
<!-- tabs:end -->

<!-- guide:start -->
## 使用

Swift 直接以模块访问，无需桥接头文件。桥接头文件是应用自己的事，
库不应替它做主。SPM 会生成模块映射；CocoaPods 在 `use_frameworks!`
下也会写一份。Objective-C 中，`ATL` 前缀代替了这门语言没有的命名空间。
名字与 Android、.NET SDK 一致。

<!-- tabs:start -->
#### Swift

```swift
import AppAtlasSDK

Atlas.start(withKey: "sdk_…")

AtlasLinks.setListener { link in
    // link.payload / link.path / link.deferred / link.match
    // link.channel / link.campaign / link.shortId / link.clickedAt
}
```

```swift
// 代理中的链接入口。
AtlasLinks.handle(url)                          // openURL:
AtlasLinks.handle(userActivity: activity)       // continueUserActivity:
```

#### Objective-C

```objc
// application:didFinishLaunchingWithOptions:
[Atlas startWithKey:@"sdk_…"];

[ATLLinks setListener:^(ATLLink *link) {
    // link.payload / link.path / link.deferred / link.match
    // link.channel / link.campaign / link.shortId
}];
```

```objc
// 代理中的链接入口。
- (BOOL)application:(UIApplication *)app continueUserActivity:(NSUserActivity *)activity
 restorationHandler:(void (^)(NSArray<id<UIUserActivityRestoring>> *))restorationHandler {
    return [ATLLinks handleUserActivity:activity];
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary *)options {
    return [ATLLinks handleURL:url];
}
```
<!-- tabs:end -->

先于监听器到达的链接会被保留并重放，冷启动的点击不会丢失。

## 延迟链接

Apple 没有 install referrer，因此访问页面借访客自己的点击把链接放进
剪贴板，应用兑换一次：

<!-- tabs:start -->
#### Swift

```swift
AtlasLinks.checkPasteboardOnFirstLaunch()
```

#### Objective-C

```objc
[ATLLinks checkPasteboardOnFirstLaunch];
```
<!-- tabs:end -->

这是一个由你调用的方法，而不是默认行为：iOS 16 的粘贴提示是应用的
第一印象，应当由应用自己把握。读取之前，SDK 会确认这是本次安装的真正
首次启动、尚未兑换过任何内容、并且剪贴板里像是有 URL（`hasURLs`，
不会触发提示）。它只读取本服务自身形状的交接内容，读后即清除，
第二个应用无法拿到同一条链接。

`AtlasLinks.firstReferringLink()` 永久返回产生这次安装的链接。

## 隐私

SDK 只生成一个安装范围内的随机 id，不读取任何设备或广告标识符：
不读 IDFA，不读 vendor id，不读任何卸载后仍然存在的东西。
这里没有任何部分需要 ATT 提示。随附发送的设备信息
（系统版本、机型、区域、时区、应用版本）是常见的崩溃报告字段，
不指向任何人。
<!-- guide:end -->

## 布局

```
Sources/AppAtlasSDK/include   公开头文件（SPM 的 publicHeadersPath）
Sources/AppAtlasSDK/Core      信封、队列、传输、设备上下文
Sources/AppAtlasSDK/Links     链接模块；UIKit 只在一个文件中触及
```

## 检查

```sh
sh check-core.sh                             # 在 macOS 上运行 Foundation 一半，
                                             # 对 iOS 12 语法检查 UIKit 绑定，
                                             # 检查 Swift 表面，比对黄金字节
ATLAS_SERVER=../app-atlas sh check-core.sh   # 再加服务器的真实解析器
swift build                                  # SPM 清单
```

MIT.
