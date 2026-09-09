#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates FCPCaption.xcodeproj.
#
# Xcode's own "FCP Workflow Extension" template can only be instantiated from the IDE, so the
# project is built here instead — from the settings that template actually sets, read out of
# /Library/Developer/Xcode/Templates/ProVideo/WorkflowExtension. Generating it has two advantages
# over clicking through Xcode once: a clone can reproduce the project exactly, and every setting
# that matters is visible in this file instead of buried in a 2000-line pbxproj.
#
#   ruby Tools/generate_project.rb
#
# Requires the xcodeproj gem (ships with CocoaPods).

require 'fileutils'
require 'xcodeproj'

ROOT = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(ROOT, 'FCPCaption.xcodeproj')
BUNDLE_ID = 'com.jkh911208.FCPCaption'
DEPLOYMENT_TARGET = '15.0'
WORKFLOW_SDK = '/Library/Developer/SDKs/WorkflowExtensionSDK.sdk'

abort("Workflow Extensions SDK not found at #{WORKFLOW_SDK}") unless Dir.exist?(WORKFLOW_SDK)

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)

# Apple silicon only, per spec §7 — never a universal binary.
shared = {
  'ARCHS' => 'arm64',
  'EXCLUDED_ARCHS' => 'x86_64',
  'MACOSX_DEPLOYMENT_TARGET' => DEPLOYMENT_TARGET,
  'SDKROOT' => 'macosx',
  'SWIFT_VERSION' => '6.0',
  'CODE_SIGN_STYLE' => 'Manual',
  'CODE_SIGN_IDENTITY' => '-',            # ad-hoc: builds and runs locally without a team
  'PROVISIONING_PROFILE_SPECIFIER' => '',
  'ENABLE_HARDENED_RUNTIME' => 'YES',
  'ALWAYS_SEARCH_USER_PATHS' => 'NO',
  'CLANG_ENABLE_MODULES' => 'YES',
  'SWIFT_EMIT_LOC_STRINGS' => 'YES',
}
project.build_configurations.each do |config|
  config.build_settings.merge!(shared)
  config.build_settings['ONLY_ACTIVE_ARCH'] = config.name == 'Debug' ? 'YES' : 'NO'
  config.build_settings['SWIFT_OPTIMIZATION_LEVEL'] = config.name == 'Debug' ? '-Onone' : '-O'
  config.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG' if config.name == 'Debug'
end

# The core and UI live in the local Swift package, so they stay testable without Xcode.
package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package.relative_path = 'FCPCaptionCore'
project.root_object.package_references << package

def package_product(project, package, name)
  product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  product.package = package
  product.product_name = name
  product
end

app = project.new_target(:application, 'FCPCaption', :osx, DEPLOYMENT_TARGET)
extension_target = project.new_target(:app_extension, 'FCPCaptionExtension', :osx, DEPLOYMENT_TARGET)

app.build_configurations.each do |config|
  config.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER' => BUNDLE_ID,
    'PRODUCT_NAME' => 'FCPCaption',
    'INFOPLIST_FILE' => 'FCPCaption/Info.plist',
    'CODE_SIGN_ENTITLEMENTS' => 'FCPCaption/FCPCaption.entitlements',
    'ENABLE_APP_SANDBOX' => 'YES',
    'MARKETING_VERSION' => '0.1.0',
    'CURRENT_PROJECT_VERSION' => '1',
    'COMBINE_HIDPI_IMAGES' => 'YES',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/../Frameworks'],
  )
end

# Everything below is what the Xcode template sets. Getting any of it wrong means an extension
# that builds and never appears in Final Cut Pro.
extension_target.build_configurations.each do |config|
  config.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER' => "#{BUNDLE_ID}.Extension",
    'PRODUCT_NAME' => 'FCPCaptionExtension',
    'INFOPLIST_FILE' => 'FCPCaptionExtension/Info.plist',
    'CODE_SIGN_ENTITLEMENTS' => 'FCPCaptionExtension/FCPCaptionExtension.entitlements',
    'WRAPPER_EXTENSION' => 'appex',
    'ADDITIONAL_SDKS' => WORKFLOW_SDK,
    'LD_ENTRY_POINT' => '_ProExtensionMain',
    'OTHER_LDFLAGS' => ['-fapplication-extension', '-lProExtension'],
    'MACH_O_TYPE' => 'mh_execute',
    'FRAMEWORK_SEARCH_PATHS' => ['/Library/Frameworks', '$(inherited)'],
    'LIBRARY_SEARCH_PATHS' => ['/usr/lib', '$(inherited)'],
    'HEADER_SEARCH_PATHS' => ['/usr/include', '$(inherited)'],
    'SWIFT_OBJC_BRIDGING_HEADER' => 'FCPCaptionExtension/FCPCaptionExtension-Bridging-Header.h',
    # The SDK release notes: v1.0.3 "may not be compatible with the Swift 6 Runtime due to
    # initialization of the principal ViewController class from a background thread". The packages
    # stay on Swift 6; only the target the host instantiates steps back.
    'SWIFT_VERSION' => '5.0',
    'MARKETING_VERSION' => '0.1.0',
    'CURRENT_PROJECT_VERSION' => '1',
    'COMBINE_HIDPI_IMAGES' => 'YES',
    # Xcode 16's debug dylib turns the executable into a stub that loads the real code from a
    # sibling dylib. Final Cut Pro loads this bundle itself, and the entry point has to be
    # _ProExtensionMain in *this* binary — so the split is off in both configurations.
    'ENABLE_DEBUG_DYLIB' => 'NO',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/../Frameworks',
                                  '@executable_path/../../../../Frameworks'],
  )
end

app_group = project.new_group('FCPCaption', 'FCPCaption')
extension_group = project.new_group('FCPCaptionExtension', 'FCPCaptionExtension')

app.add_file_references([app_group.new_reference('FCPCaptionApp.swift')])
extension_target.add_file_references([
  extension_group.new_reference('FCPCaptionExtensionViewController.swift'),
  extension_group.new_reference('CaptionDropView.swift'),
  extension_group.new_reference('FinalCutPro.swift'),
])

%w[FCPCaptionCore FCPCaptionUI].each do |name|
  [app, extension_target].each do |target|
    dependency = package_product(project, package, name)
    target.package_product_dependencies << dependency
    build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    build_file.product_ref = dependency
    target.frameworks_build_phase.files << build_file
  end
end

# The appex ships inside the app's PlugIns folder — that is how the OS discovers it.
embed = app.new_copy_files_build_phase('Embed Foundation Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
embed.add_file_reference(extension_target.product_reference).tap do |file|
  file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end
app.add_dependency(extension_target)

project.save
puts "wrote #{PROJECT_PATH}"
