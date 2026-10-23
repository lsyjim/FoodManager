import GoogleMobileAds
import UIKit
import UserMessagingPlatform
import os

/// Google UMP consent. Shows the consent / privacy message only where required (e.g. EEA, UK).
/// Personalization follows the user's choice; ads are never requested before `canRequestAds`.
@MainActor
final class GoogleConsentProvider: AdConsentProviding {
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "Consent")

    private var current: ConsentResult {
        ConsentResult(canRequestAds: ConsentInformation.shared.canRequestAds,
                      privacyOptionsRequired: ConsentInformation.shared.privacyOptionsRequirementStatus == .required)
    }

    func gatherConsent(from viewController: UIViewController) async -> ConsentResult {
        let parameters = RequestParameters()
        do {
            try await ConsentInformation.shared.requestConsentInfoUpdate(with: parameters)
            try await ConsentForm.loadAndPresentIfRequired(from: viewController)
        } catch {
            // Offline or service error: fall back to the consent stored from earlier sessions (may be "no ads").
            logger.error("Consent update failed: \(String(describing: error), privacy: .private)")
        }
        return current
    }

    func presentPrivacyOptions(from viewController: UIViewController) async -> ConsentResult {
        do {
            try await ConsentForm.presentPrivacyOptionsForm(from: viewController)
        } catch {
            logger.error("Privacy options failed: \(String(describing: error), privacy: .private)")
        }
        return current
    }

    #if DEBUG
    func resetConsent() { ConsentInformation.shared.reset() }
    #endif
}

@MainActor
final class GoogleAdSDK: AdSDKStarting {
    func start() async {
        _ = await MobileAds.shared.start()
    }
}

/// Large anchored adaptive banner backed by Google's `BannerView`.
@MainActor
final class GoogleBannerLoader: NSObject, BannerAdLoading, BannerViewDelegate {
    var prefersCompact = false
    var onLoaded: (() -> Void)?
    var onFailed: ((Error) -> Void)?
    private var banner: BannerView?
    private let unitID: String

    init(unitID: String) { self.unitID = unitID }

    var view: UIView? { banner }

    func load(width: CGFloat, rootViewController: UIViewController) -> CGSize {
        let size = Self.adSize(width: width, compact: prefersCompact)
        let banner = self.banner ?? BannerView(adSize: size)
        banner.adSize = size
        banner.adUnitID = unitID
        banner.rootViewController = rootViewController
        banner.delegate = self
        self.banner = banner
        banner.load(Request())
        return size.size
    }

    static func adSize(width: CGFloat, compact: Bool) -> AdSize {
        // Short screens: the standard 320×50 banner; otherwise Google's large anchored adaptive size.
        compact ? AdSizeBanner : largeAnchoredAdaptiveBanner(width: width)
    }

    /// Height Google will use for a banner of this width (before loading).
    static func estimatedHeight(width: CGFloat, compact: Bool) -> CGFloat {
        adSize(width: width, compact: compact).size.height
    }

    func destroy() {
        banner?.delegate = nil
        banner?.removeFromSuperview()
        banner = nil
    }

    nonisolated func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        MainActor.assumeIsolated { onLoaded?() }
    }

    nonisolated func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        MainActor.assumeIsolated { onFailed?(error) }
    }
}

/// One Google `InterstitialAd`, loaded on demand and used once (Google ads can't be shown twice).
@MainActor
final class GoogleInterstitialLoader: NSObject, InterstitialAdLoading, FullScreenContentDelegate {
    private var ad: InterstitialAd?
    private var onDismiss: ((Bool) -> Void)?
    private(set) var isLoading = false
    private let logger = Logger(subsystem: "FoodManager.HowCode", category: "Ads")

    var isReady: Bool { ad != nil }

    func load(unitID: String, completion: @escaping (Bool) -> Void) {
        guard !isLoading else { return completion(false) }
        isLoading = true
        InterstitialAd.load(with: unitID, request: Request()) { [weak self] ad, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isLoading = false
                if let error {
                    // No fill / network / configuration: the app simply carries on without an ad.
                    self.logger.notice("Interstitial load failed: \(String(describing: error), privacy: .private)")
                    completion(false)
                    return
                }
                self.ad = ad
                ad?.fullScreenContentDelegate = self
                completion(ad != nil)
            }
        }
    }

    func present(from viewController: UIViewController, onDismiss: @escaping (Bool) -> Void) -> Bool {
        guard let ad else { return false }
        self.onDismiss = onDismiss
        ad.present(from: viewController)
        return true
    }

    nonisolated func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        MainActor.assumeIsolated { finish(shown: true) }
    }

    nonisolated func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        MainActor.assumeIsolated {
            logger.notice("Interstitial failed to present: \(String(describing: error), privacy: .private)")
            finish(shown: false)
        }
    }

    private func finish(shown: Bool) {
        ad = nil // single use
        let callback = onDismiss
        onDismiss = nil
        callback?(shown)
    }
}
