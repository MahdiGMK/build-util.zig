const std = @import("std");
const Alloc = std.mem.Allocator;
const Dir = std.fs.Dir;
const File = std.fs.File;
const Build = std.Build;

pub fn listDir(alloc: Alloc, root: Dir, suffix: []const u8, dirent_kind: File.Kind) ![]const []const u8 {
    var iter = root.iterate();
    var arr = std.ArrayList([]const u8).empty;
    while (try iter.next()) |dirent| {
        if (dirent.kind == dirent_kind and
            std.mem.endsWith(u8, dirent.name, suffix))
        {
            try arr.append(alloc, try alloc.dupe(u8, dirent.name));
        }
    }
    return try arr.toOwnedSlice(alloc);
}
pub fn listFilesRecursive(alloc: Alloc, max_depth: usize, root: Dir, suffix: []const u8) ![]const []const u8 {
    var arena_base = std.heap.ArenaAllocator.init(alloc);
    defer arena_base.deinit();
    const arena = arena_base.allocator();

    var arr = std.ArrayList([]const u8).empty;

    { // curdir
        const fils = try listDir(alloc, root, suffix, .file);
        defer alloc.free(fils);

        for (fils) |fil| try arr.append(alloc, fil);
    }

    // subdirs
    if (max_depth > 0) {
        for (try listDir(arena, root, "", .directory)) |dirname| {
            var subdir = try root.openDir(dirname, .{ .iterate = true });
            defer subdir.close();

            const rec = try listFilesRecursive(arena, max_depth - 1, subdir, suffix);
            for (rec) |fil|
                try arr.append(alloc, try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dirname, fil }));
        }
    }

    return arr.toOwnedSlice(alloc);
}
