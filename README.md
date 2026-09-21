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
3. Keep the dependency rule Up to Next Major Version, from 0.3.0.
4. Press Add Package, then add the AppAtlasSDK product to the app target.

```
https://github.com/pjy0509/atlas-sdk-apple.git
```

#### Package.swift

```swift
.package(url: "https://github.com/pjy0509/atlas-sdk-apple.git", from: "0.3.0")
```

#### Podfile

```ruby
pod 'AppAtlasSDK'          # Links and Crash (pull Core)
pod 'AppAtlasSDK/Links'    # one module alone
pod 'AppAtlasSDK/Core'     # the transport half alone
```
<!-- tabs:end -->

<!-- guide:start -->

## Core

Swift reaches this as a module, with no bridging header. A bridging header is
an app's own business and never a library's. SPM generates the module map; CocoaPods writes
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
    // Modules (Links, Crash) wire in from here.
    return true
}
```

#### Objective-C

```objc title="AppDelegate.m"
// AppDelegate.m
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [Atlas startWithKey:@"sdk_…"];
    // Modules (Links, Crash) wire in from here.
    return YES;
}
```
<!-- tabs:end -->

The key may also be declared in the Info.plist, and the SDK starts itself.
The native crash hooks go in before `main` runs, from a library initializer, so a
crash in the app's own startup is already caught; the rest starts on the main
queue's first turn. An app that also calls `Atlas.start` loses nothing, a second
start is a no-op. `AtlasBaseURL` overrides the server.

```xml title="Info.plist"
<!-- Info.plist -->
<key>AtlasSDKKey</key>
<string>sdk_…</string>
```

### Modules

| Subspec | What it is | Floor |
|---|---|---|
| `AppAtlasSDK/Core` | Envelopes, the disk queue, the sender. Every module rides it. | iOS 12 / macOS 10.13 |
| `AppAtlasSDK/Links` | Deep-link inflow: the clipboard handoff and direct opens. | iOS 12 |
| `AppAtlasSDK/Crash` | Crash reporting: mach exceptions, signals, uncaught exceptions, hangs, kills, sessions. | iOS 12 / macOS 10.13 |

`pod 'AppAtlasSDK'` brings Links and Crash; SPM ships the one target with
every module in it, and a module the app never calls costs nothing at run time.

## Links

<!-- tabs:start -->
#### Swift

```swift title="AppDelegate.swift"
// AppDelegate.swift
func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    Atlas.start(withKey: "sdk_…")

    AtlasLinks.setListener { link in
        // Direct opens and the deferred link arrive here alike.
        // link.deferred: true when the link crossed the install.
        // link.match: referrer / clipboard / campaign_id / relink.
        // Route with link.path and link.payload, e.g.:
        // if let path = link.path { openScreen(path, link.payload) }
    }

    return true
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
// AppDelegate.m
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [Atlas startWithKey:@"sdk_…"];

    [ATLLinks setListener:^(ATLLink *link) {
        // Direct opens and the deferred link arrive here alike.
        // link.deferred: true when the link crossed the install.
        // link.match: referrer / clipboard / campaign_id / relink.
        // Route with link.path and link.payload, e.g.:
        // if (link.path != nil) { [self openScreen:link.path payload:link.payload]; }
    }];

    return YES;
}
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

### The deferred link

Apple offers no install referrer, so the visit page hands the link over through
the clipboard, with the visitor's own tap, and the app claims it once:

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

The SDK shows no UI of its own. The read itself is what the OS answers to:
on iOS 16 and later the system raises an allow-or-deny paste alert, iOS 14
and 15 show a banner that cannot be declined, and earlier versions show
nothing. That moment lands on your app's first launch, which is why the call
is yours to make. Before reading, the SDK checks that this is the install's
own first run, that nothing has been claimed yet, and that a URL is plausibly
present (`hasURLs`, which raises no alert), so the alert can appear at most
once per install. Content that is not this service's handoff is left
untouched and uncleared; the handoff alone is claimed and then cleared, so a
second app cannot take the same link. A decline loses only the deferred link;
the app keeps working.

`AtlasLinks.firstReferringLink()` returns the link that produced the install,
forever.

## Crash

<!-- tabs:start -->
#### Swift

```swift title="AppDelegate.swift"
// AppDelegate.swift
func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    Atlas.start(withKey: "sdk_…")
    // Crashes, hangs and kills are caught from this line on. The rest is optional.

    // Your own id for the signed-in user, and the state worth seeing beside a crash.
    AtlasCrash.setUserId("u-123")
    AtlasCrash.setKey("screen", value: "checkout")
    AtlasCrash.leaveBreadcrumb("cart", message: "add")
    AtlasCrash.log("cart total recomputed")

    return true
}
```

```swift title="CheckoutViewController.swift"
// CheckoutViewController.swift: anywhere an error is caught but still worth knowing about.
private func pay() {
    do {
        try cart.charge()
    } catch {
        AtlasCrash.recordError(error)
        // The app's own recovery goes here. Example:
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
    // Crashes, hangs and kills are caught from this line on. The rest is optional.

    // Your own id for the signed-in user, and the state worth seeing beside a crash.
    [ATLCrash setUserId:@"u-123"];
    [ATLCrash setKey:@"screen" value:@"checkout"];
    [ATLCrash leaveBreadcrumb:@"cart" message:@"add"];
    [ATLCrash log:@"cart total recomputed"];

    return YES;
}
```

```objc title="CheckoutViewController.m"
// CheckoutViewController.m: anywhere an error is caught but still worth knowing about.
- (void)pay {
    NSError *error = nil;

    if (![self.cart chargeWithError:&error]) {
        [ATLCrash recordError:error];
        // The app's own recovery goes here. Example:
        // [self showRetry];
    }
}
```
<!-- tabs:end -->

What is caught, with no call beyond `Atlas.start`:

| Death | How it is caught |
|---|---|
| A bad memory access, a stack overflow, a Swift runtime trap (`fatalError`, a force-unwrap, an index out of range), on any thread. | A mach exception server on a thread of its own, ahead of any signal, with a spare thread so a crash inside the handler is seen too. |
| `abort()` and the other fatal signals (SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSYS, SIGTRAP, SIGPIPE unless the app ignores it) | Signal handlers on an alternate stack, chained ahead of whoever held them. |
| An uncaught `NSException`. | The uncaught-exception handler, chained ahead of the previous one. |
| A main-thread hang. | A watchdog: five seconds without an answer from the main queue, reported with the main thread's frames, once per freeze. |
| An out-of-memory kill, a watchdog kill. | Inferred at the next start from the run's own record, only when the app was active in the foreground on the same boot and build, with no crash report, no clean exit and no debugger. |
| What the OS saw and nothing in-process could. | MetricKit (iOS 14, macOS 12): crash diagnostics for a window this SDK reported nothing in, CPU and disk-write exceptions. |
| An uncaught C++ exception. | The type in flight when the runtime aborts is read in the handler and demangled at the next start: the issue is `std::runtime_error`, not another SIGABRT, and `what()` rides the message. |
| An exception AppKit caught on the main thread (macOS). | `-[NSApplication reportException:]`, hooked: recorded as an error with the exception's own stack, then passed through. `AtlasCrashOnNSException` in the Info.plist makes them fatal instead, which is AppKit's own switch and a choice the app makes. |
| A guarded file descriptor or mach port misused. | `EXC_GUARD` on the mach server, named by guard type. |

Everything on the crash path is C and async-signal-safe: no allocation, no
Objective-C, memory reserved at start, one `write()` per line. A crash is
written to disk with every thread's frames, the crashed thread's registers and
the runtime's own message (`__crash_info`: the text of a Swift `fatalError`,
the reason of an `abort()`), and sent at the next start together with the end
of its session, which is what crash-free sessions are counted from. Every
report carries the last 100 breadcrumbs, up to 64 keys, the newest 64 KB of
`AtlasCrash.log` lines, and the device's state at that moment: free memory
and disk, the process's own footprint and how much more jetsam would allow,
thermal and low-power state, whether it was in the foreground. The frames of
the system's own libraries are named at the next start, from the same
libraries loaded again, so a report reads `abort` and `objc_msgSend` where a
dSYM could never help. A crash within five seconds of start is sent first
thing at the next start.

Breadcrumbs the SDK leaves on its own, all from notifications and none
needing a permission: the app going active, inactive, background and
foreground, memory warnings and the kernel's own memory-pressure levels
(which also name the reason of an out-of-memory kill), orientation, the
keyboard, screenshots, scene and window changes, thermal and low-power
changes, time-zone and clock changes; on macOS the app hiding and showing and
its windows changing.

Under a debugger the native hooks stay uninstalled, because LLDB and a mach
exception server cannot share a port, and the console says so once. Handled
errors, sessions and context still work. SwiftUI previews are not counted as runs.

`AtlasCrash.setEnabled(false)` stops collection and remembers the choice, for a
consent screen. `AtlasCrash.crashedLastRun()` says whether the previous run
ended in a crash, a hang kill or an out-of-memory kill.

### Readable stack traces (dSYM)

A native frame is reported as the image's UUID plus an address relative to the
image, which is exactly what its dSYM resolves. Upload the DWARF file inside
each build's dSYM, the app's and every framework's, and the server resolves
function, file and line, inlined frames included. The UUID is read from the
file, so only the file is needed. Upload before the release reaches users: a
crash grouped by address stays a separate issue.

```sh title="upload-dsyms.sh"
# CI, after archiving: one call per dSYM in the archive (the app's and each framework's).
# ATLAS_API_TOKEN is an App Atlas API access token, never the SDK key.
for dwarf in "$ARCHIVE_PATH"/dSYMs/*.dSYM/Contents/Resources/DWARF/*; do
  curl --fail -X POST \
    "https://appatlas.dev/api/ingest/symbols?store=app-store&appId=$BUNDLE_ID&kind=macho" \
    -H "Authorization: Bearer $ATLAS_API_TOKEN" \
    --data-binary "@$dwarf"
done
```

Bitcode-recompiled builds get their dSYMs from App Store Connect after
processing; upload those the same way.

## Privacy

The SDK mints an install-scoped random id and reads no device or advertising
identifier: not the IDFA, not the vendor id, nothing that survives an
uninstall. No ATT prompt is required by anything here. Device context (OS
version, model, locale, timezone, app version) is the standard crash-report set
and identifies no one.

<!-- guide:end -->

## Layout

```
Sources/AppAtlasSDK/include   public headers (SPM's publicHeadersPath)
Sources/AppAtlasSDK/Core      envelopes, queue, transport, device context
Sources/AppAtlasSDK/Links     the links module; UIKit is touched in one file
Sources/AppAtlasSDK/Crash     the crash module; the capture core is C, MetricKit is loaded by name
```

## Checks

```sh
sh check-core.sh                             # runs the Foundation half on macOS,
                                             # spawns itself as a victim and dies every
                                             # way the crash hooks catch, syntax-checks
                                             # the UIKit binding for iOS 12, checks the
                                             # Swift surface, and compares the golden bytes
ATLAS_SERVER=../app-atlas sh check-core.sh   # and the server's own parser
swift build                                  # the SPM manifest
```

MIT.
