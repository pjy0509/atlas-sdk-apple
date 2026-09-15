Pod::Spec.new do |s|
  s.name             = 'AppAtlasSDK'
  s.version          = '0.1.0'
  s.summary          = 'App Atlas SDK for iOS and macOS: deep-link inflow and telemetry.'
  s.description      = <<-DESC
    The client half of App Atlas. Links: deferred deep links claimed from a
    consented clipboard handoff, direct opens handed in from the app delegate,
    one listener for both. Objective-C, Foundation-only core, no dependencies.
  DESC

  s.homepage         = 'https://appatlas.dev'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Park Jungyoung' => 'qkrwnss0509@gmail.com' }
  s.source           = { :git => 'https://github.com/pjy0509/atlas-sdk-apple.git', :tag => s.version.to_s }

  # Source distribution is the point: a binary XCFramework cannot be built
  # for a deployment target current Xcode refuses to link.
  s.ios.deployment_target = '12.0'
  s.osx.deployment_target = '10.13'

  s.requires_arc     = true
  s.frameworks       = 'Foundation'
  s.public_header_files = 'Sources/AppAtlasSDK/include/*.h'

  s.default_subspec  = 'Links'

  s.subspec 'Core' do |core|
    core.source_files = 'Sources/AppAtlasSDK/include/{Atlas,ATLCore}.h', 'Sources/AppAtlasSDK/Core/*.{h,m}'
  end

  s.subspec 'Links' do |links|
    links.dependency 'AppAtlasSDK/Core'
    links.source_files = 'Sources/AppAtlasSDK/include/ATLLink*.h', 'Sources/AppAtlasSDK/Links/*.{h,m}'
  end
end
