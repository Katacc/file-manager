const std = @import("std");
const file_manager = @import("file_manager");
const print = std.debug.print;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(gpa_allocator);
    defer std.process.argsFree(gpa_allocator, args);

    var starting_folder: []const u8 = ".";
    var working_folder: []const u8 = "";

    if (args.len > 1) {
        starting_folder = args[1];
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path: []const u8 = try std.fs.cwd().realpathAlloc(alloc, starting_folder);

    var working_path = try alloc.dupe(u8, path);
    const out = std.fs.File.stdout();

    while (true) {
        working_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ working_path, working_folder });
        working_folder = "";

        var currentFolder = try std.fs.openDirAbsolute(
            working_path,
            .{ .iterate = true },
        );
        defer currentFolder.close();
        try currentFolder.setAsCwd();
        working_path = try std.fs.cwd().realpathAlloc(alloc, ".");

        print("\npath: {s}\n", .{working_path});

        try out.writeAll("File manager!\n");

        try listContents(working_path);

        var stdin_buffer: [1024]u8 = undefined;
        var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);

        try out.writeAll("\n1(a). Add a file\n");
        try out.writeAll("2(d). Delete a file\n");
        try out.writeAll("3(r). Move a file\n");
        try out.writeAll(": ");
        var user_input = try stdin_reader.interface.takeDelimiterExclusive('\n');
        var trimmed = std.mem.trim(u8, user_input, &std.ascii.whitespace);

        if (trimmed.len > 0) {
            if (std.mem.eql(u8, trimmed, "1") or std.mem.eql(u8, trimmed, "a")) {
                try out.writeAll("File to add: ");

                // Discard the buffer
                try stdin_reader.interface.discardAll(1);

                user_input = try stdin_reader.interface.takeDelimiterExclusive('\n');
                trimmed = std.mem.trim(u8, user_input, &std.ascii.whitespace);

                const file_name = try gpa_allocator.dupe(u8, trimmed);
                defer gpa_allocator.free(file_name);

                addFile(file_name, working_path) catch {
                    return;
                };

                print("Succesfully created: {s}\n", .{trimmed});
            } else if (std.mem.eql(u8, trimmed, "2") or std.mem.eql(u8, trimmed, "d")) {
                try out.writeAll("File to remove: ");

                try stdin_reader.interface.discardAll(1);

                user_input = try stdin_reader.interface.takeDelimiterExclusive('\n');
                trimmed = std.mem.trim(u8, user_input, &std.ascii.whitespace);

                // use allocator to copy the buffer to source_name
                const file_name = try gpa_allocator.dupe(u8, trimmed);
                defer gpa_allocator.free(file_name);

                delFile(file_name, working_path) catch {
                    return;
                };
                print("Succesfully deleted: {s}\n", .{trimmed});
            } else if (std.mem.eql(u8, trimmed, "3") or std.mem.eql(u8, trimmed, "r")) {
                try out.writeAll("File to rename: ");

                try stdin_reader.interface.discardAll(1);

                user_input = try stdin_reader.interface.takeDelimiterExclusive('\n');
                trimmed = std.mem.trim(u8, user_input, &std.ascii.whitespace);

                const source_name = try gpa_allocator.dupe(u8, trimmed);
                defer gpa_allocator.free(source_name);

                try out.writeAll("Rename to: ");
                try stdin_reader.interface.discardAll(1);

                const user_target = try stdin_reader.interface.takeDelimiterExclusive('\n');
                const trimmed_target = std.mem.trim(u8, user_target, &std.ascii.whitespace);

                moveFile(source_name, trimmed_target, working_path) catch {
                    return;
                };
                print("Succesfully renamed {s} - {s}\n", .{ source_name, trimmed_target });
            } else if (std.mem.eql(u8, trimmed, "cd")) {
                try stdin_reader.interface.discardAll(1);

                try out.writeAll("Folder: ");
                user_input = try stdin_reader.interface.takeDelimiterExclusive('\n');
                trimmed = std.mem.trim(u8, user_input, &std.ascii.whitespace);

                const file_name = try alloc.dupe(u8, trimmed);

                working_folder = file_name;
                try out.writeAll("\nDDebug!\n");
            } else if (std.mem.eql(u8, trimmed, "q")) {
                break;
            } else {
                try out.writeAll("Unknown command..\n");
            }
        }
    }
}

pub fn listContents(folder: []const u8) !void {
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
            print("File       {s}\n", .{entry.name});
        } else if (entry.kind == .directory) {
            print("Dir        {s}/\n", .{entry.name});
        } else {
            print("...        {s}\n", .{entry.name});
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
                print("Error: {}", .{dir_err});
                return dir_err;
            };
        } else {
            print("Error: {}", .{err});
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
                print("Error: {}", .{dir_err});
                return dir_err;
            };
        } else {
            print("Error: {}", .{err});
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
