# Atlas SDK for Apple platforms

[English](README.md) · [中文](README.zh.md)

[App Atlas](https://appatlas.dev)의 iOS·macOS 클라이언트.
Objective-C, Foundation만 쓰는 코어, 의존성 없음. **iOS 12 / macOS 10.13**을
지원하며, 소스로 배포되므로 더 낮은 배포 타깃에서도 빌드됩니다.

## 설치

<!-- tabs:start -->
#### Xcode

1. 프로젝트를 연 채 File > Add Package Dependencies… 를 선택합니다.
2. 검색창에 저장소 주소를 붙여 넣습니다.
3. Dependency Rule은 Up to Next Major Version, 0.3.0을 유지합니다.
4. Add Package를 누르고 AppAtlasSDK 제품을 앱 타깃에 추가합니다.

```
https://github.com/pjy0509/atlas-sdk-apple.git
```

#### Package.swift

```swift
.package(url: "https://github.com/pjy0509/atlas-sdk-apple.git", from: "0.3.0")
```

#### Podfile

```ruby
pod 'AppAtlasSDK'          # Links와 Crash (Core를 함께 가져옵니다)
pod 'AppAtlasSDK/Links'    # 모듈 하나만
pod 'AppAtlasSDK/Core'     # 전송 반쪽만
```

Swift에서는 어느 쪽으로 붙여도 모듈로 읽습니다. `import AppAtlasSDK`에
`use_frameworks!`도 `use_modular_headers!`도 필요하지 않습니다.

<!-- tabs:end -->

<!-- guide:start -->

## 코어

Swift에서는 모듈로 바로 접근합니다. 브리징 헤더는 필요 없습니다.
브리징 헤더는 앱의 소관이지 라이브러리가 강요할 것이 아니기 때문입니다.
SPM은 모듈맵을 생성하고, CocoaPods는 `use_frameworks!` 아래에서 하나를
써 줍니다. Objective-C에서는 언어에 없는 네임스페이스를 `ATL` 접두사가
대신합니다. 이름은 Android·.NET SDK와 같은 이름입니다.

<!-- tabs:start -->
#### Swift

```swift title="AppDelegate.swift"
// AppDelegate.swift
import AppAtlasSDK

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    Atlas.start(withKey: "sdk_…")
    // 모듈(Links, Crash)은 여기서부터 배선합니다.
    return true
}
```

#### Objective-C

```objc title="AppDelegate.m"
// AppDelegate.m
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [Atlas startWithKey:@"sdk_…"];
    // 모듈(Links, Crash)은 여기서부터 배선합니다.
    return YES;
}
```
<!-- tabs:end -->

Info.plist에 키를 선언하는 방법도 있습니다. 이 경우 SDK가 스스로 시작합니다. 네이티브
크래시 훅은 라이브러리 초기화 시점, 즉 `main`보다 먼저 설치되므로 앱 초기화 중의 크래시도
잡히며, 나머지는 메인 큐의 첫 턴에 시작됩니다. `Atlas.start`를 함께 호출해도 무방하며,
두 번째 호출은 무시됩니다. `AtlasBaseURL`은 서버 주소를 바꿉니다.

```xml title="Info.plist"
<!-- Info.plist -->
<key>AtlasSDKKey</key>
<string>sdk_…</string>
```

### 모듈

| 서브스펙 | 역할 | 하한 |
|---|---|---|
| `AppAtlasSDK/Core` | 엔벨로프, 디스크 큐, 전송기. 모든 모듈의 바탕입니다. | iOS 12 / macOS 10.13 |
| `AppAtlasSDK/Links` | 딥링크 유입: 클립보드 인계와 직접 열림. | iOS 12 |
| `AppAtlasSDK/Crash` | 크래시 리포팅: mach 예외, 시그널, 미처리 예외, 행, kill, 세션. | iOS 12 / macOS 10.13 |

`pod 'AppAtlasSDK'`는 Links와 Crash를 함께 가져옵니다. SPM은 모든 모듈이
든 타깃 하나를 배포하며, 앱이 부르지 않는 모듈은 실행 시 비용이 없습니다.

## Links

<!-- tabs:start -->
#### Swift

```swift title="AppDelegate.swift"
// AppDelegate.swift
func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    Atlas.start(withKey: "sdk_…")

    AtlasLinks.setListener { link in
        // 직접 열림과 디퍼드 링크가 같은 자리로 옵니다.
        // link.deferred: 설치를 건너온 링크면 true.
        // link.match: referrer / clipboard / campaign_id / relink.
        // link.path와 link.payload로 화면을 이동합니다. 예:
        // if let path = link.path { openScreen(path, link.payload) }
    }

    return true
}
```

```swift title="AppDelegate.swift"
// 델리게이트의 링크 진입점.
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
        // 직접 열림과 디퍼드 링크가 같은 자리로 옵니다.
        // link.deferred: 설치를 건너온 링크면 true.
        // link.match: referrer / clipboard / campaign_id / relink.
        // link.path와 link.payload로 화면을 이동합니다. 예:
        // if (link.path != nil) { [self openScreen:link.path payload:link.payload]; }
    }];

    return YES;
}
```

```objc title="AppDelegate.m"
// 델리게이트의 링크 진입점.
- (BOOL)application:(UIApplication *)app continueUserActivity:(NSUserActivity *)activity
 restorationHandler:(void (^)(NSArray<id<UIUserActivityRestoring>> *))restorationHandler {
    return [ATLLinks handleUserActivity:activity];
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary *)options {
    return [ATLLinks handleURL:url];
}
```
<!-- tabs:end -->

리스너가 등록되기 전에 도착한 링크는 보관했다가 다시 전달하므로,
콜드 스타트의 탭도 잃지 않습니다.

### 디퍼드 링크

Apple에는 install referrer가 없습니다. 그래서 방문 페이지가 방문자의 탭으로
링크를 클립보드에 넘기고, 앱이 한 번 교환합니다.

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

SDK는 자체 UI를 띄우지 않습니다. OS가 반응하는 것은 읽기 그 자체입니다.
iOS 16부터는 읽는 순간 시스템이 허용/거부 알림을 띄우고, iOS 14와 15는
거부할 수 없는 상단 배너를 표시하며, 그 이전 버전은 아무것도 띄우지
않습니다. 그 순간이 앱의 첫 실행에 걸리기 때문에 호출 여부를 앱이
정합니다. 읽기 전에 SDK는 이번이 이 설치의 진짜 첫 실행인지, 아직
아무것도 교환되지 않았는지, URL이 있을 법한지(`hasURLs`, 알림이 뜨지
않습니다)를 확인하므로 알림은 설치당 최대 한 번입니다. 핸드오프 형태가
아닌 내용은 건드리지도 지우지도 않고, 핸드오프일 때만 교환 후 지워서 두
번째 앱이 같은 링크를 가져가지 못하게 합니다. 거부해도 디퍼드 링크만
소실되고 앱은 정상 동작합니다.

`AtlasLinks.firstReferringLink()`는 설치를 만든 링크를 언제까지나 돌려줍니다.

## Crash

<!-- tabs:start -->
#### Swift

```swift title="AppDelegate.swift"
// AppDelegate.swift
func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    Atlas.start(withKey: "sdk_…")

    // 아래는 선택입니다.
    // 로그인한 사용자를 크래시 옆에 남길 때.
    AtlasCrash.setUserId("u-123")
    // 이슈를 좁힐 축이 필요할 때. 실험 그룹, 서버 환경, 화면.
    AtlasCrash.setKey("screen", value: "checkout")
    // SDK가 모르는 앱 고유의 단계를 남길 때. 화면 전환과 시스템 이벤트는 이미 자동입니다.
    AtlasCrash.leaveBreadcrumb("cart", message: "add")
    // 크래시 직전 코드 경로를 문장으로 남길 때.
    AtlasCrash.log("cart total recomputed")

    return true
}
```

```swift title="CheckoutViewController.swift"
// CheckoutViewController.swift: 오류를 잡았지만 알아 둘 가치가 있는 곳 어디서든.
private func pay() {
    do {
        try cart.charge()
    } catch {
        AtlasCrash.recordError(error)
        // 앱 자체의 복구는 여기에. 예:
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

    // 아래는 선택입니다.
    // 로그인한 사용자를 크래시 옆에 남길 때.
    [ATLCrash setUserId:@"u-123"];
    // 이슈를 좁힐 축이 필요할 때. 실험 그룹, 서버 환경, 화면.
    [ATLCrash setKey:@"screen" value:@"checkout"];
    // SDK가 모르는 앱 고유의 단계를 남길 때. 화면 전환과 시스템 이벤트는 이미 자동입니다.
    [ATLCrash leaveBreadcrumb:@"cart" message:@"add"];
    // 크래시 직전 코드 경로를 문장으로 남길 때.
    [ATLCrash log:@"cart total recomputed"];

    return YES;
}
```

```objc title="CheckoutViewController.m"
// CheckoutViewController.m: 오류를 잡았지만 알아 둘 가치가 있는 곳 어디서든.
- (void)pay {
    NSError *error = nil;

    if (![self.cart chargeWithError:&error]) {
        [ATLCrash recordError:error];
        // 앱 자체의 복구는 여기에. 예:
        // [self showRetry];
    }
}
```
<!-- tabs:end -->

`Atlas.start` 외에 아무 호출 없이 잡히는 것:

| 죽는 방식 | 잡는 방법 |
|---|---|
| 잘못된 메모리 접근, 스택 오버플로, Swift 런타임 트랩(`fatalError`, 강제 언래핑, 범위 밖 인덱스), 어느 스레드든. | 전용 스레드의 mach 예외 서버. 시그널보다 먼저 받습니다. 예비 스레드가 하나 더 있어 핸들러 안에서 난 크래시도 봅니다. |
| `abort()`와 그 밖의 치명 시그널(SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSYS, SIGTRAP, 앱이 무시하지 않는 한 SIGPIPE) | 대체 스택 위의 시그널 핸들러. 기존 핸들러 앞에 체인으로 들어갑니다. |
| 미처리 `NSException`. | 미처리 예외 핸들러. 이전 핸들러 앞에 체인으로 들어갑니다. |
| 메인 스레드 행. | 워치독: 메인 큐가 5초 동안 답하지 않으면 메인 스레드의 프레임과 함께, freeze당 한 번 보고합니다. |
| 메모리 부족 kill, 워치독 kill. | 다음 실행 때 그 실행의 기록으로 추론합니다. 같은 부팅·같은 빌드에서 포그라운드에 활성 상태였고, 크래시 리포트도 정상 종료도 디버거도 없을 때만입니다. |
| OS는 봤지만 프로세스 안에서는 볼 수 없던 것. | MetricKit(iOS 14, macOS 12): 이 SDK가 아무것도 보고하지 않은 기간의 크래시 진단, CPU·디스크 쓰기 예외. |
| 잡히지 않은 C++ 예외. | 런타임이 abort할 때 전파 중이던 예외의 타입을 핸들러에서 읽고 다음 실행 때 디맹글합니다. 이슈는 또 하나의 SIGABRT가 아니라 `std::runtime_error`로 묶이고, `what()`이 메시지에 실립니다. |
| AppKit이 메인 스레드에서 처리해 버린 예외(macOS). | `-[NSApplication reportException:]`을 훅합니다. 예외 자체의 스택과 함께 오류로 기록한 뒤 원래 구현으로 넘깁니다. Info.plist의 `AtlasCrashOnNSException`은 이를 치명적 크래시로 바꾸는 AppKit 자체의 스위치이며, 동작이 달라지므로 앱이 명시적으로 선택합니다. |
| 보호된 파일 디스크립터나 mach 포트의 오용. | mach 서버의 `EXC_GUARD`. 가드 종류별로 이름을 붙입니다. |

크래시 경로는 전부 C이며 async-signal-safe입니다. 할당도 Objective-C도 없고,
메모리는 시작 때 확보하며, 한 줄에 `write()` 한 번입니다. 크래시는 모든
스레드의 프레임, 크래시 스레드의 레지스터, 런타임 자체의 메시지(`__crash_info`:
Swift `fatalError`의 문구, `abort()`의 사유)와 함께 디스크에 기록되고, 다음 실행
때 세션 종료 상태와 함께 전송됩니다. crash-free 세션은 이 세션으로 계산합니다.
모든 리포트에 최근 브레드크럼 100개, 키 64개, `AtlasCrash.log`의 최근 64KB,
그리고 그 순간의 기기 상태가 실립니다. 남은 메모리와 디스크, 프로세스 자신의
footprint와 jetsam까지 남은 여유, 발열·저전력 상태, 포그라운드 여부입니다. 시스템
라이브러리의 프레임은 다음 실행 때 다시 로드된 같은 라이브러리에서 심볼 이름을 찾아 붙이므로,
dSYM으로는 풀 수 없는 프레임도 `abort`와 `objc_msgSend`처럼 읽힙니다. 시작 후 5초 안에 난
크래시는 다음 실행에서 가장 먼저 전송됩니다.

SDK가 자동으로 남기는 브레드크럼도 있습니다. 모두 노티피케이션 기반이며 권한이 필요하지
않습니다. 앱의 active, inactive, background, foreground 전환, 메모리 경고와 커널의 메모리
압박 단계(OOM kill의 사유에도 기록됩니다), 방향, 키보드, 스크린샷, 씬과 윈도우 변화, 발열과
저전력 변화, 시간대와 시계 변경이 해당하며, macOS에서는 앱의 숨김과 표시, 윈도우 변화가
더해집니다.

디버거가 붙어 있으면 네이티브 훅은 설치하지 않습니다. LLDB와 mach 예외 서버는
포트 하나를 나눠 쓸 수 없기 때문이며, 콘솔에 한 번 알립니다. 처리된 오류, 세션,
컨텍스트는 그대로 동작합니다. SwiftUI 프리뷰는 실행으로 세지 않습니다.

`AtlasCrash.setEnabled(false)`는 수집을 멈추고 그 선택을 기억합니다. 동의 화면에
씁니다. `AtlasCrash.crashedLastRun()`은 직전 실행이 크래시, 행 kill, 메모리 부족
kill로 끝났는지 알려 줍니다.

### 읽을 수 있는 스택 트레이스 (dSYM)

네이티브 프레임은 이미지의 UUID와 이미지 상대 주소로 보고됩니다. 그 dSYM이 푸는
것이 정확히 그것입니다. 빌드마다 dSYM 안의 DWARF 파일을 올리면 서버가 함수,
파일, 행으로 복원합니다. 앱과 모든 프레임워크의 것을 같이 올립니다.
인라인된 프레임까지입니다.
UUID는 파일에서 읽으므로 파일만 올리면 됩니다. 릴리스가 사용자에게 닿기 전에
올립니다. 주소로 묶인 크래시는 별개의 이슈로 남습니다.

```sh title="upload-dsyms.sh"
# CI, 아카이브 다음. 아카이브의 dSYM마다 한 번(앱과 프레임워크 각각).
# ATLAS_API_TOKEN은 App Atlas API 액세스 토큰이며 SDK 키가 아닙니다.
for dwarf in "$ARCHIVE_PATH"/dSYMs/*.dSYM/Contents/Resources/DWARF/*; do
  curl --fail -X POST \
    "https://appatlas.dev/api/ingest/symbols?store=app-store&appId=$BUNDLE_ID&kind=macho" \
    -H "Authorization: Bearer $ATLAS_API_TOKEN" \
    --data-binary "@$dwarf"
done
```

비트코드로 재컴파일된 빌드의 dSYM은 처리 후 App Store Connect에서 받습니다.
같은 방법으로 올립니다.

## 프라이버시

SDK는 설치 단위의 난수 id 하나를 만들 뿐, 기기 식별자나 광고 식별자를 읽지
않습니다. IDFA도, 벤더 id도, 삭제 후에 남는 어떤 것도 읽지 않습니다.
여기의 어떤 것도 ATT 프롬프트를 요구하지 않습니다. 함께 보내는 기기
정보(OS 버전, 모델, 로캘, 시간대, 앱 버전)는 일반적인 크래시 리포트
항목이며 누구도 특정하지 않습니다.

<!-- guide:end -->

## 구조

```
Sources/AppAtlasSDK/include   공개 헤더 (SPM의 publicHeadersPath)
Sources/AppAtlasSDK/Core      엔벨로프, 큐, 전송, 기기 컨텍스트
Sources/AppAtlasSDK/Links     링크 모듈; UIKit은 한 파일에서만 닿습니다
Sources/AppAtlasSDK/Crash     크래시 모듈; 캡처 코어는 C, MetricKit은 이름으로 로드합니다
```

## 검사

```sh
sh check-core.sh                             # macOS에서 Foundation 반쪽 실행,
                                             # 자기 자신을 victim으로 띄워 크래시 훅이
                                             # 잡는 방식마다 죽여 보고, iOS 12용 UIKit
                                             # 바인딩 문법 검사, Swift 표면 검사,
                                             # 골든 바이트 비교
ATLAS_SERVER=../app-atlas sh check-core.sh   # 서버의 실제 파서까지
swift build                                  # SPM 매니페스트
```

MIT.
