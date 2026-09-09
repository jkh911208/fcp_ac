# Releasing

A release is a signed, notarized `FCPCaption.dmg` on GitHub Releases. The website's download button
reads the latest release from the GitHub API, so publishing one is all it takes to update the site.

**Releases are outward-facing.** Per `CLAUDE.md`, the agent does not publish one without being
asked, each time.

## What only you can do

### 1. A Developer ID Application certificate

**Done on this Mac, 2026-09-09:** `Developer ID Application: Gyuhyong Jeon (S597P43HS4)`.

Kept here for a fresh Mac. **Apple Development** and **Apple Distribution** are not
substitutes — those are for running locally and for the App Store, while a `.dmg` handed to
someone outside the App Store needs Developer ID, and notarization refuses anything else.

**Xcode ▸ Settings ▸ Accounts ▸** your Apple ID **▸ Manage Certificates… ▸ + ▸ Developer ID
Application.** Only an Account Holder or Admin of the team can create one. Then check it appears:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

The team id is the parenthesised code in that identity, and also the `OU` of the certificate's
subject — so it never has to be looked up in a browser.

### 2. Notarization credentials

**Done on this Mac, 2026-09-09:** stored under the profile name `fcpcaption`.

Apple needs to know it is you submitting. Store them once in the keychain — this asks for a
password, so it is yours to run, not the agent's:

```bash
xcrun notarytool store-credentials fcpcaption \
  --apple-id "<your Apple ID>" \
  --team-id "<your team id>" \
  --password "<an app-specific password from appleid.apple.com>"
```

An App Store Connect API key (`--key`, `--key-id`, `--issuer`) works too, and is what CI would use.

The app-specific password is not the Apple ID password: **appleid.apple.com ▸ Sign-In and Security
▸ App-Specific Passwords**. It is shown once. It is a credential — if it is ever pasted somewhere it
can be read (a screenshot, a chat, a log), revoke it on that same page and store a new one.

## Then

```bash
export FCPCAPTION_DEVELOPMENT_TEAM="<team id>"
export FCPCAPTION_CODE_SIGN_IDENTITY="Developer ID Application: <Name> (<team id>)"
export FCPCAPTION_NOTARY_PROFILE="fcpcaption"

Tools/package_release.sh
```

It regenerates the project with that identity, builds Release, signs the appex **before** the app
that contains it, builds the dmg, notarizes, staples, and finally checks the result the way
Gatekeeper will (`spctl --assess`, `stapler validate`). Without `FCPCAPTION_NOTARY_PROFILE` it
still signs and says clearly that it skipped notarization, rather than producing a dmg that fails
on someone else's Mac.

It also refuses to continue if library validation ended up enabled on the extension. That is not
paranoia: the Workflow Extensions SDK does not work with it, and the failure is silent — the
extension builds, installs, and simply never appears in Final Cut Pro.

## Publishing

Pass the version and the script does it:

```bash
Tools/package_release.sh v0.1.0
```

The asset must stay named `FCPCaption.dmg`: the site links
`releases/latest/download/FCPCaption.dmg` as its fallback, and reads the real asset name from the
API for the button label.

## Why this is not a GitHub Action

Because it cannot be, on a hosted runner. The extension links Apple's **Workflow Extensions SDK**
from `/Library/Developer/SDKs`, which is a signed-in download from Apple: it is not present on
GitHub's macOS images and it is not ours to commit here. So the build happens on a Mac that has
it, and GitHub Releases is used as file hosting.

A self-hosted runner on this Mac would automate the tag → release path, and would need the
Developer ID certificate and notarization credentials as repository secrets. That is a real option
if releases ever become frequent enough to be a chore; it is not worth the secret handling for a
release every few weeks.

## A trap worth remembering

macOS ships **bash 3.2**, where `set -u` treats an empty array's `"${arr[@]}"` as an *unbound
variable* — not as nothing. The optional `--keychain` argument in `package_release.sh` was written
that way and aborted every local release at the signing step, because the empty case *is* the
normal case here and had never been exercised. It is written as `${arr[@]+"${arr[@]}"}` now. Any
new optional-argument array in these scripts needs the same guard.

## Verifying on another Mac

The definition of done (spec §15.5) is that a downloaded dmg opens with no Gatekeeper warning.
Locally, the closest check is to strip the quarantine-free path and test as a downloaded file:

```bash
xattr -w com.apple.quarantine "0081;00000000;Safari;" build/FCPCaption.dmg
spctl --assess --type open --context context:primary-signature -vv build/FCPCaption.dmg
```

A real second Mac is still the real test.
