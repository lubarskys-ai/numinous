import Foundation
import HealthKit

/// A health activity flattened from HealthKit into a Sendable value.
struct HealthItem: Identifiable, Sendable {
    enum Kind: Sendable { case workout, mindful }
    let id: String            // sample UUID → import externalID
    let kind: Kind
    let title: String
    let start: Date
    let duration: TimeInterval
}

/// Reads workouts and mindful sessions (with permission). On-device; a workout
/// only becomes a note (growing Body) — or a mindful session (Spirit) — when you
/// tap it. HealthKit is also hard to fake, which suits reward-verification later.
enum HealthKitService {

    enum HealthError: Error { case unavailable }

    static func fetch(daysBack: Int = 30) async throws -> [HealthItem] {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthError.unavailable }
        let store = HKHealthStore()

        let workoutType = HKObjectType.workoutType()
        let mindfulType = HKObjectType.categoryType(forIdentifier: .mindfulSession)
        var read: Set<HKObjectType> = [workoutType]
        if let mindfulType { read.insert(mindfulType) }
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
        return items.sorted { $0.start > $1.start }
    }

    private static func samples(_ store: HKHealthStore, type: HKSampleType, start: Date) async throws -> [HKSample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        return try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 100, sortDescriptors: [sort]) { _, results, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: results ?? []) }
            }
            store.execute(query)
        }
    }

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
