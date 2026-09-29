import SwiftUI
import GoogleMobileAds

// MARK: - Main Showcase View
struct ContentView: View {
    @StateObject private var adManager = DuoInterstitialAdManager.shared
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                
                PostureStatusCard(adManager: adManager)
                AdActionButtons(adManager: adManager)
                
                Spacer()
                
                ShowcaseFooter()
            }
            .navigationTitle("iPhone Duo AdMob")
            .navigationBarTitleDisplayMode(.inline)
            .duoAdMobPostureSync()
            .task {
                adManager.loadInterstitial()
            }
        }
    }
}

// MARK: - Posture & Device Info Card
struct PostureStatusCard: View {
    @ObservedObject var adManager: DuoInterstitialAdManager
    
    private var isLandscape: Bool {
        adManager.screenDimensions.width > adManager.screenDimensions.height
    }
    
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: adManager.postureName.contains("Unfolded") ? "ipad.landscape" : "iphone")
                    .font(.system(size: 28))
                    .foregroundColor(.blue)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Display Posture")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(adManager.postureName)
                        .font(.headline)
                        .fontWeight(.bold)
                }
                
                Spacer()
                
                // Aspect Ratio Badge
                Text(isLandscape ? "LANDSCAPE" : "PORTRAIT")
                    .font(.system(size: 11, weight: .heavy))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(isLandscape ? Color.indigo.opacity(0.15) : Color.blue.opacity(0.15))
                    .foregroundColor(isLandscape ? .indigo : .blue)
                    .clipShape(Capsule())
            }
            
            Divider()
            
            HStack {
                Label("Dimensions:", systemImage: "aspectratio")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(adManager.screenDimensions.width)) × \(Int(adManager.screenDimensions.height)) pt")
                    .font(.subheadline.monospaced())
                    .fontWeight(.medium)
            }
            
            HStack {
                Label("Ad Status:", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(adManager.isReady ? Color.green : (adManager.isLoading ? Color.orange : Color.gray))
                        .frame(width: 8, height: 8)
                    Text(adManager.statusMessage)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
            }
        }
        .padding(20)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 24)
    }
}

// MARK: - Action Buttons Component
struct AdActionButtons: View {
    @ObservedObject var adManager: DuoInterstitialAdManager
    
    var body: some View {
        VStack(spacing: 16) {
            Button {
                adManager.showInterstitial()
            } label: {
                HStack(spacing: 12) {
                    if adManager.isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "play.rectangle.fill")
                            .font(.title3)
                    }
                    
                    Text(adManager.isReady ? "Show Interstitial Ad" : (adManager.isLoading ? "Loading Ad..." : "Ad Not Ready"))
                        .font(.headline)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(adManager.isReady ? Color.blue : Color.gray.opacity(0.5))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: adManager.isReady ? Color.blue.opacity(0.3) : Color.clear, radius: 8, y: 4)
            }
            .disabled(!adManager.isReady || adManager.isPresenting)
            
            Button {
                adManager.loadInterstitial()
            } label: {
                Label("Reload Ad Manually", systemImage: "arrow.clockwise")
                    .font(.subheadline)
                    .foregroundColor(.blue)
            }
            .disabled(adManager.isLoading || adManager.isPresenting)
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Footer Component
struct ShowcaseFooter: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("Google Mobile Ads iPhone Duo Fix")
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)
            Text("Targeted swizzling active for GAD framework callers only.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.bottom, 12)
    }
}

#Preview {
    ContentView()
}
