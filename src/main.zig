const std = @import("std");
const http = std.http;
const Io = std.Io;
const yt_extractor = @import("yt_extractor.zig");

const info = std.log.info;
const er = std.log.err;
const warn = std.log.warn;


const YTOptions = struct {
    api_key: ?[]const u8 = null,
    video_id: ?[]const u8 = null,
    resolution: VideoResolution = .@"360p",

    pub const VideoResolution = enum {
        @"360p",
        @"1080p"
    };
};

const DownloadOptions = struct {
    video_url: []const u8,
    save_path: []const u8
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const download_options = try parseArgs(args);

    var future = Io.concurrent(io, entry, .{ io, arena, download_options })
        catch Io.async(io, entry, .{ io, arena, download_options });

    try future.await(io);
}

fn parseArgs(args: []const [:0]const u8) !DownloadOptions {
    var video_url_opt: ?[]const u8 = null;
    var save_path_opt: ?[]const u8 = null;

    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--link")) {
            if (i + 1 < args.len) {
                video_url_opt = args[i + 1];
            }
        }

        if (std.mem.eql(u8, arg, "--o")) {
            if (i + 1 < args.len) {
                save_path_opt = args[i + 1];
            }
        }
    }

    if (video_url_opt == null or save_path_opt == null) {
        info("You're must be enter the both args: --link <link> --o <save_path>", .{});
        return error.OneArgIsNull;
    }

    return .{
        .video_url = video_url_opt.?,
        .save_path = save_path_opt.?
    };
}

pub fn entry(io: Io, allocator: std.mem.Allocator, download_options: DownloadOptions) !void {
    var client = std.http.Client{
        .io = io,
        .allocator = allocator,
    };
    defer client.deinit();

    const video_url = download_options.video_url;
    const save_path = download_options.save_path;

    const yt_options = fetchYtForApiKey(io, &client, video_url, allocator) catch |err| switch (err) {
        error.VideoUrlNotFound => {
            er("Your link doesn't contain an video id. Link {s}", .{ video_url });
            std.process.cleanExit(io);
            unreachable;
        },
        error.DoesNotCountainQuery => {
            er("Your link doesn't contain a query. Link {s}", .{ video_url });
            std.process.cleanExit(io);
            unreachable;
        },
        else => return err
    };

    const json_response = try fetchYtPlayerResponse(&client, allocator, yt_options);

    const download_link = yt_extractor.extractVideoUrl(allocator, json_response) catch |err| {
        if (err == error.VideoUrlNotFound) {
            er("Download link is not found in a youtube json response. Response: {s}", .{ json_response });
            std.process.cleanExit(io);
            unreachable;
        }
        return err;
    };

    info("Download Link: {s}", .{ download_link });    
    info("Downloading to {s}", .{ save_path });

    try downloadVideoByLink(io, &client, download_link, save_path);
    
    info("Downloading is completed.", .{});
}

fn downloadVideoByLink(io: Io, client: *http.Client, link: []const u8, out_path: []const u8) !void {
    const cwd = Io.Dir.cwd();

    var file = try cwd.createFile(io, out_path, .{});
    defer file.close(io);

    var buf: [8192]u8 = undefined;
    var fw: Io.File.Writer = .init(file, io, &buf);

    _ = try client.fetch(.{
        .location = .{ .url = link },
        .method = .GET,
        .response_writer = &fw.interface
    });
}

fn fetchYtForApiKey(io: Io, client: *http.Client, video_url: []const u8, allocator: std.mem.Allocator) !YTOptions {
    var response_writer: Io.Writer.Allocating = .init(allocator);

    const options: http.Client.FetchOptions = .{
        .location = .{ .url = video_url },
        .method = .GET,
        .response_writer = &response_writer.writer,
        .headers = .{ .user_agent = .{ .override = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" } }
    };

    const result = try client.fetch(options);

    if (result.status != .ok) {
        er("Response status was not \"ok\". Status: {s}", .{ result.status.phrase() orelse "UnknownStatus" });
        return error.NotOkStatus;
    }

    const html_page = response_writer.written();
    const key = parseInternalApiKey(html_page) catch |err| {
        if (err == error.KeyNotFound) {
            er("Key was not found in the response.", .{});
            std.process.cleanExit(io);
            unreachable;
        }
        return err;
    };

    const video_id = try extractVideoIdFromUrl(video_url);

    return .{
        .api_key = key,
        .video_id = video_id
    };
}

fn parseInternalApiKey(html_page: []const u8) ![]const u8 {
    const key_name = "\"INNERTUBE_API_KEY\":";
    const hit = std.mem.indexOf(u8, html_page, key_name);

    if (hit == null) return error.KeyNotFound;

    const key_begin = hit.? + key_name.len + 1; // with " \" " quote
    const key_len = 39;
    const key_end = key_begin + key_len;

    const key = html_page[key_begin .. key_end];

    return key;
}

fn extractVideoIdFromUrl(video_url: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(video_url);
    
    if (uri.query) |q| {
        const query_str = q.percent_encoded;
        const hit = std.mem.indexOfScalar(u8, query_str, '=');
        if (hit == null) return error.VideoUrlNotFound;

        return query_str[hit.? + 1..];
    }

    return error.DoesNotCountainQuery;
}

fn fetchYtPlayerResponse(client: *http.Client, allocator: std.mem.Allocator, yt_options: YTOptions) ![]const u8 {
    const request_url = "https://www.youtube.com/youtubei/v1/player?key";
    var buffer: [1024]u8 = undefined;
    const formatted_url = try std.fmt.bufPrint(&buffer, "{s}={s}", .{ request_url, yt_options.api_key.? });

    const payload = .{
        .videoId = yt_options.video_id,
        .context = .{
            .client = .{
                .clientName = "ANDROID",
                .clientVersion = "21.22.165",
                .hl = "en",
                .gl = "US"
            }
        }
    };

    var writer_buf: [1024]u8 = undefined;
    var fixed: Io.Writer = .fixed(&writer_buf);
    try std.json.Stringify.value(payload, .{}, &fixed);
    
    var response_writer: Io.Writer.Allocating = .init(allocator);

    const options: http.Client.FetchOptions = .{
        .location = .{ .url = formatted_url },
        .method = .POST,
        .payload = fixed.buffered(),
        .response_writer = &response_writer.writer,
        .headers = .{ .user_agent = .{ .override = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" } }
    };

    const result = try client.fetch(options);

    if (result.status == .ok) 
        return response_writer.written();

    return result.status.phrase() orelse "UnknownStatus";
}






test "json_anonymous_struct:" {
    const payload = .{
        .videoId = "23123",
        .context = .{
            .client = .{
                .clientName = "ANDROID",
                .clientVersion = "21.22.165",
                .hl = "en",
                .gl = "US"
            }
        }
    };

    const json_string = try std.json.Stringify.valueAlloc(std.testing.allocator, payload, .{});
    defer std.testing.allocator.free(json_string);

    std.debug.print("{s}\n", .{ json_string });
}

test "yt_response" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var client = std.http.Client{
        .io = io,
        .allocator = allocator
    };

    const response = try fetchYtPlayerResponse(&client, allocator, .{
        .api_key = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8",
        .video_id = "UA7CBvimH8Y"
    });

    std.debug.print("Length: {d}\n", .{ response.len });
}

test "extract_streamingData" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var client = std.http.Client{
        .io = io,
        .allocator = allocator,
    };

    const video_url = "https://www.youtube.com/watch?v=UA7CBvimH8Y";
    const yt_options = try fetchYtForApiKey(io, &client, video_url, allocator);
    const response = try fetchYtPlayerResponse(&client, allocator, yt_options);
    const url = try yt_extractor.extractVideoUrl(allocator, response);

    std.debug.print("Url: {s}\n", .{ url });
}