# Releasing

A release is a signed, notarized `FCPCaption.dmg` on GitHub Releases. The website's download button
reads the latest release from the GitHub API, so publishing one is all it takes to update the site.

**Releases are outward-facing.** Per `CLAUDE.md`, the agent does not publish one without being
asked, each time.

## What only you can do

### 1. A Developer ID Application certificate

Checked on this Mac (2026-09-09), `security find-identity -v -p codesigning` lists **Apple
Development** and **Apple Distribution** but **no Developer ID Application**. Those two are for
running locally and for the App Store; a `.dmg` handed to someone outside the App Store needs
Developer ID, and notarization refuses anything else.

**Xcode ▸ Settings ▸ Accounts ▸** your Apple ID **▸ Manage Certificates… ▸ + ▸ Developer ID
Application.** Only an Account Holder or Admin of the team can create one. Then check it appears:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 2. Notarization credentials

Apple needs to know it is you submitting. Store them once in the keychain — this asks for a
password, so it is yours to run, not the agent's:

```bash
xcrun notarytool store-credentials fcpcaption \
  --apple-id "<your Apple ID>" \
  --team-id "<your team id>" \
  --password "<an app-specific password from appleid.apple.com>"
```

An App Store Connect API key (`--key`, `--key-id`, `--issuer`) works too, and is what CI would use.

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

```bash
gh release create v0.1.0 build/FCPCaption.dmg \
  --title "FCPCaption 0.1.0" --notes-file <(cat)
```

The asset must stay named `FCPCaption.dmg`: the site links
`releases/latest/download/FCPCaption.dmg` as its fallback, and reads the real asset name from the
API for the button label.

## Verifying on another Mac

The definition of done (spec §15.5) is that a downloaded dmg opens with no Gatekeeper warning.
Locally, the closest check is to strip the quarantine-free path and test as a downloaded file:

```bash
xattr -w com.apple.quarantine "0081;00000000;Safari;" build/FCPCaption.dmg
spctl --assess --type open --context context:primary-signature -vv build/FCPCaption.dmg
```

A real second Mac is still the real test.
