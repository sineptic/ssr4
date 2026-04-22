const std = @import("std");

const ssr4 = @import("ssr4");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    var stdout = &stdout_writer.interface;
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const input_buffer = try gpa.alloc(u8, 10_000);
    defer gpa.free(input_buffer);
    const input_n = try stdin_reader.interface.readSliceShort(input_buffer);
    const input = input_buffer[0..input_n];

    const blocks = try parse_task(gpa, stderr, input);
    defer gpa.free(blocks);

    // enter alt screen
    try stdout.writeAll("\x1b[?1049h");
    try stdout.flush();
    defer {
        // exit alt screen
        stdout.writeAll("\x1b[?1049l") catch {};
        stdout.flush() catch {};
    }

    try stdout.writeAll("\x1b[1;1H");
    try stdout.print("{s}", .{input});
    try stdout.flush();
    try io.sleep(.fromSeconds(1), .real);
}

const Block = struct {
    kind: BlockKind,
    string: []const u8,
};
const BlockKind = enum {
    text,
    hidden_text,
    note,
};

fn parse_task(allocator: std.mem.Allocator, stderr: *std.Io.Writer, text_raw: []const u8) ![]Block {
    var tail = std.mem.trim(u8, text_raw, " \n\t");
    var blocks = std.ArrayList(Block).empty;
    errdefer blocks.deinit(allocator);
    while (tail.len > 0) {
        const next_quote = std.mem.find(u8, tail, "`");
        const next_slashes = std.mem.find(u8, tail, "//");
        if (next_quote == 0) {
            const block, tail = std.mem.cut(u8, tail[1..], "`") orelse {
                stderr.print("ERROR: You should close backtick quote to indicate hidden_text block end.\n", .{}) catch {};
                stderr.flush() catch {};
                return error.UnclosedBacktickQuote;
            };
            try blocks.append(allocator, .{ .kind = .hidden_text, .string = block });
        } else if (next_slashes == 0) {
            const block, tail = std.mem.cut(u8, tail[2..], "\n") orelse .{ tail, &.{} };
            try blocks.append(allocator, .{ .kind = .note, .string = block });
        } else {
            const plain_text_end = std.mem.min(usize, &.{ next_quote orelse tail.len, next_slashes orelse tail.len });
            try blocks.append(allocator, .{ .kind = .text, .string = tail[0..plain_text_end] });
            tail = tail[plain_text_end..];
        }
    }
    return blocks.toOwnedSlice(allocator);
}
