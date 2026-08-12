import Foundation
import Testing

@testable import TimMethodCore

@Suite("PlateConfiguration")
struct PlateConfigurationTests {
    // MARK: - Known diameters are what they claim

    @Test("Olympic and bumper plates are both 450 mm")
    func olympicOrBumperIs450() {
        #expect(PlateConfiguration.olympicOrBumper.millimetres == 450)
    }

    @Test("standard 1-inch sizes match their declared millimetres")
    func standardOneInchSizesMatchClaim() {
        #expect(PlateConfiguration.StandardOneInch.small.millimetres == 190.5)
        #expect(PlateConfiguration.StandardOneInch.medium.millimetres == 228.6)
        #expect(PlateConfiguration.StandardOneInch.large.millimetres == 254.0)
        #expect(PlateConfiguration.StandardOneInch.extraLarge.millimetres == 279.4)
    }

    @Test("standard 1-inch sizes are a small, distinct, closed set, all below Olympic")
    func standardOneInchSizesAreDistinctAndBelowOlympic() {
        let allMm = PlateConfiguration.StandardOneInch.allCases.map(\.millimetres)
        #expect(Set(allMm).count == allMm.count) // all distinct
        #expect(allMm.allSatisfy { $0 < PlateConfiguration.olympicOrBumper.millimetres })
    }

    // MARK: - Custom measured diameter round-trips

    @Test("a custom measured diameter round-trips through .millimetres")
    func customDiameterRoundTrips() {
        let configuration = PlateConfiguration.custom(millimetres: 233.7)
        #expect(configuration.millimetres == 233.7)
    }

    @Test("a dumbbell end-cap diameter round-trips and stays distinguishable from .custom")
    func dumbbellEndCapRoundTripsAndIsDistinct() {
        let endCap = PlateConfiguration.dumbbellEndCap(millimetres: 60)
        let custom = PlateConfiguration.custom(millimetres: 60)
        #expect(endCap.millimetres == 60)
        #expect(custom.millimetres == 60)
        // Same value, different provenance — must not collapse to equal.
        #expect(endCap != custom)
    }

    @Test("a custom diameter round-trips through the catalog")
    func customDiameterRoundTripsThroughCatalog() throws {
        var catalog = PlateConfigurationCatalog()
        try catalog.set(.custom(millimetres: 233.7), forExerciseId: "reverse_curl", equipment: .barbell)
        let lookup = catalog.lookup(forExerciseId: "reverse_curl")
        #expect(lookup == .configured(.custom(millimetres: 233.7)))
        #expect(try lookup.requireConfiguration().millimetres == 233.7)
    }

    // MARK: - Refusal, not a 450 mm default

    @Test("an exercise with no configured diameter is .unconfigured, not a default")
    func unconfiguredExerciseIsUnconfigured() {
        let catalog = PlateConfigurationCatalog()
        let lookup = catalog.lookup(forExerciseId: "back_squat")

        // This is the assertion that would fail if someone later "fixed"
        // an empty lookup by defaulting to Olympic/bumper: it asserts
        // exact equality to `.unconfigured`, not merely "not 450" or
        // "nil" — a `.configured(.olympicOrBumper)` fallback would make
        // this fail, which is the point.
        #expect(lookup == .unconfigured)
        #expect(lookup != .configured(.olympicOrBumper))
    }

    @Test("requireConfiguration() throws on an unconfigured lookup rather than returning a default")
    func requireConfigurationThrowsWhenUnconfigured() {
        let lookup = PlateConfigurationLookup.unconfigured
        let error = #expect(throws: PlateConfigurationLookup.RefusalError.self) {
            try lookup.requireConfiguration()
        }
        #expect(error == .noConfiguration)
    }

    @Test("requireConfiguration() returns the value when configured")
    func requireConfigurationReturnsWhenConfigured() throws {
        let lookup = PlateConfigurationLookup.configured(.olympicOrBumper)
        #expect(try lookup.requireConfiguration() == .olympicOrBumper)
    }

    @Test("clearing a configured exercise returns it to .unconfigured")
    func clearingReturnsToUnconfigured() throws {
        var catalog = PlateConfigurationCatalog()
        try catalog.set(.olympicOrBumper, forExerciseId: "deadlift", equipment: .barbell)
        #expect(catalog.lookup(forExerciseId: "deadlift") == .configured(.olympicOrBumper))
        catalog.clear(exerciseId: "deadlift")
        #expect(catalog.lookup(forExerciseId: "deadlift") == .unconfigured)
    }

    @Test("configuring a bodyweight exercise with a plate diameter is rejected")
    func bodyweightExerciseRejectsPlateDiameter() {
        var catalog = PlateConfigurationCatalog()
        #expect(throws: PlateConfigurationError.self) {
            try catalog.set(.olympicOrBumper, forExerciseId: "pull_up", equipment: .bodyweight)
        }
        // And it must not have been silently stored either.
        #expect(catalog.lookup(forExerciseId: "pull_up") == .unconfigured)
    }

    // MARK: - Proportionality: doubling diameter doubles metres-per-pixel

    @Test("doubling the assumed diameter doubles the implied metres-per-pixel")
    func doublingDiameterDoublesMetresPerPixel() throws {
        let majorAxisPx = 300.0
        let baseMm = 450.0

        let base = try #require(PlateScale.metresPerPixel(majorAxisPx: majorAxisPx, diameterMm: baseMm))
        let doubled = try #require(PlateScale.metresPerPixel(majorAxisPx: majorAxisPx, diameterMm: baseMm * 2))

        // Hand-computed: 0.450 m / 300 px = 0.0015 m/px; doubling the
        // diameter to 0.900 m gives 0.003 m/px.
        #expect(abs(base - 0.0015) < 1e-12)
        #expect(abs(doubled - 0.003) < 1e-12)
        #expect(abs(doubled - base * 2) < 1e-12)
    }

    @Test("doubling the assumed diameter halves pixels-per-metre... doubles it, matching SPEC's formula")
    func pixelsPerMetreScalesWithDiameter() throws {
        let majorAxisPx = 300.0
        let base = try #require(PlateScale.pixelsPerMetre(majorAxisPx: majorAxisPx, diameterMm: 450))
        let doubled = try #require(PlateScale.pixelsPerMetre(majorAxisPx: majorAxisPx, diameterMm: 900))

        // pixels_per_metre = major_axis_px / plate_diameter_m (SPEC §8).
        // 300 / 0.45 = 666.67; 300 / 0.90 = 333.33 — halved, because
        // pixels-per-metre is inversely proportional to diameter (it's
        // metres-per-pixel, not pixels-per-metre, that's directly
        // proportional).
        #expect(abs(base - (300.0 / 0.45)) < 1e-9)
        #expect(abs(doubled - (300.0 / 0.90)) < 1e-9)
        #expect(abs(base - doubled * 2) < 1e-9)
    }

    @Test("PlateScale rejects non-positive or non-finite inputs")
    func plateScaleRejectsBadInputs() {
        #expect(PlateScale.metresPerPixel(majorAxisPx: 0, diameterMm: 450) == nil)
        #expect(PlateScale.metresPerPixel(majorAxisPx: -10, diameterMm: 450) == nil)
        #expect(PlateScale.metresPerPixel(majorAxisPx: 300, diameterMm: 0) == nil)
        #expect(PlateScale.metresPerPixel(majorAxisPx: 300, diameterMm: -450) == nil)
        #expect(PlateScale.metresPerPixel(majorAxisPx: .nan, diameterMm: 450) == nil)
        #expect(PlateScale.metresPerPixel(majorAxisPx: 300, diameterMm: .infinity) == nil)
    }

    // MARK: - Reference-measurement arithmetic against hand-computed values

    @Test("deriveDiameterMm matches a hand-computed value")
    func referenceMeasurementHandComputed() throws {
        // A credit card's long edge (85.6 mm) measures 200 px in frame; the
        // plate's fitted ellipse major axis measures 900 px in the same
        // frame. Implied plate diameter = 85.6 * (900 / 200) = 385.2 mm.
        let measurement = ReferenceMeasurement(referenceRealSizeMm: 85.6, referenceSizePx: 200, platePx: 900)
        let mm = try measurement.deriveDiameterMm()
        #expect(abs(mm - 385.2) < 1e-9)
    }

    @Test("deriveDiameter wraps the result as .custom, distinguishable from a catalog pick")
    func referenceMeasurementWrapsAsCustom() throws {
        let measurement = ReferenceMeasurement(referenceRealSizeMm: 297, referenceSizePx: 500, platePx: 680)
        let configuration = try measurement.deriveDiameter()
        guard case .custom(let mm) = configuration else {
            Issue.record("expected .custom, got \(configuration)")
            return
        }
        // 297 * (680 / 500) = 403.92
        #expect(abs(mm - 403.92) < 1e-9)
    }

    @Test("a 2% error in the reference measurement produces a 2% error in the derived diameter, undamped")
    func referenceMeasurementErrorPropagatesLinearly() throws {
        let accurate = ReferenceMeasurement(referenceRealSizeMm: 85.6, referenceSizePx: 200, platePx: 900)
        // Reference mismeasured 2% too large.
        let biased = ReferenceMeasurement(referenceRealSizeMm: 85.6 * 1.02, referenceSizePx: 200, platePx: 900)

        let accurateMm = try accurate.deriveDiameterMm()
        let biasedMm = try biased.deriveDiameterMm()

        #expect(abs(biasedMm - accurateMm * 1.02) < 1e-9)
    }

    // MARK: - Implausible input is rejected

    @Test("zero, negative, and absurdly large custom diameters are rejected by the catalog")
    func implausibleCustomDiametersAreRejected() {
        var catalog = PlateConfigurationCatalog()
        #expect(throws: PlateConfigurationError.self) {
            try catalog.set(.custom(millimetres: 0), forExerciseId: "x", equipment: .barbell)
        }
        #expect(throws: PlateConfigurationError.self) {
            try catalog.set(.custom(millimetres: -10), forExerciseId: "x", equipment: .barbell)
        }
        #expect(throws: PlateConfigurationError.self) {
            // A "5 m plate."
            try catalog.set(.custom(millimetres: 5_000), forExerciseId: "x", equipment: .barbell)
        }
        // None of the rejected attempts left the catalog configured.
        #expect(catalog.lookup(forExerciseId: "x") == .unconfigured)
    }

    @Test("PlateConfiguration.isPlausible rejects zero, negative, and 5 m diameters directly")
    func isPlausibleRejectsImplausibleValues() {
        #expect(!PlateConfiguration.custom(millimetres: 0).isPlausible)
        #expect(!PlateConfiguration.custom(millimetres: -1).isPlausible)
        #expect(!PlateConfiguration.custom(millimetres: 5_000).isPlausible)
        #expect(!PlateConfiguration.dumbbellEndCap(millimetres: .nan).isPlausible)
        #expect(PlateConfiguration.custom(millimetres: 100).isPlausible)
    }

    @Test("a reference measurement implying an implausible diameter is rejected")
    func referenceMeasurementRejectsImplausibleResult() {
        // Reference is tiny in frame, plate is huge in frame — implies a
        // multi-metre "plate."
        let measurement = ReferenceMeasurement(referenceRealSizeMm: 85.6, referenceSizePx: 10, platePx: 900)
        #expect(throws: PlateConfigurationError.self) {
            try measurement.deriveDiameterMm()
        }
    }

    @Test("a reference measurement with a zero or negative input is rejected")
    func referenceMeasurementRejectsBadInputs() {
        #expect(throws: PlateConfigurationError.self) {
            try ReferenceMeasurement(referenceRealSizeMm: 0, referenceSizePx: 200, platePx: 900).deriveDiameterMm()
        }
        #expect(throws: PlateConfigurationError.self) {
            try ReferenceMeasurement(referenceRealSizeMm: 85.6, referenceSizePx: -200, platePx: 900).deriveDiameterMm()
        }
        #expect(throws: PlateConfigurationError.self) {
            try ReferenceMeasurement(referenceRealSizeMm: 85.6, referenceSizePx: 200, platePx: 0).deriveDiameterMm()
        }
    }
}
