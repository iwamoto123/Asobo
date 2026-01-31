{
    @storageRestrictions(accesses: _$backingData, initializes: _lastUsedAt)
    init(initialValue) {
        _$backingData.setValue(forKey: \.lastUsedAt, to: initialValue)
        _lastUsedAt = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.lastUsedAt)
        return self.getValue(forKey: \.lastUsedAt)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.lastUsedAt) {
            self.setValue(forKey: \.lastUsedAt, to: newValue)
        }
    }
}

// original-source-range: /Users/takeshi/workspace/Asobo/Packages/DataStores/Sources/DataStores/SwiftDataParentPhrasesRepository.swift:15:26-15:26
