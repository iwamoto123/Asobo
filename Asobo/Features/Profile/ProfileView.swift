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
    @State private var currentPhotoURL: URL?
    
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
                            } else if let url = currentPhotoURL {
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .empty:
                                        ProgressView().frame(width: 90, height: 90)
                                    case .success(let image):
                                        image.resizable()
                                            .scaledToFill()
                                            .frame(width: 90, height: 90)
                                            .clipShape(Circle())
                                    case .failure:
                                        Circle()
                                            .fill(Color.gray.opacity(0.2))
                                            .frame(width: 90, height: 90)
                                            .overlay(
                                                Image(systemName: "person.crop.circle.fill")
                                                    .font(.system(size: 32))
                                                    .foregroundColor(.gray)
                                            )
                                    @unknown default:
                                        EmptyView()
                                    }
                                }
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
        .onAppear {
            loadInitialValues()
        }
        .onChange(of: selectedPhotoItem) { newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self) {
                    selectedPhotoData = data
                }
            }
        }
    }
    
    private func loadInitialValues() {
        childName = authVM.selectedChild?.displayName ?? ""
        childNickName = authVM.selectedChild?.nickName ?? ""
        teddyName = authVM.selectedChild?.teddyName ?? ""
        parentName = authVM.userProfile?.parentName ?? authVM.userProfile?.displayName ?? ""
        birthDate = authVM.selectedChild?.birthDate
        if let birth = authVM.selectedChild?.birthDate {
            birthDatePickerDate = birth
        }
        if let urlString = authVM.selectedChild?.photoURL {
            currentPhotoURL = URL(string: urlString)
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
                    // デフォルトバケット（GoogleService-Info.plistのSTORAGE_BUCKET）を利用
                    let ref = Storage.storage().reference().child("users/\(uid)/children/\(childId)/photo.jpg")
                    let metadata = StorageMetadata()
                    metadata.contentType = "image/jpeg"
                    _ = try await ref.putData(data, metadata: metadata)
                    let url = try await ref.downloadURL()
                    photoURL = url.absoluteString
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
                }
                try await db.collection("users").document(uid).collection("children").document(childId).setData(childData, merge: true)
                
                await authVM.fetchUserProfile(userId: uid)
                loadInitialValues()
                message = "保存しました"
            } catch {
                print("❌ ProfileView: 保存失敗 - \(error)")
                message = "保存に失敗しました: \(error.localizedDescription)"
            }
            isSaving = false
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
