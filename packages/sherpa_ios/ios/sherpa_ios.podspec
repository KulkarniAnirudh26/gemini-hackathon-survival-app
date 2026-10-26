Pod::Spec.new do |s|
  s.name             = 'sherpa_ios'
  s.version          = '0.1.0'
  s.summary          = "iOS side of Sherpa's native channels (AI fallback, offline 3D map)."
  s.homepage         = 'https://github.com/KulkarniAnirudh26/gemini-hackathon-survival-app'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'Sherpa' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  # Swift Package Manager builds (the app's default) use sherpa_ios/Package.swift, which adds
  # LiteRT-LM for Gemma. CocoaPods has no LiteRT-LM pod, so a CocoaPods build runs without Gemma.
  s.source_files     = 'sherpa_ios/Sources/sherpa_ios/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.libraries        = 'sqlite3'
  s.frameworks       = 'WebKit', 'AVFoundation', 'Speech'
  s.swift_version    = '5.9'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
