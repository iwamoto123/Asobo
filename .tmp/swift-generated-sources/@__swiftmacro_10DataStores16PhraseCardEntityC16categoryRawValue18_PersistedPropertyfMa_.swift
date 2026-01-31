{
    @storageRestrictions(accesses: _$backingData, initializes: _categoryRawValue)
    init(initialValue) {
        _$backingData.setValue(forKey: \.categoryRawValue, to: initialValue)
        _categoryRawValue = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.categoryRawValue)
        return self.getValue(forKey: \.categoryRawValue)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.categoryRawValue) {
            self.setValue(forKey: \.categoryRawValue, to: newValue)
        }
    }
}

// original-source-range: /Users/takeshi/workspace/Asobo/Packages/DataStores/Sources/DataStores/SwiftDataParentPhrasesRepository.swift:11:33-11:33
