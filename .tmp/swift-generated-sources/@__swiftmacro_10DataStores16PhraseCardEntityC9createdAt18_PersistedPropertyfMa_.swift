{
    @storageRestrictions(accesses: _$backingData, initializes: _createdAt)
    init(initialValue) {
        _$backingData.setValue(forKey: \.createdAt, to: initialValue)
        _createdAt = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.createdAt)
        return self.getValue(forKey: \.createdAt)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.createdAt) {
            self.setValue(forKey: \.createdAt, to: newValue)
        }
    }
}

// original-source-range: /Users/takeshi/workspace/Asobo/Packages/DataStores/Sources/DataStores/SwiftDataParentPhrasesRepository.swift:16:24-16:24
