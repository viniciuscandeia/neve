/// Keys whose value differs between two snapshots (a missing key counts as different); order is unspecified.
public func changedKeys<K: Hashable>(old: [K: Bool], new: [K: Bool]) -> [K] {
    Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
}
