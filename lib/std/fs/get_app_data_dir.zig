// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
const std = @import("../std.zig");
const builtin = @import("builtin");
const unicode = std.unicode;
const mem = std.mem;
const fs = std.fs;
const os = std.os;

pub const GetAppDataDirError = error{
    OutOfMemory,
    AppDataDirUnavailable,
};

const HomeDirError = error{
    /// Couldn't determine user information
    UserInfoUnavailable,
    /// Couldn't parse /etc/passwd
    EtcPasswdUnreadable,
    /// No matching user was found in /etc/passwd
    UserNotFound,
    OutOfMemory,
};
fn homeDirFromPasswd(allocator: *mem.Allocator) HomeDirError![]u8 {
    const user = os.getenv("USER");
    const uid = if (builtin.os.tag == .linux) os.linux.getuid() else null;
    if (user == null and uid == null) return error.UserInfoUnavailable;
    var passwdFile = fs.openFileAbsolute("/etc/passwd", .{}) catch return error.EtcPasswdUnreadable;
    defer passwdFile.close();
    const r = passwdFile.reader();

    while (try r.readUntilDelimiterAlloc(allocator, '\n')) |line| : (allocator.free(line)) {
        errdefer allocator.free(line);
        var fields = mem.split(line, ":");
        const login = fields.next() orelse return error.EtcPasswdUnreadable;
        if (user != null and !mem.eql(u8, user.?, login)) continue;
        _ = fields.next() orelse return error.EtcPasswdUnreadable; // password
        const uid_str = fields.next() orelse return error.EtcPasswdUnreadable;
        const line_uid = fmt.parseInt(u32, uid_str, 10) catch return error.EtcPasswdUnreadable;
        if (uid != null and uid.? != line_uid) continue;
        // we've now definitely found the right line
        _ = fields.next() orelse return error.EtcPasswdUnreadable; // group id
        _ = fields.next() orelse return error.EtcPasswdUnreadable; // user name/comment
        return fields.next() orelse return error.EtcPasswdUnreadable;
    } else return error.UserNotFound;
}

/// Caller owns returned memory.
/// TODO determine if we can remove the allocator requirement
pub fn getAppDataDir(allocator: *mem.Allocator, appname: []const u8) GetAppDataDirError![]u8 {
    switch (builtin.os.tag) {
        .windows => {
            var dir_path_ptr: [*:0]u16 = undefined;
            switch (os.windows.shell32.SHGetKnownFolderPath(
                &os.windows.FOLDERID_LocalAppData,
                os.windows.KF_FLAG_CREATE,
                null,
                &dir_path_ptr,
            )) {
                os.windows.S_OK => {
                    defer os.windows.ole32.CoTaskMemFree(@ptrCast(*c_void, dir_path_ptr));
                    const global_dir = unicode.utf16leToUtf8Alloc(allocator, mem.spanZ(dir_path_ptr)) catch |err| switch (err) {
                        error.UnexpectedSecondSurrogateHalf => return error.AppDataDirUnavailable,
                        error.ExpectedSecondSurrogateHalf => return error.AppDataDirUnavailable,
                        error.DanglingSurrogateHalf => return error.AppDataDirUnavailable,
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                    defer allocator.free(global_dir);
                    return fs.path.join(allocator, &[_][]const u8{ global_dir, appname });
                },
                os.windows.E_OUTOFMEMORY => return error.OutOfMemory,
                else => return error.AppDataDirUnavailable,
            }
        },
        .macos => {
            // XXX we need to free if homeDirFromPasswd is used (but not if getenv succeeded)
            const home_dir = os.getenv("HOME") orelse homeDirFromPasswd(allocator) catch return error.AppDataDirUnavailable;
            return fs.path.join(allocator, &[_][]const u8{ home_dir, "Library", "Application Support", appname });
        },
        .linux, .freebsd, .netbsd, .dragonfly, .openbsd => {
            // XXX need to free as above
            const home_dir = os.getenv("HOME") orelse homeDirFromPasswd(allocator) catch return error.AppDataDirUnavailable;
            return fs.path.join(allocator, &[_][]const u8{ home_dir, ".local", "share", appname });
        },
        else => @compileError("Unsupported OS"),
    }
}

test "getAppDataDir" {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    // We can't actually validate the result
    const dir = getAppDataDir(std.testing.allocator, "zig") catch return;
    defer std.testing.allocator.free(dir);
}
