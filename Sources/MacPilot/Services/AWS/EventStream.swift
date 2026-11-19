import Foundation

/// AWS event-stream binary framing (used by Amazon Transcribe streaming).
/// Message: total length (4) | headers length (4) | prelude CRC (4) | headers | payload | message CRC (4).
enum EventStream {
    struct Message: Equatable {
        var headers: [String: String]
        var payload: Data
    }

    enum DecodeError: Error, Equatable {
        case badPreludeCRC
        case badMessageCRC
        case malformed
    }

    static func encode(headers: [(String, String)], payload: Data) -> Data {
        var headerData = Data()
        for (name, value) in headers {
            let nameBytes = Array(name.utf8)
            let valueBytes = Array(value.utf8)
            headerData.append(UInt8(nameBytes.count))
            headerData.append(contentsOf: nameBytes)
            headerData.append(7) // string value type
            headerData.append(contentsOf: bigEndian(UInt16(valueBytes.count)))
            headerData.append(contentsOf: valueBytes)
        }
        let total = UInt32(12 + headerData.count + payload.count + 4)
        var message = Data()
        message.append(contentsOf: bigEndian(total))
        message.append(contentsOf: bigEndian(UInt32(headerData.count)))
        message.append(contentsOf: bigEndian(CRC32.checksum(message)))
        message.append(headerData)
        message.append(payload)
        message.append(contentsOf: bigEndian(CRC32.checksum(message)))
        return message
    }

    /// An `AudioEvent` carrying raw PCM; an empty payload ends the stream.
    static func audioEvent(_ pcm: Data) -> Data {
        encode(headers: [
            (":content-type", "application/octet-stream"),
            (":event-type", "AudioEvent"),
            (":message-type", "event")
        ], payload: pcm)
    }

    /// Decodes every complete message at the start of `buffer` and removes them from it.
    static func decode(_ buffer: inout Data) throws -> [Message] {
        var messages: [Message] = []
        while buffer.count >= 16 {
            let bytes = [UInt8](buffer.prefix(12))
            let total = Int(readUInt32(bytes, 0))
            let headersLength = Int(readUInt32(bytes, 4))
            guard total >= 16, headersLength <= total - 16 else { throw DecodeError.malformed }
            guard buffer.count >= total else { break }
            let message = [UInt8](buffer.prefix(total))
            guard CRC32.checksum(Data(message[0..<8])) == readUInt32(message, 8) else { throw DecodeError.badPreludeCRC }
            guard CRC32.checksum(Data(message[0..<(total - 4)])) == readUInt32(message, total - 4) else { throw DecodeError.badMessageCRC }

            var headers: [String: String] = [:]
            var index = 12
            let headersEnd = 12 + headersLength
            while index < headersEnd {
                let nameLength = Int(message[index]); index += 1
                guard index + nameLength + 1 <= headersEnd else { throw DecodeError.malformed }
                let name = String(decoding: message[index..<(index + nameLength)], as: UTF8.self); index += nameLength
                let type = message[index]; index += 1
                switch type {
                case 0, 1: // bool true / false
                    headers[name] = type == 0 ? "true" : "false"
                case 2: index += 1
                case 3: index += 2
                case 4: index += 4
                case 5, 8: index += 8
                case 9: index += 16
                case 6, 7: // byte array / string
                    guard index + 2 <= headersEnd else { throw DecodeError.malformed }
                    let length = Int(UInt16(message[index]) << 8 | UInt16(message[index + 1])); index += 2
                    guard index + length <= headersEnd else { throw DecodeError.malformed }
                    if type == 7 { headers[name] = String(decoding: message[index..<(index + length)], as: UTF8.self) }
                    index += length
                default:
                    throw DecodeError.malformed
                }
            }
            messages.append(Message(headers: headers, payload: Data(message[headersEnd..<(total - 4)])))
            buffer.removeFirst(total)
        }
        return messages
    }

    private static func bigEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}

/// CRC-32 (IEEE 802.3, the zlib polynomial).
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 {
            crc = (crc & 1) != 0 ? (0xEDB8_8320 ^ (crc >> 1)) : (crc >> 1)
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
