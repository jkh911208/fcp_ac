# Xcode setup

The running record of everything that had to be done by hand in the Xcode UI, so a fresh clone can
be reproduced and so no session has to guess what state the project is in.

Per the spec (§14) and `CLAUDE.md`, GUI-only work belongs to the user. Everything below is a click
path for a person; the agent writes the Swift, runs `xcodebuild`, and fixes compile errors.

**Status: not started.** Nothing in this document has been done yet.

---

## 0. Prerequisite — the Workflow Extensions SDK (this is not in Xcode)

Xcode has **no** Final Cut Pro extension template out of the box, and macOS has no
`ProExtension.framework`. Both arrive with a separate download from Apple:

1. Sign in at <https://developer.apple.com/download/all/?q=WorkflowExtensions> (an Apple ID is
   enough — this is not the paid Developer Program, which is only needed for notarization at M5).
2. Download the latest **Workflow Extensions SDK** and run the installer. It puts
   `ProExtension.framework` and the Xcode template where Xcode looks for them.
3. Restart Xcode, then confirm the template exists: **File ▸ New ▸ Target… ▸ macOS**, and look for
   a **Workflow Extension** section. If it isn't there, the installer didn't take — stop and say so
   rather than working around it.

Verified against Apple's own documentation:
[Building a Workflow Extension](https://developer.apple.com/documentation/professional-video-applications/building-a-workflow-extension).

## 1. The host app project

1. **File ▸ New ▸ Project… ▸ macOS ▸ App**.
   - Product Name: `FCPCaption`
   - Team: your Apple ID (personal team is fine until M5)
   - Organization Identifier: something stable you own, e.g. `com.jkh911208`
   - Interface: **SwiftUI**, Language: **Swift**, Storage: **None**, tests: unchecked
2. Save it at the **repo root** (`/Users/james/repo/fcp_ac`), and **uncheck "Create Git repository"**
   — the repo already exists.
3. Select the project in the navigator ▸ the **FCPCaption** target ▸ **General** ▸ Minimum
   Deployments: **macOS 15.0**.
4. **Build Settings** (All / Combined) for **every** target:
   - `Architectures` → `arm64`
   - `Excluded Architectures` → `x86_64`
   - `Build Active Architecture Only` → `No` for Release
   Apple silicon only, per spec §7 — do not ship a universal binary.

## 2. Wire in FCPCaptionCore

1. **File ▸ Add Package Dependencies… ▸ Add Local…** and choose the `FCPCaptionCore` folder in the
   repo.
2. Add the `FCPCaptionCore` library product to the app target, and (in step 3) to the extension
   target as well.

## 3. The extension target

1. **File ▸ New ▸ Target… ▸ macOS ▸ Workflow Extension** (from the SDK in step 0).
   - Product Name: `FCPCaptionExtension`
   - Embed in Application: `FCPCaption`
2. When Xcode offers to activate the new scheme, **Activate**.
3. Check the generated `Info.plist`. It should already contain the extension point identifier and
   the principal view controller class — read the real values off the template rather than typing
   them from a document:
   ```xml
   <key>NSExtension</key>
   <dict>
     <key>NSExtensionPointIdentifier</key>
     <string>com.apple.FinalCut.WorkflowExtension</string>
     <key>ProExtensionPrincipalViewControllerClass</key>
     <string>…</string>
   </dict>
   ```
4. Add a minimum panel size so the sidebar can't crush the UI (spec §11 — the FCP sidebar is about
   300–400pt wide):
   ```xml
   <key>ProExtensionAttributes</key>
   <dict>
     <key>ContentViewMinimumWidth</key><integer>300</integer>
     <key>ContentViewMinimumHeight</key><integer>320</integer>
   </dict>
   ```

## 4. Make Final Cut Pro see it

1. Build and **run the extension scheme once** (Xcode asks which app to run it in — choose Final
   Cut Pro). Registering the appex is what makes it appear in FCP.
2. In Final Cut Pro: **Window ▸ Extensions ▸ FCPCaption**.
3. If it doesn't appear, check that the built app is somewhere LaunchServices scans (build to
   `/Applications` or run it once from Finder), and check `pluginkit -mAvv | grep FCPCaption`.

## 5. When it works

Say so, and the agent will:
- capture the FCPXML the panel receives on the first real drop as `Fixtures/dropped_clip.fcpxml`,
- record here exactly what was clicked and any deviation from the above,
- move on to M2, the import spike (spec §10).

---

## What is still unverified

- The exact `NSExtensionPointIdentifier` string. Apple's documentation renders it inconsistently;
  the template's own value is the authority, which is why step 3 says to read it rather than type it.
- How the extension receives a dragged clip. Apple documents `ProExtensionHostSingleton()`,
  `FCPXHost`, `FCPXTimeline` and `FCPXTimelineObserver` for talking to the timeline, but the
  drag-and-drop payload path isn't spelled out in the overview — it has to come from the SDK's
  headers and sample code once installed. **Do not implement against a guess.**
