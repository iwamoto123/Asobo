import SwiftUI
import PhotosUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import Domain

struct ProfileView: View {
    @EnvironmentObject var authVM: AuthViewModel
    
    @State private var childName = ""
    @State private var childNickName = ""
    @State private var teddyName = ""
    @State private var parentName = ""
    @State private var loginMethod = ""
    @State private var birthDate: Date?
    @State private var birthDatePickerDate = Date()
    
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedPhotoData: Data?
    @State private var currentPhotoURLString: String?
    @State private var profileImage: Image?
    @State private var loadedImageURLString: String?
    
    @State private var isSaving = false
    @State private var message: String?
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                
                Text("子どものプロフィール")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(Color(hex: "5A4A42"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 12) {
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            if let data = selectedPhotoData, let uiImage = UIImage(data: data) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 90, height: 90)
                                    .clipShape(Circle())
                            } else if let image = profileImage {
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 90, height: 90)
                                    .clipShape(Circle())
                            } else if currentPhotoURLString != nil {
                                ProgressView().frame(width: 90, height: 90)
                            } else {
                                Circle()
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(width: 90, height: 90)
                                    .overlay(
                                        Image(systemName: "camera.fill")
                                            .font(.system(size: 32))
                                            .foregroundColor(.gray)
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        Text("画像をアップロード")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("子どもの名前")
                                .font(.caption)
                                .foregroundColor(.gray)
                            TextField("お名前", text: $childName)
                                .textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("呼び方")
                                .font(.caption)
                                .foregroundColor(.gray)
                            TextField("呼び名", text: $childNickName)
                                .textFieldStyle(.roundedBorder)
                        }
                        if let bd = birthDate {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("年齢")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                Text(ageString(from: bd))
                                    .font(.body)
                                    .foregroundColor(Color(hex: "5A4A42"))
                                DatePicker("誕生日", selection: $birthDatePickerDate, displayedComponents: .date)
                                    .datePickerStyle(.compact)
                                    .labelsHidden()
                                    .onChange(of: birthDatePickerDate) { newValue in
                                        self.birthDate = newValue
                                    }
                            }
                        }
                    }
                }
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("ぬいぐるみの呼び方")
                        .font(.caption)
                        .foregroundColor(.gray)
                    TextField("例：くまちゃん", text: $teddyName)
                        .textFieldStyle(.roundedBorder)
                }
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("保護者の名前")
                        .font(.caption)
                        .foregroundColor(.gray)
                    TextField("保護者のお名前", text: $parentName)
                        .textFieldStyle(.roundedBorder)
                }
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("ログイン方法")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text(loginMethod.isEmpty ? "不明" : loginMethod)
                        .font(.body)
                        .foregroundColor(Color(hex: "5A4A42"))
                }
                
                if let message = message {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                
                Button(action: saveProfile) {
                    if isSaving {
                        ProgressView().tint(.white)
                    } else {
                        Text("保存する")
                            .fontWeight(.bold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.anoneButton)
                .foregroundColor(.white)
                .cornerRadius(14)
                .disabled(isSaving) // 保存中は連打防止
                
                Button(role: .destructive) {
                    authVM.signOut()
                } label: {
                    Text("ログアウト")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .background(Color.gray.opacity(0.1))
                .cornerRadius(12)
            }
            .padding()
        }
        .navigationTitle("プロフィール")
        .navigationBarTitleDisplayMode(.inline)
        // ① 画面が表示された時にロード
        .onAppear {
            loadInitialValues()
            Task { await loadProfileImageIfNeeded(forceReload: true) }
        }
        // ② 【重要】ViewModelのデータ取得完了を検知してロード
        // idを監視することで、データが更新されたときに検知できる
        .onChange(of: authVM.selectedChild?.id) { _ in
            loadInitialValues()
            Task { await loadProfileImageIfNeeded(forceReload: true) }
        }
        .onChange(of: authVM.userProfile?.id) { _ in
            loadInitialValues()
        }
        // isLoadingがfalseになったとき（データ取得完了時）にもロード
        .onChange(of: authVM.isLoading) { isLoading in
            if !isLoading {
                loadInitialValues()
                Task { await loadProfileImageIfNeeded(forceReload: true) }
            }
        }
        .onChange(of: authVM.selectedChild?.photoURL) { newURL in
            currentPhotoURLString = newURL
            Task { await loadProfileImageIfNeeded(forceReload: true) }
        }
        .onChange(of: currentPhotoURLString) { _ in
            Task { await loadProfileImageIfNeeded(forceReload: true) }
        }
        // 写真選択時の処理
        .onChange(of: selectedPhotoItem) { newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self) {
                    selectedPhotoData = data
                }
            }
        }
    }
    
    private func loadInitialValues() {
        // データがまだロードされていない場合は何もしない（既存入力を消さないため）
        // ただし、画像URLだけは、selectedChildがnilでも、isLoadingがfalseなら設定を試みる（初回立ち上げ時の問題を解決）
        guard let child = authVM.selectedChild else {
            // selectedChildがnilの場合、画像URLだけは設定を試みる（初回立ち上げ時の問題を解決）
            if !authVM.isLoading, let urlString = authVM.selectedChild?.photoURL {
                print("📸 ProfileView: loadInitialValues - selectedChildがnilだが、photoURLを設定: \(urlString)")
                if currentPhotoURLString != urlString {
                    currentPhotoURLString = urlString
                }
            }
            return
        }
        
        // テキストフィールドが空の場合のみセット（入力中を邪魔しない）
        // または、常に最新データを正とするなら強制上書きする。今回は強制上書きパターン。
        
        childName = child.displayName
        childNickName = child.nickName ?? ""
        teddyName = child.teddyName ?? ""
        
        if let user = authVM.userProfile {
            parentName = user.parentName ?? user.displayName ?? ""
        }
        
        birthDate = child.birthDate
        birthDatePickerDate = child.birthDate
        
        // 画像の更新: selectedPhotoDataがnilの時だけURLを更新（ユーザーが選択中の画像を優先）
        if selectedPhotoData == nil {
            if let urlString = child.photoURL {
                print("📸 ProfileView: loadInitialValues - photoURL取得: \(urlString)")
                // URL文字列が変更された場合のみ更新
                if currentPhotoURLString != urlString {
                    print("📸 ProfileView: loadInitialValues - URL変更検出、強制再読み込み（前: \(currentPhotoURLString ?? "nil"), 新: \(urlString)）")
                    // 直接新しいURL文字列を設定（.id()モディファイアにより、URL文字列が変更されれば自動的に再読み込みされる）
                    currentPhotoURLString = urlString
                } else {
                    print("📸 ProfileView: loadInitialValues - URL変更なし")
                }
            } else {
                print("⚠️ ProfileView: loadInitialValues - photoURLがnil")
                currentPhotoURLString = nil
            }
        } else {
            print("ℹ️ ProfileView: loadInitialValues - selectedPhotoDataがあるため、URLは更新しません")
        }
        
        loginMethod = authVM.currentUser?.providerData.first.map { provider in
            switch provider.providerID {
            case "apple.com": return "Apple ID"
            case "google.com": return "Google"
            case "password": return "メール/パスワード"
            default: return provider.providerID
            }
        } ?? "不明"
    }
    
    private func saveProfile() {
        guard let uid = authVM.currentUser?.uid else {
            message = "ログイン情報が見つかりません"
            return
        }
        guard let childId = authVM.selectedChild?.id else {
            message = "子どもの情報が取得できません"
            return
        }
        
        isSaving = true
        message = nil
        
        Task {
            do {
                var photoURL: String? = authVM.selectedChild?.photoURL
                
                if let data = selectedPhotoData {
                    // ★ 画像圧縮処理 (JPEG 0.7)
                    guard let uiImage = UIImage(data: data),
                          let compressedData = uiImage.jpegData(compressionQuality: 0.7) else {
                        message = "画像の処理に失敗しました"
                        isSaving = false
                        return
                    }
                    
                    let storage = Storage.storage(url: "gs://asobo-539e5.firebasestorage.app")
                    let ref = storage.reference().child("users/\(uid)/children/\(childId)/photo.jpg")
                    
                    let metadata = StorageMetadata()
                    metadata.contentType = "image/jpeg"
                    
                    _ = try await ref.putData(compressedData, metadata: metadata)
                    let url = try await ref.downloadURL()
                    photoURL = url.absoluteString
                    print("📸 ProfileView: 画像アップロード成功 - URL: \(photoURL ?? "nil")")
                }
                
                let db = Firestore.firestore()
                
                // 親プロフィール更新
                var parentData: [String: Any] = [:]
                parentData["displayName"] = parentName
                parentData["parentName"] = parentName
                try await db.collection("users").document(uid).setData(parentData, merge: true)
                
                // 子プロフィール更新
                var childData: [String: Any] = [:]
                childData["displayName"] = childName
                childData["nickName"] = childNickName
                childData["teddyName"] = teddyName
                if let birthDate = birthDate {
                    childData["birthDate"] = Timestamp(date: birthDate)
                }
                if let photoURL = photoURL {
                    childData["photoURL"] = photoURL
                    print("📸 ProfileView: Firestoreに保存するphotoURL: \(photoURL)")
                } else {
                    print("⚠️ ProfileView: photoURLがnilのため、Firestoreには保存しません")
                }
                
                try await db.collection("users").document(uid).collection("children").document(childId).setData(childData, merge: true)
                print("✅ ProfileView: Firestoreへの保存完了")
                
                // 選択画像データを先にクリア（URL表示に戻す）
                await MainActor.run {
                    selectedPhotoData = nil
                    selectedPhotoItem = nil
                    // 新しいURLを直接設定（authVM.fetchUserProfile完了を待たずに、すぐに反映）
                    if let newURL = photoURL {
                        print("📸 ProfileView: saveProfile - 新しいURLを直接設定: \(newURL)")
                        currentPhotoURLString = newURL
                    }
                }
                
                // 新しい画像をすぐに読み込む
                await loadProfileImageIfNeeded(forceReload: true)
                
                // ★ 保存後にデータを再取得してViewModelを更新
                await authVM.fetchUserProfile(userId: uid)
                
                // 画面再読み込み（selectedPhotoDataがnilになった後なので、URLが更新される）
                await MainActor.run {
                    loadInitialValues()
                }
                
                // 再度画像を読み込む（authVM.fetchUserProfile完了後）
                await loadProfileImageIfNeeded(forceReload: true)
                
                message = "保存しました"
                
            } catch {
                print("❌ ProfileView: 保存失敗 - \(error)")
                message = "保存に失敗しました: \(error.localizedDescription)"
            }
            isSaving = false
        }
    }
    
    private func loadProfileImageIfNeeded(forceReload: Bool) async {
        // selectedPhotoDataがある場合は、URLから画像を読み込まない（ユーザーが選択中の画像を優先）
        guard selectedPhotoData == nil else {
            print("ℹ️ ProfileView: loadProfileImageIfNeeded - selectedPhotoDataがあるためスキップ")
            return
        }
        
        guard let urlString = currentPhotoURLString ?? authVM.selectedChild?.photoURL else {
            print("⚠️ ProfileView: loadProfileImageIfNeeded - photoURLがnil")
            await MainActor.run {
                profileImage = nil
                loadedImageURLString = nil
            }
            return
        }
        
        // URLから:443を削除（Firebase StorageのURLに含まれることがある）
        let normalizedURLString = urlString.replacingOccurrences(of: ":443", with: "")
        guard let url = URL(string: normalizedURLString) else {
            print("⚠️ ProfileView: loadProfileImageIfNeeded - URL変換失敗: \(normalizedURLString)")
            return
        }
        
        let shouldReload = forceReload || loadedImageURLString != url.absoluteString || profileImage == nil
        if !shouldReload {
            print("ℹ️ ProfileView: loadProfileImageIfNeeded - スキップ（既に読み込み済み）")
            return
        }
        
        print("📸 ProfileView: プロフィール画像の読み込み開始 - URL: \(url.absoluteString)")
        
        // Firebase Storage SDKを使用して画像を取得
        guard let userId = authVM.currentUser?.uid,
              let childId = authVM.selectedChild?.id else {
            print("⚠️ ProfileView: ユーザー情報が取得できません")
            return
        }
        
        do {
            // Storage参照を取得
            let storage = Storage.storage(url: "gs://asobo-539e5.firebasestorage.app")
            let ref = storage.reference().child("users/\(userId)/children/\(childId)/photo.jpg")
            
            // 最大サイズを10MBに設定してダウンロード
            let data = try await ref.data(maxSize: 10 * 1024 * 1024)
            print("📊 ProfileView: データ取得完了 - サイズ: \(data.count) bytes")
            
            if let uiImage = UIImage(data: data) {
                await MainActor.run {
                    profileImage = Image(uiImage: uiImage)
                    loadedImageURLString = url.absoluteString
                    print("✅ ProfileView: プロフィール画像の読み込み成功 - サイズ: \(uiImage.size)")
                }
                return
            } else {
                print("⚠️ ProfileView: プロフィール画像のデータ変換失敗 - データサイズ: \(data.count) bytes")
            }
        } catch {
            // Firebase Storage SDKでの取得に失敗した場合、URLSessionでリトライ
            print("⚠️ ProfileView: Firebase Storage SDKでの取得失敗、URLSessionでリトライ - \(error)")
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                print("📊 ProfileView: URLSessionリトライ - データ取得完了 - サイズ: \(data.count) bytes, Content-Type: \((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "unknown")")
                
                // エラーレスポンス（JSON）かどうかを確認
                if let jsonString = String(data: data, encoding: .utf8),
                   jsonString.contains("\"error\"") {
                    print("❌ ProfileView: Firebase Storage エラーレスポンス受信")
                    print("📊 ProfileView: エラー内容: \(jsonString)")
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let error = json["error"] as? [String: Any] {
                        let code = error["code"] as? Int ?? 0
                        let message = error["message"] as? String ?? "unknown"
                        print("❌ ProfileView: エラーコード: \(code), メッセージ: \(message)")
                    }
                    return
                }
                
                if let uiImage = UIImage(data: data) {
                    await MainActor.run {
                        profileImage = Image(uiImage: uiImage)
                        loadedImageURLString = url.absoluteString
                        print("✅ ProfileView: URLSessionリトライ成功 - サイズ: \(uiImage.size)")
                    }
                } else {
                    print("⚠️ ProfileView: URLSessionリトライでもデータ変換失敗 - データサイズ: \(data.count) bytes")
                }
            } catch {
                print("❌ ProfileView: URLSessionリトライも失敗 - \(error)")
            }
        }
    }
    
    private func ageString(from birthDate: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        let years = calendar.dateComponents([.year], from: birthDate, to: now).year ?? 0
        let anchor = calendar.date(byAdding: .year, value: years, to: birthDate) ?? birthDate
        let months = calendar.dateComponents([.month], from: anchor, to: now).month ?? 0
        return "\(years)歳 \(months)ヶ月"
    }
}
