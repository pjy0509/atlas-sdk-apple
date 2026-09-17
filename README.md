# Atlas SDK for Apple platforms

[한국어](README.ko.md) · [中文](README.zh.md)

The client half of [App Atlas](https://appatlas.dev) on iOS and macOS.
Objective-C, Foundation-only core, no dependencies. **iOS 12 / macOS 10.13**,
distributed as source so a lower deployment target stays buildable.

## Install

<!-- tabs:start -->
#### Xcode

1. Open the project and choose File > Add Package Dependencies…
2. Paste the repository address into the search field.
3. Keep the dependency rule Up to Next Major Version, from 0.1.0.
4. Press Add Package, then add the AppAtlasSDK product to the app target.

```
https://github.com/pjy0509/atlas-sdk-apple.git
```

#### Package.swift

```swift
.package(url: "https://github.com/pjy0509/atlas-sdk-apple.git", from: "0.1.0")
```

#### Podfile

```ruby
pod 'AppAtlasSDK'          # Links (pulls Core)
pod 'AppAtlasSDK/Core'     # the transport half alone
```
<!-- tabs:end -->

<!-- guide:start -->
## Start

Swift reaches this as a module — no bridging header, which is an app's own
business and never a library's. SPM generates the module map; CocoaPods writes
one under `use_frameworks!`. In Objective-C the `ATL` prefix stands in for the
namespace the language does not have. The names are the ones the Android and
.NET SDKs use.

<!-- tabs:start -->
#### Swift

```swift title="AppDelegate.swift"
// AppDelegate.swift
import AppAtlasSDK

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    Atlas.start(withKey: "sdk_…")
    // Modules (Links, later Push and Crash) wire in from here.
    return true
}
```

#### Objective-C

```objc title="AppDelegate.m"
// AppDelegate.m
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [Atlas startWithKey:@"sdk_…"];
    // Modules (Links, later Push and Crash) wire in from here.
    return YES;
}
```
<!-- tabs:end -->

## Links

<!-- tabs:start -->
#### Swift

```swift title="AppDelegate.swift"
// AppDelegate.swift: right after Atlas.start.
AtlasLinks.setListener { link in
    // Direct opens and the deferred link arrive here alike.
    // link.deferred: true when the link crossed the install.
    // link.match: referrer / clipboard / campaign_id / relink.
    // Route with link.path and link.payload, e.g.:
    // if let path = link.path { openScreen(path, link.payload) }
}
```

```swift title="AppDelegate.swift"
// The delegate's link entry points.
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
// AppDelegate.m: right after startWithKey:.
[ATLLinks setListener:^(ATLLink *link) {
    // Direct opens and the deferred link arrive here alike.
    // link.deferred: true when the link crossed the install.
    // link.match: referrer / clipboard / campaign_id / relink.
    // Route with link.path and link.payload, e.g.:
    // if (link.path != nil) { [self openScreen:link.path payload:link.payload]; }
}];
```

```objc title="AppDelegate.m"
// The delegate's link entry points.
- (BOOL)application:(UIApplication *)app continueUserActivity:(NSUserActivity *)activity
 restorationHandler:(void (^)(NSArray<id<UIUserActivityRestoring>> *))restorationHandler {
    return [ATLLinks handleUserActivity:activity];
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary *)options {
    return [ATLLinks handleURL:url];
}
```
<!-- tabs:end -->

A link that arrives before the listener is registered is queued and replayed,
so a cold-start tap is never lost.

## The deferred link

Apple offers no install referrer, so the visit page hands the link over through
the clipboard — with the visitor's own tap — and the app claims it once:

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

It is a call you make, not a default, because the iOS 16 paste banner is your
app's first impression to own. Before reading, the SDK checks that this is the
install's own first run, that nothing has been claimed yet, and that a URL is
plausibly present (`hasURLs`, which shows no prompt). It reads only a handoff
of this service's own shape, and clears it afterwards so a second app cannot
claim the same link.

`AtlasLinks.firstReferringLink()` returns the link that produced the install,
forever.

## Privacy

The SDK mints an install-scoped random id and reads no device or advertising
identifier — not the IDFA, not the vendor id, nothing that survives an
uninstall. No ATT prompt is required by anything here. Device context (OS
version, model, locale, timezone, app version) is the standard crash-report set
and identifies no one.
<!-- guide:end -->

## Layout

```
Sources/AppAtlasSDK/include   public headers (SPM's publicHeadersPath)
Sources/AppAtlasSDK/Core      envelopes, queue, transport, device context
Sources/AppAtlasSDK/Links     the links module; UIKit is touched in one file
```

## Checks

```sh
sh check-core.sh                             # runs the Foundation half on macOS,
                                             # syntax-checks the UIKit binding for iOS 12,
                                             # checks the Swift surface, and compares
                                             # the golden bytes
ATLAS_SERVER=../app-atlas sh check-core.sh   # and the server's own parser
swift build                                  # the SPM manifest
```

MIT.
