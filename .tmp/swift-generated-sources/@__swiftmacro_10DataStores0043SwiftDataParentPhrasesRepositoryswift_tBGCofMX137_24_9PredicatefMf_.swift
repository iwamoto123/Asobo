Foundation.Predicate<PhraseCardEntity>({
    PredicateExpressions.build_Equal(
        lhs: PredicateExpressions.build_KeyPath(
            root: PredicateExpressions.build_Arg($0),
            keyPath: \.id
        ),
        rhs: PredicateExpressions.build_Arg(id)
    )
})

// original-source-range: /Users/takeshi/workspace/Asobo/Packages/DataStores/Sources/DataStores/SwiftDataParentPhrasesRepository.swift:138:25-138:69
