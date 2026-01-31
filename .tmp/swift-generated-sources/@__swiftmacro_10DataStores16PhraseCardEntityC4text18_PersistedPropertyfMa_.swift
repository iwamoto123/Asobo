{
    @storageRestrictions(accesses: _$backingData, initializes: _text)
    init(initialValue) {
        _$backingData.setValue(forKey: \.text, to: initialValue)
        _text = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.text)
        return self.getValue(forKey: \.text)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.text) {
            self.setValue(forKey: \.text, to: newValue)
        }
    }
}

// original-source-range: /Users/takeshi/workspace/Asobo/Packages/DataStores/Sources/DataStores/SwiftDataParentPhrasesRepository.swift:10:21-10:21
