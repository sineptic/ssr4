const std = @import("std");

const ssr4 = @import("ssr4");

pub fn main() !void {
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = allocator.allocator();

    const stdout = std.fs.File.stdout();
    var stdout_buffer: [1024]u8 = undefined;
    var output_writer = stdout.writer(&stdout_buffer);
    var output = &output_writer.interface;
    const stdin = std.fs.File.stdin();
    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = stdin.reader(&stdin_buffer);
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
    std.Thread.sleep(1_000_000_000);
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
    var blocks = std.ArrayList(Block).empty;
    return blocks.toOwnedSlice(allocator);
}
