# 🚀 Google Play launch kit — Phone Clone

Everything needed before and during the Google Play launch. **Nothing here has been uploaded to Google Play yet.**

| | |
|---|---|
| App name | **Phone Clone** |
| Package (application ID) | `com.mrajkishor.phoneclone` *(permanent: never change it)* |
| First Play version | **5.2.0** (version code **11**) |
| Target / min SDK | 36 (Android 16) / 24 (Android 7.0) |
| Format | Android App Bundle (`.aab`), signed with the **upload key** |

## ✅ Done before opening Play Console

- [x] Unique package name (Play doesn't accept `com.example`)
- [x] App renamed to **Phone Clone** (launcher, title, notifications)
- [x] Release signing with an **upload key** (`android/key.properties`, never committed)
- [x] Target API 36, as required for new apps from 31 Aug 2026
- [x] New launcher icon: adaptive, round and themed (monochrome) variants
- [x] 512 × 512 Play icon and 1024 × 500 feature graphic → [`graphics/`](graphics/)
- [x] Privacy policy → [`/PRIVACY.md`](../../PRIVACY.md)
- [x] Store listing text, within Play's character limits → [`listing.md`](listing.md)
- [x] Ready-to-paste answers for All files access, foreground service, Data safety and other forms → [`declarations.md`](declarations.md)
- [x] Release `.aab` built and verified (signed with the upload key, version 5.2.0 / code 11)

## 🧭 When you're ready to launch (your steps)

> [!IMPORTANT]
> Your account is a **new personal developer account**, so Google requires a **closed test with at least 12 testers who stay opted in for 14 consecutive days** before you can apply for production access.

1. **Create the developer account** at play.google.com/console (US$25 one-time; identity verification).
2. **Create the app** → name *Phone Clone* → App → Free.
3. **Play App Signing** → keep the default (*Google generates and protects the app signing key*). Your upload key is the one in `phone-clone-upload.jks`.
4. **Internal testing** → create a release → upload `PhoneClone-v5.2.0.aab` → add yourself and a few friends → install on two real phones and test a full transfer. Take the **screenshots** here.
5. **App content** → fill in every form using [`declarations.md`](declarations.md). The **All files access**, **foreground service** and **SMS / call log** forms each need a short screen recording.

> [!WARNING]
> From 5.0.0 the app uses **SMS and call log** permissions. Google reviews these by hand; the matching exception is *"Backup and restore for users"*. If the review is slow or refused, ship a Play build without them (remove the SMS/call-log permissions and SMS components from the manifest; the app then shows those switches as unavailable) and keep the full build for sideloading.
6. **Store listing** → paste from [`listing.md`](listing.md), upload the graphics and screenshots.
7. **Closed testing** → upload the same bundle → invite **12+ testers** → keep them opted in for **14 days**.
8. **Apply for production access** → when approved, promote the release to **Production** (start with a staged rollout, e.g. 20%).

## 🔐 Signing

| File | Where | Commit to git? |
|---|---|:---:|
| `phone-clone-upload.jks` | Your safe storage + `android/upload-keystore.jks` for local builds | ❌ never |
| `key.properties` (passwords) | Your safe storage + `android/key.properties` for local builds | ❌ never |

Both are already listed in `.gitignore`. **Back them up** (password manager plus an offline copy). If the upload key is lost, Play can reset it through Play Console support, but it takes time.

### Build the bundle

```bash
cp /path/to/phone-clone-upload.jks android/upload-keystore.jks
cp /path/to/key.properties        android/key.properties
flutter test
flutter build appbundle --release
# → build/app/outputs/bundle/release/app-release.aab
```

Before every new Play upload, raise the version in `pubspec.yaml` (e.g. `4.1.1+6`). The number after `+` must always increase.

## ℹ️ The Play app vs. the sideloaded APKs

The sideloaded v3.0.0 / v4.0.0 APKs on GitHub are a **different app** (`com.example.phone_transfer`, "Phone Transfer"). They can't be updated to the Play version. Users install *Phone Clone* from Play as a new app, and can uninstall the old one afterwards.
