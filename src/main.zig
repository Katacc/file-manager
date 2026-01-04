const std = @import("std");
const file_manager = @import("file_manager");
const print = std.debug.print;
const posix = std.posix;

fn setRawInput(b: bool) !void {
    var t: posix.termios = try posix.tcgetattr(posix.STDIN_FILENO);
    t.lflag.ECHO = !b;
    t.lflag.ICANON = !b;
    try posix.tcsetattr(posix.STDIN_FILENO, .NOW, t);
}

pub fn main() !void {
    try setRawInput(true);
    defer setRawInput(false) catch unreachable;

    // General purpose allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Grab args and free allocator
    const args = try std.process.argsAlloc(gpa_allocator);
    defer std.process.argsFree(gpa_allocator, args);

    var stdin_buffer: [256]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);

    var starting_folder: []const u8 = ".";
    var working_folder: []const u8 = "";

    if (args.len > 1) {
        starting_folder = args[1];
    }

    // Arena allocator for long term allocations
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Grab the path for folder opened in
    const path: []const u8 = try std.fs.cwd().realpathAlloc(alloc, starting_folder);
    var working_path = try alloc.dupe(u8, path);

    // Open stdout
    var out = std.fs.File.stdout().writer(&.{}).interface;

    var buffer: [1]u8 = undefined;
    var info_msg: []const u8 = "";

    try out.print("\x1B[2J\x1B[H", .{});

    while (true) {
        // Add the cd'd folder to the work path and reset folder
        // CD'ing sets working_folder to the new folder
        const temp_working_path = try alloc.dupe(u8, working_path);
        working_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ working_path, working_folder });
        working_folder = "";

        // Set cwd to the path
        var currentFolder = std.fs.openDirAbsolute(
            working_path,
            .{ .iterate = true },
        ) catch |err| {
            info_msg = try std.fmt.allocPrint(alloc, "Error: {any}\n", .{err});
            alloc.free(working_path);
            working_path = try alloc.dupe(u8, temp_working_path);
            continue;
        };

        alloc.free(temp_working_path);

        defer currentFolder.close();
        try currentFolder.setAsCwd();
        working_path = try std.fs.cwd().realpathAlloc(alloc, ".");

        try out.writeAll("File manager!\n");
        try out.print("{s}\n", .{info_msg});
        try out.print("\npath: {s}\n", .{working_path});

        try listContents(&out, working_path);

        try out.writeAll("\na Add | ");
        try out.writeAll("d Delete | ");
        try out.writeAll("r Rename | ");
        try out.writeAll("c Change dir | ");
        try out.writeAll("q Quit | \n");
        try out.writeAll(": ");

        try stdin_reader.interface.discardAll(1);

        // Try to read a single byte non-blocking
        const bytes_read = std.fs.File.stdin().read(&buffer) catch |err| {
            if (err == error.WouldBlock) {
                // No input available, continue
                std.Thread.sleep(100_000_000);
                try out.print("\x1B[2J\x1B[H", .{});
                continue;
            }
            return err;
        };

        if (bytes_read > 0) {
            if (buffer[0] == 'a') {
                try setRawInput(false);
                try out.writeAll("File to add: ");

                const user_input = try stdin_reader.interface.takeDelimiterExclusive('\n');
                const trimmed = std.mem.trim(u8, user_input, &std.ascii.whitespace);

                const file_name = try gpa_allocator.dupe(u8, trimmed);
                defer gpa_allocator.free(file_name);

                try setRawInput(true);

                if (addFile(file_name, working_path)) {
                    info_msg = try std.fmt.allocPrint(alloc, "Succesfully created: {s}\n", .{trimmed});
                } else |err| {
                    info_msg = try std.fmt.allocPrint(alloc, "Error on creation: {any}\n", .{err});
                }
            }

            if (buffer[0] == 'd') {
                try setRawInput(false);
                try out.writeAll("File to remove: ");

                const user_input = try stdin_reader.interface.takeDelimiterExclusive('\n');
                const trimmed = std.mem.trim(u8, user_input, &std.ascii.whitespace);

                // use allocator to copy the buffer to source_name
                const file_name = try gpa_allocator.dupe(u8, trimmed);
                defer gpa_allocator.free(file_name);

                try setRawInput(true);

                if (delFile(file_name, working_path)) {
                    info_msg = try std.fmt.allocPrint(alloc, "Succesfully deleted: {s}\n", .{trimmed});
                } else |err| {
                    info_msg = try std.fmt.allocPrint(alloc, "Error on deletion: {any}\n", .{err});
                }
            }

            if (buffer[0] == 'r') {
                try setRawInput(false);

                try out.writeAll("File to rename: ");

                const user_input = try stdin_reader.interface.takeDelimiterExclusive('\n');
                const trimmed = std.mem.trim(u8, user_input, &std.ascii.whitespace);

                const source_name = try gpa_allocator.dupe(u8, trimmed);
                defer gpa_allocator.free(source_name);

                try out.writeAll("Rename to: ");
                // Discard the buffer
                try stdin_reader.interface.discardAll(1);

                const user_target = try stdin_reader.interface.takeDelimiterExclusive('\n');
                const trimmed_target = std.mem.trim(u8, user_target, &std.ascii.whitespace);

                try setRawInput(true);

                if (moveFile(source_name, trimmed_target, working_path)) {
                    info_msg = try std.fmt.allocPrint(alloc, "Succesfully renamed {s} - {s}", .{ source_name, trimmed_target });
                } else |err| {
                    info_msg = try std.fmt.allocPrint(alloc, "Error on rename: {any}", .{err});
                }
            }

            if (buffer[0] == 'c') {
                try setRawInput(false);

                try out.writeAll("Folder: ");
                const user_input = try stdin_reader.interface.takeDelimiterExclusive('\n');
                const trimmed = std.mem.trim(u8, user_input, &std.ascii.whitespace);

                const file_name = try alloc.dupe(u8, trimmed);
                working_folder = file_name;

                try setRawInput(true);
            }

            // Exit on 'q' or Ctrl+C
            if (buffer[0] == 'q' or buffer[0] == 3) {
                break;
            }

            std.Thread.sleep(100_000_000);
            try out.print("\x1B[2J\x1B[H", .{});
        }
    }
}

pub fn listContents(writer: *std.io.Writer, folder: []const u8) !void {
    var currentFolder = try std.fs.openDirAbsolute(
        folder,
        .{ .iterate = true },
    );
    defer currentFolder.close();

    try std.fs.File.stdout().writeAll("---------------------------------------\n");
    var iter = currentFolder.iterate();
    var items: u32 = 0;
    while (try iter.next()) |entry| {
        items += 1;
        if (entry.kind == .file) {
            try writer.print("File       {s}\n", .{entry.name});
        } else if (entry.kind == .directory) {
            try writer.print("Dir        {s}/\n", .{entry.name});
        } else {
            try writer.print("...        {s}\n", .{entry.name});
        }
    }
    try std.fs.File.stdout().writeAll("---------------------------------------\n");
    print("Items: {}\n", .{items});
}

pub fn addFile(name: []const u8, folder: []const u8) !void {
    var workingFolder = try std.fs.openDirAbsolute(
        folder,
        .{ .iterate = true },
    );
    defer workingFolder.close();

    _ = workingFolder.createFile(
        name,
        .{ .read = true },
    ) catch |err| {
        if (err == error.IsDir) {
            _ = workingFolder.makeDir(name) catch |dir_err| {
                std.debug.print("Error: {}\n", .{dir_err});
                return dir_err;
            };
        } else {
            std.debug.print("Error: {}\n", .{err});
            return err;
        }
    };
}

pub fn delFile(name: []const u8, folder: []const u8) !void {
    var workingFolder = try std.fs.openDirAbsolute(
        folder,
        .{ .iterate = true },
    );
    defer workingFolder.close();

    _ = workingFolder.deleteFile(name) catch |err| {
        if (err == error.IsDir) {
            _ = workingFolder.deleteDir(name) catch |dir_err| {
                print("Error: {}\n", .{dir_err});
                return dir_err;
            };
        } else {
            print("Error: {}\n", .{err});
            return err;
        }
    };
}

pub fn moveFile(name: []const u8, target: []const u8, folder: []const u8) !void {
    var workingFolder = try std.fs.openDirAbsolute(
        folder,
        .{ .iterate = true },
    );
    defer workingFolder.close();

    _ = workingFolder.rename(name, target) catch |err| {
        print("Error: {}\n", .{err});
        return err;
    };
}
