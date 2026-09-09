# Xcode setup

The running record of everything done by hand in the Xcode UI, so a fresh clone can be reproduced
and no session has to guess what state the project is in.

Per spec §14 and `CLAUDE.md`, GUI-only work belongs to the user. Everything below is a click path
for a person; the agent writes the Swift, runs `xcodebuild`, and fixes the compile errors.

**Status: done (2026-09-09).** The SDK is installed, the project exists, the extension builds and
Final Cut Pro can see it. Sections 1–4 below describe what `Tools/generate_project.rb` does, not
things to click.

---

## 0. Workflow Extensions SDK — done ✅

Installed from <https://developer.apple.com/download/all/?q=WorkflowExtensions>. What it put on
this Mac, verified:

| | |
|---|---|
| SDK | `/Library/Developer/SDKs/WorkflowExtensionSDK.sdk` — **v1.0.3** (release notes say v1.0.3a, January 2026) |
| Xcode template | `/Library/Developer/Xcode/Templates/ProVideo/WorkflowExtension/FCP Workflow Extension.xctemplate` |
| Static library | `usr/lib/libProExtension.a` + `usr/include/ProExtension/ProExtension.h` |
| Host headers | `Library/Frameworks/ProExtensionHost.framework` — **headers only, no binary** |

## 1. The project is generated, not clicked

Xcode's "FCP Workflow Extension" template can only be instantiated from the IDE, so the project is
built by **`ruby Tools/generate_project.rb`** instead, from the settings that template actually
sets. Two things this buys over clicking once:

- a clone reproduces the project exactly, and
- every setting that matters is readable in one 150-line script instead of a 2000-line `pbxproj`.

The `.xcodeproj` is committed, so opening it in Xcode works without running Ruby. **Settings changed
by hand in Xcode are lost the next time the script runs** — put them in the script instead. The one
thing that legitimately belongs to this Mac, a signing team, is not in there at all: the project
signs ad-hoc (`CODE_SIGN_IDENTITY = -`), which builds and runs locally without a Developer Program
membership. M5 adds real signing.

### What it produces

| | |
|---|---|
| `FCPCaption` | the container app. macOS only ships an appex inside an app; this one just says where to find the panel. |
| `FCPCaptionExtension` | the appex — `com.apple.FinalCut.WorkflowExtension`, principal class `FCPCaptionExtensionViewController`. |
| Packages | `FCPCaptionCore` and `FCPCaptionUI`, linked into both targets from the local package. |

### Verified on the built binary, not assumed

- `_ProExtensionMain` and `_ProExtensionHostSingleton` are statically linked in from
  `libProExtension.a`, and `otool -L` shows **no** ProExtensionHost framework — exactly what the
  release notes require.
- Code signature flags are `adhoc,runtime` with **no** `library-validation`. Getting this wrong is
  silent: the extension builds and then never appears in Final Cut Pro.
- The appex carries `app-sandbox`, `automation.apple-events`, `cs.disable-library-validation` and
  the three `scripting-targets`.
- `pluginkit -mAvv | grep -i fcpcaption` lists it once, from `/Applications`.

### The old click path

Kept only as a reference for what the generator is imitating.

## 1b. The host app project (reference)

1. **File ▸ New ▸ Project… ▸ macOS ▸ App**
   - Product Name: `FCPCaption`
   - Team: your Apple ID (personal team is fine until M5)
   - Organization Identifier: `com.jkh911208` (or anything stable you own)
   - Interface **SwiftUI**, Language **Swift**, Storage **None**, tests unchecked
2. Save at the **repo root** (`/Users/james/repo/fcp_ac`) and **uncheck "Create Git repository"**.
3. Target **FCPCaption** ▸ **General** ▸ Minimum Deployments: **macOS 15.0**.
4. **Build Settings** for every target: `Architectures` = `arm64`,
   `Excluded Architectures` = `x86_64`. Apple silicon only, per spec §7.

## 2. Wire in the package

**File ▸ Add Package Dependencies… ▸ Add Local…** → choose the `FCPCaptionCore` folder in the repo.
Add **`FCPCaptionCore`** and **`FCPCaptionUI`** to the app target, and to the extension target in
step 3.

## 3. The extension target

**File ▸ New ▸ Target… ▸ macOS ▸ FCP Workflow Extension**
- Product Name: `FCPCaptionExtension`
- Language: **Swift**
- Embed in Application: `FCPCaption`
- Activate the scheme when Xcode offers.

The template already sets everything below — this is a checklist, not typing:

| Setting | Value |
|---|---|
| `NSExtensionPointIdentifier` | `com.apple.FinalCut.WorkflowExtension` |
| `ProExtensionPrincipalViewControllerClass` | `<Module>.FCPCaptionExtensionViewController` |
| `ADDITIONAL_SDKS` | `/Library/Developer/SDKs/WorkflowExtensionSDK.sdk` |
| `LD_ENTRY_POINT` | `_ProExtensionMain` |
| `OTHER_LDFLAGS` | `-fapplication-extension -lProExtension` |
| `MACH_O_TYPE` | `mh_execute` |
| Bridging header | `#import <ProExtension/ProExtension.h>` |
| Entitlement | `com.apple.security.app-sandbox` = YES |

## 4. Three things the template does *not* do

All three come from the SDK release notes, and the extension does not work without them.

1. **Signing & Capabilities ▸ Hardened Runtime** (extension target): check
   **Disable Library Validation** and **Apple Events**. The SDK is not fully compatible with
   Hardened Runtime; with library validation on, the extension simply doesn't load.
2. **The scripting-target entitlement.** `ProExtensionHost` talks to Final Cut Pro over Apple
   Events, and a sandboxed extension needs permission to target it. Tell the agent when the target
   exists — this is a plist edit, not a GUI step:
   ```xml
   <key>com.apple.security.scripting-targets</key>
   <dict>
     <key>com.apple.FinalCut</key><array><string>com.apple.FinalCut.library.inspection</string></array>
     <key>com.apple.FinalCutApp</key><array><string>com.apple.FinalCut.library.inspection</string></array>
     <key>com.apple.FinalCutTrial</key><array><string>com.apple.FinalCut.library.inspection</string></array>
   </dict>
   ```
   (`com.apple.FinalCutApp` is the new variant the January 2026 notes added.)
3. **Container app `Info.plist`** needs
   `NSAppleEventsUsageDescription` = `Extensions can interact with Final Cut Pro.`

## 5. Swift 6 caveat

The release notes: *"Workflow Extensions SDK v1.0.3 may not be compatible with the Swift 6 Runtime
due to initialization of the principal ViewController class from a background thread."*

So the **extension target** stays on the Swift 5 language mode (`SWIFT_VERSION = 5`) and its view
controller does its setup on the main thread. `FCPCaptionCore` and `FCPCaptionUI` remain Swift 6 —
the caveat is about how the host instantiates the principal class, not about what it links.

## 6. Make Final Cut Pro see it

1. Build and run the extension scheme once; when Xcode asks which app to run it in, choose Final
   Cut Pro. Registering the appex is what makes it appear.
2. **Window ▸ Extensions ▸ FCPCaption** in Final Cut Pro.
3. If it doesn't appear: `pluginkit -mAvv | grep -i fcpcaption`. The release notes warn that copies
   of the app in non-standard locations also get discovered and which one wins is undefined — keep
   exactly one copy.

---

## What the SDK settled, and what it didn't

**The host API is read-only.** `FCPXHost` gives the timeline playhead, the active sequence's name,
start, duration, frame duration and timecode format, plus library/event/project names and UIDs.
That is all of it. **There is no API for sending FCPXML — or anything else — back into Final Cut
Pro.** So the §10 fallback ladder's top rung, injecting captions straight into the open project,
is not reachable with the public SDK, and the design has to go through an FCPXML the user imports
(or drags back into the timeline).

**Still unverified, to be answered by the first real drop** — the panel logs what it actually
receives rather than assuming:
- whether a clip dragged from the timeline arrives as pasteboard data or as a file URL, and under
  which type. Final Cut Pro declares `com.apple.FinalCutPro.xml` (`.fcpxml`) and
  `com.apple.finalcutpro.xmld` (`.fcpxmld`) in its own `Info.plist`, which is what we register for.
- whether dragging FCPXML *from* the panel into the timeline works, which would be a better
  delivery path than opening a file.
