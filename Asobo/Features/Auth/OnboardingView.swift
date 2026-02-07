import SwiftUI
import PhotosUI
import FirebaseStorage
import FirebaseFirestore
import Domain
import FirebaseAuth

private let analytics = AnalyticsService.shared

struct OnboardingView: View {
    @ObservedObject var authVM: AuthViewModel
    @State private var tabSelection = 0
    @State private var keyboardHeight: CGFloat = 0

    private struct AdditionalChildInput: Identifiable {
        let id = UUID()
        var name: String = ""
        var nickname: String = ""
        var birthDate: Date = Date()
    }

    private struct AgeConfirmItem: Identifiable {
        let id = UUID()
        let callName: String
        let ageText: String
    }

    // 入力データ
    @State private var parentName = ""
    @State private var childName = ""
    @State private var childNickname = ""
    @State private var hasAdditionalChildren = false
    @State private var additionalChildren: [AdditionalChildInput] = []
    @State private var teddyName = ""
    @State private var birthDate = Date()
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedPhotoData: Data?
    @State private var imageForCropping: UIImage?

    @State private var isSaving = false
    @State private var errorMessage: String?

    // 入力必須エラーフラグ
    @State private var parentError = false
    @State private var childNameError = false
    @State private var teddyError = false
    @State private var birthDateError = false

    private var ageConfirmItems: [AgeConfirmItem] {
        func callName(name: String, nickname: String) -> String? {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let nick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            if !nick.isEmpty { return nick }
            if !n.isEmpty { return n }
            return nil
        }

        var items: [AgeConfirmItem] = []

        if let mainCall = callName(name: childName, nickname: childNickname) {
            items.append(.init(callName: mainCall, ageText: ageString(from: birthDate)))
        }

        for c in additionalChildren {
            guard let cCall = callName(name: c.name, nickname: c.nickname) else { continue }
            items.append(.init(callName: cCall, ageText: ageString(from: c.birthDate)))
        }

        return items
    }

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [.anoneBgTop, .anoneBgBottom]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .overlay(AmbientCircles())

            TabView(selection: $tabSelection) {
                // Step 1: 親の名前
                OnboardingStepView(
                    title: "はじめまして！",
                    description: "あなた（保護者）が使う名前を教えてください。\nアプリでの表示名になります。"
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("あなたの名前（ニックネームOK）")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(Color(hex: "5A4A42"))
                        TextField("例：さき、むさし、さきママなど", text: $parentName)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .onChange(of: parentName) { _ in parentError = false }
                        if parentError {
                            Text("入力は必須です")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    .padding(.horizontal)
                }
                .tag(0)

                // Step 2: 子供の名前と誕生日
                OnboardingStepView(
                    title: "お子さまについて",
                    description: "お話しする長男・長女の名前と年齢を教えてください。\nごきょうだいがいる場合は、この画面の下から追加できます。"
                ) {
                    ScrollView {
                        VStack(spacing: 15) {
                            TextField("お名前（例：たろう）", text: $childName)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .onChange(of: childName) { _ in childNameError = false }
                            if childNameError {
                                Text("入力は必須です")
                                    .font(.caption)
                                    .foregroundColor(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            TextField("呼び名（任意：例：たーくん）", text: $childNickname)
                                .textFieldStyle(RoundedBorderTextFieldStyle())

                            DatePicker("お誕生日", selection: $birthDate, in: Date.distantPast...Date(), displayedComponents: .date)
                                .environment(\.locale, Locale(identifier: "ja_JP"))
                                .onChange(of: birthDate) { newDate in
                                    birthDateError = newDate > Date()
                                }
                            if birthDateError {
                                Text("過去の日付を入れてください")
                                    .font(.caption)
                                    .foregroundColor(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            // きょうだいがいる場合ボタン（画面の下）
                            Button {
                                withAnimation(.easeInOut) {
                                    hasAdditionalChildren.toggle()
                                    if hasAdditionalChildren && additionalChildren.isEmpty {
                                        additionalChildren.append(.init())
                                    }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: hasAdditionalChildren ? "chevron.down" : "chevron.right")
                                    Text("きょうだいがいる場合")
                                }
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.9))
                                .foregroundColor(Color.anoneButton)
                                .cornerRadius(12)
                            }
                            .padding(.top, 4)

                            if hasAdditionalChildren {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("きょうだい")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(Color(hex: "5A4A42"))
                                    Text("名前を呼ぶと喜ぶので、きょうだいがいる場合は入れてみてください。")
                                        .font(.footnote)
                                        .foregroundColor(Color(hex: "8A7A72"))

                                    ForEach($additionalChildren) { $c in
                                        VStack(spacing: 10) {
                                            HStack(spacing: 8) {
                                                TextField("お名前（例：はな）", text: $c.name)
                                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                                TextField("呼び名（任意：例：はーちゃん）", text: $c.nickname)
                                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                                Button {
                                                    additionalChildren.removeAll { $0.id == c.id }
                                                    if additionalChildren.isEmpty {
                                                        hasAdditionalChildren = false
                                                    }
                                                } label: {
                                                    Image(systemName: "minus.circle.fill")
                                                        .foregroundColor(.red.opacity(0.85))
                                                }
                                                .accessibilityLabel("きょうだいを削除")
                                            }
                                            DatePicker("お誕生日", selection: $c.birthDate, in: Date.distantPast...Date(), displayedComponents: .date)
                                                .environment(\.locale, Locale(identifier: "ja_JP"))
                                        }
                                        .padding(12)
                                        .background(Color.white.opacity(0.55))
                                        .cornerRadius(12)
                                    }

                                    Button {
                                        guard additionalChildren.count < 5 else { return }
                                        additionalChildren.append(.init())
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "plus.circle.fill")
                                            Text("きょうだいを追加")
                                        }
                                        .font(.subheadline.weight(.semibold))
                                    }
                                    .disabled(additionalChildren.count >= 5)
                                    .foregroundColor(additionalChildren.count >= 5 ? .gray : Color.anoneButton)
                                }
                                .padding(.top, 4)
                            }
                        }
                        .padding(.horizontal)
                        // キーボード + 下のナビボタン分の余白を確保して、隠れないようにする
                        .padding(.bottom, keyboardHeight > 0 ? keyboardHeight + 120 : 0)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
                .tag(1)

                // Step 3: 年齢確認
                VStack(spacing: 20) {
                    let items = ageConfirmItems
                    Text(items.count <= 1 ? "お子さんの年齢は" : "お子さんたちの年齢は")
                        .font(.subheadline)
                        .foregroundColor(Color(hex: "5A4A42"))

                    if let first = items.first, items.count <= 1 {
                        Text(first.ageText)
                            .font(.largeTitle.bold())
                            .foregroundColor(Color(hex: "5A4A42"))
                    } else {
                        VStack(spacing: 12) {
                            ForEach(items) { item in
                                HStack {
                                    Text(item.callName)
                                        .font(.headline.weight(.semibold))
                                        .foregroundColor(Color(hex: "5A4A42"))
                                    Spacer()
                                    Text(item.ageText)
                                        .font(.title3.bold())
                                        .foregroundColor(Color(hex: "5A4A42"))
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal, 14)
                                .background(Color.white.opacity(0.65))
                                .cornerRadius(12)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    Text("で合っていますか？")
                        .font(.subheadline)
                        .foregroundColor(Color(hex: "5A4A42"))
                        .padding(.bottom, 4)
                    Text("年齢に合わせて話します。")
                        .font(.footnote)
                        .foregroundColor(Color(hex: "8A7A72"))
                }
                .padding(.top, 100)
                .padding(.horizontal)
                .tag(2)

                // Step 4: ぬいぐるみ
                OnboardingStepView(
                    title: "相棒の名前",
                    description: "お子さまのお友達（ぬいぐるみ）は\n何と呼びますか？"
                ) {
                    TextField("例：もっちぃ、くまちゃん", text: $teddyName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding(.horizontal)
                        .onChange(of: teddyName) { _ in teddyError = false }
                    if teddyError {
                        Text("入力は必須です")
                            .font(.caption)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }
                }
                .tag(3)

                // Step 5: 写真設定と完了
                VStack(spacing: 20) {
                    Text("最後にアイコンを設定")
                        .font(.title2.bold())
                        .foregroundColor(Color(hex: "5A4A42"))

                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        if let data = selectedPhotoData, let uiImage = UIImage(data: data) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 100, height: 100)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.anoneButton, lineWidth: 2.5))
                        } else {
                            ZStack {
                                Circle().fill(Color.white)
                                Image(systemName: "camera.fill")
                                    .foregroundColor(.gray)
                            }
                            .frame(width: 100, height: 100)
                            .shadow(radius: 5)
                        }
                    }
                    .onChange(of: selectedPhotoItem) { newItem in
                        Task {
                            if let data = try? await newItem?.loadTransferable(type: Data.self),
                               let uiImage = UIImage(data: data) {
                                await MainActor.run {
                                    imageForCropping = uiImage
                                }
                            }
                        }
                    }
                    .sheet(isPresented: Binding(
                        get: { imageForCropping != nil },
                        set: { isPresented in
                            if !isPresented { imageForCropping = nil }
                        }
                    )) {
                        if let imageForCropping {
                            AvatarCropperView(
                                image: imageForCropping,
                                onCancel: { self.imageForCropping = nil },
                                onCrop: { cropped in
                                    self.selectedPhotoData = cropped.jpegData(compressionQuality: 0.9)
                                    self.imageForCropping = nil
                                }
                            )
                        }
                    }

                    if let errorMessage = errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    Button(action: saveData) {
                        if isSaving {
                            ProgressView().tint(.white)
                        } else {
                            Text("はじめる！")
                                .fontWeight(.bold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(canSubmit ? Color.anoneButton : Color.gray.opacity(0.5))
                    .foregroundColor(.white)
                    .cornerRadius(15)
                    .disabled(!canSubmit || isSaving)
                    .padding(.horizontal)
                }
                .padding()
                .tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            // 次へボタン (Step 0-2) — キーボード分だけ持ち上げる
            if tabSelection < 4 {
                VStack {
                    Spacer()
                    HStack {
                        if tabSelection > 0 {
                            Button("もどる") {
                                withAnimation { tabSelection -= 1 }
                            }
                            .padding()
                            .background(Color.white.opacity(0.9))
                            .foregroundColor(Color.anoneButton)
                            .cornerRadius(20)
                            .padding(.leading, 30)
                        }
                        Spacer()
                        Button("つぎへ") {
                            if validateCurrentStep() {
                                withAnimation { tabSelection += 1 }
                            }
                        }
                        .padding()
                        .background(Color.anoneButton)
                        .foregroundColor(.white)
                        .cornerRadius(20)
                        .padding(.trailing, 30)
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screen = UIScreen.main.bounds
            let overlap = max(0, screen.maxY - endFrame.minY)
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            withAnimation(.easeOut(duration: duration)) {
                keyboardHeight = overlap
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            withAnimation(.easeOut(duration: duration)) {
                keyboardHeight = 0
            }
        }
        .onAppear {
            analytics.log(.onboardingStart)
            analytics.logScreenView(.onboarding)
        }
        .onChange(of: tabSelection) { newStep in
            analytics.log(.onboardingStep(step: newStep))
        }
    }

    var canSubmit: Bool {
        !parentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !childName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !teddyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        birthDate <= Date()
    }

    // データ保存処理
    func saveData() {
        guard let uid = Auth.auth().currentUser?.uid else {
            errorMessage = "ログイン情報が見つかりません"
            return
        }
        let db = Firestore.firestore()
        let childRef = db.collection("users").document(uid).collection("children").document()
        isSaving = true
        errorMessage = nil

        Task {
            do {
                // 1. 画像アップロード (あれば)
                var photoURL: String?
                if let data = selectedPhotoData {
                    do {
                        // デフォルトバケットを使用し、子ごとのパスに保存
        // 明示的に default bucket（firebasestorage.app）を指定してアップロードする
        let ref = Storage
            .storage(url: "gs://asobo-539e5.firebasestorage.app")
            .reference()
            .child("users/\(uid)/children/\(childRef.documentID)/photo.jpg")
                        let metadata = StorageMetadata()
                        metadata.contentType = "image/jpeg"
                        _ = try await ref.putData(data, metadata: metadata) // ここで失敗したら catch へ
                        let url = try await ref.downloadURL()
                        photoURL = url.absoluteString
                        print("✅ OnboardingView: 写真アップロード成功 - \(photoURL ?? "nil")")
                    } catch {
                        print("❌ OnboardingView: 写真アップロード失敗 - \(error)")
                        errorMessage = "写真のアップロードに失敗しました: \(error.localizedDescription)"
                        isSaving = false
                        return
                    }
                }

                // 2. 親プロフィールの保存
                let userProfile = FirebaseParentProfile(
                    id: uid,
                    displayName: parentName, // 親の名前をdisplayNameとして使用
                    parentName: parentName,
                    email: Auth.auth().currentUser?.email,
                    currentChildId: nil, // 後で更新
                    createdAt: Date()
                )

                // 手動エンコード（FirebaseFirestoreSwiftを使わない方式）
                var profileData: [String: Any] = [:]
                profileData["displayName"] = userProfile.displayName
                profileData["parentName"] = userProfile.parentName
                if let email = userProfile.email {
                    profileData["email"] = email
                }
                profileData["createdAt"] = Timestamp(date: userProfile.createdAt)

                try await db.collection("users").document(uid).setData(profileData)
                print("✅ OnboardingView: 親プロフィール保存成功")

                // 3. 子どもプロフィールの保存（メイン + きょうだいを同列に children コレクションへ作成）
                let trimmedChildName = childName.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedChildNickname = childNickname.trimmingCharacters(in: .whitespacesAndNewlines)
                let mainChildProfile = FirebaseChildProfile(
                    id: childRef.documentID,
                    displayName: trimmedChildName,
                    nickName: trimmedChildNickname.isEmpty ? trimmedChildName : trimmedChildNickname,
                    birthDate: birthDate,
                    photoURL: photoURL,
                    teddyName: teddyName,
                    interests: [],
                    createdAt: Date()
                )

                var mainChildData: [String: Any] = [:]
                mainChildData["displayName"] = mainChildProfile.displayName
                if let nickName = mainChildProfile.nickName {
                    mainChildData["nickName"] = nickName
                }
                mainChildData["birthDate"] = Timestamp(date: mainChildProfile.birthDate)
                if let photoURL = mainChildProfile.photoURL {
                    mainChildData["photoURL"] = photoURL
                }
                if let teddyName = mainChildProfile.teddyName {
                    mainChildData["teddyName"] = teddyName
                }
                mainChildData["interestContext"] = [] // 空配列
                mainChildData["createdAt"] = Timestamp(date: mainChildProfile.createdAt)

                try await childRef.setData(mainChildData)
                print("✅ OnboardingView: 子どもプロフィール保存成功（メイン） - childId: \(childRef.documentID)")

                // きょうだい（任意）
                let additionalUsed = additionalChildren.compactMap { input -> AdditionalChildInput? in
                    let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let nickname = input.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                    if name.isEmpty && nickname.isEmpty { return nil }
                    return input
                }

                for input in additionalUsed {
                    let ref = db.collection("users").document(uid).collection("children").document()
                    let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let nickname = input.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                    let displayName = !name.isEmpty ? name : nickname
                    let nickName: String? = nickname.isEmpty ? nil : nickname

                    var data: [String: Any] = [:]
                    data["displayName"] = displayName
                    if let nickName {
                        data["nickName"] = nickName
                    }
                    data["birthDate"] = Timestamp(date: input.birthDate)
                    data["interestContext"] = []
                    data["createdAt"] = Timestamp(date: Date())

                    try await ref.setData(data)
                    print("✅ OnboardingView: 子どもプロフィール保存成功（きょうだい） - childId: \(ref.documentID)")
                }

                // 4. 親のcurrentChildIdを更新
                try await db.collection("users").document(uid).updateData(["currentChildId": childRef.documentID])
                print("✅ OnboardingView: currentChildId更新成功")

                // 5. Analytics: オンボーディング完了
                analytics.log(.onboardingComplete)

                // 6. ViewModelの状態更新 -> Mainへ遷移
                await authVM.fetchUserProfile(userId: uid)

            } catch {
                print("❌ OnboardingView: データ保存エラー - \(error)")
                errorMessage = "データの保存に失敗しました: \(error.localizedDescription)"
                isSaving = false
            }
        }
    }

    private func validateCurrentStep() -> Bool {
        // トリムして空チェック
        func isEmpty(_ text: String) -> Bool {
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        switch tabSelection {
        case 0:
            parentError = isEmpty(parentName)
            return !parentError
        case 1:
            childNameError = isEmpty(childName)
            birthDateError = birthDate > Date()
            return !(childNameError || birthDateError)
        case 2:
            // 年齢確認: 入力はないので常に通過
            return true
        case 3:
            teddyError = isEmpty(teddyName)
            return !teddyError
        default:
            return true
        }
    }
}

// 共通レイアウトコンポーネント
struct OnboardingStepView<Content: View>: View {
    let title: String
    let description: String
    let content: Content

    init(title: String, description: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.description = description
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 28) {
            Text(title)
                .font(.title.bold())
                .foregroundColor(Color(hex: "5A4A42"))

            Text(description)
                .multilineTextAlignment(.center)
                .foregroundColor(Color(hex: "8A7A72"))
                .fixedSize(horizontal: false, vertical: true)
                .fixedSize(horizontal: false, vertical: true)

            content

            Spacer()
        }
        .padding(.top, 60)
        .padding(.horizontal)
    }
}

private extension OnboardingView {
    func ageString(from birthDate: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        let years = calendar.dateComponents([.year], from: birthDate, to: now).year ?? 0
        let anchor = calendar.date(byAdding: .year, value: years, to: birthDate) ?? birthDate
        let months = calendar.dateComponents([.month], from: anchor, to: now).month ?? 0
        return "\(years)歳 \(months)ヶ月"
    }
}
