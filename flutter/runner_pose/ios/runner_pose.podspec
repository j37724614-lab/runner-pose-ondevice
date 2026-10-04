Pod::Spec.new do |s|
  s.name             = 'runner_pose'
  s.version          = '0.1.0'
  s.summary          = 'Typed Flutter bridge for on-device running analysis.'
  s.description       = 'Pigeon bridge wrapping RunnerAnalysisKit without copying video bytes through Dart.'
  s.homepage         = 'https://github.com/j37724614-lab/runner-pose-ondevice'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'runner-analysis' => 'n26142393@gs.ncku.edu.tw' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.dependency 'RunnerAnalysisKit', '= 0.1.0'
  s.platform = :ios, '16.0'
  s.swift_version = '5.9'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
