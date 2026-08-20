import CoreML
import Darwin
import Foundation
import NaturalLanguage

private struct SampleRow: Decodable {
    let text: String
    let label: String
}

private struct EvaluationSet {
    let name: String
    let rows: [SampleRow]
}

private func loadRows(from path: String) throws -> [SampleRow] {
    let payload = try String(contentsOfFile: path, encoding: .utf8)
    let decoder = JSONDecoder()
    return try payload.split(whereSeparator: \.isNewline).map { line in
        try decoder.decode(SampleRow.self, from: Data(line.utf8))
    }
}

private func modelVersion(at modelURL: URL) -> String {
    let manifestURL = modelURL
        .deletingLastPathComponent()
        .appendingPathComponent("SiftSMSClassifier.manifest.json")
    guard
        let data = try? Data(contentsOf: manifestURL),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let version = object["version"] as? String
    else {
        return modelURL.deletingLastPathComponent().lastPathComponent
    }
    return version
}

private var tests: [EvaluationSet] = []
private var modelPaths: [String] = []
private var printsErrors = false
private var requiresPerfect = false
private var confidenceFloor = 0.62
private var index = 1

while index < CommandLine.arguments.count {
    let argument = CommandLine.arguments[index]
    if argument == "--errors" {
        printsErrors = true
        index += 1
    } else if argument == "--require-perfect" {
        requiresPerfect = true
        index += 1
    } else if argument == "--confidence-floor" {
        guard
            index + 1 < CommandLine.arguments.count,
            let value = Double(CommandLine.arguments[index + 1]),
            (0...1).contains(value)
        else {
            fatalError("--confidence-floor requires a value between 0 and 1")
        }
        confidenceFloor = value
        index += 2
    } else if argument == "--test" {
        guard index + 1 < CommandLine.arguments.count else {
            fatalError("--test requires name=path")
        }
        let specification = CommandLine.arguments[index + 1]
        guard let separator = specification.firstIndex(of: "=") else {
            fatalError("--test requires name=path")
        }
        let name = String(specification[..<separator])
        let path = String(specification[specification.index(after: separator)...])
        tests.append(EvaluationSet(name: name, rows: try loadRows(from: path)))
        index += 2
    } else {
        modelPaths.append(argument)
        index += 1
    }
}

guard !tests.isEmpty, !modelPaths.isEmpty else {
    fatalError("Usage: swift evaluate_classic_models.swift [--errors] [--require-perfect] [--confidence-floor 0.62] --test name=rows.ndjson model.mlmodel ...")
}

print((["version", "size_kb"] + tests.map(\.name)).joined(separator: "\t"))

var perfectGateFailed = false
for path in modelPaths {
    let modelURL = URL(fileURLWithPath: path)
    do {
        let compiledURL = try MLModel.compileModel(at: modelURL)
        defer { try? FileManager.default.removeItem(at: compiledURL) }
        let model = try NLModel(contentsOf: compiledURL)
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.doubleValue ?? 0
        var columns = [modelVersion(at: modelURL), String(format: "%.1f", size / 1024)]

        var errors: [(test: String, expected: String, predicted: String, confidence: Double, text: String)] = []
        var lowConfidence: [(test: String, label: String, confidence: Double, text: String)] = []
        for test in tests {
            let correct = test.rows.reduce(into: 0) { count, row in
                let hypotheses = model.predictedLabelHypotheses(for: row.text, maximumCount: 3)
                let prediction = model.predictedLabel(for: row.text)
                    ?? hypotheses.max { lhs, rhs in lhs.value < rhs.value }?.key
                    ?? "<nil>"
                let confidence = hypotheses[prediction] ?? 0
                if prediction == row.label {
                    count += 1
                    if confidence < confidenceFloor {
                        lowConfidence.append((test.name, prediction, confidence, row.text))
                    }
                } else {
                    errors.append((test.name, row.label, prediction, confidence, row.text))
                }
            }
            let accuracy = test.rows.isEmpty ? 0 : Double(correct) / Double(test.rows.count)
            columns.append(String(format: "%.2f%%", accuracy * 100))
        }

        print(columns.joined(separator: "\t"))
        perfectGateFailed = perfectGateFailed || !errors.isEmpty
        if printsErrors {
            for error in errors {
                print(String(
                    format: "ERROR\t%@\t%@\t%@\t%.4f\t%@",
                    error.test,
                    error.expected,
                    error.predicted,
                    error.confidence,
                    error.text
                ))
            }
            for item in lowConfidence {
                print(String(
                    format: "LOW\t%@\t%@\t%.4f\t%@",
                    item.test,
                    item.label,
                    item.confidence,
                    item.text
                ))
            }
        }
    } catch {
        perfectGateFailed = true
        print("\(modelVersion(at: modelURL))\terror: \(error)")
    }
}

if requiresPerfect, perfectGateFailed {
    exit(1)
}
