# TestFlight Setup Guide

This guide covers the manual setup needed in Apple Developer Portal, App Store Connect, and GitHub before the CI/CD pipeline can deploy Scribe to TestFlight.

## Prerequisites

- Apple Developer Program membership (Team ID: `89DBN36T4T`)
- Admin access to the GitHub repository

## 1. Apple Developer Portal

### 1.1 Register App IDs

Go to [Certificates, Identifiers & Profiles > Identifiers](https://developer.apple.com/account/resources/identifiers/list).

**App ID — Scribe:**
- Platform: iOS
- Bundle ID: `com.gordonbeeming.scribe` (Explicit)
- Capabilities: Push Notifications, CloudKit, App Groups (`group.com.gordonbeeming.scribe`)

**App ID — Scribe Widget:**
- Platform: iOS
- Bundle ID: `com.gordonbeeming.scribe.widget` (Explicit)
- Capabilities: App Groups (`group.com.gordonbeeming.scribe`)

### 1.2 Create Distribution Certificate

Go to [Certificates](https://developer.apple.com/account/resources/certificates/list).

1. Click **+** to create a new certificate
2. Select **Apple Distribution**
3. Upload a CSR (create one in Keychain Access > Certificate Assistant > Request a Certificate from a Certificate Authority)
4. Download the `.cer` file and install it in Keychain Access
5. Export as `.p12` from Keychain Access (right-click the certificate > Export) — you'll need this for GitHub secrets

### 1.3 Create Provisioning Profiles

Go to [Profiles](https://developer.apple.com/account/resources/profiles/list).

**Profile — Scribe (App Store):**
1. Click **+**, select **App Store Connect**
2. Select App ID: `com.gordonbeeming.scribe`
3. Select the distribution certificate created above
4. Name it: `Scribe App Store` (note this name — it's used as `PROVISIONING_PROFILE_NAME`)
5. Download the `.mobileprovision` file

**Profile — Scribe Widget (App Store):**
1. Click **+**, select **App Store Connect**
2. Select App ID: `com.gordonbeeming.scribe.widget`
3. Select the distribution certificate
4. Name it: `Scribe Widget App Store` (note this name — it's used as `WIDGET_PROVISIONING_PROFILE_NAME`)
5. Download the `.mobileprovision` file

### 1.4 Create CloudKit Container

Go to [CloudKit Dashboard](https://icloud.developer.apple.com/).

1. Ensure the container `iCloud.com.gordonbeeming.scribe` exists
2. Deploy the development schema to production when ready

## 2. App Store Connect

### 2.1 Create the App

Go to [App Store Connect > My Apps](https://appstoreconnect.apple.com/apps).

1. Click **+** > **New App**
2. Platform: iOS
3. Name: `Scribe`
4. Primary Language: English (Australia) or English (U.S.)
5. Bundle ID: `com.gordonbeeming.scribe`
6. SKU: `com.gordonbeeming.scribe`

### 2.2 Create App Store Connect API Key

Go to [Users and Access > Integrations > App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api).

1. Click **+** to generate a new key
2. Name: `GitHub Actions - Scribe`
3. Access: **App Manager** (minimum role for TestFlight uploads)
4. Download the `.p8` private key file (you can only download it once!)
5. Note the **Key ID** and **Issuer ID** shown on the page

## 3. GitHub Repository Configuration

### 3.1 Create the `beta` Environment

Go to **Settings > Environments** in the GitHub repository.

1. Click **New environment**
2. Name: `beta`
3. Optionally add protection rules (e.g., required reviewers)

### 3.2 Add Repository Secrets

Go to **Settings > Environments > beta > Environment secrets**.

| Secret | Value | How to get it |
|--------|-------|---------------|
| `CERTIFICATES_P12` | Base64-encoded `.p12` certificate | `base64 -i Certificates.p12 \| pbcopy` |
| `CERTIFICATES_PASSWORD` | Password used when exporting the `.p12` | Set during Keychain export |
| `PROVISIONING_PROFILE` | Base64-encoded Scribe `.mobileprovision` | `base64 -i "Scribe_App_Store.mobileprovision" \| pbcopy` |
| `WIDGET_PROVISIONING_PROFILE` | Base64-encoded Widget `.mobileprovision` | `base64 -i "Scribe_Widget_App_Store.mobileprovision" \| pbcopy` |
| `APP_STORE_CONNECT_API_KEY` | Contents of the `.p8` private key file | `cat AuthKey_XXXXXXXX.p8 \| pbcopy` |

### 3.3 Add Environment Variables

Go to **Settings > Environments > beta > Environment variables**.

| Variable | Value | Description |
|----------|-------|-------------|
| `APPLE_TEAM_ID` | `89DBN36T4T` | Apple Developer Team ID |
| `CODE_SIGN_IDENTITY` | `Apple Distribution` | Signing identity name |
| `PROVISIONING_PROFILE_NAME` | `Scribe App Store` | Exact name from Developer Portal |
| `WIDGET_PROVISIONING_PROFILE_NAME` | `Scribe Widget App Store` | Exact name from Developer Portal |
| `APP_STORE_CONNECT_API_KEY_ID` | *(from step 2.2)* | Key ID shown in App Store Connect |
| `APP_STORE_CONNECT_ISSUER_ID` | *(from step 2.2)* | Issuer ID shown in App Store Connect |

## 4. Verification

### 4.1 Local Build Check

```bash
xcodegen generate
xcodebuild build -project Scribe.xcodeproj -scheme Scribe \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -quiet
```

### 4.2 Test the Pipeline

1. Push a commit to `main` (or use **Actions > Build, Test & Deploy to TestFlight > Run workflow**)
2. Monitor the workflow in the **Actions** tab
3. After successful upload, the build appears in **App Store Connect > TestFlight**

### 4.3 Common Issues

- **"No signing certificate" error**: Ensure `CERTIFICATES_P12` contains both the certificate and private key. Re-export from Keychain Access.
- **"No provisioning profile" error**: Verify profile names match exactly between Developer Portal and `PROVISIONING_PROFILE_NAME` / `WIDGET_PROVISIONING_PROFILE_NAME` variables.
- **CloudKit entitlements mismatch**: The production entitlements (`Scribe-Production.entitlements`) must match the capabilities registered for the App ID.
- **Widget signing fails**: Both the app and widget extension need separate provisioning profiles. Ensure `WIDGET_PROVISIONING_PROFILE` secret is set.
