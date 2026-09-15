# Atlas SDK for Apple platforms

The client half of [App Atlas](https://appatlas.dev) on iOS and macOS.
Objective-C, Foundation-only core, no dependencies. **iOS 12 / macOS 10.13**,
distributed as source so a lower deployment target stays buildable.

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/pjy0509/atlas-sdk-apple.git", from: "0.1.0")
```

CocoaPods:

```ruby
pod 'AppAtlasSDK'          # Links (pulls Core)
pod 'AppAtlasSDK/Core'     # the transport half alone
```

## Use

```objc
// application:didFinishLaunchingWithOptions:
[Atlas startWithKey:@"sdk_…"];

[ATLLinks setListener:^(ATLLink *link) {
    // link.payload / link.path / link.deferred / link.match
    // link.channel / link.campaign / link.shortId
}];
```

```objc
// The delegate's link entry points.
- (BOOL)application:(UIApplication *)app continueUserActivity:(NSUserActivity *)activity
 restorationHandler:(void (^)(NSArray<id<UIUserActivityRestoring>> *))restorationHandler {
    return [ATLLinks handleUserActivity:activity];
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary *)options {
    return [ATLLinks handleOpenURL:url];
}
```

A link that arrives before the listener is registered is queued and replayed,
so a cold-start tap is never lost.

## The deferred link

Apple offers no install referrer, so the visit page hands the link over through
the clipboard — with the visitor's own tap — and the app claims it once:

```objc
[ATLLinks checkPasteboardOnFirstLaunch];
```

It is a call you make, not a default, because the iOS 16 paste banner is your
app's first impression to own. Before reading, the SDK checks that this is the
install's own first run, that nothing has been claimed yet, and that a URL is
plausibly present (`hasURLs`, which shows no prompt). It reads only a handoff
of this service's own shape, and clears it afterwards so a second app cannot
claim the same link.

`[ATLLinks firstReferringLink]` returns the link that produced the install,
forever.

## Privacy

The SDK mints an install-scoped random id and reads no device or advertising
identifier — not the IDFA, not the vendor id, nothing that survives an
uninstall. No ATT prompt is required by anything here. Device context (OS
version, model, locale, timezone, app version) is the standard crash-report set
and identifies no one.

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
                                             # and compares the golden bytes
ATLAS_SERVER=../app-atlas sh check-core.sh   # and the server's own parser
swift build                                  # the SPM manifest
```

MIT.
