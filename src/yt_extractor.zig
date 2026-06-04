const std = @import("std");

pub fn extractVideoUrl(allocator: std.mem.Allocator, json_response: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_response, .{});
    defer parsed.deinit();
    const root = parsed.value;

    if (root.object.get("streamingData")) |streaming_data| {
        if (streaming_data.object.get("formats")) |formats| {
            if (formats.array.items[0].object.get("url")) |url| {
                return try allocator.dupe(u8, url.string);
            }
        }
    }

    return error.VideoUrlNotFound;
}