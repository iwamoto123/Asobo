{
    @storageRestrictions(accesses: _$backingData, initializes: _priority)
    init(initialValue) {
        _$backingData.setValue(forKey: \.priority, to: initialValue)
        _priority = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.priority)
        return self.getValue(forKey: \.priority)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.priority) {
            self.setValue(forKey: \.priority, to: newValue)
        }
    }
}

// original-source-range: /Users/takeshi/workspace/Asobo/Packages/DataStores/Sources/DataStores/SwiftDataParentPhrasesRepository.swift:13:22-13:22
