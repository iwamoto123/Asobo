{
    @storageRestrictions(accesses: _$backingData, initializes: _isPreset)
    init(initialValue) {
        _$backingData.setValue(forKey: \.isPreset, to: initialValue)
        _isPreset = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.isPreset)
        return self.getValue(forKey: \.isPreset)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.isPreset) {
            self.setValue(forKey: \.isPreset, to: newValue)
        }
    }
}

// original-source-range: /Users/takeshi/workspace/Asobo/Packages/DataStores/Sources/DataStores/SwiftDataParentPhrasesRepository.swift:12:23-12:23
