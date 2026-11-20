# Mac App Store: your checklist

Done already: the sandboxed edition, the signed-`.pkg` build script, the
privacy policy, the listing draft and five screenshots. What's left needs your Apple account,
team **39B92NB2W2**. About 60–90 minutes the first time, plus Apple's review (usually 1–3 days).

## 0. Decide (5 min)

- [x] **Name** on the store: "Notch Planner: Focus & Tasks" (on the Mac it's still "Notch")
- [x] **Price**: Free
- [x] **Version**: 1.0.0 (build 5), set in `Resources/Info.plist`
- [ ] **Listing copy**: read LISTING.md; it's a draft until you approve it
- [x] **Push the repo**, so PRIVACY.md is live at the privacy-policy URL App Store Connect asks for

## 1. Try the sandboxed build on your Mac (10 min)

The store edition runs in Apple's sandbox. Its self-test passes, but nobody has used it by hand yet.
1. Quit Notch (right-click the open notch › Quit), so two don't fight over the notch.
2. Build the test copy. It uses its own app ID, so it can't touch your real tasks:
   `NOTCH_TEST=1 scripts/build-app.sh --appstore`
3. Open `build/NotchTest.app` and check: the notch opens on hover, the calendar prompt appears and
   events show, a task you add is still there after quitting and reopening, a reminder banner drops,
   and the board's "All projects" menu filters the board.
4. Quit it and reopen your normal Notch.

## 2. Certificates, in Xcode (5 min)

Xcode › Settings › Accounts › sign in with your Apple ID › select team 39B92NB2W2 ›
**Manage Certificates…** › **+**, twice:
- [ ] **Apple Distribution** (signs the app)
- [ ] **Mac Installer Distribution** (signs the .pkg)

## 3. App ID and provisioning profile (10 min)

At developer.apple.com › Certificates, Identifiers & Profiles:
- [ ] **Identifiers › +** › App IDs › App › platform macOS › Explicit bundle ID
      `com.dineshrevunuru.notch`. No extra capabilities needed.
- [ ] **Profiles › +** › Distribution › **Mac App Store Connect** › that App ID › your Apple
      Distribution certificate › name it "Notch Mac App Store" › Download.
- [ ] Save the download as `notch/Resources/AppStore/embedded.provisionprofile`
      (git ignores it; it never goes public).

## 4. The app record in App Store Connect (20–30 min)

appstoreconnect.apple.com › Apps › **+** › New App:
- [ ] Platform macOS · Name "Notch Planner: Focus & Tasks" · Primary language English (U.S.) ·
      Bundle ID `com.dineshrevunuru.notch` · SKU, e.g. `NOTCH-MAC-1` · Full access
- [ ] Fill the version page from LISTING.md: subtitle, promotional text, description, keywords,
      support URL, category Productivity
- [ ] Screenshots: the five in `docs/app-store/screenshots/` (2880 × 1800, in order 1–5)
- [ ] **App Privacy** › Get Started › "No, we do not collect data from this app"
- [ ] Privacy Policy URL: `https://github.com/dineshrevunuru/notch/blob/main/PRIVACY.md`
- [ ] Age rating questionnaire: answer None/No throughout → 4+
- [ ] Pricing and Availability: Free, all regions or your pick
- [ ] App Review Information: your contact details, and paste "Notes for App Review" from LISTING.md

## 5. Build and upload (15 min, plus Apple's processing)

1. `scripts/build-app.sh --appstore` makes `dist/Notch-<version>-AppStore.pkg`, signed with both
   certificates. If it says a certificate or the profile is missing, it names which.
2. Get **Transporter** (free, Mac App Store) › sign in › drag the .pkg in › **Deliver**.
3. Processing takes about 15–60 minutes; Apple emails when the build is ready, or if it was rejected
   on upload (the email names the problem).

## 6. Submit (5 min)

- [ ] On the version page, **Build** › select the uploaded build. Export compliance is already
      answered in the app (no encryption beyond Apple's), so it shouldn't ask.
- [ ] **Add for Review** › **Submit**.

## After it's approved

- The store edition moves your existing tasks into its sandbox on first launch. Once you switch to
  it, delete the direct-download copy in /Applications, so the two don't each keep half your tasks.
- Website detection (YouTube, Reddit) stays in the direct-download edition only; the sandbox doesn't
  allow asking browsers for their tabs. The store edition still catches games and video apps.
- Each update: bump the version in `Resources/Info.plist`, run step 5, then submit the new version.

## Next: 1.1 with Live Activities (your decision, 2026-11-19)

Apple's new MacBook Pro has a system Dynamic Island, and apps reach it only through Live
Activities. Those are reported to come to Mac apps in macOS 27.3, which is in beta; today's SDK doesn't
have them. When the 27.3 SDK is released:
- [ ] Notch's focus timer, current task and next meeting become Live Activities, in the menu bar
      on every Mac and in the Dynamic Island on the new MacBook Pro (about 1–2 days, including a move
      to an Xcode project for the widget extension).
- [ ] App Store Connect › Featuring › Nominations › **+** › App Enhancement, at least 2 weeks before the
      update goes out.
- Never call Notch a "Dynamic Island" in the listing or marketing: it's Apple's registered trademark.

If you or a friend has the new MacBook Pro, run `/Applications/Notch.app/Contents/MacOS/Notch --selftest`
on it and send the output: its last lines show whether Notch would sit on top of Apple's island.
