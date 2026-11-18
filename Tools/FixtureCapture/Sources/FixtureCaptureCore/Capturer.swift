import EHModels
import EHNetwork
import EHParsing
import Foundation

/// Why a capture run stopped. Nothing is retried and nothing is written after any of these. Cases carry sites,
/// fixture paths, statuses and display modes only; a transport message has credentials masked.
public enum CaptureAbort: Error, Equatable {
    /// The site's front page is not in the Compact display mode (nil: no mode could be read). The tool never
    /// changes site settings; the user has to.
    case notCompactView(site: EHSite, mode: ListDisplayMode?)
    /// 429, 509 or a 5xx: the server wants fewer requests or is failing.
    case stoppedByServer(site: EHSite, fixturePath: String, status: Int)
    /// A plain-text answer mentioning a ban.
    case banned(site: EHSite, fixturePath: String)
    case unexpectedStatus(site: EHSite, fixturePath: String, status: Int)
    /// An ExHentai page came back empty or not HTML: the cookies do not grant access, or no longer do.
    case exAccessDenied
    /// The request could not be sent or answered.
    case transport(site: EHSite, fixturePath: String, message: String)
    /// A step whose fixture the run needs was not sent (see `CapturePlan.optionalFixturePaths`).
    case requiredStepSkipped(site: EHSite, fixturePath: String)
}

/// A step that was not sent: something it depends on is missing, or it would not have been read-only.
public struct SkippedStep: Sendable, Equatable {
    /// The fixture path, or a name for the unsaved cover download.
    public let fixturePath: String
    /// What was missing; names, never values.
    public let reason: String
    /// The fixture path this step would have written; nil for steps that save nothing (the cover download).
    public let savedPath: String?
}

/// What a run captured, before sanitizing.
public struct CaptureReport: Sendable {
    public var captures: [RawCapture]
    public var skipped: [SkippedStep]
    /// The steps' warnings (`CaptureContext.warnings`), site by site; explanations only, never a value.
    public var warnings: [String] = []
}

/// Runs the capture plan of each site, strictly one request at a time.
public struct Capturer: Sendable {
    private let transport: any CaptureTransport
    private let credentials: CaptureCredentials
    private let targets: CaptureTargets

    public init(transport: any CaptureTransport, credentials: CaptureCredentials, targets: CaptureTargets) {
        self.transport = transport
        self.credentials = credentials
        self.targets = targets
    }

    /// Captures `sites` in the given order (each once), every site's steps in plan order. Each request gets the
    /// user agent, `Accept`, `Accept-Language`, the cookies for its host and the site's receive timeout. After each
    /// answer, in this order: 429, 509 or 5xx stops the run; a plain-text ban notice stops it; a 4xx to a step that
    /// `skipsOnClientError` (the image lookup and its result page, the only exception) skips that step with a
    /// warning and the run goes on; on ExHentai an empty or non-HTML answer to an HTML page stops it (the not-found
    /// gallery only needs a body; JSON, the cover and the image lookup redirect are exempt); a status outside the
    /// step's expected ones stops it; a front page that is not in the Compact display mode stops it. Then the step's
    /// values are extracted and, if it has a fixture path, the response is recorded. A step whose inputs are missing,
    /// or whose request would not be read-only (`CapturePlan.isReadOnly`), is skipped without being sent.
    /// - Throws: `CaptureAbort`. Nothing is retried.
    public func run(sites: [EHSite]) async throws -> CaptureReport {
        let masker = Sanitizer(secrets: SecretSet(credentialSecrets: credentials.secrets, extraSecrets: []))
        var report = CaptureReport(captures: [], skipped: [])
        var seen = Set<EHSite>()
        for site in sites where seen.insert(site).inserted {
            var context = CaptureContext()
            let steps = CapturePlan.steps(for: site, targets: targets[site])
            for (index, step) in steps.enumerated() {
                var request: CaptureRequest
                switch step.resolve(context) {
                case .missing(let reason):
                    report.skipped.append(SkippedStep(fixturePath: step.label, reason: reason, savedPath: step.fixturePath))
                    continue
                case .ready(let ready):
                    request = ready
                }
                guard CapturePlan.isReadOnly(request, site: site) else {
                    report.skipped.append(SkippedStep(
                        fixturePath: step.label, reason: "refused: the request would not be read-only", savedPath: step.fixturePath
                    ))
                    continue
                }
                addDefaults(to: &request, site: site)

                let response: CaptureResponse
                do {
                    response = try await transport.send(request)
                } catch {
                    throw CaptureAbort.transport(
                        site: site, fixturePath: step.label, message: masker.sanitize(error.localizedDescription)
                    )
                }
                guard try Self.check(response, of: step, isFirst: index == 0) else {
                    // A 4xx to the image lookup or its result page: nothing extracted, so the result page is skipped
                    // too when the lookup fails.
                    report.skipped.append(SkippedStep(
                        fixturePath: step.label, reason: "image lookup returned HTTP \(response.status); skipped", savedPath: step.fixturePath
                    ))
                    context.warnings.append(
                        "\(site.rawValue) image lookup: \(step.label) returned HTTP \(response.status); skipped"
                    )
                    continue
                }
                step.extract(response, &context)
                if let path = step.fixturePath {
                    report.captures.append(RawCapture(
                        fixturePath: path, site: site, method: request.method, url: request.url,
                        status: response.status, headers: response.headers, body: response.body, capturedAt: Date()
                    ))
                }
            }
            report.warnings += context.warnings
        }
        return report
    }

    private func addDefaults(to request: inout CaptureRequest, site: EHSite) {
        request.headers["User-Agent"] = credentials.userAgent
        request.headers["Accept"] = RequestDefaults.accept
        request.headers["Accept-Language"] = RequestDefaults.acceptLanguage
        if let cookie = credentials.cookieHeader(for: request.url.host() ?? "", includeNW: request.includeNW) {
            request.headers["Cookie"] = cookie
        }
        request.timeout = RequestDefaults.timeouts(for: site).receive
    }

    /// The checks of `run`, in order.
    /// - Returns: false when the step is to be skipped (a 4xx to a step that `skipsOnClientError`), else true.
    private static func check(_ response: CaptureResponse, of step: CaptureStep, isFirst: Bool) throws -> Bool {
        let site = step.site
        let status = response.status
        if status == 429 || status == 509 || status >= 500 {
            throw CaptureAbort.stoppedByServer(site: site, fixturePath: step.label, status: status)
        }
        let text = response.text
        let isJSON = response.header("Content-Type")?.range(of: "json", options: .caseInsensitive) != nil
        let isHTML = text.range(of: "<html", options: .caseInsensitive) != nil
        if !isJSON, !isHTML, text.range(of: "banned", options: .caseInsensitive) != nil {
            throw CaptureAbort.banned(site: site, fixturePath: step.label)
        }
        if step.skipsOnClientError, (400..<500).contains(status) { return false }
        if site == .ex {
            switch step.exBody {
            case .html where response.body.isEmpty || !isHTML, .nonEmpty where response.body.isEmpty:
                throw CaptureAbort.exAccessDenied
            case .html, .nonEmpty, .unchecked:
                break
            }
        }
        if !step.expectedStatus.contains(status) {
            throw CaptureAbort.unexpectedStatus(site: site, fixturePath: step.label, status: status)
        }
        if isFirst {
            // A page SwiftSoup cannot parse counts as one without a display mode.
            let mode: ListDisplayMode? = (try? ListDisplayMode.detect(in: text)) ?? nil
            if mode != .compact { throw CaptureAbort.notCompactView(site: site, mode: mode) }
        }
        return true
    }
}
