import Foundation
import HealthKit

/// A health activity flattened from HealthKit into a Sendable value.
struct HealthItem: Identifiable, Sendable {
    enum Kind: Sendable { case workout, mindful, nutrition }
    let id: String            // sample UUID → import externalID
    let kind: Kind
    let title: String
    let start: Date
    let duration: TimeInterval
    var detail: String? = nil // e.g. a day's macros for nutrition
}

/// Reads workouts and mindful sessions (with permission). On-device; a workout
/// only becomes a note (growing Body) — or a mindful session (Spirit) — when you
/// tap it. HealthKit is also hard to fake, which suits reward-verification later.
enum HealthKitService {

    enum HealthError: Error { case unavailable }

    /// Does this device have Health at all? (No prompt, no permission needed.)
    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// One store for the lifetime of the app. Constructing an `HKHealthStore` per call is not
    /// free, and this used to be built on every SwiftUI render.
    private static let sharedStore: HKHealthStore? = isAvailable ? HKHealthStore() : nil

    /// Have we ever asked for Health access? Reading this NEVER prompts — only `fetch` does.
    /// It's what lets the home screen offer the import without throwing a system permission
    /// sheet at someone who just opened the app. Still an XPC hop to the Health daemon, so
    /// read it once into state — never from inside a view's `body`.
    static var accessRequested: Bool {
        guard let store = sharedStore else { return false }
        return store.authorizationStatus(for: HKObjectType.workoutType()) != .notDetermined
    }

    static func fetch(daysBack: Int = 30) async throws -> [HealthItem] {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthError.unavailable }
        let store = HKHealthStore()

        let workoutType = HKObjectType.workoutType()
        let mindfulType = HKObjectType.categoryType(forIdentifier: .mindfulSession)
        var read: Set<HKObjectType> = [workoutType]
        if let mindfulType { read.insert(mindfulType) }
        // Nutrition (from MyFitnessPal, Cronometer, etc. via Apple Health) → Gut.
        let nutritionTypes: [HKQuantityTypeIdentifier] = [.dietaryEnergyConsumed, .dietaryProtein, .dietaryFiber]
        for id in nutritionTypes { if let t = HKObjectType.quantityType(forIdentifier: id) { read.insert(t) } }
        try await store.requestAuthorization(toShare: [], read: read)

        let start = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
        var items: [HealthItem] = []

        for sample in try await samples(store, type: workoutType, start: start) {
            guard let workout = sample as? HKWorkout else { continue }
            items.append(HealthItem(id: workout.uuid.uuidString, kind: .workout,
                                    title: workoutName(workout.workoutActivityType),
                                    start: workout.startDate, duration: workout.duration))
        }
        if let mindfulType {
            for sample in try await samples(store, type: mindfulType, start: start) {
                items.append(HealthItem(id: sample.uuid.uuidString, kind: .mindful,
                                        title: "Mindful session", start: sample.startDate,
                                        duration: sample.endDate.timeIntervalSince(sample.startDate)))
            }
        }
        // Nutrition summed per day → one item each ("2100 kcal · 90g protein · 28g fiber").
        let energy  = await dailySums(store, .dietaryEnergyConsumed, unit: .kilocalorie(), start: start)
        let protein = await dailySums(store, .dietaryProtein, unit: .gram(), start: start)
        let fiber   = await dailySums(store, .dietaryFiber, unit: .gram(), start: start)
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        for day in Set(energy.keys).union(protein.keys).union(fiber.keys) {
            var parts: [String] = []
            if let e = energy[day] { parts.append("\(Int(e.rounded())) kcal") }
            if let p = protein[day] { parts.append("\(Int(p.rounded()))g protein") }
            if let f = fiber[day] { parts.append("\(Int(f.rounded()))g fiber") }
            guard !parts.isEmpty else { continue }
            items.append(HealthItem(id: "nutrition-\(df.string(from: day))", kind: .nutrition,
                                    title: "Nutrition", start: day, duration: 0,
                                    detail: parts.joined(separator: " · ")))
        }
        return items.sorted { $0.start > $1.start }
    }

    /// Sum a dietary quantity per calendar day.
    private static func dailySums(_ store: HKHealthStore, _ id: HKQuantityTypeIdentifier, unit: HKUnit, start: Date) async -> [Date: Double] {
        guard let type = HKObjectType.quantityType(forIdentifier: id),
              let samples = try? await samples(store, type: type, start: start, limit: HKObjectQueryNoLimit)
        else { return [:] }
        let cal = Calendar.current
        var sums: [Date: Double] = [:]
        for s in samples {
            guard let q = s as? HKQuantitySample else { continue }
            sums[cal.startOfDay(for: q.startDate), default: 0] += q.quantity.doubleValue(for: unit)
        }
        return sums
    }

    private static func samples(_ store: HKHealthStore, type: HKSampleType, start: Date, limit: Int = 100) async throws -> [HKSample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        return try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit, sortDescriptors: [sort]) { _, results, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: results ?? []) }
            }
            store.execute(query)
        }
    }

    #if DEBUG
    /// Metadata key stamped on every sample we seed, so we can find and remove them
    /// again (and never mix them up with the user's real data).
    static let sampleMetadataKey = "NuminousSampleData"
    private static var sampleMetadata: [String: Any] { [sampleMetadataKey: true] }

    /// Test-only: writes a few sample workouts + mindful sessions to HealthKit so
    /// the Health tab has something to read. Idempotent by design — the caller only
    /// seeds once (a persisted toggle), and every sample is tagged for later removal.
    static func seedSampleData() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let store = HKHealthStore()
        let workoutType = HKObjectType.workoutType()
        guard let mindfulType = HKObjectType.categoryType(forIdentifier: .mindfulSession) else { return }
        var share: Set<HKSampleType> = [workoutType, mindfulType]
        let nutritionIDs: [HKQuantityTypeIdentifier] = [.dietaryEnergyConsumed, .dietaryProtein, .dietaryFiber]
        for id in nutritionIDs { if let t = HKObjectType.quantityType(forIdentifier: id) { share.insert(t) } }
        try? await store.requestAuthorization(toShare: share, read: [])

        let cal = Calendar.current
        let workouts: [(Int, HKWorkoutActivityType, Int)] = [
            (0, .running, 32), (1, .traditionalStrengthTraining, 47), (2, .yoga, 25), (4, .cycling, 55),
        ]
        for (daysAgo, type, minutes) in workouts {
            let base = cal.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
            let end = cal.date(bySettingHour: 8, minute: 0, second: 0, of: base) ?? base
            let start = end.addingTimeInterval(-Double(minutes) * 60)
            let builder = HKWorkoutBuilder(healthStore: store, configuration: {
                let c = HKWorkoutConfiguration(); c.activityType = type; return c
            }(), device: nil)
            do {
                try await builder.beginCollection(at: start)
                try? await builder.addMetadata(sampleMetadata)   // tag it as ours
                try await builder.endCollection(at: end)
                _ = try await builder.finishWorkout()   // saves the workout itself
            } catch { }
        }
        // Mindful sessions aren't saved by a builder, so save them explicitly.
        var mindful: [HKSample] = []
        for (daysAgo, minutes) in [(0, 10), (2, 15)] {
            let base = cal.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
            let end = cal.date(bySettingHour: 21, minute: 0, second: 0, of: base) ?? base
            let start = end.addingTimeInterval(-Double(minutes) * 60)
            mindful.append(HKCategorySample(type: mindfulType, value: HKCategoryValue.notApplicable.rawValue, start: start, end: end, metadata: sampleMetadata))
        }
        try? await store.save(mindful)

        // A couple of days of nutrition (as if synced from MyFitnessPal).
        var nutrition: [HKSample] = []
        let daily: [(Int, Double, Double, Double)] = [(0, 2140, 96, 27), (1, 1980, 88, 31)]
        func q(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double, _ day: Date) -> HKQuantitySample? {
            guard let t = HKObjectType.quantityType(forIdentifier: id) else { return nil }
            let end = cal.date(bySettingHour: 20, minute: 0, second: 0, of: day) ?? day
            return HKQuantitySample(type: t, quantity: HKQuantity(unit: unit, doubleValue: value), start: end.addingTimeInterval(-3600), end: end, metadata: sampleMetadata)
        }
        for (daysAgo, kcal, protein, fiber) in daily {
            let day = cal.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
            if let s = q(.dietaryEnergyConsumed, .kilocalorie(), kcal, day) { nutrition.append(s) }
            if let s = q(.dietaryProtein, .gram(), protein, day) { nutrition.append(s) }
            if let s = q(.dietaryFiber, .gram(), fiber, day) { nutrition.append(s) }
        }
        try? await store.save(nutrition)
    }

    /// Remove exactly the samples we seeded (matched by our metadata tag), leaving
    /// any real HealthKit data untouched — so the toggle can be switched off.
    static func removeSampleData() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let store = HKHealthStore()
        let predicate = HKQuery.predicateForObjects(withMetadataKey: sampleMetadataKey)
        var types: [HKSampleType] = [HKObjectType.workoutType()]
        if let m = HKObjectType.categoryType(forIdentifier: .mindfulSession) { types.append(m) }
        for id in [HKQuantityTypeIdentifier.dietaryEnergyConsumed, .dietaryProtein, .dietaryFiber] {
            if let t = HKObjectType.quantityType(forIdentifier: id) { types.append(t) }
        }
        for type in types {
            await withCheckedContinuation { cont in
                store.deleteObjects(of: type, predicate: predicate) { _, _, _ in cont.resume() }
            }
        }
    }
    #endif

    private static func workoutName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "Run"
        case .walking: return "Walk"
        case .cycling: return "Cycling"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "Strength"
        case .highIntensityIntervalTraining: return "HIIT"
        case .yoga: return "Yoga"
        case .swimming: return "Swim"
        case .hiking: return "Hike"
        case .coreTraining: return "Core"
        case .elliptical: return "Elliptical"
        case .rowing: return "Rowing"
        case .dance, .cardioDance: return "Dance"
        case .pilates: return "Pilates"
        default: return "Workout"
        }
    }
}
