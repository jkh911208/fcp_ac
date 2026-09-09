import Foundation

/// Failures a user can act on. Messages are Korean because they are shown as-is in the panel.
public enum TranscriptionError: LocalizedError, Equatable {
    case modelUnavailable(model: String, underlying: String)
    case audioUnreadable(URL)
    case cancelled
    case engineFailure(String)

    public var errorDescription: String? {
        switch self {
        case let .modelUnavailable(model, underlying):
            "음성 인식 모델(\(model))을 준비하지 못했습니다. 네트워크 연결과 디스크 여유 공간을 확인해 주세요. (\(underlying))"
        case let .audioUnreadable(url):
            "오디오를 읽지 못했습니다: \(url.lastPathComponent)"
        case .cancelled:
            "작업을 취소했습니다."
        case let .engineFailure(detail):
            "전사에 실패했습니다. (\(detail))"
        }
    }
}
