/// CodepointMap is a map of codepoints to a discovery descriptor of a font
/// to use for that codepoint. If the descriptor doesn't return any matching
/// font, the codepoint is rendered using the default font.
const CodepointMap = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const discovery = @import("discovery.zig");

pub const Entry = struct {
    /// Unicode codepoint range. Asserts range[0] <= range[1].
    range: [2]u21,

    /// The discovery descriptor of the font to use for this range.
    descriptor: discovery.Descriptor,
};

/// The list of entries. We use a multiarraylist because Descriptors are
/// quite large and we will very rarely match, so we'd rather pack our
/// ranges together to make everything more cache friendly for lookups.
///
/// Note: we just do a linear search because we expect to always have very
/// few entries, so the overhead of a binary search is not worth it. This is
/// possible to defeat with some pathological inputs, but there is no realistic
/// scenario where this will be a problem except people trying to fuck around.
list: std.MultiArrayList(Entry) = .{},

pub fn deinit(self: *CodepointMap, alloc: Allocator) void {
    self.list.deinit(alloc);
}

/// Add an entry to the map.
///
/// For conflicting codepoints, entries added later take priority over
/// entries added earlier.
pub fn add(self: *CodepointMap, alloc: Allocator, entry: Entry) !void {
    assert(entry.range[0] <= entry.range[1]);
    try self.list.append(alloc, entry);
}

/// Get a descriptor for a codepoint.
pub fn get(self: *const CodepointMap, cp: u21) ?discovery.Descriptor {
    const items = self.list.items(.range);
    for (items, 0..) |range, forward_i| {
        const i = items.len - forward_i - 1;
        if (range[0] <= cp and cp <= range[1]) {
            const descs = self.list.items(.descriptor);
            return descs[i];
        }
    }

    return null;
}

test "codepointmap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var m: CodepointMap = .{};
    defer m.deinit(alloc);

    // Exact range
    try testing.expect(m.get(1) == null);
    try m.add(alloc, .{ .range = .{ 1, 1 }, .descriptor = .{ .family = "A" } });
    {
        const d = m.get(1).?;
        try testing.expectEqualStrings("A", d.family.?);
    }

    // Later entry takes priority
    try m.add(alloc, .{ .range = .{ 1, 2 }, .descriptor = .{ .family = "B" } });
    {
        const d = m.get(1).?;
        try testing.expectEqualStrings("B", d.family.?);
    }

    // Non-matching
    try testing.expect(m.get(0) == null);
    try testing.expect(m.get(3) == null);
}
