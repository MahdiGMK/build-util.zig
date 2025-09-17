const std = @import("std");

const butil = @import("build-util.zig");
pub const listDir = butil.listDir;
pub const listFilesRecursive = butil.listFilesRecursive;

pub fn build(b: *std.Build) void {
    _ = b; // autofix
    @compileError("build-util is not meant to build! use it as library");
}
