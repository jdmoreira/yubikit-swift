//
//  OATHSession+Extensions.swift
//  YubiKit
//
//  Created by Jens Utbult on 2022-11-21.
//

import Foundation
import CommonCrypto

private var hotpCode: UInt8 = 0x10
private var totpCode: UInt8 = 0x20

extension OATHSession {
    
    public enum CredentialTemplateError: Error {
        case missingScheme, missingName, missingSecret, parseType, parseAlgorithm
    }
    
    public enum CredentialType: CustomStringConvertible {
        
        case HOTP(counter: UInt32 = 0)
        case TOTP(period: TimeInterval = 30)
        
        public var code: UInt8 {
            switch self {
            case .HOTP:
                return hotpCode
            case .TOTP:
                return totpCode
            }
        }
        
        static public func isHOTP(_ code: UInt8) -> Bool {
            return code == hotpCode
        }
        
        static public func isTOTP(_ code: UInt8) -> Bool {
            return code == totpCode
        }
        
        public var description: String {
            switch self {
            case .HOTP(counter: let counter):
                return "HOTP(\(counter))"
            case .TOTP(period: let period):
                return "TOTP(\(period))"
            }
        }
    }
    
    public enum HashAlgorithm: UInt8 {
        case SHA1   = 0x01
        case SHA256 = 0x02
        case SHA512 = 0x03
    }
    
    public struct Credential: Identifiable, CustomStringConvertible {

        public let deviceId: String
        public let id: Data
        public let type: OATHSession.CredentialType
        public let hashAlgorithm: OATHSession.HashAlgorithm?
        public let name: String
        public let issuer: String?
        public var label: String {
            if let issuer {
                return "\(issuer):\(name)"
            } else {
                return name
            }
        }
        public var description: String {
            return "Credential(type: \(type), label:\(label), algorithm: \(hashAlgorithm.debugDescription)"
        }

        init(deviceId: String, id: Data, type: OATHSession.CredentialType, hashAlgorithm: OATHSession.HashAlgorithm? = nil, name: String, issuer: String?) {
            self.deviceId = deviceId
            self.id = id
            self.type = type
            self.hashAlgorithm = hashAlgorithm
            self.name = name
            self.issuer = issuer
        }
    }
    
    struct CredentialIdParser {
        
        let account: String
        let issuer: String?
        let period: TimeInterval?
        
        init?(data: Data) {
            // "period/issuer:account"
            let periodIssuerAndAccount = #/^(?<period>\d+)\/(?<issuer>.+):(?<account>.+)$/#
            // "issuer:account"
            let issuerAndAccount = #/^(?<issuer>.+):(?<account>.+)$/#
            // "period/account"
            let periodAndAccount = #/^(?<period>\d+)\/(?<account>.+)$/#
            
            guard let id = String(data: data, encoding: .utf8) else { return nil }

            if let match = id.firstMatch(of: periodIssuerAndAccount) {
                period = TimeInterval(String(match.period))
                issuer = String(match.issuer)
                account = String(match.account)
            } else if let match = id.firstMatch(of: issuerAndAccount) {
                period = nil
                issuer = String(match.issuer)
                account = String(match.account)
            } else if let match = id.firstMatch(of: periodAndAccount) {
                period = TimeInterval(String(match.period))
                issuer = nil
                account = String(match.account)
            } else {
                period = nil
                issuer = nil
                account = id
//            }
        }
    }

    public struct Code: Identifiable, CustomStringConvertible {
        
        public var description: String {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "HH:mm:ss"
            return "Code(\(code), validFrom:\(dateFormatter.string(from: validFrom)), validTo:\(dateFormatter.string(from: validTo))"
        }
        
        public let id = UUID()
        public let code: String
        public var validFrom: Date {
            switch credentialType {
            case .HOTP(_):
                return Date()
            case .TOTP(period: let period):
                return Date(timeIntervalSince1970: timestamp.timeIntervalSince1970 - timestamp.timeIntervalSince1970.truncatingRemainder(dividingBy: period))
            }
        }
        public var validTo: Date {
            switch credentialType {
            case .HOTP(_):
                return validFrom.addingTimeInterval(.infinity)
            case .TOTP(period: let period):
                return validFrom.addingTimeInterval(period)
            }
        }
        
        init(code: String, timestamp: Date, credentialType: CredentialType) {
            self.code = code
            self.timestamp = timestamp
            self.credentialType = credentialType
        }
        
        private let timestamp: Date
        private let credentialType: CredentialType

    }
    
    public struct CredentialTemplate {
        
        private static let minSecretLenght = 14
        
        public var key: String {
            let key: String
            if let issuer {
                key = "\(issuer):\(name)"
            } else {
                key = name
            }
            if case let .TOTP(period) = type {
                if period != oathDefaultPeriod {
                    return "\(String(format: "%.0f", period))/\(key)"
                } else {
                    return key
                }
            } else {
                return key
            }
        }
        
        public init(withURL url: URL, skipValidation: Bool = false) throws {
            guard url.scheme == "otpauth" else { throw CredentialTemplateError.missingScheme }
            
            var issuer: String?
            var name: String = ""
            if !skipValidation {
                guard url.pathComponents.count > 1 else { throw CredentialTemplateError.missingName }
                name = url.pathComponents[1]
                if name.contains(":") {
                    let components = name.components(separatedBy: ":")
                    name = components[1]
                    issuer = components[0]
                } else {
                    issuer = url.queryValueFor(key: "issuer")
                }
            }
            
            let type = try OATHSession.CredentialType(fromURL: url)
            
            let algorithm = try OATHSession.HashAlgorithm(fromUrl: url) ?? .SHA1
            
            let digits: UInt8
            if let digitsString = url.queryValueFor(key: "digits"), let parsedDigits = UInt8(digitsString) {
                digits = parsedDigits
            } else {
                digits = 6
            }
            
            guard let secret = url.queryValueFor(key: "secret")?.base32DecodedData else {
                throw CredentialTemplateError.missingSecret
            }
            
            self.init(type: type, algorithm: algorithm, secret: secret, issuer: issuer, name: name, digits: digits)
        }
        
        public init(type: CredentialType, algorithm: HashAlgorithm, secret: Data, issuer: String?, name: String, digits: UInt8 = 6, requiresTouch: Bool = false) {
            self.type = type
            self.algorithm = algorithm
            
            if secret.count < Self.minSecretLenght {
                var mutableSecret = secret
                mutableSecret.append(Data(count: Self.minSecretLenght - secret.count))
                self.secret = mutableSecret
            } else if algorithm == .SHA1 && secret.count > CC_SHA1_BLOCK_BYTES {
                self.secret = secret.sha1()
            } else if algorithm == .SHA256 && secret.count > CC_SHA256_BLOCK_BYTES {
                self.secret = secret.sha256()
            } else if algorithm == .SHA512 && secret.count > CC_SHA512_BLOCK_BYTES {
                self.secret = secret.sha512()
            } else {
                self.secret = secret
            }
            
            self.issuer = issuer
            self.name = name
            self.digits = digits
            self.requiresTouch = requiresTouch
        }
        
        public let type: CredentialType
        public let algorithm: HashAlgorithm
        public let secret: Data
        public let issuer: String?
        public let name: String
        public let digits: UInt8
        public let requiresTouch: Bool
    }
    
}


extension OATHSession.HashAlgorithm {
    internal init?(fromUrl url: URL) throws {
        if let name = url.queryValueFor(key: "algorithm") {
            switch name {
            case "SHA1":
                self = .SHA1
            case "SHA256":
                self = .SHA256
            case "SHA512":
                self = .SHA512
            default:
                throw OATHSession.CredentialTemplateError.parseAlgorithm
            }
        } else {
            return nil
        }
    }
}

extension OATHSession.CredentialType {
    internal init(fromURL url: URL) throws {
        let type = url.host?.lowercased()
        
        switch type {
        case "totp":
            if let stringPeriod = url.queryValueFor(key: "period"), let period = Double(stringPeriod) {
                self = .TOTP(period: period)
            } else {
                self = .TOTP()
            }
        case "hotp":
            if let stringCounter = url.queryValueFor(key: "counter"), let counter = UInt32(stringCounter) {
                self = .HOTP(counter: counter)
            } else {
                self = .HOTP()
            }
        default:
            throw OATHSession.CredentialTemplateError.parseType
        }
    }
}

extension Data {
    internal func sha1() -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1(self.bytes, UInt32(self.count), &digest)
        return Data(digest)
    }
    
    internal func sha256() -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256(self.bytes, UInt32(self.count), &digest)
        return Data(digest)
    }
    
    internal func sha512() -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        CC_SHA512(self.bytes, UInt32(self.count), &digest)
        return Data(digest)
    }
}

extension URL {
    internal func queryValueFor(key: String) -> String? {
        let components = URLComponents(url: self, resolvingAgainstBaseURL: true)
        return components?.queryItems?.first(where: { $0.name == key })?.value
    }
}
