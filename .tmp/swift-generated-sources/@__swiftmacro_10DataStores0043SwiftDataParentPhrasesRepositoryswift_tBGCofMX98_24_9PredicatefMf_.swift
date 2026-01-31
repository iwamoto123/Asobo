Foundation.Predicate<PhraseCardEntity>({
    PredicateExpressions.build_Equal(
        lhs: PredicateExpressions.build_KeyPath(
            root: PredicateExpressions.build_Arg($0),
            keyPath: \.categoryRawValue
        ),
        rhs: PredicateExpressions.build_KeyPath(
            root: PredicateExpressions.build_Arg(category),
            keyPath: \.rawValue
        )
    )
})

// original-source-range: /Users/takeshi/workspace/Asobo/Packages/DataStores/Sources/DataStores/SwiftDataParentPhrasesRepository.swift:99:25-101:10
