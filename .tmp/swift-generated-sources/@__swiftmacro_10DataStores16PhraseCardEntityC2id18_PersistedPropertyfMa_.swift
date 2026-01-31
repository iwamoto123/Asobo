{
    @storageRestrictions(accesses: _$backingData, initializes: _id)
    init(initialValue) {
        _$backingData.setValue(forKey: \.id, to: initialValue)
        _id = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.id)
        return self.getValue(forKey: \.id)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.id) {
            self.setValue(forKey: \.id, to: newValue)
        }
    }
}

// original-source-range: /Users/takeshi/workspace/Asobo/Packages/DataStores/Sources/DataStores/SwiftDataParentPhrasesRepository.swift:9:37-9:37
