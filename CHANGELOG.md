# Changelog

All notable changes to **Android Phone Clone (Phone Transfer)** are listed here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

| Version | Theme | Protocol | Install over previous? | Build time |
|---|---|:---:|:---:|:---:|
| [4.0.0](#400--2026-11-08) | Fast: parallel lanes, batches, duplicate cloning; works with v3 phones | 4 (talks 3) | ✅ even mid-transfer | ~15 min |
| [3.0.0](#300--2026-11-08) | Unstoppable: survives timeouts, drops, pauses and the app being closed | 3 | ✅ | ~16 min |
| [2.0.0](#200--2026-11-08) | Exact: same folders, same dates, verified, no duplicates | 2 | ✅ | ~14 min |
| [1.0.0](#100--2026-11-08) | It works: first Wi-Fi transfer between two phones | 1 | — | ~43 min |

> v1–v3 each changed the network protocol, so both phones had to match. **v4 also talks to v3 phones** (in either direction), falling back to one file at a time; full speed needs v4 on both.

---

## [4.2.1] — 2026-11-08

### Fixed
- **"Looking for identical files" looked stuck** on phones with many files. It now shows a progress bar with files and bytes checked (e.g. *1,240 of 5,300 files • 3.2 GB of 9.8 GB*) and the file being checked, updated in steps of at most 20 files or 64 MB.
- New **"Skip this step and start sending"** button. Identical files are then sent normally, and there are still no duplicates on the new phone.

## [4.2.0] — 2026-11-08

### Why this release
On a real test, the old phone was running the hotspot and its battery died. The hotspot disappeared, and after the restart the new phone had a different address. The only way to get a fresh QR code was to force-stop the app from Settings. 4.2.0 makes reconnecting a one-tap step.

### Added
- **New phone shows its address** at the top of the progress screen, so you can compare it with the address the old phone is trying.
- **"Show QR" button** on the progress screen, with the same pairing code and the current address.
- **Connection-lost view.** If the old phone goes silent for 15 s in the middle of a transfer, the new phone switches to *Connection to the old phone lost* and shows the QR code. It also says when its own address has changed.
- **Address refresh.** The new phone re-checks its address every 3 s, so the QR code and address follow hotspot or Wi-Fi changes.
- **Continue → scanner.** If *Continue previous transfer* can't reach the saved address, the old phone opens the scanner straight away and keeps your category choices.
- The old phone's *Waiting for the new phone…* banner shows the address it's trying.
- 1 new test: old phone vanishes mid-file, the new phone's address changes, then reconnecting via the fresh QR completes the transfer exactly (**11 tests**).

## [4.1.0] — 2026-11-08 *(prepared for Google Play, not published)*

- App renamed to **Phone Clone**, with the permanent package name `com.mrajkishor.phoneclone` and target API 36.
- Release signing through an upload key in `android/key.properties`, which is never committed.
- New adaptive, themed launcher icon, Play icon and feature graphic.
- Privacy policy (`PRIVACY.md`) and the Play launch kit in `docs/play-store/`.

## [4.0.0] — 2026-11-08

### Why this release
v3 sent one file at a time. For large videos that was fine, since Wi-Fi was the limit. For a phone full of photos and documents, each file cost about 3 round trips plus a wait for Android's media index, so the Wi-Fi sat idle much of the time. v4 keeps every v3 guarantee and makes transfers **several times faster**. It's also the first version you can **update to in the middle of a transfer**.

### Added
- **Parallel lanes.** 2–6 transfers in flight at once. It starts with 3, adds a lane every 4 s while speed keeps rising, and drops one on stalls or errors. Lane 1 takes large files (over 2 MB), so a big video never blocks the photos behind it.
- **Small-file batches.** Files of 2 MB or less are sent up to 300 at a time (max 32 MB) in one request (`POST /batch`). Each file carries its own SHA-256 and is verified and saved as soon as it arrives. If a batch stalls, only the file the new phone was stuck on goes to the retry queue; the files already saved are kept and the rest are re-sent.
- **Duplicate cloning.** Files of 64 KB or more that share a name and size are checksummed first. Identical content is sent once, and the new phone copies it to the other paths locally (`POST /clone`). It falls back to a normal upload if the original didn't arrive.
- **Background checksums.** SHA-256 now runs in worker isolates on both phones, so the main thread only moves bytes.
- **Batched media indexing.** New files are reported to Android's media index 200 at a time, every 2 s, instead of waiting after each file. Original dates are restored directly.
- **1 MB reads** for fewer, larger socket writes.
- **One-tap "Continue previous transfer".** The old phone remembers the last unfinished transfer (pairing and selected categories), and the new phone keeps its pairing code and port for 7 days. No QR scan is needed to continue after a restart or an update.
- **Update from v3 mid-transfer.** v4 reads v3's index (and v2's `received_v2.jsonl`), uses the same staging folder and file IDs, and is signed with the same key. A transfer paused on v3 continues on v4 from the exact byte, with nothing re-sent.
- **Works with v3 phones in both directions.** The QR code still says `v: 3` for v3 apps and adds `max: 4`. A v4 old phone sending to a v3 new phone uses compatibility mode (one file at a time); a v3 old phone sending to a v4 new phone works exactly like v3.
- **UI.** Every file and batch in flight is shown with live bytes, plus the lane count, a fast/compatibility mode indicator, cloned and resumed totals, a "Speed-ups" summary at the end, and a fastest-setup tip on the QR screen (5 GHz hotspot).
- **4 new tests:** speed features (lanes, batches, cloning, exact copies), QR compatibility, update from v3 with a half-sent file and old index records, and a v3 new phone. **10 tests in total**, all passing.

### Changed
- Protocol version **3 → 4**. The new phone keeps every v3 endpoint, and `/ping` now reports its version.
- A stuck file inside a batch is identified from what the new phone has actually saved, rather than from what the old phone last wrote, since small files can be fully buffered before the new phone reads them.

## [3.0.0] — 2026-11-08

### Why this release
v2 made every copy exact. Long transfers could still go wrong, though. A file that stalled held up everything behind it, a Wi-Fi drop failed every remaining file, there was no way to take a break, a half-sent 4 GB video started over from zero, and closing the app stopped the transfer. v3 fixes all of that.

### Added
- **Live, byte-level progress.** Both phones show the file in flight (name, folder, bytes so far out of the total, % and a progress bar), updated about 10 times a second, plus a *Just finished* list.
- **Stall timeout.** A file with no progress for **20 s** is aborted and skipped, and the transfer moves on to the next file.
- **Retry queue (DLQ).** Skipped and failed files are listed on both phones with their path, attempt count and last error. The queue is retried **after all other files**, in rounds with **exponential backoff** (5 s → 10 s → 20 s → 40 s, ±20% jitter), up to **5 attempts** per file.
- **Final report.** A 🎉 *Hurray!* screen when everything arrives. Otherwise, each failed file with its **full path and error**, a **Copy list** button for moving files manually, and a **Try the failed files again** button.
- **Pause / Resume.** Pause stops mid-file. Resume continues from the **exact byte** where it stopped. The stall timeout doesn't count while paused.
- **Byte-level resume.** The new phone keeps partly received files in a hidden staging folder. Pauses, retries, reconnects and even app restarts continue from the last received byte instead of starting the file over.
- **Automatic reconnect.** If the new phone becomes unreachable, the app shows *Waiting for the new phone…*, re-checks with backoff (2 s → 4 s → 8 s → 15 s), and carries on when it's back. A connection drop is not counted as a file failure.
- **Background running.** An Android foreground service with a progress notification, a CPU wake lock and a Wi-Fi lock. The Flutter engine is owned by the app process instead of the screen, so the transfer continues after pressing Back or Home, or after swiping the app away. Tapping the notification reopens the running transfer.
- **Status mirroring.** The old phone sends a heartbeat every second, so the new phone shows the same overall progress, paused or reconnecting state, and retry queue.
- New protocol endpoints: `/status` (resume point), `/state` (heartbeat). `/upload` now takes an `offset`.
- Tests for: a stalled file being queued and recovered after the others, a permanently failing file ending up in the final list with its path and error, and pause mid-file resuming at the same byte. That's **6 end-to-end tests** in total.

### Changed
- **Duplicate detection** is now described as an *index*: path + size + modified time → SHA-256 and saved location, stored persistently on the new phone. It's checked before every run, and a content check still applies if the index is lost.
- The staging folder is no longer wiped when the app starts. It's cleared only after a fully successful transfer, so partial files can resume.
- Upload IDs are now stable per file version (derived from its key), which is what allows resuming across sessions.
- The Back button during a transfer sends the app to the background instead of asking to stop.
- Protocol version **2 → 3**.

### Fixed
- An older upload that was stuck (for example, after a network drop) could still be writing when a newer retry of the same file started. Now only one writer per file is allowed. A newer request takes over immediately and the older one steps aside.

---

## [2.0.0] — 2026-11-08

### Why this release
A line-by-line review of v1 against two requirements — *"nothing on the old phone changes"* and *"nothing on the new phone is duplicated, modified or missed"* — found that the first held but the second didn't. On top of that, documents had to be picked by hand, so files could easily be missed.

### Added
- **Automatic detection of every file.** With *All files access*, the old phone scans its entire storage (including SD cards) in a background isolate and groups files into Photos, Videos, Music & audio, Documents, Archives, App installers (APK), Other media, Other files, and Hidden files (off by default). Each group shows a count and size, with an on/off switch.
- **Same folders.** Every file is written to the same relative path it had on the old phone, such as `DCIM/Camera` or `Documents/Bills`.
- **Original dates.** The modified time is restored and Android's media index is refreshed, so the gallery timeline is unchanged.
- **SHA-256 verification.** The old phone hashes while streaming, the new phone hashes what it received, and a file is only kept if the two match. A mismatched file is re-sent, up to 3 tries.
- **Duplicate protection.**
  - A persistent record of received files lets repeat runs skip what's already there.
  - A file with the same name and checksum is never written twice, even if the record is lost.
  - A different file with the same name is saved beside it as `name (1).ext`.
  - A repeated commit is recognised and doesn't create a copy.
- **Resume after interruption.** *Send again* continues and skips files that already arrived.
- **Contacts:** sent as JSON with all fields and full-size photos. Contacts that already exist (same phone number or email) are skipped.
- **Progress in bytes**, with percentage, speed and time left.
- **Reports on both phones**: copied, already there and failed, for each category.
- **Permission screen** explaining *All files access*, with a button that opens the right Settings screen.
- The first **end-to-end tests**: scan classification, exact copy with the old phone unchanged, re-runs, a lost record, a name clash, and stop-and-resume.

### Changed
- Dependencies trimmed: `photo_manager`, `file_picker`, `network_info_plus` and `wakelock_plus` were replaced with small native helpers in `MainActivity.kt` (media index query, storage roots, file dates, keep screen on).
- Protocol version **1 → 2** (two-step upload → commit).

### Removed
- Manual file picking. Every file is now found automatically.

---

## [1.0.0] — 2026-11-08

### Added
- First release: a Flutter app for Android that transfers data from an old phone to a new one over **local Wi-Fi or hotspot**, with no cloud involved.
- **Pairing by QR code.** The new phone shows its address and a 6-digit code, and the old phone scans it. Manual entry is also available.
- Transfers **photos, videos, music, contacts** (as vCards), and **documents you pick by hand**.
- Photos and videos are saved to the Gallery, music to `Music/PhoneTransfer`, and files to `Download/PhoneTransfer`.
- Progress by file count, with a summary on both phones.
- Up to 3 retries per file; screen kept on during the transfer.

### Fixed (during the first build)
- Updated plugins to versions compatible with current Android SDKs (`file_picker`, `flutter_contacts`, `mobile_scanner`, `permission_handler`), and adapted the code to their new APIs.
- Raised `compileSdk` to 37 and reduced Gradle memory so the release build completes.

### Known issues (fixed in 2.0.0)
- Photos and videos got *today's* date, which mixed up the gallery timeline.
- Albums were merged into one folder.
- Running the transfer twice duplicated everything, and contacts synced through Google could appear twice.
- No checksum verification.
- Documents had to be picked by hand, so files could be missed.

[4.0.0]: https://github.com/mrajkishor/Android-Phone-Clone/releases/tag/v4.0.0
[3.0.0]: https://github.com/mrajkishor/Android-Phone-Clone/releases/tag/v3.0.0
[2.0.0]: #200--2026-11-08
[1.0.0]: #100--2026-11-08
