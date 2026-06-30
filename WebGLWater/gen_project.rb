#!/usr/bin/env ruby
require 'xcodeproj'

root = File.dirname(File.expand_path(__FILE__))
proj_path = File.join(root, 'WebGLWater.xcodeproj')
src = File.join(root, 'WebGLWater')

project = Xcodeproj::Project.new(proj_path)

# ---- File references -------------------------------------------------------
main = project.main_group.new_group('WebGLWater', 'WebGLWater')
shared_g = main.new_group('Shared', 'Shared')
macos_g  = main.new_group('macOS', 'macOS')
ios_g    = main.new_group('iOS', 'iOS')
res_g    = main.new_group('Resources', 'Resources')

shared_refs = ['Shared/WaterGame.swift', 'Shared/DemoAssets.swift'].map { |f| main.new_reference(File.join(src, f)) }
macos_app   = main.new_reference(File.join(src, 'macOS/AppDelegate.swift'))
macos_main  = main.new_reference(File.join(src, 'macOS/main.swift'))
ios_app     = main.new_reference(File.join(src, 'iOS/AppDelegate.swift'))
ios_vc      = main.new_reference(File.join(src, 'iOS/GameViewController.swift'))
macos_plist = main.new_reference(File.join(src, 'macOS/Info.plist'))
ios_plist   = main.new_reference(File.join(src, 'iOS/Info.plist'))
vision_g    = main.new_group('visionOS', 'visionOS')
vision_app  = main.new_reference(File.join(src, 'visionOS/WebGLWaterXRApp.swift'))
vision_game = main.new_reference(File.join(src, 'visionOS/WaterXRGame.swift'))
vision_occl = main.new_reference(File.join(src, 'visionOS/SceneOcclusion.swift'))
vision_plist = main.new_reference(File.join(src, 'visionOS/Info.plist'))

resource_files = %w[tiles.jpg xpos.jpg xneg.jpg ypos.jpg zpos.jpg zneg.jpg]
resource_refs = resource_files.map { |f| main.new_reference(File.join(src, 'Resources', f)) }

# ---- Swift Package dependency (localized after save) -----------------------
pkg = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
pkg.repositoryURL = 'https://github.com/untoldengine/UntoldEngine.git'
pkg.requirement = { 'kind' => 'branch', 'branch' => 'develop' }
project.root_object.package_references << pkg

def add_engine_dependency(project, target, pkg, products = ['UntoldEngine'])
  products.each do |name|
    dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    dep.package = pkg
    dep.product_name = name
    target.package_product_dependencies << dep
    bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    bf.product_ref = dep
    target.frameworks_build_phase.files << bf
  end
end

def common_settings(c)
  c.build_settings['PRODUCT_NAME'] = 'WebGLWater'
  c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.untoldengine.WebGLWater'
  c.build_settings['SWIFT_VERSION'] = '5.0'
  c.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  c.build_settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  c.build_settings['CURRENT_PROJECT_VERSION'] = '1'
  c.build_settings['MARKETING_VERSION'] = '1.0'
  c.build_settings['ENABLE_PREVIEWS'] = 'YES'
end

# ---- macOS target ----------------------------------------------------------
mac = project.new_target(:application, 'WebGLWater-macOS', :osx, '14.0')
mac.build_configurations.each do |c|
  common_settings(c)
  c.build_settings['SDKROOT'] = 'macosx'
  c.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
  c.build_settings['INFOPLIST_FILE'] = 'WebGLWater/macOS/Info.plist'
  c.build_settings['COMBINE_HIDPI_IMAGES'] = 'YES'
  c.build_settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/../Frameworks']
end
mac.add_file_references(shared_refs + [macos_app, macos_main])
mac.add_resources(resource_refs)
add_engine_dependency(project, mac, pkg)

# ---- iOS target ------------------------------------------------------------
ios = project.new_target(:application, 'WebGLWater-iOS', :ios, '17.0')
ios.build_configurations.each do |c|
  common_settings(c)
  c.build_settings['SDKROOT'] = 'iphoneos'
  c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  c.build_settings['INFOPLIST_FILE'] = 'WebGLWater/iOS/Info.plist'
  c.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  c.build_settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks']
end
ios.add_file_references(shared_refs + [ios_app, ios_vc])
ios.add_resources(resource_refs)
add_engine_dependency(project, ios, pkg)

# ---- visionOS target (xrOS) ------------------------------------------------
# The xcodeproj gem (1.16) has no :visionos platform, so create as :ios and
# override the build settings to target xrOS.
let_demo_assets = shared_refs[1] # DemoAssets.swift (cross-platform loader)
vision = project.new_target(:application, 'WebGLWater-visionOS', :ios, '2.0')
vision.build_configurations.each do |c|
  common_settings(c)
  c.build_settings['SDKROOT'] = 'xros'
  c.build_settings['SUPPORTED_PLATFORMS'] = 'xros xrsimulator'
  c.build_settings['XROS_DEPLOYMENT_TARGET'] = '2.0'
  c.build_settings.delete('IPHONEOS_DEPLOYMENT_TARGET')
  c.build_settings['INFOPLIST_FILE'] = 'WebGLWater/visionOS/Info.plist'
  c.build_settings['TARGETED_DEVICE_FAMILY'] = '7'
  c.build_settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks']
end
vision.add_file_references([let_demo_assets, vision_app, vision_game, vision_occl])
vision.add_resources(resource_refs)
add_engine_dependency(project, vision, pkg, ['UntoldEngine', 'UntoldEngineXR'])

project.save

# ---- Shared schemes --------------------------------------------------------
[[mac, 'WebGLWater-macOS'], [ios, 'WebGLWater-iOS'], [vision, 'WebGLWater-visionOS']].each do |target, name|
  scheme = Xcodeproj::XCScheme.new
  scheme.add_build_target(target)
  scheme.set_launch_target(target)
  scheme.save_as(proj_path, name, true)
end

# ---- Post-process: convert the remote package ref into a local path --------
pbx = File.join(proj_path, 'project.pbxproj')
content = File.read(pbx)
content.sub!(
  /isa = XCRemoteSwiftPackageReference;.*?requirement = \{.*?\};/m,
  "isa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = \"../../UntoldEngine\";"
)
content.gsub!('XCRemoteSwiftPackageReference', 'XCLocalSwiftPackageReference')
File.write(pbx, content)

puts "Generated #{proj_path}"
