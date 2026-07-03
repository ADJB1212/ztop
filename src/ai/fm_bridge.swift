import Foundation
import Dispatch

#if canImport(FoundationModels)
import FoundationModels
#endif

public typealias FMStreamCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void

@_cdecl("fm_is_available")
public func fm_is_available() -> Int32 {
    if #available(macOS 15.0, *) {
        #if canImport(FoundationModels)
        return SystemLanguageModel.default.isAvailable ? 1 : 0
        #else
        return 0
        #endif
    } else {
        return 0
    }
}

@_cdecl("fm_generate_text")
public func fm_generate_text(_ prompt: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let prompt else {
        return strdup("ERROR: prompt was null")
    }

    let promptText = String(cString: prompt)
    let semaphore = DispatchSemaphore(value: 0)
    var output = "ERROR: unknown failure"

    if #available(macOS 15.0, *) {
        Task {
            defer { semaphore.signal() }

            #if canImport(FoundationModels)
            do {
                let model = SystemLanguageModel.default
                guard model.isAvailable else {
                    output = "ERROR: Apple Intelligence model is not available on this Mac."
                    return
                }

                let session = LanguageModelSession(model: model)
                let response = try await session.respond(to: promptText)
                output = response.content
            } catch {
                output = "ERROR: \(error)"
            }
            #else
            output = "ERROR: FoundationModels framework not found in this SDK."
            #endif
        }
    } else {
        output = "ERROR: macOS 15.0+ is required."
        semaphore.signal()
    }

    semaphore.wait()
    return strdup(output)
}

@_cdecl("fm_stream_text")
public func fm_stream_text(
    _ prompt: UnsafePointer<CChar>?,
    _ callback: FMStreamCallback?,
    _ context: UnsafeMutableRawPointer?
) -> Int32 {
    guard let prompt else {
        return 1
    }
    guard let callback else {
        return 2
    }

    let promptText = String(cString: prompt)
    let semaphore = DispatchSemaphore(value: 0)
    var status: Int32 = 0

    if #available(macOS 15.0, *) {
        Task {
            defer { semaphore.signal() }

            #if canImport(FoundationModels)
            do {
                let model = SystemLanguageModel.default
                guard model.isAvailable else {
                    status = 3
                    return
                }

                let session = LanguageModelSession(model: model)
                let stream = session.streamResponse(to: promptText)

                var previous = ""
                for try await snapshot in stream {
                    let current = snapshot.content
                    let chunk: String
                    if current.hasPrefix(previous) {
                        chunk = String(current.dropFirst(previous.count))
                    } else {
                        chunk = current
                    }
                    previous = current

                    if !chunk.isEmpty {
                        chunk.withCString { callback($0, context) }
                    }
                }
            } catch {
                status = 4
            }
            #else
            status = 5
            #endif
        }
    } else {
        status = 6
        semaphore.signal()
    }

    semaphore.wait()
    return status
}

#if canImport(FoundationModels)
@available(macOS 15.0, *)
@Generable
struct ProcessDiagnosis: Codable {
    @Guide(description: "A concise 1 or 2 sentence explanation of why the process might be causing this resource spike.")
    var explanation: String
    
    @Guide(description: "The primary resource bottleneck classification. Short phrase, e.g., 'CPU Bound', 'Memory Intensive', 'Heavy I/O', or 'Background Daemon'.")
    var bottleneck: String
    
    @Guide(description: "Practical advice in 2 to 5 words, e.g., 'Normal OS process', 'High load expected', or 'Consider terminating if frozen'.")
    var advice: String
}
#endif

@_cdecl("fm_generate_diagnosis")
public func fm_generate_diagnosis(_ prompt: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let prompt else {
        return strdup("{\"error\":\"prompt was null\"}")
    }

    let promptText = String(cString: prompt)
    let semaphore = DispatchSemaphore(value: 0)
    var output = "{\"error\":\"unknown failure\"}"

    if #available(macOS 15.0, *) {
        Task {
            defer { semaphore.signal() }

            #if canImport(FoundationModels)
            do {
                let model = SystemLanguageModel.default
                guard model.isAvailable else {
                    output = "{\"error\":\"model unavailable\"}"
                    return
                }

                let session = LanguageModelSession(model: model)
                let response = try await session.respond(to: promptText, generating: ProcessDiagnosis.self)
                let diag = response.content
                if let data = try? JSONEncoder().encode(diag), let jsonStr = String(data: data, encoding: .utf8) {
                    output = jsonStr
                } else {
                    let exp = diag.explanation.replacingOccurrences(of: "\"", with: "\\\"")
                    let bot = diag.bottleneck.replacingOccurrences(of: "\"", with: "\\\"")
                    let adv = diag.advice.replacingOccurrences(of: "\"", with: "\\\"")
                    output = "{\"explanation\":\"\(exp)\",\"bottleneck\":\"\(bot)\",\"advice\":\"\(adv)\"}"
                }
            } catch {
                let errStr = "\(error)".replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ")
                output = "{\"error\":\"\(errStr)\"}"
            }
            #else
            output = "{\"error\":\"FoundationModels not found\"}"
            #endif
        }
    } else {
        output = "{\"error\":\"macOS 15.0+ required\"}"
        semaphore.signal()
    }

    semaphore.wait()
    return strdup(output)
}

@_cdecl("fm_free_string")
public func fm_free_string(_ ptr: UnsafeMutablePointer<CChar>?) {
    free(ptr)
}
