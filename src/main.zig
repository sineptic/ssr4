const std = @import("std");

const ssr4 = @import("ssr4");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const stdout = std.Io.File.stdout();
    var stdout_buffer: [1024]u8 = undefined;
    var output_writer = stdout.writer(io, &stdout_buffer);
    var output = &output_writer.interface;
    const stdin = std.Io.File.stdin();
    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = stdin.reader(io, &stdin_buffer);
    const input_buffer = try gpa.alloc(u8, 10_000);
    defer gpa.free(input_buffer);
    const input_n = try stdin_reader.interface.readSliceShort(input_buffer);
    const input = input_buffer[0..input_n];

    // enter alt screen
    try output.writeAll("\x1b[?1049h");
    try output.flush();
    defer {
        // exit alt screen
        output.writeAll("\x1b[?1049l") catch {};
        output.flush() catch {};
    }

    try output.writeAll("\x1b[1;1H");
    try output.print("{s}", .{input});
    try output.flush();
    try io.sleep(.fromSeconds(1), .real);
}

const Block = union(enum) {
    text: []const u8,
    hidden_text: []const u8,
    note: []const u8,
};

fn is_next(string: []const u8, pattern: []const u8) bool {
    if (pattern.len > string.len) return false;
    return std.mem.eql(u8, string[0..pattern.len], pattern);
}
fn parse_task(allocator: std.mem.Allocator, text: []const u8) ![]Block {
    _ = text;
    var blocks = std.ArrayList(Block).empty;
    return blocks.toOwnedSlice(allocator);
}
