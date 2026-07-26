import Combine
import HealthKit

@MainActor
final class SleepScheduleService: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?

    private let store = HKHealthStore()

    func updateSleepWindow() async -> (start: Int, end: Int)? {
        guard HKHealthStore.isHealthDataAvailable(),
              let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            message = "Apple Health sleep data isn’t available on this device."
            return nil
        }

        isLoading = true
        defer { isLoading = false }

        do {
            try await store.requestAuthorization(toShare: [], read: [sleepType])
            let samples = try await sleepSamples(type: sleepType)
            let window = typicalWindow(from: samples)
            message = window == nil
                ? "No recent sleep history was available. Keep the manual schedule for now."
                : "Sleep protection updated from Apple Health."
            return window
        } catch {
            message = "Couldn’t read sleep history: \(error.localizedDescription)"
            return nil
        }
    }

    private func sleepSamples(type: HKCategoryType) async throws -> [HKCategorySample] {
        let start = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: Date(),
            options: .strictStartDate
        )

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(
                        returning: samples?.compactMap { $0 as? HKCategorySample } ?? []
                    )
                }
            }
            store.execute(query)
        }
    }

    private func typicalWindow(from samples: [HKCategorySample]) -> (start: Int, end: Int)? {
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue
        ]
        let asleep = samples.filter { asleepValues.contains($0.value) }
        guard asleep.count >= 3 else { return nil }

        let calendar = Calendar.current
        let nights = Dictionary(grouping: asleep) { sample in
            let shifted = sample.startDate.addingTimeInterval(12 * 60 * 60)
            return calendar.startOfDay(for: shifted)
        }
        .values
        .compactMap { samples -> (start: Date, end: Date)? in
            guard let start = samples.map(\.startDate).min(),
                  let end = samples.map(\.endDate).max() else {
                return nil
            }
            return (start, end)
        }
        guard nights.count >= 3 else { return nil }

        let starts = nights.map {
            let components = calendar.dateComponents([.hour, .minute], from: $0.start)
            let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            return minutes < 12 * 60 ? minutes + 24 * 60 : minutes
        }
        let ends = nights.map {
            let components = calendar.dateComponents([.hour, .minute], from: $0.end)
            return (components.hour ?? 0) * 60 + (components.minute ?? 0)
        }

        return (median(starts) % (24 * 60), median(ends))
    }

    private func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
