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
    var onLoaded: (() -> Void)?
    var onFailed: ((Error) -> Void)?
    private var banner: BannerView?
    private let unitID: String

    init(unitID: String) { self.unitID = unitID }

    var view: UIView? { banner }

    func load(width: CGFloat, rootViewController: UIViewController) -> CGSize {
        let size = largeAnchoredAdaptiveBanner(width: width)
        let banner = self.banner ?? BannerView(adSize: size)
        banner.adSize = size
        banner.adUnitID = unitID
        banner.rootViewController = rootViewController
        banner.delegate = self
        self.banner = banner
        banner.load(Request())
        return size.size
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
