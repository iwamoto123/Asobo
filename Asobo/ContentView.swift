import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                Text("Asobo - Kids Talk App")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .padding()
                
                Text("音声を文字に変換するアプリ")
                    .font(.title2)
                    .foregroundColor(.secondary)
                    .padding(.bottom)
                
                NavigationLink(destination: MinimalVoiceToTextView()) {
                    HStack {
                        Image(systemName: "mic.circle.fill")
                            .font(.title)
                        Text("音声→文字変換を開始")
                            .font(.headline)
                    }
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(12)
                }
                
                NavigationLink(destination: ConversationView()) {
                    HStack {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.title)
                        Text("会話モード（AI応答付き）")
                            .font(.headline)
                    }
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.green)
                    .cornerRadius(12)
                }
                
                NavigationLink(destination: RealtimeTestView()) {
                    HStack {
                        Image(systemName: "testtube.2")
                            .font(.title)
                        Text("Realtime API テスト（料理評論家）")
                            .font(.headline)
                    }
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.orange)
                    .cornerRadius(12)
                }
                
                Spacer()
            }
            .padding()
        }
    }
}

#Preview {
    ContentView()
}
