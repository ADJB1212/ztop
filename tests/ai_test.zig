const std = @import("std");
const ai = @import("ztop").ai;

test "AI availability check does not panic" {
    const available = ai.isAvailable();
    // Either true or false depending on hardware/OS, but must return without error.
    _ = available;
}

test "AsyncQuery init and basic state" {
    var query = ai.AsyncQuery.init();
    try std.testing.expectEqual(ai.DiagnosticState.idle, query.getStatus());
    var buf: [128]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), query.getResult(&buf));
}

test "parseDiagnosisJson correctly decodes structured diagnosis" {
    const sample_json =
        \\{"explanation":"The process is compiling source code.","bottleneck":"CPU Bound","advice":"Normal compiler work"}
    ;
    const parsed = try ai.parseDiagnosisJson(std.testing.allocator, sample_json);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("The process is compiling source code.", parsed.value.explanation);
    try std.testing.expectEqualStrings("CPU Bound", parsed.value.bottleneck);
    try std.testing.expectEqualStrings("Normal compiler work", parsed.value.advice);
}

test "diagnosis cache reuses decoded strings and replaces invalid responses" {
    var cache: ai.DiagnosisCache = .{};
    const json = "{\"explanation\":\"line\\nnext\",\"bottleneck\":\"CPU\",\"advice\":\"wait\",\"extra\":42}";
    const first = cache.get(json).?;
    try std.testing.expectEqualStrings("line\nnext", first.explanation);
    try std.testing.expectEqualStrings("CPU", first.bottleneck);
    const second = cache.get(json).?;
    try std.testing.expectEqual(first.explanation.ptr, second.explanation.ptr);
    try std.testing.expectEqual(@as(?ai.ParsedDiagnosis, null), cache.get("invalid"));
    try std.testing.expectEqual(@as(?ai.ParsedDiagnosis, null), cache.get("invalid"));
    const replaced = cache.get("{\"explanation\":\"updated\"}").?;
    try std.testing.expectEqualStrings("updated", replaced.explanation);
    try std.testing.expectEqualStrings("", replaced.advice);
    const oversized: [1025]u8 = @splat('x');
    try std.testing.expectEqual(@as(?ai.ParsedDiagnosis, null), cache.get(&oversized));
    try std.testing.expectEqualStrings("line\nnext", cache.get(json).?.explanation);
}
