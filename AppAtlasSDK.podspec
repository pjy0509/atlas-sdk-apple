Pod::Spec.new do |s|
  s.name             = 'AppAtlasSDK'
  s.version          = '0.3.0'
  s.summary          = 'App Atlas SDK for iOS and macOS: deep-link inflow, crash reporting and telemetry.'
  s.description      = <<-DESC
    The client half of App Atlas. Links: deferred deep links claimed from a
    consented clipboard handoff, direct opens handed in from the app delegate,
    one listener for both. Crash: mach exceptions, signals, uncaught
    NSExceptions and Swift traps captured in async-signal-safe C, main-thread
    hangs, out-of-memory and watchdog kills inferred at the next start,
    MetricKit diagnostics on iOS 14+, dSYM symbolication on the server.
    Objective-C, Foundation-only core, no dependencies.
  DESC

  s.homepage         = 'https://appatlas.dev'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Park Jungyoung' => 'qkrwnss0509@gmail.com' }
  s.source           = { :git => 'https://github.com/pjy0509/atlas-sdk-apple.git', :tag => "v#{s.version}" }

  # Source distribution is the point: a binary XCFramework cannot be built
  # for a deployment target current Xcode refuses to link.
  s.ios.deployment_target = '12.0'
  s.osx.deployment_target = '10.13'

  s.requires_arc     = true
  s.frameworks       = 'Foundation'
  s.libraries        = 'z'

  # Swift reads this as a module in every integration, not only under
  # use_frameworks!. A pod's own DEFINES_MODULE is what CocoaPods weighs last
  # when it decides to write the module map (Target#defines_module?), so
  # `import AppAtlasSDK` asks nothing of the app's Podfile. Every public
  # header imports Foundation and its siblings only, which is what a module
  # map needs from them.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.resource_bundles = { 'AppAtlasSDK' => ['Sources/AppAtlasSDK/PrivacyInfo.xcprivacy'] }

  s.default_subspecs = 'Links', 'Crash'

  s.subspec 'Core' do |core|
    core.source_files = 'Sources/AppAtlasSDK/include/{Atlas,ATLCore}.h', 'Sources/AppAtlasSDK/Core/*.{h,m}'
    core.public_header_files = 'Sources/AppAtlasSDK/include/{Atlas,ATLCore}.h'
  end

  s.subspec 'Links' do |links|
    links.dependency 'AppAtlasSDK/Core'
    links.source_files = 'Sources/AppAtlasSDK/include/ATLLink*.h', 'Sources/AppAtlasSDK/Links/*.{h,m}'
    links.public_header_files = 'Sources/AppAtlasSDK/include/ATLLink*.h'
  end

  s.subspec 'Crash' do |crash|
    crash.dependency 'AppAtlasSDK/Core'
    crash.source_files = 'Sources/AppAtlasSDK/include/ATLCrash.h', 'Sources/AppAtlasSDK/Crash/*.{h,m,c}'
    crash.public_header_files = 'Sources/AppAtlasSDK/include/ATLCrash.h'
    # MetricKit is loaded by name at runtime; no link, weak or otherwise.
  end
end
