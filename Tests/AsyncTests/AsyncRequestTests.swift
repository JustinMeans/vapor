import XCTVapor
import XCTest
import Vapor
import NIOCore
import AsyncHTTPClient
import Atomics
import NIOConcurrencyHelpers

fileprivate extension String {
    static func randomDigits(length: Int = 999) -> String {
        var string = ""
        for _ in 0...999 {
            string += String(Int.random(in: 0...9))
        }
        return string
    }
}

final class AsyncRequestTests: XCTestCase {
    
    var app: Application!
    
    override func setUp() async throws {
        app = Application(.testing)
    }
    
    override func tearDown() async throws {
        app.shutdown()
    }
    
    func testStreamingRequest() async throws {
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        
        let testValue = String.randomDigits()

        app.on(.POST, "stream", body: .stream) { req in
            var recievedBuffer = ByteBuffer()
            for try await part in req.body {
                XCTAssertNotNil(part)
                var part = part
                recievedBuffer.writeBuffer(&part)
            }
            let string = String(buffer: recievedBuffer)
            return string
        }

        app.environment.arguments = ["serve"]
        XCTAssertNoThrow(try app.start())
        
        XCTAssertNotNil(app.http.server.shared.localAddress)
        guard let localAddress = app.http.server.shared.localAddress,
              let ip = localAddress.ipAddress,
              let port = localAddress.port else {
            return XCTFail("couldn't get ip/port from \(app.http.server.shared.localAddress.debugDescription)")
        }
        
        var request = HTTPClientRequest(url: "http://\(ip):\(port)/stream")
        request.method = .POST
        request.body = .stream(testValue.utf8.async, length: .unknown)
        
        let response: HTTPClientResponse = try await app.http.client.shared.execute(request, timeout: .seconds(5))
        XCTAssertEqual(response.status, .ok)
        let body = try await response.body.collect(upTo: 1024 * 1024)
        XCTAssertEqual(body.string, testValue)
    }
    
    func testStreamingRequestBodyCleansUp() async throws {
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        
        let bytesTheServerRead = ManagedAtomic<Int>(0)
        
        app.on(.POST, "hello", body: .stream) { req async throws -> Response in
            var bodyIterator = req.body.makeAsyncIterator()
            let firstChunk = try await bodyIterator.next()
            bytesTheServerRead.wrappingIncrement(by: firstChunk?.readableBytes ?? 0, ordering: .relaxed)
            throw Abort(.internalServerError)
        }
        
        app.environment.arguments = ["serve"]
        XCTAssertNoThrow(try app.start())
        
        XCTAssertNotNil(app.http.server.shared.localAddress)
        guard let localAddress = app.http.server.shared.localAddress,
              let ip = localAddress.ipAddress,
              let port = localAddress.port else {
            XCTFail("couldn't get ip/port from \(app.http.server.shared.localAddress.debugDescription)")
            return
        }
        
        var oneMBBB = ByteBuffer(repeating: 0x41, count: 1024 * 1024)
        let oneMB = try XCTUnwrap(oneMBBB.readData(length: oneMBBB.readableBytes))
        var request = HTTPClientRequest(url: "http://\(ip):\(port)/hello")
        request.method = .POST
        request.body = .stream(oneMB.async, length: .known(oneMB.count))
        let response = try await app.http.client.shared.execute(request, timeout: .seconds(5))
        
        XCTAssertGreaterThan(bytesTheServerRead.load(ordering: .relaxed), 0)
        XCTAssertEqual(response.status, .internalServerError)
    }
    
    // TODO: Re-enable once it reliably works and doesn't cause issues with trying to shut the application down
    // This may require some work in Vapor
    func _testRequestBodyBackpressureWorksWithAsyncStreaming() async throws {
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        
        let numberOfTimesTheServerGotOfferedBytes = ManagedAtomic<Int>(0)
        let bytesTheServerSaw = ManagedAtomic<Int>(0)
        let bytesTheClientSent = ManagedAtomic<Int>(0)
        let serverSawEnd = ManagedAtomic<Bool>(false)
        let serverSawRequest = ManagedAtomic<Bool>(false)
        
        let requestHandlerTask: NIOLockedValueBox<Task<Response, Error>?> = .init(nil)
        
        app.on(.POST, "hello", body: .stream) { req async throws -> Response in
            requestHandlerTask.withLockedValue {
                $0 = Task {
                    XCTAssertTrue(serverSawRequest.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged)
                    var bodyIterator = req.body.makeAsyncIterator()
                    let firstChunk = try await bodyIterator.next() // read only first chunk
                    numberOfTimesTheServerGotOfferedBytes.wrappingIncrement(ordering: .relaxed)
                    bytesTheServerSaw.wrappingIncrement(by: firstChunk?.readableBytes ?? 0, ordering: .relaxed)
                    defer {
                        _ = bodyIterator // make sure to not prematurely cancelling the sequence
                    }
                    try await Task.sleep(nanoseconds: 10_000_000_000) // wait "forever"
                    serverSawEnd.store(true, ordering: .relaxed)
                    return Response(status: .ok)
                }
            }
            
            do {
                let task = requestHandlerTask.withLockedValue { $0 }
                return try await task!.value
            } catch {
                throw Abort(.internalServerError)
            }
        }
        
        app.environment.arguments = ["serve"]
        XCTAssertNoThrow(try app.start())
        
        XCTAssertNotNil(app.http.server.shared.localAddress)
        guard let localAddress = app.http.server.shared.localAddress,
              let ip = localAddress.ipAddress,
              let port = localAddress.port else {
            XCTFail("couldn't get ip/port from \(app.http.server.shared.localAddress.debugDescription)")
            return
        }
        
        final class ResponseDelegate: HTTPClientResponseDelegate {
            typealias Response = Void
            
            private let bytesTheClientSent: ManagedAtomic<Int>
            
            init(bytesTheClientSent: ManagedAtomic<Int>) {
                self.bytesTheClientSent = bytesTheClientSent
            }
            
            func didFinishRequest(task: HTTPClient.Task<Response>) throws -> Response {
                return ()
            }
            
            func didSendRequestPart(task: HTTPClient.Task<Response>, _ part: IOData) {
                self.bytesTheClientSent.wrappingIncrement(by: part.readableBytes, ordering: .relaxed)
            }
        }
        
        let tenMB = ByteBuffer(repeating: 0x41, count: 10 * 1024 * 1024)
        let request = try! HTTPClient.Request(url: "http://\(ip):\(port)/hello",
                                              method: .POST,
                                              headers: [:],
                                              body: .byteBuffer(tenMB))
        let delegate = ResponseDelegate(bytesTheClientSent: bytesTheClientSent)
        let httpClient = HTTPClient(eventLoopGroup: MultiThreadedEventLoopGroup.singleton)
        XCTAssertThrowsError(try httpClient.execute(request: request,
                                                                delegate: delegate,
                                                                deadline: .now() + .milliseconds(500)).wait()) { error in
            if let error = error as? HTTPClientError {
                XCTAssert(error == .readTimeout || error == .deadlineExceeded)
            } else {
                XCTFail("unexpected error: \(error)")
            }
        }
        
        XCTAssertEqual(1, numberOfTimesTheServerGotOfferedBytes.load(ordering: .relaxed))
        XCTAssertGreaterThan(tenMB.readableBytes, bytesTheServerSaw.load(ordering: .relaxed))
        XCTAssertGreaterThan(tenMB.readableBytes, bytesTheClientSent.load(ordering: .relaxed))
        XCTAssertEqual(0, bytesTheClientSent.load(ordering: .relaxed)) // We'd only see this if we sent the full 10 MB.
        XCTAssertFalse(serverSawEnd.load(ordering: .relaxed))
        XCTAssertTrue(serverSawRequest.load(ordering: .relaxed))
        
        requestHandlerTask.withLockedValue { $0?.cancel() }
        try await httpClient.shutdown()
    }
}

// This was taken from AsyncHTTPClients's AsyncRequestTests.swift code.
// The license for the original work is reproduced below. See NOTICES.txt for
// more.

//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2022 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

struct AsyncLazySequence<Base: Sequence>: AsyncSequence {
    typealias Element = Base.Element
    struct AsyncIterator: AsyncIteratorProtocol {
        var iterator: Base.Iterator
        init(iterator: Base.Iterator) {
            self.iterator = iterator
        }

        mutating func next() async throws -> Base.Element? {
            self.iterator.next()
        }
    }

    var base: Base

    init(base: Base) {
        self.base = base
    }

    func makeAsyncIterator() -> AsyncIterator {
        .init(iterator: self.base.makeIterator())
    }
}

extension AsyncLazySequence: Sendable where Base: Sendable {}
extension AsyncLazySequence.AsyncIterator: Sendable where Base.Iterator: Sendable {}

extension Sequence {
    /// Turns `self` into an `AsyncSequence` by vending each element of `self` asynchronously.
    var async: AsyncLazySequence<Self> {
        .init(base: self)
    }
}
