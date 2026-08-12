import Foundation
import Testing

@testable import TimMethodCore

@Suite("Eval scoring")
struct EvalTests {
    // MARK: - Fixture helpers

    private func fixture(
        exerciseId: String = "back_squat",
        equipment: Equipment = .barbell,
        trueRepCount: Int,
        truePartialCount: Int = 0,
        cameraPosition: CameraPosition = .perpendicular,
        perRepTimestamps: [TimeInterval]? = nil
    ) -> Fixture {
        Fixture(
            exerciseId: exerciseId,
            equipment: equipment,
            trueRepCount: trueRepCount,
            truePartialCount: truePartialCount,
            cameraPosition: cameraPosition,
            lightingNote: "test",
            sourceDataset: "own",
            licence: .ownFootage,
            perRepTimestamps: perRepTimestamps
        )
    }

    private func evaluation(
        name: String = "clip",
        exerciseId: String = "back_squat",
        equipment: Equipment = .barbell,
        cameraPosition: CameraPosition = .perpendicular,
        trueCount: Int,
        predictedCount: Int
    ) -> ClipEvaluation {
        ClipEvaluator.evaluate(
            name: name,
            fixture: fixture(exerciseId: exerciseId, equipment: equipment, trueRepCount: trueCount, cameraPosition: cameraPosition),
            prediction: RepCountResult(repCount: predictedCount)
        )
    }

    // MARK: - RepCounting / StubRepCounter

    @Test("StubRepCounter counts zero reps over a flat signal")
    func stubCounterFlatSignal() {
        var signal = RepSignal(scale: .torsoRelative)
        for t in stride(from: 0.0, to: 1.0, by: 1.0 / 60.0) {
            signal.append(t: t, x: 0, confidence: 1.0)
        }
        let result = StubRepCounter().count(signal: signal)
        #expect(result.repCount == 0)
        #expect(result.repTimestamps.isEmpty)
    }

    @Test("StubRepCounter counts two full swings above the amplitude threshold")
    func stubCounterCountsSwings() {
        var signal = RepSignal(scale: .torsoRelative)
        // 0 -> 0.05 -> 0 -> 0.05 -> 0: two full up/down swings, each well
        // above the default 0.02 minAmplitude.
        for (t, x) in [(0.0, 0.0), (1.0, 0.05), (2.0, 0.0), (3.0, 0.05), (4.0, 0.0)] {
            signal.append(t: t, x: x, confidence: 1.0)
        }
        let result = StubRepCounter().count(signal: signal)
        #expect(result.repCount == 2)
        #expect(result.repTimestamps == [2.0, 4.0])
    }

    @Test("StubRepCounter ignores swings smaller than minAmplitude")
    func stubCounterIgnoresJitter() {
        var signal = RepSignal(scale: .torsoRelative)
        // Swing of only 0.005, below the default 0.02 threshold.
        for (t, x) in [(0.0, 0.0), (1.0, 0.005), (2.0, 0.0)] {
            signal.append(t: t, x: x, confidence: 1.0)
        }
        let result = StubRepCounter().count(signal: signal)
        #expect(result.repCount == 0)
    }

    @Test("RepCountResult on an empty signal")
    func stubCounterEmptySignal() {
        let signal = RepSignal(scale: .torsoRelative)
        let result = StubRepCounter().count(signal: signal)
        #expect(result.repCount == 0)
    }

    // MARK: - ClipEvaluator: count-derived FP/FN (no perRepTimestamps)

    @Test("count-derived basis when perRepTimestamps is absent, over-count")
    func countDerivedOverCount() {
        let eval = ClipEvaluator.evaluate(
            name: "clip",
            fixture: fixture(trueRepCount: 5),
            prediction: RepCountResult(repCount: 7)
        )
        #expect(eval.delta == 2)
        #expect(eval.fpFnBasis == .countDerived)
        #expect(eval.falsePositiveCount == 2)
        #expect(eval.falseNegativeCount == 0)
        #expect(eval.falsePositiveTimestamps == nil)
        #expect(eval.falseNegativeTimestamps == nil)
        #expect(eval.isCountCorrect == false)
        #expect(eval.isWithinOffByOne == false)
    }

    @Test("count-derived basis when perRepTimestamps is absent, under-count")
    func countDerivedUnderCount() {
        let eval = ClipEvaluator.evaluate(
            name: "clip",
            fixture: fixture(trueRepCount: 5),
            prediction: RepCountResult(repCount: 3)
        )
        #expect(eval.delta == -2)
        #expect(eval.fpFnBasis == .countDerived)
        #expect(eval.falsePositiveCount == 0)
        #expect(eval.falseNegativeCount == 2)
    }

    @Test("count-derived basis is used even when perRepTimestamps is present but the counter reports none")
    func countDerivedWhenCounterOmitsTimestamps() {
        let eval = ClipEvaluator.evaluate(
            name: "clip",
            fixture: fixture(trueRepCount: 3, perRepTimestamps: [0.1, 0.2, 0.3]),
            prediction: RepCountResult(repCount: 2) // no repTimestamps
        )
        #expect(eval.fpFnBasis == .countDerived)
        #expect(eval.falsePositiveTimestamps == nil)
    }

    // MARK: - ClipEvaluator: timestamp-matched FP/FN

    @Test("timestamp-matched basis finds an exact false negative and false positive")
    func timestampMatchedFindsMismatch() {
        // True reps at 1, 2, 3. Predicted reps at 1.05, 2.05, 5.0 (the last
        // one doesn't correspond to anything; the true rep at 3 was missed).
        let eval = ClipEvaluator.evaluate(
            name: "clip",
            fixture: fixture(trueRepCount: 3, perRepTimestamps: [1.0, 2.0, 3.0]),
            prediction: RepCountResult(repCount: 3, repTimestamps: [1.05, 2.05, 5.0])
        )
        #expect(eval.fpFnBasis == .timestampMatched)
        #expect(eval.falsePositiveCount == 1)
        #expect(eval.falseNegativeCount == 1)
        #expect(eval.falsePositiveTimestamps == [5.0])
        #expect(eval.falseNegativeTimestamps == [3.0])
        #expect(eval.matchToleranceSeconds != nil)
    }

    @Test("timestamp-matched basis finds no mismatch when every predicted rep lands within tolerance")
    func timestampMatchedAllMatch() {
        let eval = ClipEvaluator.evaluate(
            name: "clip",
            fixture: fixture(trueRepCount: 2, perRepTimestamps: [1.0, 2.0]),
            prediction: RepCountResult(repCount: 2, repTimestamps: [1.1, 1.95])
        )
        #expect(eval.falsePositiveCount == 0)
        #expect(eval.falseNegativeCount == 0)
        #expect(eval.falsePositiveTimestamps == [])
        #expect(eval.falseNegativeTimestamps == [])
    }

    // MARK: - ClipEvaluator: partials are never fabricated

    @Test("predictedPartialCount stays nil when the counter doesn't classify partials")
    func predictedPartialsNilByDefault() {
        let eval = ClipEvaluator.evaluate(
            name: "clip",
            fixture: fixture(trueRepCount: 5, truePartialCount: 1),
            prediction: RepCountResult(repCount: 5)
        )
        #expect(eval.truePartialCount == 1)
        #expect(eval.predictedPartialCount == nil)
    }

    // MARK: - Off-by-one: <= 1, not == 1

    @Test("off-by-one accuracy counts |delta| <= 1, not |delta| == 1", arguments: [
        (5, 5, true),   // delta 0 — exact, still within-one
        (5, 6, true),   // delta +1
        (5, 4, true),   // delta -1
        (5, 7, false),  // delta +2
        (5, 3, false),  // delta -2
    ])
    func offByOneIsInclusiveOfExact(trueCount: Int, predictedCount: Int, expectWithinOne: Bool) {
        let eval = evaluation(trueCount: trueCount, predictedCount: predictedCount)
        #expect(eval.isWithinOffByOne == expectWithinOne)
    }

    // MARK: - AggregateEvaluator: edge cases

    @Test("aggregate over zero clips reports nil metrics, not zero")
    func aggregateZeroFixtures() {
        let aggregate = AggregateEvaluator.aggregate([])
        #expect(aggregate.clipCount == 0)
        #expect(aggregate.countMAEOverall == nil)
        #expect(aggregate.countMAELoaded == nil)
        #expect(aggregate.countMAEBodyweight == nil)
        #expect(aggregate.offByOneAccuracyOverall == nil)
        #expect(aggregate.offByOneAccuracyLoaded == nil)
        #expect(aggregate.falsePositivesPerSession == nil)
        #expect(aggregate.perExercise.isEmpty)
        #expect(aggregate.perCameraPosition.isEmpty)
    }

    @Test("aggregate over a single correct clip")
    func aggregateSingleCorrectClip() {
        let eval = evaluation(trueCount: 5, predictedCount: 5)
        let aggregate = AggregateEvaluator.aggregate([eval])
        #expect(aggregate.clipCount == 1)
        #expect(aggregate.countMAEOverall?.value == 0)
        #expect(aggregate.countMAEOverall?.sampleCount == 1)
        #expect(aggregate.offByOneAccuracyOverall?.value == 1.0)
    }

    @Test("aggregate over a single wrong clip")
    func aggregateSingleWrongClip() {
        let eval = evaluation(trueCount: 5, predictedCount: 8)
        let aggregate = AggregateEvaluator.aggregate([eval])
        #expect(aggregate.countMAEOverall?.value == 3)
        #expect(aggregate.offByOneAccuracyOverall?.value == 0)
    }

    @Test("aggregate over all-correct clips")
    func aggregateAllCorrect() {
        let evals = [
            evaluation(name: "a", trueCount: 5, predictedCount: 5),
            evaluation(name: "b", trueCount: 3, predictedCount: 3),
            evaluation(name: "c", trueCount: 8, predictedCount: 8),
        ]
        let aggregate = AggregateEvaluator.aggregate(evals)
        #expect(aggregate.countMAEOverall?.value == 0)
        #expect(aggregate.offByOneAccuracyOverall?.value == 1.0)
        #expect(aggregate.falsePositivesPerSession?.value == 0)
    }

    @Test("aggregate over all-wrong clips")
    func aggregateAllWrong() {
        let evals = [
            evaluation(name: "a", trueCount: 5, predictedCount: 10),
            evaluation(name: "b", trueCount: 3, predictedCount: 0),
            evaluation(name: "c", trueCount: 8, predictedCount: 2),
        ]
        let aggregate = AggregateEvaluator.aggregate(evals)
        // MAE = (5 + 3 + 6) / 3
        #expect(aggregate.countMAEOverall?.value == (5.0 + 3.0 + 6.0) / 3.0)
        #expect(aggregate.offByOneAccuracyOverall?.value == 0)
    }

    @Test("loaded/bodyweight partition excludes bodyweight from the loaded MAE")
    func loadedBodyweightPartition() {
        let evals = [
            evaluation(name: "squat", equipment: .barbell, trueCount: 5, predictedCount: 5),
            evaluation(name: "row", equipment: .dumbbell, trueCount: 6, predictedCount: 4),
            evaluation(name: "pushup", equipment: .bodyweight, trueCount: 8, predictedCount: 8),
        ]
        let aggregate = AggregateEvaluator.aggregate(evals)
        // Loaded: squat (delta 0) + row (delta -2) -> MAE 1.0 over n=2
        #expect(aggregate.countMAELoaded?.value == 1.0)
        #expect(aggregate.countMAELoaded?.sampleCount == 2)
        // Bodyweight: pushup only, delta 0 -> MAE 0 over n=1
        #expect(aggregate.countMAEBodyweight?.value == 0)
        #expect(aggregate.countMAEBodyweight?.sampleCount == 1)
    }

    @Test("per-exercise breakdown groups by exerciseId")
    func perExerciseBreakdown() {
        let evals = [
            evaluation(name: "a", exerciseId: "back_squat", trueCount: 5, predictedCount: 5),
            evaluation(name: "b", exerciseId: "back_squat", trueCount: 5, predictedCount: 6),
            evaluation(name: "c", exerciseId: "pushup", trueCount: 8, predictedCount: 8),
        ]
        let aggregate = AggregateEvaluator.aggregate(evals)
        #expect(aggregate.perExercise.count == 2)
        let squat = try! #require(aggregate.perExercise.first { $0.exerciseId == "back_squat" })
        #expect(squat.clipCount == 2)
        #expect(squat.countMAE.value == 0.5)
    }

    @Test("per-camera breakdown carries degreesOffPerpendicular")
    func perCameraBreakdown() {
        let evals = [
            evaluation(name: "a", cameraPosition: .oblique45, trueCount: 5, predictedCount: 5),
        ]
        let aggregate = AggregateEvaluator.aggregate(evals)
        #expect(aggregate.perCameraPosition.count == 1)
        #expect(aggregate.perCameraPosition[0].cameraPosition == .oblique45)
        #expect(aggregate.perCameraPosition[0].degreesOffPerpendicular == 45)
    }

    // MARK: - EvalGate

    @Test("gate passes when every checked metric clears its floor")
    func gatePassesAboveFloor() {
        let aggregate = AggregateEvaluation(
            clipCount: 4,
            countMAEOverall: Metric(value: 0.05, sampleCount: 4),
            countMAELoaded: Metric(value: 0.05, sampleCount: 2),
            countMAEBodyweight: Metric(value: 0.1, sampleCount: 2),
            offByOneAccuracyOverall: Metric(value: 1.0, sampleCount: 4),
            offByOneAccuracyLoaded: Metric(value: 1.0, sampleCount: 2),
            falsePositivesPerSession: Metric(value: 0.0, sampleCount: 4),
            perExercise: [],
            perCameraPosition: []
        )
        let gate = EvalGate.evaluate(aggregate)
        #expect(gate.passed == true)
        #expect(gate.checks.filter { $0.status == .pass }.count == 4)
        #expect(gate.checks.filter { $0.status == .skippedNoData }.count == 2)
    }

    @Test("gate fails when a checked metric falls below its floor")
    func gateFailsBelowFloor() {
        let aggregate = AggregateEvaluation(
            clipCount: 2,
            countMAEOverall: Metric(value: 0.5, sampleCount: 2),
            countMAELoaded: Metric(value: 0.5, sampleCount: 2), // floor is <= 0.15
            countMAEBodyweight: nil,
            offByOneAccuracyOverall: Metric(value: 1.0, sampleCount: 2),
            offByOneAccuracyLoaded: Metric(value: 1.0, sampleCount: 2),
            falsePositivesPerSession: Metric(value: 0.0, sampleCount: 2),
            perExercise: [],
            perCameraPosition: []
        )
        let gate = EvalGate.evaluate(aggregate)
        #expect(gate.passed == false)
        let loadedMAECheck = try! #require(gate.checks.first { $0.metric == "Count MAE, loaded" })
        #expect(loadedMAECheck.status == .fail)
        #expect(loadedMAECheck.observed == 0.5)
    }

    @Test("gate skips rather than passes when a metric has no data")
    func gateSkipsWithoutData() {
        let aggregate = AggregateEvaluation(
            clipCount: 0,
            countMAEOverall: nil,
            countMAELoaded: nil,
            countMAEBodyweight: nil,
            offByOneAccuracyOverall: nil,
            offByOneAccuracyLoaded: nil,
            falsePositivesPerSession: nil,
            perExercise: [],
            perCameraPosition: []
        )
        let gate = EvalGate.evaluate(aggregate)
        // Vacuous pass: nothing failed because nothing had data to check.
        #expect(gate.passed == true)
        for check in gate.checks {
            #expect(check.status == .skippedNoData)
            #expect(check.observed == nil)
        }
        #expect(gate.checks.count == 6)
    }

    @Test("velocity RMSE and set-boundary F1 are always skipped in this wave")
    func velocityAndSetBoundaryAlwaysSkipped() {
        let aggregate = AggregateEvaluator.aggregate([
            evaluation(trueCount: 5, predictedCount: 5),
        ])
        let gate = EvalGate.evaluate(aggregate)
        let velocity = try! #require(gate.checks.first { $0.metric == "Mean concentric velocity RMSE" })
        let setBoundary = try! #require(gate.checks.first { $0.metric == "Set-boundary detection F1" })
        #expect(velocity.status == .skippedNoData)
        #expect(setBoundary.status == .skippedNoData)
    }
}
