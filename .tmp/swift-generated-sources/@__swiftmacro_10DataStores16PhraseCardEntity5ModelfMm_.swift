@Transient
private var _$backingData: any SwiftData.BackingData<PhraseCardEntity> = PhraseCardEntity.createBackingData()

public var persistentBackingData: any SwiftData.BackingData<PhraseCardEntity> {
    get {
        return _$backingData
    }
    set {
        _$backingData = newValue
    }
}

static var schemaMetadata: [SwiftData.Schema.PropertyMetadata] {
  return [
    SwiftData.Schema.PropertyMetadata(name: "id", keypath: \PhraseCardEntity.id, defaultValue: nil, metadata: SwiftData.Schema.Attribute(.unique)),
    SwiftData.Schema.PropertyMetadata(name: "text", keypath: \PhraseCardEntity.text, defaultValue: nil, metadata: nil),
    SwiftData.Schema.PropertyMetadata(name: "categoryRawValue", keypath: \PhraseCardEntity.categoryRawValue, defaultValue: nil, metadata: nil),
    SwiftData.Schema.PropertyMetadata(name: "isPreset", keypath: \PhraseCardEntity.isPreset, defaultValue: nil, metadata: nil),
    SwiftData.Schema.PropertyMetadata(name: "priority", keypath: \PhraseCardEntity.priority, defaultValue: nil, metadata: nil),
    SwiftData.Schema.PropertyMetadata(name: "usageCount", keypath: \PhraseCardEntity.usageCount, defaultValue: nil, metadata: nil),
    SwiftData.Schema.PropertyMetadata(name: "lastUsedAt", keypath: \PhraseCardEntity.lastUsedAt, defaultValue: nil, metadata: nil),
    SwiftData.Schema.PropertyMetadata(name: "createdAt", keypath: \PhraseCardEntity.createdAt, defaultValue: nil, metadata: nil)
  ]
}

init(backingData: any SwiftData.BackingData<PhraseCardEntity>) {
  _id = _SwiftDataNoType()
  _text = _SwiftDataNoType()
  _categoryRawValue = _SwiftDataNoType()
  _isPreset = _SwiftDataNoType()
  _priority = _SwiftDataNoType()
  _usageCount = _SwiftDataNoType()
  _lastUsedAt = _SwiftDataNoType()
  _createdAt = _SwiftDataNoType()
  self.persistentBackingData = backingData
}

@Transient private let _$observationRegistrar = Observation.ObservationRegistrar()

internal nonisolated func access<_M>(
    keyPath: KeyPath<PhraseCardEntity, _M>
) {
  _$observationRegistrar.access(self, keyPath: keyPath)
}

internal nonisolated func withMutation<_M, _MR>(
  keyPath: KeyPath<PhraseCardEntity, _M>,
  _ mutation: () throws -> _MR
) rethrows -> _MR {
  try _$observationRegistrar.withMutation(of: self, keyPath: keyPath, mutation)
}

struct _SwiftDataNoType {
}

// original-source-range: /Users/takeshi/workspace/Asobo/Packages/DataStores/Sources/DataStores/SwiftDataParentPhrasesRepository.swift:55:1-55:1
