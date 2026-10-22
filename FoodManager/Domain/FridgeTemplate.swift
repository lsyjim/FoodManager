import Foundation

/// Describes a fridge illustration and where its editable zones sit inside the drawn artwork.
/// Editable rects are normalized to the open image's full pixel canvas (0...1), so they stay
/// correct at any display size. They are measured by hand from the artwork, never inferred at runtime.
struct FridgeTemplate: Equatable {
    struct CompartmentSeed: Equatable {
        let name: String
        let type: CompartmentType
        let storageType: StorageType
        let height: Double
    }

    let id: String
    let closedImageKey: String
    let openImageKey: String
    /// Pixel aspect of each artwork; also used by the programmatic fallback art.
    let closedImageSize: CGSize
    let openImageSize: CGSize
    let cabinetEditableRect: NormalizedRect
    let doorEditableRect: NormalizedRect
    /// Visible front of the closed door (inside the outline, excluding feet and side edge), normalized to the
    /// closed image. Fridge magnets are positioned relative to this rect.
    let closedDoorRect: NormalizedRect
    let defaultLayout: [ZoneID: [CompartmentSeed]]

    /// Width / height of the closed door surface in points-independent units (used to keep magnet aspect ratios).
    var closedDoorAspect: Double {
        Double(closedDoorRect.width * closedImageSize.width) / Double(closedDoorRect.height * closedImageSize.height)
    }

    func editableRect(for zone: ZoneID) -> NormalizedRect {
        switch zone {
        case .cabinet: return cabinetEditableRect
        case .door: return doorEditableRect
        }
    }
}

extension FridgeTemplate {
    /// Standard single-door fridge. Rects measured from `fridge_open_flat` (761×654 px, transparent margin cropped):
    /// cabinet opening ≈ x 51…360, y 42…574; door inner panel ≈ x 429…720, y 37…600
    /// (the door panel is slightly keystoned, so the rect is inset to stay inside it).
    static let standardSingleDoor = FridgeTemplate(
        id: "standard.single-door.v1",
        closedImageKey: "fridge_closed",
        openImageKey: "fridge_open_flat",
        closedImageSize: CGSize(width: 353, height: 650),
        openImageSize: CGSize(width: 761, height: 654),
        cabinetEditableRect: NormalizedRect(x: 56.0 / 761, y: 48.0 / 654, width: 299.0 / 761, height: 520.0 / 654),
        doorEditableRect: NormalizedRect(x: 440.0 / 761, y: 56.0 / 654, width: 270.0 / 761, height: 526.0 / 654),
        // `fridge_closed` (353×650): door front ≈ x 24…346, y 8…630 (outline measured at x 19–22 / 348–351, y 1–3 / 631–634).
        closedDoorRect: NormalizedRect(x: 24.0 / 353, y: 8.0 / 650, width: 322.0 / 353, height: 622.0 / 650),
        defaultLayout: [
            .cabinet: [
                CompartmentSeed(name: "上層", type: .shelf, storageType: .refrigerated, height: 0.22),
                CompartmentSeed(name: "中層", type: .shelf, storageType: .refrigerated, height: 0.22),
                CompartmentSeed(name: "下層", type: .shelf, storageType: .refrigerated, height: 0.22),
                CompartmentSeed(name: "蔬果抽屜", type: .drawer, storageType: .refrigerated, height: 0.24),
            ],
            .door: [
                CompartmentSeed(name: "門架 1", type: .doorShelf, storageType: .unspecified, height: 0.28),
                CompartmentSeed(name: "門架 2", type: .doorShelf, storageType: .unspecified, height: 0.28),
                CompartmentSeed(name: "門架 3", type: .doorShelf, storageType: .unspecified, height: 0.28),
            ],
        ]
    )
}

enum FridgeTemplateCatalog {
    static let all: [FridgeTemplate] = [.standardSingleDoor]
    static let defaultTemplate = FridgeTemplate.standardSingleDoor

    static func template(id: String) -> FridgeTemplate {
        all.first { $0.id == id } ?? defaultTemplate
    }
}

enum FridgeFactory {
    /// Builds a fresh fridge from a template's default layout, with packed, validated frames.
    /// With `idSeed`, compartment IDs are derived deterministically (used for damaged-layout fallback,
    /// so every launch produces the same IDs instead of a new series).
    static func makeDefault(template: FridgeTemplate = FridgeTemplateCatalog.defaultTemplate,
                            name: String = "我的冰箱", idSeed: UUID? = nil) -> Fridge {
        var fridge = Fridge(id: UUID(), name: name, templateID: template.id, lastDoorState: .closed,
                            cabinetCompartments: [], doorCompartments: [])
        for zone in ZoneID.allCases {
            let seeds = template.defaultLayout[zone] ?? []
            let compartments = seeds.enumerated().map { index, seed in
                Compartment(id: idSeed.map { FridgeLayoutRepair.deterministicID(seed: $0, salt: "default-\(zone.rawValue)-\(index)") }
                                ?? UUID(),
                            parentZoneID: zone, name: seed.name, type: seed.type,
                            storageType: seed.storageType, sortOrder: index,
                            normalizedFrame: NormalizedRect(x: 0, y: 0, width: 1, height: seed.height))
            }
            fridge.setCompartments(FridgeLayoutEngine.pack(compartments), in: zone)
        }
        return fridge
    }
}
