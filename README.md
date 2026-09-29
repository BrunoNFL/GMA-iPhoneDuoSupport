# Fixing Google Mobile Ads (AdMob) on Foldable iOS: The iPhone Duo Guide & Disassembly Analysis

> *A comprehensive technical breakdown of how Apple's foldable iPhone Duo in iOS 27 breaks AdMob's internal viewport calculations, why global method swizzling crashes UIKit, and how to fix it using caller-targeted Mach-O swizzling and generational lifecycle management.*

---

## 📱 Executive Summary

With the introduction of the **iPhone Duo** in **iOS 27**, Apple entered the foldable smartphone era. While SwiftUI and UIKit automatically adapt views across the outer folded screen and the expansive inner canvas, third-party SDKs, most notably **Google Mobile Ads (AdMob)**, were designed around decade-old assumptions regarding orientation and screen aspect ratios.

When running AdMob interstitial or rewarded ads on the unfolded iPhone Duo display:
1. **Ads freeze**: Interstitial creatives load into an incorrect viewport.
2. **Timers stall**: The 5-second countdown timer halts and never finishes.
3. **The close button vanishes**: The native dismiss button (`X`) is never rendered or revealed, trapping users in the ad view and forcing them to force-quit the application.

This repository provides a **production-ready, zero-side-effect drop-in solution** (`GoogleMobileAdsDuoFix.swift`) and a showcase SwiftUI application demonstrating flawless ad presentation across both folded and unfolded postures.

---

## 🔍 The Root Cause: Disassembling AdMob's Viewport Math

Why does AdMob fail exclusively when unfolded? To understand the problem, we analyzed AdMob's binary (`GoogleMobileAds.framework`) using dynamic analysis and disassembly.

### The Upright Landscape Paradox

The iPhone Duo has two primary physical screen configurations:
- **Display 1 (Folded / Outer Screen)**: $428 \times 926$ points (Vertical portrait aspect ratio $\approx 9:19.5$).
- **Display 3 (Unfolded / Inner Dual Screen)**: $951 \times 669$ points (Horizontal landscape aspect ratio $\approx 1.42:1$).

When a user holds the unfolded iPhone Duo upright in their hands, iOS hardware sensors report that the device orientation is **portrait**. Consequently, UIKit reports:
```swift
UIWindowScene.interfaceOrientation == .portrait
UIApplication.statusBarOrientation == .portrait
```

However, the coordinate space bounds of the active screen are:
$$\text{Width} = 951\text{ pt}, \quad \text{Height} = 669\text{ pt}$$

This introduces an architectural paradox: **an upright orientation with a landscape aspect ratio**.

### Reverse Engineering `_GADStandardizedMainScreenPortraitBounds`

Inside Google Mobile Ads, screen dimensions are calculated through an internal routine named `_GADStandardizedMainScreenPortraitBounds`. The compiled ARM64 disassembly contains the following logic:

```assembly
; AdMob queries the current interface orientation
bl      _UIInterfaceOrientation
sub     x8, x0, #3          ; Check if orientation is LandscapeLeft (3) or LandscapeRight (4)
cmp     x8, #2
b.lo    loc_swap_dimensions ; If landscape, swap width and height to normalize portrait bounds

; Device is reported as portrait (x0 == 1)
; AdMob takes width and height as-is:
fcsel   s0, s2, s1, lo      ; Uses raw width (951) as portrait width
fcsel   s1, s1, s2, lo      ; Uses raw height (669) as portrait height
```

Because UIKit reports `.portrait`, AdMob **skips swapping the dimensions**. It records the "standard portrait width" as **951 pt** and the "standard portrait height" as **669 pt**.

When AdMob constructs its ad request payload to the Google ad server:
1. It sends `u_so: p` (User Screen Orientation: Portrait).
2. It requests a portrait-formatted interstitial creative designed for a canvas taller than it is wide.
3. When the creative arrives, AdMob renders it inside an internal `WKWebView` sized to $951 \times 669$ pt.
4. The creative's JavaScript framework attempts to negotiate viewport bounds with `window.screen.width` and `window.orientation`. Because the received creative layout mismatches the host webview viewport, the JavaScript timer loop fails to trigger its completion callback.
5. The native SDK delegate never receives the `adDidCompleteAction` signal, and the dismiss button (`X`) remains permanently hidden.

---

## ⚠️ The Naive Fix & Why It Fails (The UIKit Trap)

When developers first encounter display mismatches on multi-screen setups, the natural instinct is to swizzle `UIScreen.main`:

```swift
// ❌ DO NOT DO THIS GLOBALLY!
@objc class func naive_mainScreen() -> UIScreen {
    return UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.screen }
        .first ?? original_mainScreen()
}
```

### Why Global Swizzling Crashes
During fold/unfold transitions, the iOS system compositor (`backboardd` and `InputUI`) transitions the active window scene from Display 1 to Display 3. 

If `UIScreen.main` is swizzled globally:
- UIKit's internal window transition animations query `UIScreen.main` during layout phases.
- Returning the new screen prematurely before UIKit completes scene reconciliation results in layout recursion or invalid `CALayer` geometry assertions.
- On the iPhone Duo simulator and physical hardware, this manifests as an instant crash in `InputUI` or `SceneKit` (`EXC_BAD_ACCESS` in `UIKitCore`).

**Rule: Never swizzle UIKit methods globally when adapting to device posture.**

---

## 🛠️ The 3-Pillar Solution

Our solution addresses the issue with mathematical precision without disturbing the operating system or application UI frameworks:

```
┌────────────────────────────────────────────────────────┐
│                   DuoAdMobFix Architecture             │
├────────────────────────────────────────────────────────┤
│  1. Targeted Caller Swizzling (Mach-O dladdr)          │
│     ├── UIScreen.main (Ad SDK callers only)            │
│     ├── UIWindowScene.interfaceOrientation (Ad SDK)    │
│     └── UIApplication.statusBarOrientation (Ad SDK)    │
├────────────────────────────────────────────────────────┤
│  2. Generational Posture Invalidation                  │
│     ├── loadGeneration counter                         │
│     ├── Eager posture change discard                   │
│     └── In-flight network request drop                 │
├────────────────────────────────────────────────────────┤
│  3. UIKit Presentation Concurrency Safety              │
│     ├── isPresenting lock                              │
│     └── Hierarchy validation (presentedViewController) │
└────────────────────────────────────────────────────────┘
```

### Pillar 1: Caller-Targeted Swizzling via Mach-O Inspection

Instead of modifying behavior for the entire process, we inspect the call stack using `backtrace` and `dladdr` to determine the calling binary image (`dli_fbase`).

```swift
fileprivate static func isCallerFromTargetFrameworks(_ caller: UnsafeMutableRawPointer, info: Dl_info) -> Bool {
    guard let fbase = info.dli_fbase else { return false }
    let basePtr = UnsafeRawPointer(fbase)
    
    // Fast path: cached matched image base pointers
    if matchedBases.contains(basePtr) { return true }
    if nonMatchedBases.contains(basePtr) { return false }
    
    let fname = info.dli_fname != nil ? String(cString: info.dli_fname) : ""
    let isAdFramework = fname.contains("GoogleMobileAds") || 
                        fname.contains("UserMessagingPlatform") || 
                        fname.contains("Unity")
    
    if isAdFramework {
        matchedBases.insert(basePtr)
        return true
    }
    
    nonMatchedBases.insert(basePtr)
    return false
}
```

We intercept three key methods **strictly for AdMob callers**:
1. **`UIScreen.main`**: Returns the active `UIWindowScene`'s screen rather than the default outer display.
2. **`UIWindowScene.interfaceOrientation`**: When called by AdMob on an unfolded screen ($951 \times 669$ pt), it dynamically returns `.landscapeLeft`. This forces AdMob to calculate dimensions correctly and send `u_so: l` (Landscape).
3. **`UIApplication.statusBarOrientation`**: Coordinates status bar orientation with the active screen aspect ratio.

All other callers (UIKit, SwiftUI, system rendering) execute original system implementations untouched.

### Pillar 2: Generational Posture Invalidation

If an ad is requested while the device is folded (portrait), the Google Ad Server serves an asset optimized for vertical display. If the user unfolds the phone before the ad is presented:
- The preloaded asset cannot simply be stretched to fit $951 \times 669$ pt.
- Displaying a portrait ad on a landscape display triggers the timer freeze bug.

To solve this, `DuoInterstitialAdManager` enforces **Generational Discarding**:
- Every posture change increments a `loadGeneration` integer.
- The preloaded ad is immediately discarded.
- In-flight HTTP requests verify that their captured generation matches the current generation upon completion. If the user unfolded while the request was in-flight, the response is discarded safely.

### Pillar 3: UIKit Presentation Concurrency Safety

Presenting an ad while UIKit is handling a view controller transition or while another modal is appearing results in:
`Warning: Attempt to present <GADFullscreenAdViewController> on <MyApp.ContentView> which is already presenting.`

`DuoInterstitialAdManager` includes robust guards:
- Checks `root.presentedViewController == nil`.
- Verifies `!root.isBeingPresented` and `!root.isBeingDismissed`.
- Uses an atomic `isPresenting` flag to prevent duplicate presentation triggers.

---

## 🚀 Drop-in Integration Guide

### 1. Add `GoogleMobileAdsDuoFix.swift`
Copy `GoogleMobileAdsDuoFix.swift` into your Xcode project. It has zero external dependencies other than the standard `GoogleMobileAds` SDK and Apple frameworks.

### 2. Configure `Info.plist`
Ensure your `GADApplicationIdentifier` is configured in your project settings:
```xml
<key>GADApplicationIdentifier</key>
<string>ca-app-pub-3940256099942544~1458002511</string>
```

### 3. Initialize in `App` or `AppDelegate`
Enable the fix before initializing Google Mobile Ads:

```swift
import SwiftUI
import GoogleMobileAds

@main
struct MyApp: App {
    init() {
        // 1. Enable caller-targeted swizzling
        DuoAdMobFix.enable()
        
        // 2. Initialize Google Mobile Ads SDK
        MobileAds.shared.start { status in
            print("AdMob initialized: \(status)")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

### 4. Present Ads via `DuoInterstitialAdManager`
In your SwiftUI view:

```swift
struct ContentView: View {
    @StateObject private var adManager = DuoInterstitialAdManager.shared
    
    var body: some View {
        VStack(spacing: 20) {
            Button("Show Interstitial Ad") {
                adManager.showInterstitial()
            }
            .disabled(!adManager.isReady)
        }
        .duoAdMobPostureSync() // 🌟 One-line automatic posture & geometry sync
        .task {
            adManager.loadInterstitial()
        }
    }
}
```

---

## 🛡️ Policy & App Store Compliance

A critical design requirement for this fix was **100% compliance** with both Apple App Store Guidelines and Google AdMob Publisher Policies:

| Requirement | Policy | Our Approach | Status |
| :--- | :--- | :--- | :--- |
| **No Ad Creative Tampering** | Google AdMob Terms of Service | Creative HTML, CSS, JavaScript, and WebViews are **never modified or injected**. Only official SDK methods are used. | ✅ Compliant |
| **Public API Usage** | App Store Review (Guideline 2.5.1) | `UIScreen.main`, `UIWindowScene.interfaceOrientation`, `UIApplication.statusBarOrientation` are 100% public APIs. No private SPIs. | ✅ Compliant |
| **Method Swizzling Safety** | App Store Review (Guideline 2.5.2) | Swizzling is standard on iOS (used by Firebase, Sentry, Datadog). Our implementation is strictly isolated to Google Ad binaries via `dladdr` inspection. | ✅ Compliant |
| **OMSDK Ad Verification** | Open Measurement (IAB / Google) | Ad viewability, layout bounds, and session integrity remain completely untouched for OMSDK verification. | ✅ Compliant |

> [!NOTE]
> **Technical Note on Google's Static Test Ads**:
> When testing with the generic Google test ad unit (`ca-app-pub-3940256099942544/4411468910`), Google's CDN serves a specific static image template (`ns-pe79v`) with the unicycle monster. In landscape/unfolded mode, this template exhibits a known WebKit SVG flexbox layout quirk (`align-items: center` with `height: 100%` collapses the SVG width to 0px). In production, real advertisers deliver responsive video, playable MRAID, or properly sized assets which render normally. **Do not inject CSS or JavaScript into the ad WebView to fix test ads**, as altering Google's creative code violates AdMob ToS.


---

## 🧪 Testing on iPhone Duo Simulator

1. **Open the Showcase Project** in Xcode (`GoogleMobileAds - iPhone Duo fix.xcodeproj`).
2. Select the **iPhone Duo** simulator run destination.
3. Build and run (`Cmd + R`).
4. **Folded Mode (Display 1)**:
   - Tap **"Show Interstitial Ad"**.
   - Notice the portrait ad presentation, 5-second countdown timer, and working dismiss button (`X`).
5. **Unfolded Mode (Display 3)**:
   - Unfold the simulator (via Simulator menu: **Features > Device Pose / Posture**).
   - Observe the live UI card update to **"Unfolded (Display 3), LANDSCAPE"**.
   - Tap **"Show Interstitial Ad"**.
   - Notice the ad loads in landscape mode, the timer counts down smoothly, and the dismiss button (`X`) appears and functions reliably.

---

## 📄 License & Attribution
Created by Bruno Cesar. Free to use, adapt, and distribute under the MIT License.
