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
3. Dependency Rule 保持 Up to Next Major Version，从 0.2.0 起。
4. 点击 Add Package，把 AppAtlasSDK 产品添加到应用目标。

```
https://github.com/pjy0509/atlas-sdk-apple.git
```

#### Package.swift

```swift
.package(url: "https://github.com/pjy0509/atlas-sdk-apple.git", from: "0.2.0")
```

#### Podfile

```ruby
pod 'AppAtlasSDK'          # Links 与 Crash（会一并引入 Core）
pod 'AppAtlasSDK/Links'    # 仅一个模块
pod 'AppAtlasSDK/Core'     # 仅传输那一半
```
<!-- tabs:end -->

<!-- guide:start -->

## 核心

Swift 直接以模块访问，无需桥接头文件。桥接头文件是应用自己的事，
库不应替它做主。SPM 会生成模块映射；CocoaPods 在 `use_frameworks!`
下也会写一份。Objective-C 中，`ATL` 前缀代替了这门语言没有的命名空间。
名字与 Android、.NET SDK 一致。

<!-- tabs:start -->
#### Swift

```swift title="AppDelegate.swift"
// AppDelegate.swift
import AppAtlasSDK

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    Atlas.start(withKey: "sdk_…")
    // 各模块（Links、Crash）从这里开始接线。
    return true
}
```

#### Objective-C

```objc title="AppDelegate.m"
// AppDelegate.m
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [Atlas startWithKey:@"sdk_…"];
    // 各模块（Links、Crash）从这里开始接线。
    return YES;
}
```
<!-- tabs:end -->

### 模块

| Subspec | 作用 | 下限 |
|---|---|---|
| `AppAtlasSDK/Core` | 信封、磁盘队列、发送器。所有模块的基础。 | iOS 12 / macOS 10.13 |
| `AppAtlasSDK/Links` | 深层链接流入：剪贴板交接与直接打开。 | iOS 12 |
| `AppAtlasSDK/Crash` | 崩溃报告：mach 异常、信号、未捕获异常、卡死、kill、会话。 | iOS 12 / macOS 10.13 |

`pod 'AppAtlasSDK'` 会一并引入 Links 与 Crash；SPM 发布的是包含全部模块的
一个 target，应用不调用的模块在运行时没有开销。

## Links

<!-- tabs:start -->
#### Swift

```swift title="AppDelegate.swift"
// AppDelegate.swift
func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    Atlas.start(withKey: "sdk_…")

    AtlasLinks.setListener { link in
        // 直接打开与延迟链接都到达这里。
        // link.deferred: 跨越了安装的链接为 true。
        // link.match: referrer / clipboard / campaign_id / relink。
        // 用 link.path 与 link.payload 做页面跳转，例如：
        // if let path = link.path { openScreen(path, link.payload) }
    }

    return true
}
```

```swift title="AppDelegate.swift"
// 代理中的链接入口。
func application(_ app: UIApplication, open url: URL,
                 options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    return AtlasLinks.handle(url)
}

func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                 restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    return AtlasLinks.handle(userActivity: userActivity)
}
```

#### Objective-C

```objc title="AppDelegate.m"
// AppDelegate.m
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [Atlas startWithKey:@"sdk_…"];

    [ATLLinks setListener:^(ATLLink *link) {
        // 直接打开与延迟链接都到达这里。
        // link.deferred: 跨越了安装的链接为 true。
        // link.match: referrer / clipboard / campaign_id / relink。
        // 用 link.path 与 link.payload 做页面跳转，例如：
        // if (link.path != nil) { [self openScreen:link.path payload:link.payload]; }
    }];

    return YES;
}
```

```objc title="AppDelegate.m"
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

### 延迟链接

Apple 没有 install referrer，因此访问页面借访客自己的点击把链接放进
剪贴板，应用兑换一次：

<!-- tabs:start -->
#### Swift

```swift title="AppDelegate.swift"
// AppDelegate.swift
func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    Atlas.start(withKey: "sdk_…")
    AtlasLinks.setListener { link in /* … */ }

    AtlasLinks.checkPasteboardOnFirstLaunch()

    return true
}
```

#### Objective-C

```objc title="AppDelegate.m"
// AppDelegate.m
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [Atlas startWithKey:@"sdk_…"];
    [ATLLinks setListener:^(ATLLink *link) { /* … */ }];

    [ATLLinks checkPasteboardOnFirstLaunch];

    return YES;
}
```
<!-- tabs:end -->

SDK 不会显示任何自己的界面。操作系统响应的是读取这个动作本身：
iOS 16 起，读取时系统会弹出允许或拒绝的粘贴提示；iOS 14 与 15 显示
无法拒绝的顶部横幅；更早的版本没有任何提示。那一刻落在应用的首次启动，
因此是否调用由应用决定。读取之前，SDK 会确认这是本次安装的真正首次
启动、尚未兑换过任何内容、并且剪贴板里像是有 URL（`hasURLs`，不会触发
提示），所以提示每次安装最多出现一次。不是本服务交接形状的内容不改动
也不清除；只有交接内容才会兑换并清除，第二个应用无法拿到同一条链接。
拒绝也只会失去延迟链接，应用照常运行。

`AtlasLinks.firstReferringLink()` 永久返回产生这次安装的链接。

## Crash

<!-- tabs:start -->
#### Swift

```swift title="AppDelegate.swift"
// AppDelegate.swift
func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    Atlas.start(withKey: "sdk_…")
    // 从这一行起，崩溃、卡死与 kill 都会被捕获。其余均为可选。

    // 你方的已登录用户 id，以及值得与崩溃一起查看的状态。
    AtlasCrash.setUserId("u-123")
    AtlasCrash.setKey("screen", value: "checkout")
    AtlasCrash.leaveBreadcrumb("cart", message: "add")
    AtlasCrash.log("cart total recomputed")

    return true
}
```

```swift title="CheckoutViewController.swift"
// CheckoutViewController.swift：任何捕获了错误却仍值得知晓的地方。
private func pay() {
    do {
        try cart.charge()
    } catch {
        AtlasCrash.recordError(error)
        // 应用自身的恢复逻辑放在这里。例如：
        // showRetry()
    }
}
```

#### Objective-C

```objc title="AppDelegate.m"
// AppDelegate.m
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [Atlas startWithKey:@"sdk_…"];
    // 从这一行起，崩溃、卡死与 kill 都会被捕获。其余均为可选。

    // 你方的已登录用户 id，以及值得与崩溃一起查看的状态。
    [ATLCrash setUserId:@"u-123"];
    [ATLCrash setKey:@"screen" value:@"checkout"];
    [ATLCrash leaveBreadcrumb:@"cart" message:@"add"];
    [ATLCrash log:@"cart total recomputed"];

    return YES;
}
```

```objc title="CheckoutViewController.m"
// CheckoutViewController.m：任何捕获了错误却仍值得知晓的地方。
- (void)pay {
    NSError *error = nil;

    if (![self.cart chargeWithError:&error]) {
        [ATLCrash recordError:error];
        // 应用自身的恢复逻辑放在这里。例如：
        // [self showRetry];
    }
}
```
<!-- tabs:end -->

除 `Atlas.start` 外无需任何调用即可捕获：

| 死亡方式 | 捕获方式 |
|---|---|
| 非法内存访问、栈溢出、Swift 运行时陷阱（`fatalError`、强制解包、下标越界），任意线程 | 独立线程上的 mach 异常服务器，先于任何信号；另有一条备用线程，处理器内部的崩溃也能看到 |
| `abort()` 与其他致命信号（SIGABRT、SIGBUS、SIGFPE、SIGILL、SIGSYS、SIGTRAP，以及应用未忽略时的 SIGPIPE） | 备用栈上的信号处理器，链接在原有处理器之前 |
| 未捕获的 `NSException` | 未捕获异常处理器，链接在原有处理器之前 |
| 主线程卡死 | 看门狗：主队列 5 秒无应答即上报，附主线程帧，每次冻结一次 |
| 内存不足 kill、看门狗 kill | 下次启动时由该次运行的自身记录推断——仅当应用在同一次开机、同一构建下处于前台活跃状态，且无崩溃报告、无正常退出、无调试器时 |
| 系统看到而进程内无法看到的 | MetricKit（iOS 14、macOS 12）：本 SDK 未上报任何内容的时间窗内的崩溃诊断，以及 CPU、磁盘写入异常 |

崩溃路径全部为 C 且 async-signal-safe：不分配内存、不触及 Objective-C，内存在启动时
预留，每行一次 `write()`。崩溃连同所有线程的帧、崩溃线程的寄存器、运行时自身的
消息（`__crash_info`：Swift `fatalError` 的文字、`abort()` 的原因）写入磁盘，并在下次
启动时与其会话的结束一起发送——crash-free 会话正是据此统计。每份报告携带最近 100 条
面包屑、至多 64 个键、`AtlasCrash.log` 最新的 64 KB，以及那一刻的设备状态：剩余内存与
磁盘、热状态与低电量模式、是否在前台。启动后 5 秒内的崩溃会在下次启动时最先发送。

连接调试器时不安装原生钩子——LLDB 与 mach 异常服务器无法共用一个端口——控制台会
提示一次；已处理错误、会话与上下文照常工作。SwiftUI 预览不计为运行。

`AtlasCrash.setEnabled(false)` 停止收集并记住该选择，用于同意界面。
`AtlasCrash.crashedLastRun()` 告知上一次运行是否以崩溃、卡死 kill 或内存不足 kill 结束。

### 可读的堆栈跟踪（dSYM）

原生帧以镜像的 UUID 加相对镜像的地址上报，这正是其 dSYM 所解析的内容。上传每个构建
dSYM 内的 DWARF 文件——应用与每个框架的——服务器即可还原函数、文件与行号，包括内联帧。
UUID 从文件中读取，因此只需上传文件。在发布触达用户之前上传：按地址分组的崩溃会作为
单独的问题留存。

```sh title="upload-dsyms.sh"
# CI，归档之后：归档中的每个 dSYM 各调用一次（应用与各框架）。
# ATLAS_API_TOKEN 是 App Atlas API 访问令牌，绝不是 SDK 密钥。
for dwarf in "$ARCHIVE_PATH"/dSYMs/*.dSYM/Contents/Resources/DWARF/*; do
  curl --fail -X POST \
    "https://appatlas.dev/api/ingest/symbols?store=app-store&appId=$BUNDLE_ID&kind=macho" \
    -H "Authorization: Bearer $ATLAS_API_TOKEN" \
    --data-binary "@$dwarf"
done
```

经 bitcode 重新编译的构建，其 dSYM 在处理完成后从 App Store Connect 获取，以同样方式上传。

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
Sources/AppAtlasSDK/Crash     崩溃模块；捕获核心为 C，MetricKit 按名称加载
```

## 检查

```sh
sh check-core.sh                             # 在 macOS 上运行 Foundation 一半，
                                             # 把自身作为受害进程按崩溃钩子能捕获的
                                             # 每种方式杀死，对 iOS 12 语法检查 UIKit
                                             # 绑定，检查 Swift 表面，比对黄金字节
ATLAS_SERVER=../app-atlas sh check-core.sh   # 再加服务器的真实解析器
swift build                                  # SPM 清单
```

MIT.
