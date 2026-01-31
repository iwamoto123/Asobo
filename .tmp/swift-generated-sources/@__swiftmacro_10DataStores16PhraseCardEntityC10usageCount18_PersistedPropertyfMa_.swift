{
    @storageRestrictions(accesses: _$backingData, initializes: _usageCount)
    init(initialValue) {
        _$backingData.setValue(forKey: \.usageCount, to: initialValue)
        _usageCount = _SwiftDataNoType()
    }
    get {
        _$observationRegistrar.access(self, keyPath: \.usageCount)
        return self.getValue(forKey: \.usageCount)
    }
    set {
        _$observationRegistrar.withMutation(of: self, keyPath: \.usageCount) {
            self.setValue(forKey: \.usageCount, to: newValue)
        }
    }
}

// original-source-range: /Users/takeshi/workspace/Asobo/Packages/DataStores/Sources/DataStores/SwiftDataParentPhrasesRepository.swift:14:24-14:24
