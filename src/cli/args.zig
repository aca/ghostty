const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const ErrorList = @import("../config/ErrorList.zig");

// TODO:
//   - Only `--long=value` format is accepted. Do we want to allow
//     `--long value`? Not currently allowed.

// For trimming
const whitespace = " \t";

/// The base errors for arg parsing. Additional errors can be returned due
/// to type-specific parsing but these are always possible.
pub const Error = error{
    ValueRequired,
    InvalidField,
    InvalidValue,
};

/// Parse the command line arguments from iter into dst.
///
/// dst must be a struct. The fields and their types will be used to determine
/// the valid CLI flags. See the tests in this file as an example. For field
/// types that are structs, the struct can implement the `parseCLI` function
/// to do custom parsing.
///
/// If the destination type has a field "_arena" of type `?ArenaAllocator`,
/// an arena allocator will be created (or reused if set already) for any
/// allocations. Allocations are necessary for certain types, like `[]const u8`.
///
/// If the destination type has a field "_errors" of type "ErrorList" then
/// errors will be added to that list. In this case, the only error returned by
/// parse are allocation errors.
///
/// Note: If the arena is already non-null, then it will be used. In this
/// case, in the case of an error some memory might be leaked into the arena.
pub fn parse(comptime T: type, alloc: Allocator, dst: *T, iter: anytype) !void {
    const info = @typeInfo(T);
    assert(info == .Struct);

    // Make an arena for all our allocations if we support it. Otherwise,
    // use an allocator that always fails. If the arena is already set on
    // the config, then we reuse that. See memory note in parse docs.
    const arena_available = @hasField(T, "_arena");
    var arena_owned: bool = false;
    const arena_alloc = if (arena_available) arena: {
        // If the arena is unset, we create it. We mark that we own it
        // only so that we can clean it up on error.
        if (dst._arena == null) {
            dst._arena = ArenaAllocator.init(alloc);
            arena_owned = true;
        }

        break :arena dst._arena.?.allocator();
    } else fail: {
        // Note: this is... not safe...
        var fail = std.testing.FailingAllocator.init(alloc, .{});
        break :fail fail.allocator();
    };
    errdefer if (arena_available and arena_owned) {
        dst._arena.?.deinit();
        dst._arena = null;
    };

    while (iter.next()) |arg| {
        // Do manual parsing if we have a hook for it.
        if (@hasDecl(T, "parseManuallyHook")) {
            if (!try dst.parseManuallyHook(arena_alloc, arg, iter)) return;
        }

        // If the destination supports help then we check for it, call
        // the help function and return.
        if (@hasDecl(T, "help")) {
            if (mem.eql(u8, arg, "--help") or
                mem.eql(u8, arg, "-h"))
            {
                try dst.help();
                return;
            }
        }

        if (mem.startsWith(u8, arg, "--")) {
            var key: []const u8 = arg[2..];
            const value: ?[]const u8 = value: {
                // If the arg has "=" then the value is after the "=".
                if (mem.indexOf(u8, key, "=")) |idx| {
                    defer key = key[0..idx];
                    break :value key[idx + 1 ..];
                }

                break :value null;
            };

            parseIntoField(T, arena_alloc, dst, key, value) catch |err| {
                if (comptime !canTrackErrors(T)) return err;

                // The error set is dependent on comptime T, so we always add
                // an extra error so we can have the "else" below.
                const ErrSet = @TypeOf(err) || error{Unknown};
                switch (@as(ErrSet, @errorCast(err))) {
                    // OOM is not recoverable since we need to allocate to
                    // track more error messages.
                    error.OutOfMemory => return err,

                    error.InvalidField => try dst._errors.add(arena_alloc, .{
                        .message = try std.fmt.allocPrintZ(
                            arena_alloc,
                            "{s}: unknown field",
                            .{key},
                        ),
                    }),

                    error.ValueRequired => try dst._errors.add(arena_alloc, .{
                        .message = try std.fmt.allocPrintZ(
                            arena_alloc,
                            "{s}: value required",
                            .{key},
                        ),
                    }),

                    error.InvalidValue => try dst._errors.add(arena_alloc, .{
                        .message = try std.fmt.allocPrintZ(
                            arena_alloc,
                            "{s}: invalid value",
                            .{key},
                        ),
                    }),

                    else => try dst._errors.add(arena_alloc, .{
                        .message = try std.fmt.allocPrintZ(
                            arena_alloc,
                            "{s}: unknown error {}",
                            .{ key, err },
                        ),
                    }),
                }
            };
        }
    }
}

/// Returns true if this type can track errors.
fn canTrackErrors(comptime T: type) bool {
    return @hasField(T, "_errors");
}

/// Parse a single key/value pair into the destination type T.
///
/// This may result in allocations. The allocations can only be freed by freeing
/// all the memory associated with alloc. It is expected that alloc points to
/// an arena.
fn parseIntoField(
    comptime T: type,
    alloc: Allocator,
    dst: *T,
    key: []const u8,
    value: ?[]const u8,
) !void {
    const info = @typeInfo(T);
    assert(info == .Struct);

    inline for (info.Struct.fields) |field| {
        if (field.name[0] != '_' and mem.eql(u8, field.name, key)) {
            // If the value is empty string (set but empty string),
            // then we reset the value to the default.
            if (value) |v| default: {
                if (v.len != 0) break :default;
                const raw = field.default_value orelse break :default;
                const ptr: *const field.type = @alignCast(@ptrCast(raw));
                @field(dst, field.name) = ptr.*;
                return;
            }

            // For optional fields, we just treat it as the child type.
            // This lets optional fields default to null but get set by
            // the CLI.
            const Field = switch (@typeInfo(field.type)) {
                .Optional => |opt| opt.child,
                else => field.type,
            };

            // If we are a type that can have decls and have a parseCLI decl,
            // we call that and use that to set the value.
            const fieldInfo = @typeInfo(Field);
            if (fieldInfo == .Struct or fieldInfo == .Union or fieldInfo == .Enum) {
                if (@hasDecl(Field, "parseCLI")) {
                    const fnInfo = @typeInfo(@TypeOf(Field.parseCLI)).Fn;
                    switch (fnInfo.params.len) {
                        // 1 arg = (input) => output
                        1 => @field(dst, field.name) = try Field.parseCLI(value),

                        // 2 arg = (self, input) => void
                        2 => try @field(dst, field.name).parseCLI(value),

                        // 3 arg = (self, alloc, input) => void
                        3 => try @field(dst, field.name).parseCLI(alloc, value),

                        // 4 arg = (self, alloc, errors, input) => void
                        4 => if (comptime canTrackErrors(T)) {
                            try @field(dst, field.name).parseCLI(alloc, &dst._errors, value);
                        } else {
                            var list: ErrorList = .{};
                            try @field(dst, field.name).parseCLI(alloc, &list, value);
                            if (!list.empty()) return error.InvalidValue;
                        },

                        else => @compileError("parseCLI invalid argument count"),
                    }

                    return;
                }
            }

            // No parseCLI, magic the value based on the type
            @field(dst, field.name) = switch (Field) {
                []const u8 => value: {
                    const slice = value orelse return error.ValueRequired;
                    const buf = try alloc.alloc(u8, slice.len);
                    @memcpy(buf, slice);
                    break :value buf;
                },

                [:0]const u8 => value: {
                    const slice = value orelse return error.ValueRequired;
                    const buf = try alloc.allocSentinel(u8, slice.len, 0);
                    @memcpy(buf, slice);
                    buf[slice.len] = 0;
                    break :value buf;
                },

                bool => try parseBool(value orelse "t"),

                inline u8,
                u16,
                u32,
                u64,
                usize,
                i8,
                i16,
                i32,
                i64,
                isize,
                => |Int| std.fmt.parseInt(
                    Int,
                    value orelse return error.ValueRequired,
                    0,
                ) catch return error.InvalidValue,

                f64 => std.fmt.parseFloat(
                    f64,
                    value orelse return error.ValueRequired,
                ) catch return error.InvalidValue,

                else => switch (fieldInfo) {
                    .Enum => std.meta.stringToEnum(
                        Field,
                        value orelse return error.ValueRequired,
                    ) orelse return error.InvalidValue,

                    .Struct => try parsePackedStruct(
                        Field,
                        value orelse return error.ValueRequired,
                    ),

                    else => unreachable,
                },
            };

            return;
        }
    }

    return error.InvalidField;
}

fn parsePackedStruct(comptime T: type, v: []const u8) !T {
    const info = @typeInfo(T).Struct;
    assert(info.layout == .@"packed");

    var result: T = .{};

    // We split each value by ","
    var iter = std.mem.splitSequence(u8, v, ",");
    loop: while (iter.next()) |part_raw| {
        // Determine the field we're looking for and the value. If the
        // field is prefixed with "no-" then we set the value to false.
        const part, const value = part: {
            const negation_prefix = "no-";
            const trimmed = std.mem.trim(u8, part_raw, whitespace);
            if (std.mem.startsWith(u8, trimmed, negation_prefix)) {
                break :part .{ trimmed[negation_prefix.len..], false };
            } else {
                break :part .{ trimmed, true };
            }
        };

        inline for (info.fields) |field| {
            assert(field.type == bool);
            if (std.mem.eql(u8, field.name, part)) {
                @field(result, field.name) = value;
                continue :loop;
            }
        }

        // No field matched
        return error.InvalidValue;
    }

    return result;
}

fn parseBool(v: []const u8) !bool {
    const t = &[_][]const u8{ "1", "t", "T", "true" };
    const f = &[_][]const u8{ "0", "f", "F", "false" };

    inline for (t) |str| {
        if (mem.eql(u8, v, str)) return true;
    }
    inline for (f) |str| {
        if (mem.eql(u8, v, str)) return false;
    }

    return error.InvalidValue;
}

test "parse: simple" {
    const testing = std.testing;

    var data: struct {
        a: []const u8 = "",
        b: bool = false,
        @"b-f": bool = true,

        _arena: ?ArenaAllocator = null,
    } = .{};
    defer if (data._arena) |arena| arena.deinit();

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "--a=42 --b --b-f=false",
    );
    defer iter.deinit();
    try parse(@TypeOf(data), testing.allocator, &data, &iter);
    try testing.expect(data._arena != null);
    try testing.expectEqualStrings("42", data.a);
    try testing.expect(data.b);
    try testing.expect(!data.@"b-f");

    // Reparsing works
    var iter2 = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "--a=84",
    );
    defer iter2.deinit();
    try parse(@TypeOf(data), testing.allocator, &data, &iter2);
    try testing.expect(data._arena != null);
    try testing.expectEqualStrings("84", data.a);
    try testing.expect(data.b);
    try testing.expect(!data.@"b-f");
}

test "parse: quoted value" {
    const testing = std.testing;

    var data: struct {
        a: u8 = 0,
        b: []const u8 = "",
        _arena: ?ArenaAllocator = null,
    } = .{};
    defer if (data._arena) |arena| arena.deinit();

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "--a=\"42\" --b=\"hello!\"",
    );
    defer iter.deinit();
    try parse(@TypeOf(data), testing.allocator, &data, &iter);
    try testing.expectEqual(@as(u8, 42), data.a);
    try testing.expectEqualStrings("hello!", data.b);
}

test "parse: empty value resets to default" {
    const testing = std.testing;

    var data: struct {
        a: u8 = 42,
        b: bool = false,
        _arena: ?ArenaAllocator = null,
    } = .{};
    defer if (data._arena) |arena| arena.deinit();

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "--a= --b=",
    );
    defer iter.deinit();
    try parse(@TypeOf(data), testing.allocator, &data, &iter);
    try testing.expectEqual(@as(u8, 42), data.a);
    try testing.expect(!data.b);
}

test "parse: error tracking" {
    const testing = std.testing;

    var data: struct {
        a: []const u8 = "",
        b: enum { one } = .one,

        _arena: ?ArenaAllocator = null,
        _errors: ErrorList = .{},
    } = .{};
    defer if (data._arena) |arena| arena.deinit();

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "--what --a=42",
    );
    defer iter.deinit();
    try parse(@TypeOf(data), testing.allocator, &data, &iter);
    try testing.expect(data._arena != null);
    try testing.expectEqualStrings("42", data.a);
    try testing.expect(!data._errors.empty());
}

test "parseIntoField: ignore underscore-prefixed fields" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        _a: []const u8 = "12",
    } = .{};

    try testing.expectError(
        error.InvalidField,
        parseIntoField(@TypeOf(data), alloc, &data, "_a", "42"),
    );
    try testing.expectEqualStrings("12", data._a);
}

test "parseIntoField: string" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        a: []const u8,
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "a", "42");
    try testing.expectEqualStrings("42", data.a);
}

test "parseIntoField: sentinel string" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        a: [:0]const u8,
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "a", "42");
    try testing.expectEqualStrings("42", data.a);
    try testing.expectEqual(@as(u8, 0), data.a[data.a.len]);
}

test "parseIntoField: bool" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        a: bool,
    } = undefined;

    // True
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "1");
    try testing.expectEqual(true, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "t");
    try testing.expectEqual(true, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "T");
    try testing.expectEqual(true, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "true");
    try testing.expectEqual(true, data.a);

    // False
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "0");
    try testing.expectEqual(false, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "f");
    try testing.expectEqual(false, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "F");
    try testing.expectEqual(false, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "false");
    try testing.expectEqual(false, data.a);
}

test "parseIntoField: unsigned numbers" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        u8: u8,
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "u8", "1");
    try testing.expectEqual(@as(u8, 1), data.u8);
}

test "parseIntoField: floats" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        f64: f64,
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "f64", "1");
    try testing.expectEqual(@as(f64, 1.0), data.f64);
}

test "parseIntoField: enums" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Enum = enum { one, two, three };
    var data: struct {
        v: Enum,
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "v", "two");
    try testing.expectEqual(Enum.two, data.v);
}

test "parseIntoField: packed struct" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Field = packed struct {
        a: bool = false,
        b: bool = true,
    };
    var data: struct {
        v: Field,
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "v", "b");
    try testing.expect(!data.v.a);
    try testing.expect(data.v.b);
}

test "parseIntoField: packed struct negation" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Field = packed struct {
        a: bool = false,
        b: bool = true,
    };
    var data: struct {
        v: Field,
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "v", "a,no-b");
    try testing.expect(data.v.a);
    try testing.expect(!data.v.b);
}

test "parseIntoField: packed struct whitespace" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Field = packed struct {
        a: bool = false,
        b: bool = true,
    };
    var data: struct {
        v: Field,
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "v", " a, no-b ");
    try testing.expect(data.v.a);
    try testing.expect(!data.v.b);
}

test "parseIntoField: optional field" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        a: ?bool = null,
    } = .{};

    // True
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "1");
    try testing.expectEqual(true, data.a.?);

    // Unset
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "");
    try testing.expect(data.a == null);
}

test "parseIntoField: struct with parse func" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        a: struct {
            const Self = @This();

            v: []const u8,

            pub fn parseCLI(value: ?[]const u8) !Self {
                _ = value;
                return Self{ .v = "HELLO!" };
            }
        },
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "a", "42");
    try testing.expectEqual(@as([]const u8, "HELLO!"), data.a.v);
}

test "parseIntoField: struct with parse func with error tracking" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        a: struct {
            const Self = @This();

            pub fn parseCLI(
                _: Self,
                parse_alloc: Allocator,
                errors: *ErrorList,
                value: ?[]const u8,
            ) !void {
                _ = value;
                try errors.add(parse_alloc, .{ .message = "OH NO!" });
            }
        } = .{},

        _errors: ErrorList = .{},
    } = .{};

    try parseIntoField(@TypeOf(data), alloc, &data, "a", "42");
    try testing.expect(!data._errors.empty());
}

test "parseIntoField: struct with parse func with unsupported error tracking" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        a: struct {
            const Self = @This();

            pub fn parseCLI(
                _: Self,
                parse_alloc: Allocator,
                errors: *ErrorList,
                value: ?[]const u8,
            ) !void {
                _ = value;
                try errors.add(parse_alloc, .{ .message = "OH NO!" });
            }
        } = .{},
    } = .{};

    try testing.expectError(
        error.InvalidValue,
        parseIntoField(@TypeOf(data), alloc, &data, "a", "42"),
    );
}

/// Returns an iterator (implements "next") that reads CLI args by line.
/// Each CLI arg is expected to be a single line. This is used to implement
/// configuration files.
pub fn LineIterator(comptime ReaderType: type) type {
    return struct {
        const Self = @This();

        /// The maximum size a single line can be. We don't expect any
        /// CLI arg to exceed this size. Can't wait to git blame this in
        /// like 4 years and be wrong about this.
        pub const MAX_LINE_SIZE = 4096;

        r: ReaderType,
        entry: [MAX_LINE_SIZE]u8 = [_]u8{ '-', '-' } ++ ([_]u8{0} ** (MAX_LINE_SIZE - 2)),

        pub fn next(self: *Self) ?[]const u8 {
            // TODO: detect "--" prefixed lines and give a friendlier error
            const buf = buf: {
                while (true) {
                    // Read the full line
                    var entry = self.r.readUntilDelimiterOrEof(self.entry[2..], '\n') catch {
                        // TODO: handle errors
                        unreachable;
                    } orelse return null;

                    // Trim any whitespace (including CR) around it
                    const trim = std.mem.trim(u8, entry, whitespace ++ "\r");
                    if (trim.len != entry.len) {
                        std.mem.copyForwards(u8, entry, trim);
                        entry = entry[0..trim.len];
                    }

                    // Ignore blank lines and comments
                    if (entry.len == 0 or entry[0] == '#') continue;

                    // Trim spaces around '='
                    if (mem.indexOf(u8, entry, "=")) |idx| {
                        const key = std.mem.trim(u8, entry[0..idx], whitespace);
                        const value = value: {
                            var value = std.mem.trim(u8, entry[idx + 1 ..], whitespace);

                            // Detect a quoted string.
                            if (value.len >= 2 and
                                value[0] == '"' and
                                value[value.len - 1] == '"')
                            {
                                // Trim quotes since our CLI args processor expects
                                // quotes to already be gone.
                                value = value[1 .. value.len - 1];
                            }

                            break :value value;
                        };

                        const len = key.len + value.len + 1;
                        if (entry.len != len) {
                            std.mem.copyForwards(u8, entry, key);
                            entry[key.len] = '=';
                            std.mem.copyForwards(u8, entry[key.len + 1 ..], value);
                            entry = entry[0..len];
                        }
                    }

                    break :buf entry;
                }
            };

            // We need to reslice so that we include our '--' at the beginning
            // of our buffer so that we can trick the CLI parser to treat it
            // as CLI args.
            return self.entry[0 .. buf.len + 2];
        }
    };
}

// Constructs a LineIterator (see docs for that).
pub fn lineIterator(reader: anytype) LineIterator(@TypeOf(reader)) {
    return .{ .r = reader };
}

/// An iterator valid for arg parsing from a slice.
pub const SliceIterator = struct {
    const Self = @This();

    slice: []const []const u8,
    idx: usize = 0,

    pub fn next(self: *Self) ?[]const u8 {
        if (self.idx >= self.slice.len) return null;
        defer self.idx += 1;
        return self.slice[self.idx];
    }
};

/// Construct a SliceIterator from a slice.
pub fn sliceIterator(slice: []const []const u8) SliceIterator {
    return .{ .slice = slice };
}

test "LineIterator" {
    const testing = std.testing;
    var fbs = std.io.fixedBufferStream(
        \\A
        \\B=42
        \\C
        \\
        \\# A comment
        \\D
        \\
        \\  # An indented comment
        \\  E
        \\
        \\# A quoted string with whitespace
        \\F=  "value "
    );

    var iter = lineIterator(fbs.reader());
    try testing.expectEqualStrings("--A", iter.next().?);
    try testing.expectEqualStrings("--B=42", iter.next().?);
    try testing.expectEqualStrings("--C", iter.next().?);
    try testing.expectEqualStrings("--D", iter.next().?);
    try testing.expectEqualStrings("--E", iter.next().?);
    try testing.expectEqualStrings("--F=value ", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}

test "LineIterator end in newline" {
    const testing = std.testing;
    var fbs = std.io.fixedBufferStream("A\n\n");

    var iter = lineIterator(fbs.reader());
    try testing.expectEqualStrings("--A", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}

test "LineIterator spaces around '='" {
    const testing = std.testing;
    var fbs = std.io.fixedBufferStream("A = B\n\n");

    var iter = lineIterator(fbs.reader());
    try testing.expectEqualStrings("--A=B", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}

test "LineIterator no value" {
    const testing = std.testing;
    var fbs = std.io.fixedBufferStream("A = \n\n");

    var iter = lineIterator(fbs.reader());
    try testing.expectEqualStrings("--A=", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}

test "LineIterator with CRLF line endings" {
    const testing = std.testing;
    var fbs = std.io.fixedBufferStream("A\r\nB = C\r\n");

    var iter = lineIterator(fbs.reader());
    try testing.expectEqualStrings("--A", iter.next().?);
    try testing.expectEqualStrings("--B=C", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}
