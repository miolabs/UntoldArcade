import CoolScanServerCore
import Foundation
import MIOServerKit
import NIOHTTP1

/// HTTP surface of the reconstruction server.
///
/// Request bodies are buffered by MIOServerKit, so every upload is a single
/// file (`PUT /jobs/:id/files` with the relative path in `X-File-Path`).
enum Routes {
    static let protocolVersion = 1

    struct HealthResponse: Encodable {
        let protocolVersion: Int
        let version: String
        let photogrammetrySupported: Bool
        let defaultDetail: String
        let maxUploadBytes: Int
        let serverName: String
    }

    struct CreateJobRequest: Decodable {
        let name: String
        let options: ReconstructionOptions?
        let files: [String]
    }

    struct RecookRequest: Decodable {
        let options: ReconstructionOptions?
    }

    struct ErrorResponse: Encodable {
        let error: String
    }

    static func makeRouter(jobs: JobManager, serverName: String, defaultOptions: ReconstructionOptions) -> Router {
        let router = Router()

        router.endpoint("/health").get { (ctx: RouterContext) async throws -> (any Sendable)? in
            HealthResponse(
                protocolVersion: protocolVersion,
                version: "1.0",
                photogrammetrySupported: await jobs.isSupported,
                defaultDetail: defaultOptions.detail.rawValue,
                maxUploadBytes: await jobs.maxUploadBytes,
                serverName: serverName
            )
        }

        let jobsEndpoint = router.endpoint("/jobs")
        jobsEndpoint.get { (ctx: RouterContext) async throws -> (any Sendable)? in
            await jobs.allJobs()
        }

        jobsEndpoint.post { (ctx: RouterContext) async throws -> (any Sendable)? in
            guard let body = ctx.bodyAsData(),
                  let request = try? JSONDecoder().decode(CreateJobRequest.self, from: body)
            else {
                return fail(ctx, .badRequest, "Expected JSON {name, options?, files:[…]}")
            }
            do {
                var options = request.options ?? defaultOptions
                if request.options == nil { options = defaultOptions }
                let job = try await jobs.create(name: request.name, options: options, expectedFiles: request.files)
                ctx.response.status = .created
                return job
            } catch {
                return fail(ctx, .badRequest, "\(error)")
            }
        }

        let jobEndpoint = router.endpoint("/jobs/:id")
        jobEndpoint.get { (ctx: RouterContext) async throws -> (any Sendable)? in
            let id: String = try ctx.urlParam("id")
            guard let job = await jobs.status(jobID: id) else {
                return fail(ctx, .notFound, "Job \(id) not found")
            }
            return job
        }

        router.endpoint("/jobs/:id/files").put { (ctx: RouterContext) async throws -> (any Sendable)? in
            let id: String = try ctx.urlParam("id")
            guard let path = ctx.request.headers.first(name: "X-File-Path"), !path.isEmpty else {
                return fail(ctx, .badRequest, "Missing X-File-Path header")
            }
            let data = ctx.bodyAsData() ?? Data()
            do {
                return try await jobs.receiveFile(jobID: id, relativePath: path, data: data)
            } catch JobManager.JobError.notFound {
                return fail(ctx, .notFound, "Job \(id) not found")
            } catch JobManager.JobError.tooLarge(let name) {
                return fail(ctx, .payloadTooLarge, "File exceeds the upload limit: \(name)")
            } catch {
                return fail(ctx, .badRequest, "\(error)")
            }
        }

        router.endpoint("/jobs/:id/start").post { (ctx: RouterContext) async throws -> (any Sendable)? in
            let id: String = try ctx.urlParam("id")
            do {
                return try await jobs.start(jobID: id)
            } catch JobManager.JobError.notFound {
                return fail(ctx, .notFound, "Job \(id) not found")
            } catch {
                return fail(ctx, .conflict, "\(error)")
            }
        }

        router.endpoint("/jobs/:id/recook").post { (ctx: RouterContext) async throws -> (any Sendable)? in
            let id: String = try ctx.urlParam("id")
            let request = ctx.bodyAsData().flatMap { try? JSONDecoder().decode(RecookRequest.self, from: $0) }
            do {
                return try await jobs.recook(jobID: id, options: request?.options)
            } catch JobManager.JobError.notFound {
                return fail(ctx, .notFound, "Job \(id) not found")
            } catch {
                return fail(ctx, .conflict, "\(error)")
            }
        }

        router.endpoint("/jobs/:id/result").get { (ctx: RouterContext) async throws -> (any Sendable)? in
            let id: String = try ctx.urlParam("id")
            do {
                let url = try await jobs.resultURL(jobID: id)
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                ctx.response.headers.replaceOrAdd(name: "Content-Type", value: "application/zip")
                ctx.response.headers.replaceOrAdd(
                    name: "Content-Disposition", value: "attachment; filename=\"\(id).zip\""
                )
                return data
            } catch JobManager.JobError.notFound {
                return fail(ctx, .notFound, "Job \(id) not found")
            } catch {
                return fail(ctx, .conflict, "\(error)")
            }
        }

        router.endpoint("/jobs/:id/cancel").post { (ctx: RouterContext) async throws -> (any Sendable)? in
            let id: String = try ctx.urlParam("id")
            do {
                return try await jobs.cancel(jobID: id)
            } catch {
                return fail(ctx, .notFound, "Job \(id) not found")
            }
        }

        jobEndpoint.delete { (ctx: RouterContext) async throws -> (any Sendable)? in
            let id: String = try ctx.urlParam("id")
            do {
                try await jobs.delete(jobID: id)
                ctx.response.status = .noContent
                return nil
            } catch {
                return fail(ctx, .notFound, "Job \(id) not found")
            }
        }

        return router
    }

    private static func fail(_ ctx: RouterContext, _ status: HTTPResponseStatus, _ message: String) -> any Sendable {
        ctx.response.status = status
        return ErrorResponse(error: message)
    }
}
