const std = @import("std");

const ssr4 = @import("ssr4");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdin_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;
    const input_buffer = try gpa.alloc(u8, 10_000);
    defer gpa.free(input_buffer);
    const input_n = try stdin_reader.interface.readSliceShort(input_buffer);
    const input = input_buffer[0..input_n];

    const blocks = try parse_task(gpa, stderr, input);
    defer gpa.free(blocks);

    const tty_file = try std.Io.Dir.cwd().openFile(io, "/dev/tty", .{});
    defer tty_file.close(io);
    var tty_buffer: [1024]u8 = undefined;
    var tty_reader = tty_file.reader(io, &tty_buffer);
    var tty = &tty_reader.interface;

    const original_termios = try std.posix.tcgetattr(tty_file.handle);
    defer std.posix.tcsetattr(tty_file.handle, .FLUSH, original_termios) catch {};
    var termios = original_termios;
    termios.lflag.ECHO = false;
    termios.lflag.ICANON = false;
    try std.posix.tcsetattr(tty_file.handle, .NOW, termios);

    // enter alt screen
    try stdout.writeAll("\x1b[?1049h");
    try stdout.flush();
    defer {
        // exit alt screen
        stdout.writeAll("\x1b[?1049l") catch {};
        stdout.flush() catch {};
    }

    var inp: std.ArrayList(u8) = .empty;
    defer inp.deinit(gpa);
    while (true) {
        try stdout.writeAll("\x1b[2J\x1b[1;1H\x1b[0m");
        try stdout.writeAll(inp.items);
        try stdout.flush();

        const byte = try tty.takeByte();
        if (byte == 8 or byte == 127) {
            if (inp.items.len == 0) continue;
            for (0..4) |_| {
                const popped = inp.pop().?;
                // if character start
                if ((popped & 0b11000000) != 0b10000000) break;
            } else {
                @panic("non utf-8 input");
            }
        } else {
            try inp.append(gpa, byte);
        }
    }
}

const Block = union(enum) {
    text: []const u8,
    hidden: struct {
        original_text: []const u8,
        user_input: []const u8,
        field_cursor: usize,
    },
    note: []const u8,

    fn is_interactive(self: Block) bool {
        return switch (self) {
            .text, .note => false,
            .hidden => true,
        };
    }
};

fn parse_task(gpa: std.mem.Allocator, stderr: *std.Io.Writer, task: []const u8) ![]Block {
    var tail = std.mem.trim(u8, task, " \n\t");
    var blocks = std.ArrayList(Block).empty;
    errdefer blocks.deinit(gpa);
    while (tail.len > 0) {
        const next_quote = std.mem.find(u8, tail, "`");
        const next_slashes = std.mem.find(u8, tail, "//");
        if (next_quote == 0) {
            const block, tail = std.mem.cut(u8, tail[1..], "`") orelse {
                stderr.print(
                    "ERROR: You should close backtick quote to indicate hidden_text block end.\n",
                    .{},
                ) catch {};
                stderr.flush() catch {};
                return error.UnclosedBacktickQuote;
            };
            try blocks.append(gpa, .{ .hidden = .{
                .original_text = block,
                .user_input = &.{},
                .field_cursor = 0,
            } });
        } else if (next_slashes == 0) {
            const block, tail = std.mem.cut(u8, tail[2..], "\n") orelse .{ tail, &.{} };
            try blocks.append(gpa, .{ .note = block });
        } else {
            const plain_text_end = std.mem.min(
                usize,
                &.{ next_quote orelse tail.len, next_slashes orelse tail.len },
            );
            try blocks.append(gpa, .{ .text = tail[0..plain_text_end] });
            tail = tail[plain_text_end..];
        }
    }
    if (blocks.items.len == 0) {
        stderr.print("ERROR: You should write task.\n", .{}) catch {};
        stderr.flush() catch {};
        return error.EmptyTask;
    }
    return blocks.toOwnedSlice(gpa);
}

fn display_blocks_interactive(output: *std.Io.Writer, blocks: []const Block, cursor: usize) !void {
    try output.writeAll("\x1b[2J\x1b[1;1H\x1b[0m");

    for (blocks, 0..) |block, i| {
        switch (block) {
            .text => |string| {
                try output.print("{s}", .{string});
            },
            .note => {},
            .hidden => |hidden_block| {
                if (hidden_block.user_input.len == 0 and i != cursor) {
                    try output.print("\x1b[3m<empty>\x1b[0m", .{});
                } else {
                    try output.print("\x1b[3;4m{s}\x1b7{s}\x1b[0m", .{
                        hidden_block.user_input[0..hidden_block.field_cursor],
                        hidden_block.user_input[hidden_block.field_cursor..],
                    });
                }
            },
        }
    }
    if (blocks[cursor].is_interactive()) {
        try output.writeAll("\x1b8\x1b[?25h");
    } else {
        try output.writeAll("\x1b[?25l");
    }

    try output.flush();
}
