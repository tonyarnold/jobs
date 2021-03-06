import Jobs
import Vapor
import XCTest

final class JobsTests: XCTestCase {
    func testVaporIntegration() throws {
        let server = try self.startServer()
        defer { server.shutdown() }
        let worker = try self.startWorker()
        defer { worker.shutdown() }
        
        FooJob.dequeuePromise = server.make(EventLoopGroup.self)
            .next().makePromise(of: Void.self)
        
        let task = server.make(EventLoopGroup.self).next().scheduleTask(in: .seconds(5)) {
            return server.client.get("http://localhost:8080/foo")
        }
        let res = try task.futureResult.wait().wait()
        XCTAssertEqual(res.body?.string, "done")
        
        try FooJob.dequeuePromise!.futureResult.wait()
    }
    
    private func startServer() throws -> Application {
        let app = self.setupApplication(.init(name: "worker", arguments: ["vapor", "serve"]))
        try app.start()
        return app
    }
    
    private func startWorker() throws -> Application {
        let app = self.setupApplication(.init(name: "worker", arguments: ["vapor", "jobs"]))
        try app.start()
        return app
    }
    
    private func setupApplication(_ env: Environment) -> Application {
        let app = Application(environment: env)
        app.provider(JobsProvider())
        app.register(JobsDriver.self) { app in
            return TestDriver(on: app.make())
        }
        app.register(extension: JobsConfiguration.self) { jobs, app in
            jobs.add(FooJob())
        }
        app.get("foo") { req in
            return req.jobs.dispatch(FooJob.Data(foo: "bar"))
                .map { "done" }
        }
        return app
    }
}

extension ByteBuffer {
    var string: String {
        return .init(decoding: self.readableBytesView, as: UTF8.self)
    }
}

var storage: [String: JobStorage] = [:]
var lock = Lock()

final class TestDriver: JobsDriver {
    var eventLoopGroup: EventLoopGroup
    
    init(on eventLoopGroup: EventLoopGroup) {
        self.eventLoopGroup = eventLoopGroup
    }
    
    func get(key: String, eventLoop: JobsEventLoopPreference) -> EventLoopFuture<JobStorage?> {
        lock.lock()
        defer { lock.unlock() }
        let job: JobStorage?
        if let existing = storage[key] {
            job = existing
            storage[key] = nil
        } else {
            job = nil
        }
        return eventLoop.delegate(for: self.eventLoopGroup)
            .makeSucceededFuture(job)
    }
    
    func set(key: String, job: JobStorage, eventLoop: JobsEventLoopPreference) -> EventLoopFuture<Void> {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = job
        return eventLoop.delegate(for: self.eventLoopGroup)
            .makeSucceededFuture(())
    }
    
    func completed(key: String, job: JobStorage, eventLoop: JobsEventLoopPreference) -> EventLoopFuture<Void> {
        return eventLoop.delegate(for: self.eventLoopGroup)
            .makeSucceededFuture(())
    }
    
    func processingKey(key: String) -> String {
        return key
    }
    
    func requeue(key: String, job: JobStorage, eventLoop: JobsEventLoopPreference) -> EventLoopFuture<Void> {
        return eventLoop.delegate(for: self.eventLoopGroup)
            .makeSucceededFuture(())
    }
}

struct FooJob: Job {
    static var dequeuePromise: EventLoopPromise<Void>?
    
    struct Data: JobData {
        var foo: String
    }
    
    func dequeue(_ context: JobContext, _ data: Data) -> EventLoopFuture<Void> {
        Self.dequeuePromise!.succeed(())
        return context.eventLoop.makeSucceededFuture(())
    }
    
    func error(_ context: JobContext, _ error: Error, _ data: Data) -> EventLoopFuture<Void> {
        Self.dequeuePromise!.fail(error)
        return context.eventLoop.makeSucceededFuture(())
    }
}
