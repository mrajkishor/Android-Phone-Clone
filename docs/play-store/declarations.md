# Play Console declarations — ready-to-paste answers

These are the **App content** forms Play asks for (*Play Console → Policy → App content*), with suggested answers for Phone Clone. Read each answer before submitting: you are the one declaring it to Google.

---

## 1. All files access (`MANAGE_EXTERNAL_STORAGE`)

*Play Console → Policy → App content → Sensitive app permissions → All files access*

- **Core functionality / permitted use:** *Device migration or phone transfer*
- **Description:**

```
Phone Clone is a phone-to-phone migration app: its core and only purpose is to help users move their data from their old Android phone to their new one over a local Wi-Fi connection.

All files access is required on both phones:
- On the old phone, the app must find and read every file the user owns across shared storage (Documents, Download, DCIM, Pictures, Music, WhatsApp media folders, SD card, etc.), including file types that are not in the MediaStore (PDF, Office documents, archives, APKs), so that nothing is left behind.
- On the new phone, the app must write each file back into the SAME relative folder it had on the old phone, with its original modification date, so the user's folder structure is preserved.

The Storage Access Framework is not sufficient: Android 11+ does not allow a user to grant access to the root of internal storage or the Download folder through SAF, so a migration would silently miss files. The app never modifies or deletes anything on the old phone (read-only), never accesses Android/data or Android/obb, and never sends data anywhere other than the user's own new phone on the local network.
```

- **Video:** a short screen recording showing (1) the *Allow access to all files* screen, (2) the category list with counts on the old phone, (3) files arriving in the same folders on the new phone.

> The core purpose must also be prominent in the store description. The full description in [`listing.md`](listing.md) says so in its second paragraph.

---

## 2. Foreground service (Android 14+)

*Play Console → Policy → App content → Foreground service permissions*

- **Type:** `dataSync` (`FOREGROUND_SERVICE_DATA_SYNC`)
- **Description:**

```
While a phone-to-phone transfer is running, Phone Clone runs a dataSync foreground service on both phones: on the old phone it uploads the user's files and contacts, on the new phone it receives and saves them. Transfers of tens of gigabytes take many minutes, and users switch apps or turn the screen off meanwhile. The service shows an ongoing notification with live progress, starts only when the user starts a transfer (or opens the receive screen), and stops as soon as the transfer finishes, is stopped by the user, or the user leaves the screen.
```

- **User impact if deferred or interrupted:** *the transfer would stop partway and the user would have to restart it.*
- **Video:** start a transfer, press Home, show the progress notification continuing, then tap it to return to the app.

---

## 2b. SMS and call log (`READ_SMS`, `SEND_SMS`, `RECEIVE_SMS`, `RECEIVE_MMS`, `RECEIVE_WAP_PUSH`, `READ_CALL_LOG`, `WRITE_CALL_LOG`)

*Play Console → Policy → App content → Sensitive permissions → SMS and Call Log*

| Question | Answer |
|---|---|
| Core functionality | **Backup and restore for users** (also fits *Device migration / phone transfer*) |
| Description | *Phone Clone copies the user's own messages and call history from their old phone to their new phone, over their local Wi-Fi, when the user turns on "Messages" or "Call history" and starts a transfer. On the new phone the app asks to become the default SMS app only while it writes the messages, then helps the user switch back. Nothing is sent to any server.* |
| Default SMS handler | Requested temporarily on the new phone (`RoleManager.ROLE_SMS`) |
| Video | Old phone: choose *Messages* → transfer. New phone: *Allow* popup → default-SMS prompt → messages appear → *Switch back* |

## 2c. Install apps (`REQUEST_INSTALL_PACKAGES`)

| Question | Answer |
|---|---|
| Use case | **Device migration / phone transfer**: reinstall the apps the user had on the old phone from their APKs, after the user taps *Install* (Android confirms each one) |

Package visibility uses a `<queries>` element for launcher apps only (no `QUERY_ALL_PACKAGES`).

## 3. Data safety

*Play Console → Policy → App content → Data safety*

Google defines **collected** as *"transmitting data from your app off a user's device"*, and a transfer to the user's own new phone isn't explicitly exempted. The conservative answer is to declare it as collected for app functionality, and not shared (user-initiated transfers are exempt from "sharing").

| Question | Answer |
|---|---|
| Does your app collect or share any of the required user data types? | **Yes** |
| Is all of the user data collected by your app encrypted in transit? | **No** *(local HTTP; see note below)* |
| Do you provide a way for users to request that their data is deleted? | **Yes**: clear the app's storage or uninstall; the developer holds no data |

Data types to declare as **Collected** (not *Shared*):

| Category | Type | Collected | Shared | Processed ephemerally? | Required or optional | Purpose |
|---|---|:---:|:---:|:---:|---|---|
| Photos and videos | Photos, Videos | ✅ | ❌ | No | Optional (user chooses) | App functionality |
| Audio files | Music files, Other audio files | ✅ | ❌ | No | Optional | App functionality |
| Files and docs | Files and docs | ✅ | ❌ | No | Optional | App functionality |
| Contacts | Contacts | ✅ | ❌ | No | Optional | App functionality |
| Messages | SMS or MMS | ✅ | ❌ | No | Optional | App functionality |
| App activity | Other user-generated content *(call history)* | ✅ | ❌ | No | Optional | App functionality |
| Calendar | Calendar events | ✅ | ❌ | No | Optional | App functionality |
| App info and performance | Other app info *(installed apps list and APKs)* | ✅ | ❌ | No | Optional | App functionality |

Not collected: location, personal info, financial info, health, web browsing, device or other IDs.

> **Worth improving later:** Data that is end-to-end encrypted, so only sender and recipient can read it, doesn't have to be declared at all. Adding encryption to the transfer (keyed from the QR pairing) would let the listing say **"No data collected"** and **"Data is encrypted in transit"**.

---

## 4. Other App content forms

| Form | Answer |
|---|---|
| **Privacy policy** | `https://github.com/mrajkishor/Android-Phone-Clone/blob/main/PRIVACY.md` |
| **App access** | *All functionality is available without special access* (no login) |
| **Ads** | *No, my app does not contain ads* |
| **Content rating** | Category **Utility, productivity, communication or other**. Answer *No* to violence, sexuality, language, controlled substances, gambling. User interaction: users don't interact or share content with other users; no location sharing; no digital purchases. Expected rating: **Everyone / PEGI 3** |
| **Target audience** | **18 and over** *(keeps the app outside the Families policy; it's a general utility)* |
| **News app** | No |
| **Government app** | No |
| **Financial features** | None |
| **Health** | No health features |
| **Camera permission** | Used only to scan the pairing QR code |
| **Contacts permission** | Read on the old phone, write on the new phone, solely to transfer the user's own contacts |
| **Calendar permission** | Read on the old phone, write on the new phone, solely to transfer the user's own events |
