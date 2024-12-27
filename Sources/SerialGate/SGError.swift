import Foundation

public enum SGError: LocalizedError {
    case couldNotOpenPort(String)
    case portIsNotOpen(String)
    case couldNotClosePort(String)
    case couldNotSetOptions(String)
    case invalidData
    case writeFailed(Int32)
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .couldNotOpenPort(let portName):
            return "Could not open port (\(portName))."
        case .portIsNotOpen(let portName):
            return "Port (\(portName)) is not open."
        case .couldNotClosePort(let portName):
            return "Could not close port (\(portName))."
        case .couldNotSetOptions(let portName):
            return "Could not set options to port (\(portName))."
        case .invalidData:
            return "Invalid Data"
        case .writeFailed(let errorCode):
            return "Failed to write with error code \(errorCode)"
        case .encodingFailed(let errorMessage):
            return errorMessage
        }
    }
}
