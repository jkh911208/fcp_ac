import Foundation

public enum FCPXMLError: LocalizedError, Equatable {
    case notXML
    case notFCPXML
    case malformedTime(String)
    case missingAttribute(element: String, attribute: String)
    case noClips
    case clipNotFound(String)
    case unknownResource(String)

    public var errorDescription: String? {
        switch self {
        case .notXML:
            "FCPXML을 읽지 못했습니다. 파일이 손상되었을 수 있습니다."
        case .notFCPXML:
            "Final Cut Pro의 FCPXML 형식이 아닙니다."
        case let .malformedTime(raw):
            "시간 값을 해석하지 못했습니다: \(raw)"
        case let .missingAttribute(element, attribute):
            "FCPXML의 <\(element)>에 필요한 \(attribute) 값이 없습니다."
        case .noClips:
            "FCPXML에서 클립을 찾지 못했습니다. 타임라인의 클립을 드래그했는지 확인해 주세요."
        case let .clipNotFound(name):
            "대상 클립을 찾지 못했습니다: \(name)"
        case let .unknownResource(id):
            "FCPXML이 참조하는 리소스를 찾지 못했습니다: \(id)"
        }
    }
}
