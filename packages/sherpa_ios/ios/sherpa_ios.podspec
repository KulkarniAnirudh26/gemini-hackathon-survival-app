Pod::Spec.new do |s|
  s.name             = 'sherpa_ios'
  s.version          = '0.1.0'
  s.summary          = "iOS side of Sherpa's native channels (AI fallback, offline 3D map)."
  s.homepage         = 'https://github.com/KulkarniAnirudh26/gemini-hackathon-survival-app'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'Sherpa' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  # MapPack/ is plain Swift, parity-tested on the Mac by ../swift-tests
  s.source_files     = 'Classes/**/*.swift', 'MapPack/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.libraries        = 'sqlite3'
  s.frameworks       = 'WebKit', 'AVFoundation'
  s.swift_version    = '5.9'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
