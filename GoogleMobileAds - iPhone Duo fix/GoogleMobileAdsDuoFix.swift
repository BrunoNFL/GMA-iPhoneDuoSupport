import Foundation
import UIKit
import GoogleMobileAds
import ObjectiveC
import Darwin
import MachO
import Combine
import SwiftUI

// MARK: - DuoAdMobFix
/// Provides caller-targeted swizzling and posture coordination for Google Mobile Ads SDK on foldable iOS devices (e.g., iPhone Duo).
public final class DuoAdMobFix: Sendable {
    private static var isEnabled = false
    private static let lock = NSLock()
    
    /// Enables targeted swizzling for UIScreen.main, UIWindowScene.interfaceOrientation, and UIApplication.statusBarOrientation.
    /// Only calls originating from Google Mobile Ads (and mediation frameworks) are intercepted.
    public static func enable() {
        lock.lock()
        defer { lock.unlock() }
        guard !isEnabled else { return }
        isEnabled = true
        
        UIScreen.enableFoldableDisplayFix()
        UIWindowScene.enableOrientationFix()
        UIApplication.enableStatusBarOrientationFix()
        
        print(">>> [DuoAdMobFix] Targeted swizzling active for Google Mobile Ads SDK ✅")
    }
}

// MARK: - Targeted UIScreen Swizzling
extension UIScreen {
    private static var isMainScreenSwizzled = false
    private static let screenLock = NSRecursiveLock()
    private static weak var _cachedActiveScreen: UIScreen?
    private static var matchedBases = Set<UnsafeRawPointer>()
    private static var nonMatchedBases = Set<UnsafeRawPointer>()
    
    /// Thread-safe cached reference to the currently active display screen
    fileprivate static var cachedActiveScreen: UIScreen? {
        get {
            screenLock.lock()
            defer { screenLock.unlock() }
            return _cachedActiveScreen
        }
        set {
            screenLock.lock()
            defer { screenLock.unlock() }
            _cachedActiveScreen = newValue
        }
    }
    
    /// Inspects the stack frame image base pointer to verify whether the caller originates from Google Mobile Ads or mediation frameworks.
    fileprivate static func isCallerFromTargetFrameworks(_ caller: UnsafeMutableRawPointer, info: Dl_info) -> Bool {
        guard let fbase = info.dli_fbase else { return false }
        
        let basePtr = UnsafeRawPointer(fbase)
        screenLock.lock()
        if matchedBases.contains(basePtr) {
            screenLock.unlock()
            return true
        }
        if nonMatchedBases.contains(basePtr) {
            screenLock.unlock()
            return false
        }
        screenLock.unlock()
        
        let fname = info.dli_fname != nil ? String(cString: info.dli_fname) : "unknown"
        let sname = info.dli_sname != nil ? String(cString: info.dli_sname) : "unknown"
        
        // Never match the host app's own executable even if the project name contains "GoogleMobileAds"
        if let mainExecutable = Bundle.main.executablePath, fname == mainExecutable {
            screenLock.lock()
            nonMatchedBases.insert(basePtr)
            screenLock.unlock()
            return false
        }
        
        let isAdDylib = fname.contains("/GoogleMobileAds.framework/") ||
                        fname.contains("/GoogleMobileAds.") ||
                        fname.contains("/UserMessagingPlatform.framework/") ||
                        fname.contains("/UserMessagingPlatform.") ||
                        fname.contains("/UnityAds.framework/")
        if isAdDylib {
            screenLock.lock()
            matchedBases.insert(basePtr)
            screenLock.unlock()
            let name = (fname as NSString).lastPathComponent
            print(">>> [DuoAdMobFix] Identified Ad SDK caller from framework \(name) at base \(basePtr) ✅")
            return true
        }
        
        if sname.contains("GAD") {
            print(">>> [DuoAdMobFix] Identified Ad SDK caller from symbol \(sname) in \((fname as NSString).lastPathComponent) ✅")
            return true
        }
        
        let isSystemOrUI = fname.contains("UIKit") || fname.contains("QuartzCore") || fname.contains("CoreGraphics") || fname.contains("SwiftUI")
        if isSystemOrUI {
            screenLock.lock()
            nonMatchedBases.insert(basePtr)
            screenLock.unlock()
        }
        return false
    }
    
    /// Returns the coordinate space bounds of the foreground active scene, falling back to cached screen bounds.
    public static var activeScreenBounds: CGRect {
        if Thread.isMainThread {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }) {
                if #available(iOS 26.0, *) {
                    return activeScene.effectiveGeometry.coordinateSpace.bounds
                } else {
                    return activeScene.coordinateSpace.bounds
                }
            }
            if let firstScene = scenes.first {
                if #available(iOS 26.0, *) {
                    return firstScene.effectiveGeometry.coordinateSpace.bounds
                } else {
                    return firstScene.coordinateSpace.bounds
                }
            }
        }
        return cachedActiveScreen?.bounds ?? .zero
    }
    
    /// Indicates whether the active display has landscape aspect ratio (width > height).
    public static var isCurrentScreenLandscape: Bool {
        let bounds = activeScreenBounds
        return bounds.width > bounds.height
    }
    
    /// Updates the cached active screen. Must ONLY be invoked on the main thread when outside a UIKit transition.
    @MainActor
    public static func updateActiveScreen() {
        guard Thread.isMainThread else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }) {
            cachedActiveScreen = activeScene.screen
            return
        }
        if let firstScene = scenes.first {
            cachedActiveScreen = firstScene.screen
            return
        }
    }
    
    @objc class func dynamic_mainScreen() -> UIScreen {
        var stack = [UnsafeMutableRawPointer?](repeating: nil, count: 6)
        let depth = backtrace(&stack, 6)
        for i in 1..<Int(depth) {
            guard let frame = stack[i] else { continue }
            var info = Dl_info()
            guard dladdr(frame, &info) != 0 else { continue }
            let sname = info.dli_sname != nil ? String(cString: info.dli_sname) : ""
            if sname.contains("dynamic_mainScreen") { continue }
            
            if isCallerFromTargetFrameworks(frame, info: info) {
                if let cached = cachedActiveScreen {
                    return cached
                }
            }
            break
        }
        return self.dynamic_mainScreen()
    }
    
    fileprivate static func enableFoldableDisplayFix() {
        guard !isMainScreenSwizzled else { return }
        isMainScreenSwizzled = true
        
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                updateActiveScreen()
            }
        } else {
            DispatchQueue.main.async {
                updateActiveScreen()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let scene = notification.object as? UIWindowScene {
                cachedActiveScreen = scene.screen
            } else {
                DispatchQueue.main.async {
                    updateActiveScreen()
                }
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let window = notification.object as? UIWindow, let scene = window.windowScene {
                cachedActiveScreen = scene.screen
            } else {
                DispatchQueue.main.async {
                    updateActiveScreen()
                }
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: UIScreen.modeDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                updateActiveScreen()
                DuoInterstitialAdManager.shared.handlePostureOrSizeChange()
            }
        }
        
        guard let screenClass: AnyClass = object_getClass(UIScreen.self),
              let origMethod = class_getInstanceMethod(screenClass, NSSelectorFromString("mainScreen")),
              let swizMethod = class_getInstanceMethod(screenClass, #selector(UIScreen.dynamic_mainScreen)) else {
            print(">>> [DuoAdMobFix] Error: Could not find UIScreen.main methods to swizzle")
            return
        }
        method_exchangeImplementations(origMethod, swizMethod)
    }
}

// MARK: - Targeted UIWindowScene Orientation Swizzling
extension UIWindowScene {
    private static var isOrientationSwizzled = false
    
    @objc func dynamic_interfaceOrientation() -> UIInterfaceOrientation {
        var stack = [UnsafeMutableRawPointer?](repeating: nil, count: 6)
        let depth = backtrace(&stack, 6)
        for i in 1..<Int(depth) {
            guard let frame = stack[i] else { continue }
            var info = Dl_info()
            guard dladdr(frame, &info) != 0 else { continue }
            let sname = info.dli_sname != nil ? String(cString: info.dli_sname) : ""
            if sname.contains("dynamic_interfaceOrientation") { continue }
            
            if UIScreen.isCallerFromTargetFrameworks(frame, info: info) {
                let bounds: CGRect
                if #available(iOS 26.0, *) {
                    bounds = self.effectiveGeometry.coordinateSpace.bounds
                } else {
                    bounds = self.coordinateSpace.bounds
                }
                return bounds.width > bounds.height ? .landscapeLeft : .portrait
            }
            break
        }
        return self.dynamic_interfaceOrientation()
    }
    
    fileprivate static func enableOrientationFix() {
        guard !isOrientationSwizzled else { return }
        isOrientationSwizzled = true
        
        guard let origMethod = class_getInstanceMethod(UIWindowScene.self, NSSelectorFromString("interfaceOrientation")),
              let swizMethod = class_getInstanceMethod(UIWindowScene.self, #selector(UIWindowScene.dynamic_interfaceOrientation)) else {
            print(">>> [DuoAdMobFix] Error: Could not find UIWindowScene.interfaceOrientation methods to swizzle")
            return
        }
        method_exchangeImplementations(origMethod, swizMethod)
    }
}

// MARK: - Targeted UIApplication Orientation Swizzling
extension UIApplication {
    private static var isStatusBarOrientationSwizzled = false
    
    @objc func dynamic_statusBarOrientation() -> UIInterfaceOrientation {
        var stack = [UnsafeMutableRawPointer?](repeating: nil, count: 6)
        let depth = backtrace(&stack, 6)
        for i in 1..<Int(depth) {
            guard let frame = stack[i] else { continue }
            var info = Dl_info()
            guard dladdr(frame, &info) != 0 else { continue }
            let sname = info.dli_sname != nil ? String(cString: info.dli_sname) : ""
            if sname.contains("dynamic_statusBarOrientation") { continue }
            
            if UIScreen.isCallerFromTargetFrameworks(frame, info: info) {
                let bounds = UIScreen.activeScreenBounds
                return bounds.width > bounds.height ? .landscapeLeft : .portrait
            }
            break
        }
        return self.dynamic_statusBarOrientation()
    }
    
    fileprivate static func enableStatusBarOrientationFix() {
        guard !isStatusBarOrientationSwizzled else { return }
        isStatusBarOrientationSwizzled = true
        
        guard let origMethod = class_getInstanceMethod(UIApplication.self, NSSelectorFromString("statusBarOrientation")),
              let swizMethod = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.dynamic_statusBarOrientation)) else {
            print(">>> [DuoAdMobFix] Error: Could not find UIApplication.statusBarOrientation methods to swizzle")
            return
        }
        method_exchangeImplementations(origMethod, swizMethod)
    }
}

// MARK: - Posture-Aware Interstitial Ad Manager
@MainActor
public final class DuoInterstitialAdManager: NSObject, ObservableObject, FullScreenContentDelegate {
    public static let shared = DuoInterstitialAdManager()
    
    public nonisolated static let defaultTestAdUnitId = "ca-app-pub-3940256099942544/4411468910"
    
    @Published public private(set) var isReady = false
    @Published public private(set) var isLoading = false
    @Published public private(set) var isPresenting = false
    @Published public private(set) var statusMessage = "Not loaded"
    @Published public private(set) var postureName = "Folded"
    @Published public private(set) var screenDimensions = CGSize.zero
    
    private var interstitial: InterstitialAd?
    private var lastAdUnitId: String = DuoInterstitialAdManager.defaultTestAdUnitId
    private var loadedIsLandscape: Bool?
    private var loadedScreenBounds: CGRect?
    private var loadGeneration: Int = 0
    
    private override init() {
        super.init()
        updatePostureInfo()
    }
    
    /// Updates the public display posture and geometry status
    public func updatePostureInfo(newSize: CGSize? = nil) {
        let bounds = UIScreen.activeScreenBounds
        let size = newSize ?? bounds.size
        self.screenDimensions = size
        
        let isLandscape = size.width > size.height
        if isLandscape {
            self.postureName = "Unfolded (Display 3)"
        } else {
            self.postureName = "Folded (Display 1)"
        }
    }
    
    /// Discards any preloaded interstitial ad, incrementing the generation counter to invalidate in-flight network requests.
    public func discardPreloadedAd(reason: String) {
        loadGeneration += 1
        interstitial = nil
        loadedIsLandscape = nil
        loadedScreenBounds = nil
        isReady = false
        statusMessage = "Discarded (\(reason))"
        print(">>> [DuoAdMobFix] Discarded preloaded ad: \(reason) [gen: \(loadGeneration)]")
    }
    
    /// Called when the screen mode, folding posture, or window size changes.
    public func handlePostureOrSizeChange(newSize: CGSize? = nil) {
        UIScreen.updateActiveScreen()
        updatePostureInfo(newSize: newSize)
        
        if isPresenting {
            print(">>> [DuoAdMobFix] Posture changed during active ad presentation. Presentation will finish naturally.")
            return
        }
        
        let activeBounds = UIScreen.activeScreenBounds
        let currentIsLandscape = newSize.map { $0.width > $0.height } ?? (activeBounds.width > activeBounds.height)
        
        let orientationChanged = loadedIsLandscape != nil && loadedIsLandscape != currentIsLandscape
        let sizeChanged = loadedScreenBounds != nil && (abs(loadedScreenBounds!.width - activeBounds.width) > 50 || abs(loadedScreenBounds!.height - activeBounds.height) > 50)
        
        if orientationChanged || sizeChanged {
            discardPreloadedAd(reason: "Display changed to \(currentIsLandscape ? "landscape" : "portrait") (\(Int(activeBounds.width))x\(Int(activeBounds.height)))")
            loadInterstitial(adUnitId: lastAdUnitId)
        }
    }
    
    /// Loads an interstitial ad matching the currently active screen posture.
    public func loadInterstitial(adUnitId: String = DuoInterstitialAdManager.defaultTestAdUnitId) {
        self.lastAdUnitId = adUnitId
        
        guard !isPresenting else {
            print(">>> [DuoAdMobFix] Skip load: An ad is currently presenting")
            return
        }
        
        guard !isLoading else {
            print(">>> [DuoAdMobFix] Skip load: Interstitial request already in flight")
            return
        }
        
        DuoAdMobFix.enable()
        UIScreen.updateActiveScreen()
        updatePostureInfo()
        
        let activeBounds = UIScreen.activeScreenBounds
        let isLandscape = activeBounds.width > activeBounds.height
        
        // Reuse fresh ad if it already matches the active posture
        if interstitial != nil, loadedIsLandscape == isLandscape {
            print(">>> [DuoAdMobFix] Existing preloaded ad matches active posture (\(isLandscape ? "landscape" : "portrait"))")
            isReady = true
            statusMessage = "Ready (\(isLandscape ? "Landscape" : "Portrait"))"
            return
        }
        
        if interstitial != nil {
            discardPreloadedAd(reason: "Replacing mismatched ad with fresh one")
        }
        
        let currentGen = self.loadGeneration
        self.isLoading = true
        self.isReady = false
        self.statusMessage = "Loading for \(isLandscape ? "Landscape" : "Portrait")..."
        print(">>> [DuoAdMobFix] Requesting Interstitial [gen: \(currentGen), posture: \(isLandscape ? "landscape" : "portrait")]...")
        
        let request = Request()
        InterstitialAd.load(with: adUnitId, request: request) { [weak self] ad, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLoading = false
                
                // Discard if invalidated while network request was in flight
                guard self.loadGeneration == currentGen else {
                    print(">>> [DuoAdMobFix] Dropped loaded ad: generation changed (\(currentGen) vs \(self.loadGeneration))")
                    return
                }
                
                if let error = error {
                    print(">>> [DuoAdMobFix] Error: Load failed - \(error.localizedDescription)")
                    self.statusMessage = "Error: \(error.localizedDescription)"
                    return
                }
                
                // Confirm posture did not change while request was downloading
                let currentIsLandscape = UIScreen.isCurrentScreenLandscape
                guard currentIsLandscape == isLandscape else {
                    print(">>> [DuoAdMobFix] Dropped loaded ad: posture changed during download")
                    self.loadInterstitial(adUnitId: adUnitId)
                    return
                }
                
                print(">>> [DuoAdMobFix] Interstitial loaded successfully for \(isLandscape ? "landscape" : "portrait") ✅")
                self.interstitial = ad
                self.loadedIsLandscape = isLandscape
                self.loadedScreenBounds = activeBounds
                self.interstitial?.fullScreenContentDelegate = self
                self.isReady = true
                self.statusMessage = "Ready (\(isLandscape ? "Landscape" : "Portrait"))"
            }
        }
    }
    
    /// Safely presents the loaded interstitial ad.
    public func showInterstitial() {
        guard !isPresenting else {
            print(">>> [DuoAdMobFix] Skip show: Ad already presenting")
            return
        }
        
        DuoAdMobFix.enable()
        UIScreen.updateActiveScreen()
        
        let currentIsLandscape = UIScreen.isCurrentScreenLandscape
        if let loaded = loadedIsLandscape, loaded != currentIsLandscape {
            print(">>> [DuoAdMobFix] Posture mismatch on presentation. Reloading fresh ad...")
            discardPreloadedAd(reason: "Posture mismatch at show")
            loadInterstitial(adUnitId: lastAdUnitId)
            return
        }
        
        guard let ad = interstitial else {
            print(">>> [DuoAdMobFix] Skip show: No ad ready")
            statusMessage = "Ad not ready"
            if !isLoading {
                loadInterstitial(adUnitId: lastAdUnitId)
            }
            return
        }
        
        guard let root = getTopViewController() else {
            print(">>> [DuoAdMobFix] Error: No root view controller found")
            return
        }
        
        guard root.presentedViewController == nil, !root.isBeingPresented, !root.isBeingDismissed else {
            print(">>> [DuoAdMobFix] Skip show: Root view controller is busy presenting/dismissing another view")
            return
        }
        
        print(">>> [DuoAdMobFix] Presenting Interstitial (posture: \(currentIsLandscape ? "landscape" : "portrait"))...")
        self.isPresenting = true
        self.statusMessage = "Presenting..."
        ad.present(from: root)
        self.interstitial = nil
        self.loadedIsLandscape = nil
        self.loadedScreenBounds = nil
        self.isReady = false
    }
    
    private func getTopViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        let window = activeScene?.windows.first(where: { $0.isKeyWindow }) ?? activeScene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
    
    // MARK: - FullScreenContentDelegate
    public nonisolated func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        print(">>> [DuoAdMobFix] Ad dismissed cleanly ✅")
        Task { @MainActor in
            self.isPresenting = false
            self.statusMessage = "Dismissed. Preparing next ad..."
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !self.isPresenting else { return }
            self.loadInterstitial(adUnitId: self.lastAdUnitId)
        }
    }
    
    public nonisolated func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        print(">>> [DuoAdMobFix] Ad presentation failed: \(error.localizedDescription) ❌")
        Task { @MainActor in
            self.isPresenting = false
            self.statusMessage = "Failed: \(error.localizedDescription)"
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !self.isPresenting else { return }
            self.loadInterstitial(adUnitId: self.lastAdUnitId)
        }
    }
}

// MARK: - SwiftUI Posture Coordination Extension
extension View {
    /// Automatically synchronizes window geometry and folding posture with DuoInterstitialAdManager on foldable devices.
    @MainActor
    public func duoAdMobPostureSync() -> some View {
        self.onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            DuoInterstitialAdManager.shared.handlePostureOrSizeChange(newSize: newSize)
        }
    }
}

