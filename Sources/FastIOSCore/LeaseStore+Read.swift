import Foundation

extension LeaseStore {
    /// The current leases, read without taking the lock, for display only.
    /// Leases whose holder has exited are left out, as `reap` would drop them.
    public static func readOnly() -> [String: Lease] {
        var state = load()
        _ = state.reap()
        return state.leases
    }

    /// One line per pool simulator of the current set, for display only:
    /// changes nothing (the trim itself runs in `leases`, `release` and the helper).
    public static func poolStatus(booted: Set<String>) -> [String] {
        var state = load()
        _ = state.reap()
        return PoolTrim.describe(pool: Array(state.pool.values), leased: Set(state.leases.keys), booted: booted,
                                 set: Simctl.deviceSet ?? "", memory: .read(), policy: AdmissionPolicy(),
                                 warmSize: LeaseManager.warmSize, idleLimit: PoolTrim.idleLimit)
    }
}
