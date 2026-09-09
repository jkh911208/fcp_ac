//  Exposes the SDK's C entry point to Swift.
//
//  ProExtension.h declares ProExtensionHostSingleton(); FCPXHost.h declares the protocol that
//  singleton conforms to. The release notes are explicit that the extension must NOT link the
//  ProExtensionHost framework — the SDK ships its headers without a binary, and Final Cut Pro
//  provides the implementation at runtime. Importing the header for its declarations is fine;
//  a link-time dependency on it is what would break. `otool -L` on the built appex is the check.
#import <ProExtension/ProExtension.h>
#import <ProExtensionHost/FCPXHost.h>
