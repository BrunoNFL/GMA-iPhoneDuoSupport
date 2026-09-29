import SwiftUI
import GoogleMobileAds

@main
struct MyApp: App {
    init() {
        // Enable targeted swizzling for Google Mobile Ads callers before starting SDK
        DuoAdMobFix.enable()
        
        MobileAds.shared.start { status in
            print(">>> [Showcase] Google Mobile Ads SDK initialized: \(status.adapterStatusesByClassName)")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
