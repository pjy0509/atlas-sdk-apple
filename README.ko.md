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
3. Dependency Rule은 Up to Next Major Version, 0.1.0을 유지합니다.
4. Add Package를 누르고 AppAtlasSDK 제품을 앱 타깃에 추가합니다.

```
https://github.com/pjy0509/atlas-sdk-apple.git
```

#### Package.swift

```swift
.package(url: "https://github.com/pjy0509/atlas-sdk-apple.git", from: "0.1.0")
```

#### Podfile

```ruby
pod 'AppAtlasSDK'          # Links (Core를 함께 가져옵니다)
pod 'AppAtlasSDK/Core'     # 전송 반쪽만
```
<!-- tabs:end -->

<!-- guide:start -->
## 사용

Swift에서는 모듈로 바로 접근합니다. 브리징 헤더는 필요 없습니다.
브리징 헤더는 앱의 소관이지 라이브러리가 강요할 것이 아니기 때문입니다.
SPM은 모듈맵을 생성하고, CocoaPods는 `use_frameworks!` 아래에서 하나를
써 줍니다. Objective-C에서는 언어에 없는 네임스페이스를 `ATL` 접두사가
대신합니다. 이름은 Android·.NET SDK와 같은 이름입니다.

<!-- tabs:start -->
#### Swift

```swift
// AppDelegate.swift
import AppAtlasSDK

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

```objc
// application:didFinishLaunchingWithOptions:
[Atlas startWithKey:@"sdk_…"];

[ATLLinks setListener:^(ATLLink *link) {
    // link.payload / link.path / link.deferred / link.match
    // link.channel / link.campaign / link.shortId
}];
```

```objc
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

## 디퍼드 링크

Apple에는 install referrer가 없습니다. 그래서 방문 페이지가 방문자의 탭으로
링크를 클립보드에 넘기고, 앱이 한 번 교환합니다.

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

기본 동작이 아니라 앱이 직접 부르는 호출입니다. iOS 16의 붙여넣기 배너는
앱의 첫인상이고, 그것은 앱이 스스로 결정할 몫이기 때문입니다. 읽기 전에
SDK는 이번이 이 설치의 진짜 첫 실행인지, 아직 아무것도 교환되지 않았는지,
URL이 있을 법한지(`hasURLs`, 프롬프트를 띄우지 않습니다)를 확인합니다.
이 서비스의 형태를 한 핸드오프만 읽고, 읽은 뒤에는 지워서 두 번째 앱이
같은 링크를 가져가지 못하게 합니다.

`AtlasLinks.firstReferringLink()`는 설치를 만든 링크를 언제까지나 돌려줍니다.

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
```

## 검사

```sh
sh check-core.sh                             # macOS에서 Foundation 반쪽 실행,
                                             # iOS 12용 UIKit 바인딩 문법 검사,
                                             # Swift 표면 검사, 골든 바이트 비교
ATLAS_SERVER=../app-atlas sh check-core.sh   # 서버의 실제 파서까지
swift build                                  # SPM 매니페스트
```

MIT.
