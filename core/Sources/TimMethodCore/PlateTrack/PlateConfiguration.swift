import Foundation

/// The real-world diameter Track A (SPEC §8) assumes for whatever is being
/// tracked, and where that number came from.
///
/// This is a closed catalog of known sizes plus one case for a value the
/// user supplied — deliberately kept as two different *kinds* of case so
/// "I picked a standard size" and "I measured (or entered) mine" never
/// collapse into the same untyped `Double`. That distinction is what lets
/// a caller — or a future debugging session — tell a catalog pick from a
/// one-off measurement without re-deriving it from context.
///
/// Scale is only as good as this number. A 2% error here is a 2% error on
/// every velocity and every ROM figure this exercise ever produces
/// (`PlateScale.metresPerPixel` is linear in `millimetres`), and it looks
/// exactly as confident on screen as a correct one. See
/// `PlateConfigurationLookup` for how an *absent* configuration is kept
/// from silently becoming this number's most dangerous case: a guess.
public enum PlateConfiguration: Sendable, Equatable {
    /// Olympic and bumper plates: both are 450 mm regardless of weight
    /// (SPEC §8) — the one size in this catalog that is actually
    /// standardized across manufacturers.
    case olympicOrBumper

    /// A standard 1" plate. These are not manufacturer-standardized the
    /// way Olympic/bumper plates are (SPEC §8: "standard 1-inch plates
    /// vary"), so this carries one of a small, closed set of common sizes
    /// rather than an arbitrary `Double` — "pick from a list," per the
    /// task brief, not "type a number and hope."
    case standardOneInch(StandardOneInch)

    /// A dumbbell end-cap diameter, millimetres, entered once per pair
    /// (SPEC §8). Kept distinct from `.custom` even though both carry a
    /// user-supplied `Double`: a dumbbell end-cap is measured directly off
    /// the object in hand (calipers, a ruler), never derived from the
    /// reference-object flow (`ReferenceMeasurement`) that `.custom`
    /// typically comes from.
    case dumbbellEndCap(millimetres: Double)

    /// A one-off measured diameter for anything not covered above —
    /// typically the output of `ReferenceMeasurement.deriveDiameter()`,
    /// but also usable for a plate directly measured with a tape.
    case custom(millimetres: Double)

    /// A standard 1" plate size, chosen from a small, representative set
    /// of commonly manufactured diameters (converted from common nominal
    /// inch sizes). This list is illustrative, not exhaustive or
    /// authoritative — standard plates vary by manufacturer in a way
    /// Olympic/bumper plates don't (SPEC §8) — so a plate that doesn't
    /// match one of these should be entered via `.custom`, either measured
    /// directly or via `ReferenceMeasurement`, not forced onto the
    /// nearest case here.
    public enum StandardOneInch: Sendable, Equatable, CaseIterable {
        /// 7.5 in, common on smaller standard plates (e.g. 10 lb).
        case small
        /// 9 in, common on mid-weight standard plates (e.g. 25 lb).
        case medium
        /// 10 in, common on heavier standard plates (e.g. 35 lb).
        case large
        /// 11 in — close to, but not, the Olympic 450 mm. Conflating the
        /// two is exactly the mistake keeping this as a separate case
        /// (rather than folding it into `.olympicOrBumper`) prevents.
        case extraLarge

        public var millimetres: Double {
            switch self {
            case .small: 190.5 // 7.5 in * 25.4
            case .medium: 228.6 // 9 in * 25.4
            case .large: 254.0 // 10 in * 25.4
            case .extraLarge: 279.4 // 11 in * 25.4
            }
        }
    }

    /// The diameter this configuration implies, millimetres, regardless of
    /// which case produced it. This is the only place `PlateScale` (or
    /// anything else) should read a number out of a `PlateConfiguration` —
    /// everything downstream should be indifferent to which case it came
    /// from.
    public var millimetres: Double {
        switch self {
        case .olympicOrBumper: 450
        case .standardOneInch(let size): size.millimetres
        case .dumbbellEndCap(let mm): mm
        case .custom(let mm): mm
        }
    }

    /// The plausible range for any real barbell plate or dumbbell end cap,
    /// millimetres. Below the low end nothing sold as a weight plate is
    /// this small; above the high end is roughly 1.3x the largest Olympic
    /// plate and already well past anything real. This exists specifically
    /// to catch the failure mode a mistyped or mis-measured `.custom` /
    /// `.dumbbellEndCap` value produces: a number that type-checks fine and
    /// silently scales every rep wrong (SPEC §8's "worst failure mode").
    public static let plausibleRangeMm: ClosedRange<Double> = 20...600

    /// Whether `millimetres` falls inside `plausibleRangeMm`. Always `true`
    /// for `.olympicOrBumper` and `.standardOneInch` — both are fixed,
    /// known-good catalog values — so this only ever actually rejects a
    /// `.dumbbellEndCap` or `.custom` value someone mistyped or
    /// mismeasured (zero, negative, or absurdly large).
    public var isPlausible: Bool {
        millimetres.isFinite && PlateConfiguration.plausibleRangeMm.contains(millimetres)
    }
}

/// Everything that can go wrong configuring or deriving a
/// `PlateConfiguration`. Every case names the offending value, matching the
/// rest of the codebase's error style (see `FixtureLoadError`) — a
/// rejected diameter should be debuggable from the error alone, not force
/// a re-read of the call site.
public enum PlateConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A diameter outside `PlateConfiguration.plausibleRangeMm` — zero,
    /// negative, non-finite, or absurdly large (e.g. a "5 m plate").
    case implausibleDiameter(millimetres: Double)

    /// A `PlateConfiguration` was set for an exercise whose equipment is
    /// `.bodyweight` — there is no plate to have a diameter (mirrors
    /// `FixtureLoadError.plateDiameterOnBodyweight`, same rule for the
    /// same reason).
    case equipmentHasNoPlate(exerciseId: String, equipment: Equipment)

    public var description: String {
        switch self {
        case .implausibleDiameter(let mm):
            "implausible plate diameter: \(mm) mm (must be in \(PlateConfiguration.plausibleRangeMm))"
        case .equipmentHasNoPlate(let exerciseId, let equipment):
            "exercise \"\(exerciseId)\" is \(equipment) — no plate to have a diameter"
        }
    }
}

/// The result of asking whether an exercise has a configured plate
/// diameter. This exists so that "no configuration" is a distinct, named
/// case a caller must match on — not `nil` folded into `Double?`, which
/// is one `??` away from silently becoming 450 mm. There is deliberately
/// no computed property on this type that hands back a bare
/// `PlateConfiguration?` or `Double?`: the only way to get the diameter out
/// is `requireConfiguration()`, which throws instead of ever defaulting.
///
/// This lines up with `RepSignal.ScaleSource`: `.unconfigured` here is the
/// Track A analogue of `.torsoRelative` there — no absolute scale exists,
/// so absolute quantities derived from it must refuse, not guess.
public enum PlateConfigurationLookup: Sendable, Equatable {
    /// A diameter is on file for this exercise.
    case configured(PlateConfiguration)

    /// No diameter is on file. Track A must refuse rather than assume
    /// 450 mm (SPEC §8's "Done when": "An exercise with no configured
    /// diameter refuses Track A rather than guessing 450 mm").
    case unconfigured

    /// Thrown by `requireConfiguration()` when this is `.unconfigured`.
    public enum RefusalError: Error, Sendable, Equatable, CustomStringConvertible {
        case noConfiguration

        public var description: String {
            "Track A refused: no plate diameter configured for this exercise."
        }
    }

    /// Returns the configured diameter, or throws — never a default.
    ///
    /// This is the forcing function: there is no `?? PlateConfiguration
    /// .olympicOrBumper` anywhere in this file, and there cannot
    /// accidentally be one at any call site either, because the only way
    /// to extract a `PlateConfiguration` from a lookup is through this
    /// `throws` call. (`try?` immediately followed by a hand-written `??`
    /// fallback is still physically possible in Swift — nothing stops
    /// that — but it is a visible, deliberate, greppable act at the call
    /// site, not an accident one `??` away.)
    public func requireConfiguration() throws -> PlateConfiguration {
        switch self {
        case .configured(let configuration): configuration
        case .unconfigured: throw RefusalError.noConfiguration
        }
    }
}

/// Per-exercise plate/equipment diameter configuration, keyed by exercise
/// id (a plain `String`, matching `Fixture.exerciseId` and the future
/// `Exercise.id` from SPEC §12).
///
/// The task brief for `Exercise.plateDiameterMm` (SPEC §8's "Do" list) is
/// to store this on the `Exercise` model — but `Exercise` doesn't exist
/// yet (W8-01 owns the exercise catalog), so this is deliberately a
/// standalone lookup instead of a property bag hung off a model that
/// isn't there. **W8-01 should fold this into `Exercise.plateDiameterMm`
/// when it lands**; until then, this catalog is the source of truth Track
/// A consults. A plain value type on purpose: no database, no
/// persistence, no singleton — a caller owns an instance and threads it
/// through explicitly.
public struct PlateConfigurationCatalog: Sendable, Equatable {
    private var entries: [String: PlateConfiguration] = [:]

    public init() {}

    /// Configures `exerciseId` with `configuration`, or throws without
    /// mutating anything.
    ///
    /// Throws `.equipmentHasNoPlate` for `.bodyweight` — no plate is ever
    /// in frame for a bodyweight exercise, same rule `FixtureLoader`
    /// already enforces on `Fixture.plateDiameterMm`. Throws
    /// `.implausibleDiameter` when `configuration.isPlausible` is `false`
    /// — this is the one place a mistyped or mismeasured `.custom` /
    /// `.dumbbellEndCap` value gets caught before it can become the scale
    /// for every rep of this exercise.
    public mutating func set(
        _ configuration: PlateConfiguration,
        forExerciseId exerciseId: String,
        equipment: Equipment
    ) throws {
        guard equipment != .bodyweight else {
            throw PlateConfigurationError.equipmentHasNoPlate(exerciseId: exerciseId, equipment: equipment)
        }
        guard configuration.isPlausible else {
            throw PlateConfigurationError.implausibleDiameter(millimetres: configuration.millimetres)
        }
        entries[exerciseId] = configuration
    }

    /// Removes any configuration for `exerciseId`, returning it to
    /// `.unconfigured`.
    public mutating func clear(exerciseId: String) {
        entries.removeValue(forKey: exerciseId)
    }

    /// Looks up `exerciseId`. Never defaults — see `PlateConfigurationLookup`.
    public func lookup(forExerciseId exerciseId: String) -> PlateConfigurationLookup {
        if let configuration = entries[exerciseId] {
            .configured(configuration)
        } else {
            .unconfigured
        }
    }
}

/// The Track A scale arithmetic (SPEC §8):
/// `pixels_per_metre = major_axis_px / plate_diameter_m`, recomputed every
/// frame so the scale survives the lifter drifting toward or away from the
/// camera. This type owns only the arithmetic — measuring `majorAxisPx`
/// from a frame is `EllipseFit`/`PlateDetector`'s job, owned elsewhere.
public enum PlateScale {
    /// Metres per pixel implied by a plate whose fitted ellipse has major
    /// axis `majorAxisPx` and whose assumed real diameter is `diameterMm`.
    /// The inverse of SPEC §8's `pixels_per_metre`.
    ///
    /// Linear in `diameterMm` by construction: doubling `diameterMm`
    /// doubles the result. That is the whole reason a wrong diameter is
    /// dangerous rather than merely imprecise — every metre and every
    /// velocity computed from this scale inherits the same error, exactly
    /// proportionally, silently.
    ///
    /// `nil` when either input is non-positive or non-finite: there is no
    /// sensible scale for a zero-or-negative measurement, so this returns
    /// nothing rather than letting `0`, `Infinity`, or `NaN` flow
    /// downstream as if it were a real number.
    public static func metresPerPixel(majorAxisPx: Double, diameterMm: Double) -> Double? {
        guard majorAxisPx.isFinite, majorAxisPx > 0,
            diameterMm.isFinite, diameterMm > 0
        else { return nil }
        return (diameterMm / 1000.0) / majorAxisPx
    }

    /// SPEC §8's formula directly: pixels per metre implied by the same
    /// inputs as `metresPerPixel`. `nil` under the same conditions.
    public static func pixelsPerMetre(majorAxisPx: Double, diameterMm: Double) -> Double? {
        guard let metresPerPixel = metresPerPixel(majorAxisPx: majorAxisPx, diameterMm: diameterMm) else {
            return nil
        }
        return 1.0 / metresPerPixel
    }
}

/// The one-time "measure against a reference" flow for a plate that isn't
/// in `PlateConfiguration`'s catalog (SPEC §8): a reference object of known
/// real size is visible in the same frame as the unknown plate, and the
/// plate's real diameter is derived from the ratio of their pixel sizes.
///
/// This is the data model and arithmetic only — no UI, no capture, no
/// frame access. A later wave is what points a camera at a reference
/// object and measures pixel sizes; this type just does the division once
/// those two numbers exist.
public struct ReferenceMeasurement: Sendable, Equatable {
    /// The reference object's true real-world size, millimetres (e.g. a
    /// credit card's long edge, ≈85.6 mm, or a sheet of A4 paper's long
    /// edge, 297 mm).
    public let referenceRealSizeMm: Double

    /// The same reference object's size in the frame, pixels, measured
    /// along the same axis as `referenceRealSizeMm`.
    public let referenceSizePx: Double

    /// The plate's measured size in the same frame, pixels — its fitted
    /// ellipse's major axis (SPEC §8), so this is comparable to
    /// `referenceSizePx` regardless of camera angle.
    public let platePx: Double

    public init(referenceRealSizeMm: Double, referenceSizePx: Double, platePx: Double) {
        self.referenceRealSizeMm = referenceRealSizeMm
        self.referenceSizePx = referenceSizePx
        self.platePx = platePx
    }

    /// Derives the plate's real diameter, millimetres:
    ///
    /// `plateDiameterMm = referenceRealSizeMm * (platePx / referenceSizePx)`
    ///
    /// i.e. pixels-per-mm implied by the reference (`referenceSizePx /
    /// referenceRealSizeMm`), inverted and applied to the plate's pixel
    /// size.
    ///
    /// **Error propagation is undamped and permanent.** This is a straight
    /// ratio: a 2% error in `referenceRealSizeMm` (the wrong reference
    /// object, or a mismeasured one) or in `referenceSizePx` (a sloppy
    /// pixel measurement) becomes a 2% error in the derived diameter,
    /// exactly, with no averaging-out. And because `PlateScale
    /// .metresPerPixel` is linear in the diameter, that 2% is not a
    /// one-time cost paid here — it is baked into every velocity and every
    /// ROM number this exercise ever produces, for as long as the
    /// resulting `PlateConfiguration` stays configured. That is exactly
    /// why SPEC §8 frames this as a *one-time, deliberate, user-initiated*
    /// flow rather than something run silently per session: the user
    /// should measure carefully once, not repeatedly and casually.
    ///
    /// Throws `.implausibleDiameter` for non-positive/non-finite inputs or
    /// a result outside `PlateConfiguration.plausibleRangeMm` — e.g. a
    /// fat-fingered pixel measurement implying a 5 m plate.
    public func deriveDiameterMm() throws -> Double {
        guard referenceRealSizeMm.isFinite, referenceRealSizeMm > 0,
            referenceSizePx.isFinite, referenceSizePx > 0,
            platePx.isFinite, platePx > 0
        else {
            throw PlateConfigurationError.implausibleDiameter(millimetres: 0)
        }
        let mm = referenceRealSizeMm * (platePx / referenceSizePx)
        guard mm.isFinite, PlateConfiguration.plausibleRangeMm.contains(mm) else {
            throw PlateConfigurationError.implausibleDiameter(millimetres: mm)
        }
        return mm
    }

    /// `deriveDiameterMm()` wrapped as a `.custom` `PlateConfiguration` —
    /// the form the result actually gets stored in
    /// `PlateConfigurationCatalog` as, keeping "measured against a
    /// reference" distinguishable from "picked a standard" or "entered a
    /// dumbbell end-cap directly."
    public func deriveDiameter() throws -> PlateConfiguration {
        .custom(millimetres: try deriveDiameterMm())
    }
}
