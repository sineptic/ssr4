const std = @import("std");
const sqlite3 = @cImport({
    @cInclude("sqlite3.h");
});
const ssr4 = @import("ssr4");
const assert = std.debug.assert;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    // FIXME: Why it is required by .toSlice, that allocator is arena style?
    defer gpa.free(args);

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdin_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    assert(args.len > 0);
    if (args.len == 1) {
        try stderr.writeAll("Calling app without arguments is currently unsupported.\n");
        try stderr.flush();
        return error.UnsupportedMode;
    }

    const input_buffer = try gpa.alloc(u8, 10_000);
    defer gpa.free(input_buffer);
    const input_n = try stdin_reader.interface.readSliceShort(input_buffer);
    const input = input_buffer[0..input_n];

    const blocks = try parse_task(gpa, stderr, input);
    defer {
        for (blocks) |*block| {
            block.deinit(gpa);
        }
        gpa.free(blocks);
    }
    if (std.mem.eql(u8, args[1], "preview")) {
        const tty_file = try std.Io.Dir.cwd().openFile(io, "/dev/tty", .{});
        defer tty_file.close(io);
        var tty_buffer: [1024]u8 = undefined;
        var tty_reader = tty_file.reader(io, &tty_buffer);
        const tty = &tty_reader.interface;

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

        const difficulty = try repeat_task(gpa, stdout, tty, tty_file, blocks);
        std.debug.panic("difficulty: {}", .{difficulty});
    }
    if (std.mem.eql(u8, args[1], "add")) {
        var db: ?*sqlite3.sqlite3 = undefined;
        _ = sqlite3.sqlite3_open("ssr4.db", &db);
        defer _ = sqlite3.sqlite3_close(db);
        {
            var errmsg: [*c]u8 = undefined;
            const res = sqlite3.sqlite3_exec(
                db,
                \\PRAGMA journal_mode = WAL;
                \\
                \\CREATE TABLE IF NOT EXISTS tasks (
                \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
                \\  text TEXT,
                \\  creation_time TEXT
                \\);
            ,
                null,
                undefined,
                &errmsg,
            );
            if (res != 0) {
                const ermsg_len = std.zig.c_translation.builtins.strlen(errmsg);
                defer sqlite3.sqlite3_free(errmsg);
                std.debug.print("err: {s}\n", .{errmsg[0..ermsg_len]});
                return error.CantCreateTable;
            }
        }

        var stmt: ?*sqlite3.sqlite3_stmt = undefined;
        {
            const rc = sqlite3.sqlite3_prepare_v2(
                db,
                "INSERT INTO tasks (text, creation_time) VALUES (?, datetime('now', 'localtime'))",
                10 * 1024,
                &stmt,
                0,
            );
            if (rc != 0) {
                const errmsg = sqlite3.sqlite3_errmsg(db);
                const errmsg_len = std.zig.c_translation.builtins.strlen(errmsg);
                std.debug.print("err: {s}\n", .{errmsg[0..errmsg_len]});
                @panic("TODO");
            }
        }
        defer _ = sqlite3.sqlite3_finalize(stmt);
        {
            const SQLITE_TRANSIENT: *anyopaque = @ptrFromInt(0xFFFFFFFFFFFFFFFF);
            const rc = sqlite3.sqlite3_bind_text(
                stmt,
                1,
                input.ptr,
                @intCast(input.len),
                SQLITE_TRANSIENT,
            );
            if (rc != 0) @panic("TODO");
        }
        {
            const rc = sqlite3.sqlite3_step(stmt);
            if (rc != sqlite3.SQLITE_DONE) @panic("TODO");
        }
        std.debug.print("row added\n", .{});

        // var stmt: ?*sqlite3.sqlite3_stmt = undefined;
        // _ = sqlite3.sqlite3_prepare_v2(db, "SELECT a, b FROM tasks", -1, &stmt, 0);
        // defer _ = sqlite3.sqlite3_finalize(stmt);
        // while (sqlite3.sqlite3_step(stmt) == sqlite3.SQLITE_ROW) {
        //     const my_type = struct {
        //         a: []const u8,
        //         b: i32,
        //     };
        //     const a_raw = sqlite3.sqlite3_column_text(stmt, 0);
        //     const a_len = std.zig.c_translation.builtins.strlen(a_raw);
        //     const a = a_raw[0..a_len];
        //     const b = sqlite3.sqlite3_column_int(stmt, 1);
        //     const val =
        //         my_type{
        //             .a = a,
        //             .b = b,
        //         };
        //     std.debug.print("row: {any}\n", .{val});
        // }
        // std.debug.panic("asdf", .{});
    }
}

const RepetitionDifficulty = enum {
    again,
    hard,
    good,
    easy,
};
/// Repeat task and return difficulty
fn repeat_task(
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    tty: *std.Io.Reader,
    tty_file: std.Io.File,
    blocks: []Block,
) !RepetitionDifficulty {
    var cursor: usize = 0;
    for (blocks, 0..) |block, i| {
        if (block.is_interactive()) {
            cursor = i;
            break;
        }
    }
    while (true) {
        try display_blocks_interactive(stdout, blocks, cursor);

        // TODO: Also consume all availble in buffer bytes.
        // NOTE: Availability could be checked using `tty.bufferedLen()`
        const byte = try tty.takeByte();
        if (blocks[cursor].is_interactive()) {
            blocks[cursor].eat_byte(gpa, byte) catch |err| switch (err) {
                error.FormSubmission => {
                    break;
                },
                error.GotoNextBlock => {
                    for (blocks[cursor..], cursor..) |block, i| {
                        if (block.is_interactive() and i > cursor) {
                            cursor = i;
                            break;
                        }
                    }
                },
                error.GotoPreviousBlock => {
                    var last = cursor;
                    for (blocks[0..cursor], 0..) |block, i| {
                        if (block.is_interactive()) {
                            last = i;
                        }
                    }
                    cursor = last;
                },
                else => return err,
            };
        }
    }
    try display_blocks_answer_overview(stdout, tty_file, blocks);
    while (true) {
        const byte = try tty.takeByte();
        switch (byte) {
            '1' => return .again,
            '2' => return .hard,
            '3' => return .good,
            '4' => return .easy,
            else => {},
        }
    }
}

const Block = union(enum) {
    text: []const u8,
    hidden: struct {
        original_text: []const u8,
        user_input: std.ArrayList(u8),
        cursor_index: usize,
    },
    note: []const u8,

    fn is_interactive(self: Block) bool {
        return switch (self) {
            .text, .note => false,
            .hidden => true,
        };
    }
    const Error = error{
        OutOfMemory,
        NonUtf8Input,
        FormSubmission,
        GotoNextBlock,
        GotoPreviousBlock,
    };
    /// Block must be interactive.
    fn eat_byte(self: *Block, gpa: std.mem.Allocator, byte: u8) Error!void {
        switch (self.*) {
            .text, .note => unreachable,
            .hidden => |*this| {
                if (byte == 4) {
                    return error.FormSubmission;
                }
                if (byte == 9) {
                    return error.GotoNextBlock;
                }
                if (byte == 8 or byte == 127) {
                    if (this.cursor_index == 0) return;
                    for (0..4) |_| {
                        const popped = this.user_input.orderedRemove(this.cursor_index - 1);
                        this.cursor_index -= 1;
                        // if character start
                        if ((popped & 0b11000000) != 0b10000000) break;
                    } else {
                        return error.NonUtf8Input;
                    }
                    return;
                }
                var temp = try this.user_input.addManyAt(gpa, this.cursor_index, 1);
                temp[0] = byte;
                this.cursor_index += 1;
                // left arrow
                if (std.mem.endsWith(u8, this.user_input.items[0..this.cursor_index], "\x1b[D")) {
                    this.user_input.orderedRemoveMany(&.{
                        this.cursor_index - 3,
                        this.cursor_index - 2,
                        this.cursor_index - 1,
                    });
                    this.cursor_index -= 3;

                    if (this.cursor_index > 0) {
                        for (0..4) |_| {
                            const ch = this.user_input.items[this.cursor_index - 1];
                            this.cursor_index -= 1;
                            // if character start
                            if ((ch & 0b11000000) != 0b10000000) break;
                        } else {
                            return error.NonUtf8Input;
                        }
                    }
                    return;
                }
                // right arrow
                if (std.mem.endsWith(u8, this.user_input.items[0..this.cursor_index], "\x1b[C")) {
                    this.user_input.orderedRemoveMany(&.{
                        this.cursor_index - 3,
                        this.cursor_index - 2,
                        this.cursor_index - 1,
                    });
                    this.cursor_index -= 3;

                    if (this.cursor_index < this.user_input.items.len) {
                        const first_byte = this.user_input.items[this.cursor_index];
                        this.cursor_index += std.unicode.utf8ByteSequenceLength(first_byte) catch {
                            return error.NonUtf8Input;
                        };
                    }
                    return;
                }
                // back tab
                if (std.mem.endsWith(u8, this.user_input.items[0..this.cursor_index], "\x1b[Z")) {
                    this.user_input.orderedRemoveMany(&.{
                        this.cursor_index - 3,
                        this.cursor_index - 2,
                        this.cursor_index - 1,
                    });
                    this.cursor_index -= 3;

                    return error.GotoPreviousBlock;
                }
                // 'delete' key
                if (std.mem.endsWith(u8, this.user_input.items[0..this.cursor_index], "\x1b[3~")) {
                    this.user_input.orderedRemoveMany(&.{
                        this.cursor_index - 4,
                        this.cursor_index - 3,
                        this.cursor_index - 2,
                        this.cursor_index - 1,
                    });
                    this.cursor_index -= 4;

                    if (this.cursor_index < this.user_input.items.len) {
                        const first_byte = this.user_input.items[this.cursor_index];
                        const char_length = std.unicode.utf8ByteSequenceLength(first_byte) catch {
                            return error.NonUtf8Input;
                        };
                        const indexes: []const usize = &.{
                            this.cursor_index,
                            this.cursor_index + 1,
                            this.cursor_index + 2,
                            this.cursor_index + 3,
                        };
                        this.user_input.orderedRemoveMany(indexes[0..char_length]);
                    }
                    return;
                }
            },
        }
    }
    fn deinit(self: *Block, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .text, .note => {},
            .hidden => |*this| {
                this.user_input.deinit(gpa);
            },
        }
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
                .user_input = .empty,
                .cursor_index = 0,
            } });
        } else if (next_slashes == 0) {
            const block, tail = std.mem.cut(u8, tail[2..], "\n") orelse .{ tail, &.{} };
            try blocks.append(gpa, .{ .note = std.mem.trim(u8, block, " \t") });
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
            .hidden => |this| {
                if (this.user_input.items.len == 0 and i != cursor) {
                    try output.print("\x1b[3m<empty>\x1b[0m", .{});
                } else {
                    try output.print("\x1b[3;4m{s}\x1b7{s}\x1b[0m", .{
                        this.user_input.items[0..this.cursor_index],
                        this.user_input.items[this.cursor_index..],
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

fn display_blocks_answer_overview(
    output: *std.Io.Writer,
    tty_file: std.Io.File,
    blocks: []const Block,
) !void {
    try output.writeAll("\x1b[2J\x1b[1;1H\x1b[0m\x1b[?25l");

    for (blocks) |block| {
        switch (block) {
            .text => |string| {
                try output.print("{s}", .{string});
            },
            .note => |string| {
                try output.print("\x1b[2m{s}\n\x1b[0m", .{string});
            },
            .hidden => |this| {
                if (this.original_text.len == 0) {
                    try output.print("\x1b[3;32m<empty>\x1b[0m", .{});
                } else {
                    try output.print("\x1b[3;4;32m{s}\x1b[0m", .{this.original_text});
                }

                const user_input_trimmed = std.mem.trim(u8, this.user_input.items, " \n");
                const original_text_trimmed = std.mem.trim(u8, this.original_text, " \n");
                if (!std.mem.eql(u8, user_input_trimmed, original_text_trimmed)) {
                    // TODO: Separate by newline when any of them is multiline.
                    try output.writeAll(" ");
                    if (user_input_trimmed.len == 0) {
                        try output.writeAll("\x1b[3;33m<empty>\x1b[0m");
                    } else {
                        try output.print("\x1b[3;4;33m{s}\x1b[0m", .{this.user_input.items});
                    }
                }
            },
        }
    }
    var winsize: std.posix.winsize = undefined;
    const rc = std.c.ioctl(
        tty_file.handle,
        std.c.T.IOCGWINSZ,
        &winsize,
    );
    if (rc != 0) return error.FailedToGetWinsize;

    const difficulty_art: []const []const u8 = &.{
        "╭──────────┬─────────┬─────────┬─────────╮",
        "│ \x1b[31m1. again\x1b[0m │ \x1b[33m2. hard\x1b[0m │ \x1b[36m3. good\x1b[0m │ \x1b[32m4. easy\x1b[0m │",
        "╰──────────┴─────────┴─────────┴─────────╯",
    };
    const difficulty_art_width = 42;
    for (difficulty_art, 0..) |line, i| {
        try output.print("\x1b[{};{}H", .{
            winsize.row - 4 + i,
            (winsize.col - difficulty_art_width) / 2 + 1,
        });
        try output.print("{s}\n", .{line});
    }

    try output.flush();
}
