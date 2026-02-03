# Firebase/Firestore 実装まとめ

## 📁 ファイル構成

### 1. データモデル定義
**`Packages/Domain/Sources/Domain/FirebaseModels.swift`**
- Firebase Firestoreに保存するためのデータモデル（DTO）を定義
- すべての型は`Codable`に準拠
- `Firebase`プレフィックスで命名（既存の`DomainModels.swift`との衝突を回避）

### 2. リポジトリ実装
**`Packages/DataStores/Sources/DataStores/FirebaseConversationsRepository.swift`**
- Firestoreへの保存・取得処理を実装
- 手動エンコード/デコード方式（`FirebaseFirestoreSwift`は未使用）

### 3. パッケージ依存関係
**`Packages/DataStores/Package.swift`**
- `FirebaseFirestore`のみを依存関係に追加
- `FirebaseFirestoreSwift`は削除済み

### 4. 使用箇所
**`Asobo/Features/Conversation/ConversationController.swift`**
- 会話セッションの開始・終了時にFirestoreに保存
- 各ターン（ユーザー発言・AI応答）をリアルタイムで保存
- 会話終了後に分析処理を実行

---

## 📊 データモデル一覧

### Enums

```swift
// 興味タグ
FirebaseInterestTag: dinosaurs, space, cooking, animals, vehicles, music, sports, crafts, stories, insects, princess, heroes, robots, nature, others

// セッションモード
FirebaseSessionMode: freeTalk, story

// ロール
FirebaseRole: child, ai, parent

// 安全性フラグ
FirebaseSafetyFlag: selfHarm, violence, sexual, hate, bullying, other

// 音声ペイロード種別
FirebaseVoicePayloadKind: recorded, tts

// トリガー種別
FirebaseTriggerType: manual, timeBased

// 共有レベル
FirebaseSharingLevel: none, summaryOnly, full
```

### Structs

#### 1. `FirebaseParentProfile`
- **パス**: `/users/{userId}`
- **用途**: 親ユーザーのプロフィール
- **フィールド**: `id`, `displayName`, `currentChildId`, `createdAt`

#### 2. `FirebaseChildProfile`
- **パス**: `/users/{userId}/children/{childId}`
- **用途**: 子供のプロフィール
- **フィールド**: `id`, `displayName`, `nickName`, `birthDate`, `interests`, `createdAt`
- **計算プロパティ**: `currentAge`（年齢を自動計算）

#### 3. `FirebaseConversationSession` ⭐ **現在使用中**
- **パス**: `/users/{userId}/children/{childId}/sessions/{sessionId}`
- **用途**: 会話セッションのメタデータ
- **フィールド**: 
  - `id`: セッションID
  - `mode`: セッションモード（freeTalk/story）
  - `startedAt`: 開始時刻
  - `endedAt`: 終了時刻（オプション）
  - `speakerChildId`: きょうだいがいる場合の「この会話は誰の会話か」(オプション)
  - `speakerChildName`: きょうだいがいる場合の表示名（履歴カード用）(オプション)
  - `interestContext`: この会話で触れられた興味タグ
  - `summaries`: 会話の短い要約（配列）
  - `newVocabulary`: 新しく使った言葉（配列）
  - `turnCount`: ターンの総数

#### 4. `FirebaseTurn` ⭐ **現在使用中**
- **パス**: `/users/{userId}/children/{childId}/sessions/{sessionId}/turns/{turnId}`
- **用途**: 会話の各ターン（発言単位）
- **サブコレクション**: `sessions`の下に`turns`コレクション
- **フィールド**:
  - `id`: ターンID
  - `role`: 発言者（child/ai/parent）
  - `text`: 会話テキスト
  - `audioPath`: Storageパス（現在未使用）
  - `duration`: 音声の長さ（現在未使用）
  - `safety`: 安全性フラグ（現在未使用）
  - `timestamp`: 発話時刻

#### 5. `FirebaseVoiceStamp`
- **パス**: `/users/{userId}/voiceStamps/{stampId}`
- **用途**: 親の声スタンプ（録音音声やTTS）
- **フィールド**: `id`, `title`, `payloadKind`, `trigger`, `isEnabled`, `audioPath`, `ttsText`, `createdAt`, `lastPlayedAt`

#### 6. `FirebaseWeeklyReport`
- **パス**: `/users/{userId}/children/{childId}/reports/{weekISO}`
- **用途**: 週次レポート（LINE通知の代わり）
- **フィールド**: `id`, `summary`, `topInterests`, `newVocabulary`, `adviceForParent`, `createdAt`

#### 7. `FirebaseAppSettings`
- **パス**: `/users/{userId}/settings/config`
- **用途**: アプリ設定
- **フィールド**: `id`, `sharingLevel`, `quietHours`, `languageCode`, `enableEnglishMode`

---

## 🔧 リポジトリ実装詳細

### `FirebaseConversationsRepository`

#### セッション管理

```swift
// セッション作成（会話開始時）
func createSession(userId: String, childId: String, session: FirebaseConversationSession) async throws

// セッション終了更新（会話終了時）
func finishSession(userId: String, childId: String, sessionId: String, endedAt: Date) async throws

// ターン数更新
func updateTurnCount(userId: String, childId: String, sessionId: String, turnCount: Int) async throws
```

#### ターン管理

```swift
// ターン追加（会話中）
func addTurn(userId: String, childId: String, sessionId: String, turn: FirebaseTurn) async throws

// 全ターン取得（分析用）
func fetchTurns(userId: String, childId: String, sessionId: String) async throws -> [FirebaseTurn]
```

#### 分析結果更新

```swift
// 分析結果更新（要約・興味など）
func updateAnalysis(
    userId: String,
    childId: String,
    sessionId: String,
    summaries: [String],
    interests: [FirebaseInterestTag],
    newVocabulary: [String]
) async throws
```

### 実装方式

- **エンコード**: `JSONEncoder` → `JSONSerialization` → `[String: Any]` → `Timestamp`変換
- **デコード**: `[String: Any]` → `Timestamp` → `Date`変換 → `JSONSerialization` → `JSONDecoder`
- **Date/Timestamp変換**: 手動で`Timestamp(date:)`と`timestamp.dateValue()`を使用

---

## 🔄 ConversationControllerでの使用フロー

### 1. セッション開始時

```swift
// startRealtimeSessionInternal()内
let newSessionId = UUID().uuidString
let session = FirebaseConversationSession(
    id: newSessionId,
    mode: .freeTalk,
    startedAt: Date(),
    interestContext: [],
    summaries: [],
    newVocabulary: [],
    turnCount: 0
)
try await firebaseRepository.createSession(
    userId: currentUserId,
    childId: currentChildId,
    session: session
)
```

### 2. ユーザー発言時（onInputCommitted）

```swift
let turn = FirebaseTurn(
    role: .child,
    text: transcript,
    timestamp: Date()
)
try await firebaseRepository.addTurn(
    userId: currentUserId,
    childId: currentChildId,
    sessionId: sessionId,
    turn: turn
)
// ターン数を更新
turnCount += 1
try await firebaseRepository.updateTurnCount(...)
```

### 3. AI応答時（onResponseDone）

```swift
let turn = FirebaseTurn(
    role: .ai,
    text: aiResponseText,
    timestamp: Date()
)
try await firebaseRepository.addTurn(...)
// ターン数を更新
turnCount += 1
try await firebaseRepository.updateTurnCount(...)
```

### 4. セッション終了時（stopRealtimeSession）

```swift
try await firebaseRepository.finishSession(
    userId: currentUserId,
    childId: currentChildId,
    sessionId: sessionId,
    endedAt: Date()
)
// 分析処理を実行
await analyzeSession(sessionId: sessionId)
```

### 5. 会話分析（analyzeSession）

```swift
// 1. 全ターンを取得
let turns = try await firebaseRepository.fetchTurns(...)

// 2. 会話ログを生成
let conversationLog = turns.compactMap { ... }.joined(separator: "\n")

// 3. OpenAI Chat Completion APIに投げる
// (gpt-4o-mini, JSON形式で要約・興味・新語彙を抽出)

// 4. 分析結果をFirestoreに保存
try await firebaseRepository.updateAnalysis(
    summaries: [...],
    interests: [...],
    newVocabulary: [...]
)
```

---

## 📦 パッケージ依存関係

### DataStores Package

```swift
dependencies: [
    .package(path: "../Domain"),
    .package(url: "https://github.com/firebase/firebase-ios-sdk", from: "12.6.0")
]

targets: [
    .target(
        name: "DataStores",
        dependencies: [
            .product(name: "Domain", package: "Domain"),
            .product(name: "FirebaseFirestore", package: "firebase-ios-sdk")
        ]
    )
]
```

**注意**: `FirebaseFirestoreSwift`は使用していない（手動エンコード/デコード方式のため）

---

## 🔐 現在の実装状況

### ✅ 実装済み

- [x] セッション作成・終了
- [x] ターン追加（ユーザー発言・AI応答）
- [x] ターン数更新
- [x] 全ターン取得
- [x] 会話分析（OpenAI API連携）
- [x] 分析結果保存

### ⚠️ TODO（現在ダミー値）

- [ ] `currentUserId`: 現在`"dummy_parent_uid"` → Firebase Authから取得
- [ ] `currentChildId`: 現在`"dummy_child_uid"` → 選択中の子供IDを設定

### 📝 未実装（データモデルは定義済み）

- [ ] `FirebaseParentProfile`の保存・取得
- [ ] `FirebaseChildProfile`の保存・取得
- [ ] `FirebaseVoiceStamp`の保存・取得
- [ ] `FirebaseWeeklyReport`の生成・表示
- [ ] `FirebaseAppSettings`の保存・取得
- [ ] 音声ファイルのFirebase Storageへのアップロード（`audioPath`）

---

## 🗂️ Firestoreデータ構造

```
/users/{userId}
  ├── displayName: String
  ├── currentChildId: String?
  ├── createdAt: Timestamp
  │
  ├── /children/{childId}
  │   ├── displayName: String
  │   ├── nickName: String?
  │   ├── birthDate: Timestamp
  │   ├── interests: [String]
  │   ├── createdAt: Timestamp
  │   │
  │   ├── /sessions/{sessionId} ⭐ 現在使用中
  │   │   ├── mode: String
  │   │   ├── startedAt: Timestamp
  │   │   ├── endedAt: Timestamp?
  │   │   ├── interestContext: [String]
  │   │   ├── summaries: [String]
  │   │   ├── newVocabulary: [String]
  │   │   ├── turnCount: Int
  │   │   │
  │   │   └── /turns/{turnId} ⭐ 現在使用中
  │   │       ├── role: String
  │   │       ├── text: String?
  │   │       ├── audioPath: String?
  │   │       ├── duration: Double?
  │   │       ├── safety: [String]
  │   │       └── timestamp: Timestamp
  │   │
  │   └── /reports/{weekISO}
  │       ├── summary: String
  │       ├── topInterests: [String]
  │       ├── newVocabulary: [String]
  │       ├── adviceForParent: String?
  │       └── createdAt: Timestamp
  │
  ├── /voiceStamps/{stampId}
  │   ├── title: String
  │   ├── payloadKind: String
  │   ├── trigger: String
  │   ├── isEnabled: Bool
  │   ├── audioPath: String?
  │   ├── ttsText: String?
  │   ├── createdAt: Timestamp
  │   └── lastPlayedAt: Timestamp?
  │
  └── /settings/config
      ├── sharingLevel: String
      ├── quietHours: { start: String, end: String }?
      ├── languageCode: String
      └── enableEnglishMode: Bool
```

---

## 💡 実装の特徴

### 手動エンコード/デコード方式

- `FirebaseFirestoreSwift`の`@DocumentID`や`setData(from:)`は使用していない
- `JSONEncoder`/`JSONDecoder`と`JSONSerialization`を組み合わせて実装
- `Date` ↔ `Timestamp`の変換を手動で処理

### エラーハンドリング

- すべてのFirestore操作は`async throws`
- `ConversationController`では`Task { try? await ... }`で非同期実行し、エラーはログ出力のみ

### 非同期処理

- Firestore操作はすべて`Task`で非同期実行
- UIスレッドをブロックしない設計

---

## 🔍 デバッグログ

すべてのFirestore操作で以下のログを出力：

- ✅ 成功時: `✅ FirebaseConversationsRepository: [操作名] - [詳細]`
- ❌ 失敗時: `❌ ConversationController: [操作名]失敗 - [エラー]`

---

## 🔒 セキュリティルール設定（開発環境）

### 問題: Permission denied エラー

現在、`currentUserId`が`"dummy_parent_uid"`という固定値になっているため、Firebaseのデフォルトセキュリティルールでは書き込みが拒否されます。

エラーメッセージ例:
```
Permission denied: Missing or insufficient permissions.
```

### 解決策: 開発用セキュリティルールの設定

#### 手順

1. **Firebaseコンソールを開く**
   - https://console.firebase.google.com/

2. **プロジェクトを選択**

3. **Firestore Database > ルール (Rules) タブを選択**

4. **以下のルールに書き換えて「公開 (Publish)」ボタンを押す**

#### オプション1: 全許可（開発用・最も簡単）

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // ⚠️ 開発中はすべての読み書きを許可
    // ⚠️ 本番リリース前には必ず適切なルールに変更してください
    match /{document=**} {
      allow read, write: if true;
    }
  }
}
```

#### オプション2: パス構造に基づいた許可（推奨）

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /users/{userId} {
      // 開発中: 認証チェックなしで全ユーザーにアクセス許可
      allow read, write: if true;
      
      match /children/{childId} {
        allow read, write: if true;
        
        match /sessions/{sessionId} {
          allow read, write: if true;
          
          match /turns/{turnId} {
            allow read, write: if true;
          }
        }
        
        match /reports/{reportId} {
          allow read, write: if true;
        }
      }
      
      match /voiceStamps/{stampId} {
        allow read, write: if true;
      }
      
      match /settings/{settingId} {
        allow read, write: if true;
      }
    }
  }
}
```

#### オプション3: 本番環境用（認証必須）

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /users/{userId} {
      // 認証済みユーザーのみ、自分のデータにアクセス可能
      allow read, write: if request.auth != null && request.auth.uid == userId;
      
      match /children/{childId} {
        allow read, write: if request.auth != null && request.auth.uid == userId;
        
        match /sessions/{sessionId} {
          allow read, write: if request.auth != null && request.auth.uid == userId;
          
          match /turns/{turnId} {
            allow read, write: if request.auth != null && request.auth.uid == userId;
          }
        }
        
        match /reports/{reportId} {
          allow read, write: if request.auth != null && request.auth.uid == userId;
        }
      }
      
      match /voiceStamps/{stampId} {
        allow read, write: if request.auth != null && request.auth.uid == userId;
      }
      
      match /settings/{settingId} {
        allow read, write: if request.auth != null && request.auth.uid == userId;
      }
    }
  }
}
```

### 確認事項

- ルールを変更してから反映されるまで、**数秒〜1分程度**かかる場合があります
- 変更後、再度実機でアプリを動かして、ログに`❌ ConversationController: ...失敗`が出なくなるか確認してください
- エラーログに`Permission denied`が含まれている場合、`logFirebaseError`関数がセキュリティルールの設定方法を案内します

### 注意事項

⚠️ **本番リリース前には必ず適切なセキュリティルールに変更してください**

- オプション1（全許可）は**開発環境のみ**で使用してください
- 本番環境では、オプション3（認証必須）または適切な権限チェックを実装してください
- セキュリティルールの変更は、Firebaseコンソールから行います

---

## 📚 参考

- Firebase Firestore公式ドキュメント: https://firebase.google.com/docs/firestore
- Firestore セキュリティルール: https://firebase.google.com/docs/firestore/security/get-started
- Swift Package Manager: https://swift.org/package-manager/

