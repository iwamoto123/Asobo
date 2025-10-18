import Foundation
import Domain

struct ConversationViewState {
  var partialText: String = ""
  var isTalking: Bool = false
  var errorMessage: String?
  var interests: [InterestTag] = []
  static let empty = ConversationViewState()
}
