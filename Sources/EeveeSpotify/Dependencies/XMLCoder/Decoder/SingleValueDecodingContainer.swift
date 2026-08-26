// Copyright (c) 2017-2020 Shawn Moore and XMLCoder contributors
//
// This software is released under the MIT License.
// https://opensource.org/licenses/MIT
//
//  Created by Shawn Moore on 11/20/17.
//

import Foundation

extension XMLDecoderImplementation: SingleValueDecodingContainer {
    // MARK: SingleValueDecodingContainer Methods

    public func decodeNil() -> Bool {
        return (try? topContainer().isNull) ?? true
    }

    public func decode(_: Bool.Type) throws -> Bool {
        return try unbox(try topContainer())
    }

    // Swift 6 adds these overloads to SingleValueDecodingContainer. Keeping
    // explicit implementations here prevents the older generic overloads
    // below from being diagnosed as near-matches by the current SDK.
    @available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, *)
    public func decode(_: Int128.Type) throws -> Int128 {
        return try unbox(try topContainer())
    }

    @available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, *)
    public func decode(_: UInt128.Type) throws -> UInt128 {
        return try unbox(try topContainer())
    }

    public func decode(_: Decimal.Type) throws -> Decimal {
        return try unbox(try topContainer())
    }

    public func decode<T: BinaryInteger & SignedInteger & Decodable>(_: T.Type) throws -> T {
        return try unbox(try topContainer())
    }

    public func decode<T: BinaryInteger & UnsignedInteger & Decodable>(_: T.Type) throws -> T {
        return try unbox(try topContainer())
    }

    public func decode(_: Float.Type) throws -> Float {
        return try unbox(try topContainer())
    }

    public func decode(_: Double.Type) throws -> Double {
        return try unbox(try topContainer())
    }

    public func decode(_: String.Type) throws -> String {
        return try unbox(try topContainer())
    }

    public func decode(_: String.Type) throws -> Date {
        return try unbox(try topContainer())
    }

    public func decode(_: String.Type) throws -> Data {
        return try unbox(try topContainer())
    }

    public func decode<T: Decodable>(_: T.Type) throws -> T {
        return try unbox(try topContainer())
    }
}
