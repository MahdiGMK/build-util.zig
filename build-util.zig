const std = @import("std");
const Alloc = std.mem.Allocator;
const Dir = std.fs.Dir;
const File = std.fs.File;
const Build = std.Build;
const Step = std.Build.Step;
const Compile = Step.Compile;
const LazyPath = Build.LazyPath;

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

pub const ProtoC = struct {
    step: Step,
    protoc_cmd: ?LazyPath,
    root_directory: LazyPath,
    depth: usize,
    out_langs: OutLangs,
    // cpp_out_dir: ?LazyPath, // TODO: add support for custom paths
    const OutLangs = packed struct {
        cpp_out: bool,
        const CPP = @This(){ .cpp_out = true };
    };
    const Options = struct { root_directory: LazyPath, depth: ?usize = null, protoc_cmd: ?LazyPath = null, out_langs: OutLangs = .CPP };
    pub fn create(owner: *std.Build, options: Options) *ProtoC {
        const res = owner.allocator.create(ProtoC) catch @panic("OOM");
        res.* = ProtoC{
            .root_directory = options.root_directory,
            .depth = options.depth orelse 128,
            .protoc_cmd = options.protoc_cmd,
            .out_langs = options.out_langs,
            .step = Step.init(.{
                .id = .custom,
                .owner = owner,
                .name = "ProtoC",
                .makeFn = ProtoC.makeFn,
            }),
        };
        return res;
    }
    fn makeFn(step: *Step, mk_opt: std.Build.Step.MakeOptions) anyerror!void {
        const self: *ProtoC = @fieldParentPtr("step", step);
        const dirpath = self.root_directory.getPath3(step.owner, &self.step);
        const protofiles = try listFilesRecursive(
            step.owner.allocator,
            self.depth,
            try dirpath.root_dir.handle.openDir("./", .{ .iterate = true }),
            ".proto",
        );

        const node = mk_opt.progress_node.start("protoc", protofiles.len);
        defer node.end();

        for (protofiles) |file| {
            defer node.completeOne();

            const cwd = try dirpath.root_dir.handle.realpathAlloc(step.owner.allocator, "./");
            const protoc_cmd =
                if (self.protoc_cmd) |cmd| blk: {
                    const path = cmd.getPath3(step.owner, step);
                    break :blk try path.root_dir.handle.realpathAlloc(step.owner.allocator, path.sub_path);
                } else "protoc";

            var argv = std.ArrayList([]const u8).empty;
            try argv.appendSlice(step.owner.allocator, &.{ protoc_cmd, file });
            defer argv.deinit(step.owner.allocator);

            if (self.out_langs.cpp_out)
                try argv.append(step.owner.allocator, "--cpp_out=./"); // TODO: add support for custom paths

            try step.handleChildProcUnsupported(cwd, argv.items);
            const res = try std.process.Child.run(.{
                .allocator = step.owner.allocator,
                .argv = argv.items,
                .cwd = cwd,
                .progress_node = node,
            });
            step.handleChildProcessTerm(res.term, cwd, argv.items) catch |e| {
                switch (e) {
                    error.MakeFailed => try step.addError(
                        \\protoc command failed :
                        \\{s}
                    , .{res.stderr}),
                    else => {},
                }
                return e;
            };
        }
    }
};
