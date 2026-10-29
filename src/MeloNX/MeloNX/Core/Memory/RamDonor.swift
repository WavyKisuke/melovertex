import Foundation

@_silgen_name("mlx_ram_donor_is_available") private func mlx_ram_donor_is_available() -> Bool
@_silgen_name("mlx_ram_donor_last_error") private func mlx_ram_donor_last_error() -> UnsafePointer<CChar>?
@_silgen_name("mlx_ram_donor_set_kill_after_mapping") private func mlx_ram_donor_set_kill_after_mapping(_ enabled: Bool)
@_silgen_name("mlx_ram_donor_acquire_up_to") private func mlx_ram_donor_acquire_up_to(_ size: UInt64, _ minimum: UInt64, _ actual: UnsafeMutablePointer<UInt64>) -> UnsafeMutableRawPointer?
@_silgen_name("mlx_ram_donor_release") private func mlx_ram_donor_release(_ base: UnsafeMutableRawPointer)
@_silgen_name("mlx_ram_donor_shutdown") private func mlx_ram_donor_shutdown()
@_silgen_name("offer_donated_memory") private func offer_donated_memory(_ base: UnsafeMutableRawPointer, _ size: UInt64)
@_silgen_name("withdraw_donated_memory") private func withdraw_donated_memory()

enum RamDonor {
    private static let mib: UInt64 = 1024 * 1024
    private static let enabledKey = "donateGuestMemory"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private(set) static var region: UnsafeMutableRawPointer?
    private(set) static var regionSize: UInt64 = 0
    private(set) static var lastStatus = "Not attempted yet"

    private static var nativeError: String? {
        guard let raw = mlx_ram_donor_last_error() else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }

    private static func fail(_ reason: String) -> Bool {
        lastStatus = [reason, nativeError].compactMap { $0 }.joined(separator: ": ")
        print(lastStatus)
        return false
    }

    @discardableResult
    static func prepare(bytes: UInt64) -> Bool {
        guard bytes > 0 else { return fail("Asked for no memory") }
        guard isEnabled else { return fail("Memory donation is disabled") }
        guard mlx_ram_donor_is_available() else { return fail("The RAM helper is missing from this build") }
        guard region == nil else { return true }

        mlx_ram_donor_set_kill_after_mapping(true)
        var granted: UInt64 = 0
        let minimum = min(bytes, 256 * mib)

        guard let mapped = mlx_ram_donor_acquire_up_to(bytes, minimum, &granted), granted > 0 else {
            mlx_ram_donor_shutdown()
            return fail("Could not acquire donor memory")
        }

        region = mapped
        regionSize = granted
        offer_donated_memory(mapped, granted)
        lastStatus = "Guest RAM donation: \(granted / mib) MiB"
        print(lastStatus)
        return true
    }

    static func teardown() {
        guard let mapped = region else { return }
        withdraw_donated_memory()
        mlx_ram_donor_release(mapped)
        mlx_ram_donor_shutdown()
        region = nil
        regionSize = 0
        lastStatus = "Donor released"
    }
}
