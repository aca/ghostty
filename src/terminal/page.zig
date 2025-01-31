const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const assert = std.debug.assert;
const testing = std.testing;
const posix = std.posix;
const fastmem = @import("../fastmem.zig");
const color = @import("color.zig");
const sgr = @import("sgr.zig");
const style = @import("style.zig");
const size = @import("size.zig");
const getOffset = size.getOffset;
const Offset = size.Offset;
const OffsetBuf = size.OffsetBuf;
const BitmapAllocator = @import("bitmap_allocator.zig").BitmapAllocator;
const hash_map = @import("hash_map.zig");
const AutoOffsetHashMap = hash_map.AutoOffsetHashMap;
const alignForward = std.mem.alignForward;
const alignBackward = std.mem.alignBackward;

const log = std.log.scoped(.page);

/// The allocator to use for multi-codepoint grapheme data. We use
/// a chunk size of 4 codepoints. It'd be best to set this empirically
/// but it is currently set based on vibes. My thinking around 4 codepoints
/// is that most skin-tone emoji are <= 4 codepoints, letter combiners
/// are usually <= 4 codepoints, and 4 codepoints is a nice power of two
/// for alignment.
const grapheme_chunk_len = 4;
const grapheme_chunk = grapheme_chunk_len * @sizeOf(u21);
const GraphemeAlloc = BitmapAllocator(grapheme_chunk);
const grapheme_count_default = GraphemeAlloc.bitmap_bit_size;
const grapheme_bytes_default = grapheme_count_default * grapheme_chunk;
const GraphemeMap = AutoOffsetHashMap(Offset(Cell), Offset(u21).Slice);

/// A page represents a specific section of terminal screen. The primary
/// idea of a page is that it is a fully self-contained unit that can be
/// serialized, copied, etc. as a convenient way to represent a section
/// of the screen.
///
/// This property is useful for renderers which want to copy just the pages
/// for the visible portion of the screen, or for infinite scrollback where
/// we may want to serialize and store pages that are sufficiently far
/// away from the current viewport.
///
/// Pages are always backed by a single contiguous block of memory that is
/// aligned on a page boundary. This makes it easy and fast to copy pages
/// around. Within the contiguous block of memory, the contents of a page are
/// thoughtfully laid out to optimize primarily for terminal IO (VT streams)
/// and to minimize memory usage.
pub const Page = struct {
    comptime {
        // The alignment of our members. We want to ensure that the page
        // alignment is always divisible by this.
        assert(std.mem.page_size % @max(
            @alignOf(Row),
            @alignOf(Cell),
            style.Set.base_align,
        ) == 0);
    }

    /// The backing memory for the page. A page is always made up of a
    /// a single contiguous block of memory that is aligned on a page
    /// boundary and is a multiple of the system page size.
    memory: []align(std.mem.page_size) u8,

    /// The array of rows in the page. The rows are always in row order
    /// (i.e. index 0 is the top row, index 1 is the row below that, etc.)
    rows: Offset(Row),

    /// The array of cells in the page. The cells are NOT in row order,
    /// but they are in column order. To determine the mapping of cells
    /// to row, you must use the `rows` field. From the pointer to the
    /// first column, all cells in that row are laid out in column order.
    cells: Offset(Cell),

    /// The multi-codepoint grapheme data for this page. This is where
    /// any cell that has more than one codepoint will be stored. This is
    /// relatively rare (typically only emoji) so this defaults to a very small
    /// size and we force page realloc when it grows.
    grapheme_alloc: GraphemeAlloc,

    /// The mapping of cell to grapheme data. The exact mapping is the
    /// cell offset to the grapheme data offset. Therefore, whenever a
    /// cell is moved (i.e. `erase`) then the grapheme data must be updated.
    /// Grapheme data is relatively rare so this is considered a slow
    /// path.
    grapheme_map: GraphemeMap,

    /// The available set of styles in use on this page.
    styles: style.Set,

    /// The current dimensions of the page. The capacity may be larger
    /// than this. This allows us to allocate a larger page than necessary
    /// and also to resize a page smaller witout reallocating.
    size: Size,

    /// The capacity of this page. This is the full size of the backing
    /// memory and is fixed at page creation time.
    capacity: Capacity,

    /// If this is true then verifyIntegrity will do nothing. This is
    /// only present with runtime safety enabled.
    pause_integrity_checks: if (std.debug.runtime_safety) usize else void =
        if (std.debug.runtime_safety) 0 else {},

    /// Initialize a new page, allocating the required backing memory.
    /// The size of the initialized page defaults to the full capacity.
    ///
    /// The backing memory is always allocated using mmap directly.
    /// You cannot use custom allocators with this structure because
    /// it is critical to performance that we use mmap.
    pub fn init(cap: Capacity) !Page {
        const l = layout(cap);

        // We use mmap directly to avoid Zig allocator overhead
        // (small but meaningful for this path) and because a private
        // anonymous mmap is guaranteed on Linux and macOS to be zeroed,
        // which is a critical property for us.
        assert(l.total_size % std.mem.page_size == 0);
        const backing = try posix.mmap(
            null,
            l.total_size,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        errdefer posix.munmap(backing);

        const buf = OffsetBuf.init(backing);
        return initBuf(buf, l);
    }

    /// Initialize a new page using the given backing memory.
    /// It is up to the caller to not call deinit on these pages.
    pub fn initBuf(buf: OffsetBuf, l: Layout) Page {
        const cap = l.capacity;
        const rows = buf.member(Row, l.rows_start);
        const cells = buf.member(Cell, l.cells_start);

        // We need to go through and initialize all the rows so that
        // they point to a valid offset into the cells, since the rows
        // zero-initialized aren't valid.
        const cells_ptr = cells.ptr(buf)[0 .. cap.cols * cap.rows];
        for (rows.ptr(buf)[0..cap.rows], 0..) |*row, y| {
            const start = y * cap.cols;
            row.* = .{
                .cells = getOffset(Cell, buf, &cells_ptr[start]),
            };
        }

        return .{
            .memory = @alignCast(buf.start()[0..l.total_size]),
            .rows = rows,
            .cells = cells,
            .styles = style.Set.init(
                buf.add(l.styles_start),
                l.styles_layout,
            ),
            .grapheme_alloc = GraphemeAlloc.init(
                buf.add(l.grapheme_alloc_start),
                l.grapheme_alloc_layout,
            ),
            .grapheme_map = GraphemeMap.init(
                buf.add(l.grapheme_map_start),
                l.grapheme_map_layout,
            ),
            .size = .{ .cols = cap.cols, .rows = cap.rows },
            .capacity = cap,
        };
    }

    /// Deinitialize the page, freeing any backing memory. Do NOT call
    /// this if you allocated the backing memory yourself (i.e. you used
    /// initBuf).
    pub fn deinit(self: *Page) void {
        posix.munmap(self.memory);
        self.* = undefined;
    }

    /// Reinitialize the page with the same capacity.
    pub fn reinit(self: *Page) void {
        // We zero the page memory as u64 instead of u8 because
        // we can and it's empirically quite a bit faster.
        @memset(@as([*]u64, @ptrCast(self.memory))[0 .. self.memory.len / 8], 0);
        self.* = initBuf(OffsetBuf.init(self.memory), layout(self.capacity));
    }

    pub const IntegrityError = error{
        ZeroRowCount,
        ZeroColCount,
        UnmarkedGraphemeRow,
        MissingGraphemeData,
        InvalidGraphemeCount,
        MissingStyle,
        UnmarkedStyleRow,
        MismatchedStyleRef,
        InvalidStyleCount,
        InvalidSpacerTailLocation,
        InvalidSpacerHeadLocation,
        UnwrappedSpacerHead,
    };

    /// Temporarily pause integrity checks. This is useful when you are
    /// doing a lot of operations that would trigger integrity check
    /// violations but you know the page will end up in a consistent state.
    pub fn pauseIntegrityChecks(self: *Page, v: bool) void {
        if (comptime std.debug.runtime_safety) {
            if (v) {
                self.pause_integrity_checks += 1;
            } else {
                self.pause_integrity_checks -= 1;
            }
        }
    }

    /// A helper that can be used to assert the integrity of the page
    /// when runtime safety is enabled. This is a no-op when runtime
    /// safety is disabled. This uses the libc allocator.
    pub fn assertIntegrity(self: *Page) void {
        if (comptime std.debug.runtime_safety) {
            self.verifyIntegrity(std.heap.c_allocator) catch unreachable;
        }
    }

    /// Verifies the integrity of the page data. This is not fast,
    /// but it is useful for assertions, deserialization, etc. The
    /// allocator is only used for temporary allocations -- all memory
    /// is freed before this function returns.
    ///
    /// Integrity errors are also logged as warnings.
    pub fn verifyIntegrity(self: *Page, alloc_gpa: Allocator) !void {
        // Some things that seem like we should check but do not:
        //
        // - We do not check that the style ref count is exact, only that
        //   it is at least what we see. We do this because some fast paths
        //   trim rows without clearing data.
        // - We do not check that styles seen is exactly the same as the
        //   styles count in the page for the same reason as above.
        // - We only check that we saw less graphemes than the total memory
        //   used for the same reason as styles above.
        //

        if (comptime std.debug.runtime_safety) {
            if (self.pause_integrity_checks > 0) return;
        }

        if (self.size.rows == 0) {
            log.warn("page integrity violation zero row count", .{});
            return IntegrityError.ZeroRowCount;
        }
        if (self.size.cols == 0) {
            log.warn("page integrity violation zero col count", .{});
            return IntegrityError.ZeroColCount;
        }

        var arena = ArenaAllocator.init(alloc_gpa);
        defer arena.deinit();
        const alloc = arena.allocator();

        var graphemes_seen: usize = 0;
        var styles_seen = std.AutoHashMap(style.Id, usize).init(alloc);
        defer styles_seen.deinit();

        const rows = self.rows.ptr(self.memory)[0..self.size.rows];
        for (rows, 0..) |*row, y| {
            const graphemes_start = graphemes_seen;
            const cells = row.cells.ptr(self.memory)[0..self.size.cols];
            for (cells, 0..) |*cell, x| {
                if (cell.hasGrapheme()) {
                    // If a cell has grapheme data, it must be present in
                    // the grapheme map.
                    _ = self.lookupGrapheme(cell) orelse {
                        log.warn(
                            "page integrity violation y={} x={} grapheme data missing",
                            .{ y, x },
                        );
                        return IntegrityError.MissingGraphemeData;
                    };

                    graphemes_seen += 1;
                }

                if (cell.style_id != style.default_id) {
                    // If a cell has a style, it must be present in the styles
                    // set.
                    _ = self.styles.lookupId(
                        self.memory,
                        cell.style_id,
                    ) orelse {
                        log.warn(
                            "page integrity violation y={} x={} style missing id={}",
                            .{ y, x, cell.style_id },
                        );
                        return IntegrityError.MissingStyle;
                    };

                    if (!row.styled) {
                        log.warn(
                            "page integrity violation y={} x={} row not marked as styled",
                            .{ y, x },
                        );
                        return IntegrityError.UnmarkedStyleRow;
                    }

                    const gop = try styles_seen.getOrPut(cell.style_id);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                }

                switch (cell.wide) {
                    .narrow => {},
                    .wide => {},

                    .spacer_tail => {
                        // Spacer tails can't be at the start because they follow
                        // a wide char.
                        if (x == 0) {
                            log.warn(
                                "page integrity violation y={} x={} spacer tail at start",
                                .{ y, x },
                            );
                            return IntegrityError.InvalidSpacerTailLocation;
                        }

                        // Spacer tails must follow a wide char
                        const prev = cells[x - 1];
                        if (prev.wide != .wide) {
                            log.warn(
                                "page integrity violation y={} x={} spacer tail not following wide",
                                .{ y, x },
                            );
                            return IntegrityError.InvalidSpacerTailLocation;
                        }
                    },

                    .spacer_head => {
                        // Spacer heads must be at the end
                        if (x != self.size.cols - 1) {
                            log.warn(
                                "page integrity violation y={} x={} spacer head not at end",
                                .{ y, x },
                            );
                            return IntegrityError.InvalidSpacerHeadLocation;
                        }

                        // The row must be wrapped
                        if (!row.wrap) {
                            log.warn(
                                "page integrity violation y={} spacer head not wrapped",
                                .{y},
                            );
                            return IntegrityError.UnwrappedSpacerHead;
                        }
                    },
                }
            }

            // Check row grapheme data
            if (graphemes_seen > graphemes_start) {
                // If a cell in a row has grapheme data, the row must
                // be marked as having grapheme data.
                if (!row.grapheme) {
                    log.warn(
                        "page integrity violation y={} grapheme data but row not marked",
                        .{y},
                    );
                    return IntegrityError.UnmarkedGraphemeRow;
                }
            }
        }

        // Our graphemes seen should exactly match the grapheme count
        if (graphemes_seen > self.graphemeCount()) {
            log.warn(
                "page integrity violation grapheme count mismatch expected={} actual={}",
                .{ graphemes_seen, self.graphemeCount() },
            );
            return IntegrityError.InvalidGraphemeCount;
        }

        // Verify all our styles have the correct ref count.
        {
            var it = styles_seen.iterator();
            while (it.next()) |entry| {
                const style_val = self.styles.lookupId(self.memory, entry.key_ptr.*).?.*;
                const md = self.styles.upsert(self.memory, style_val) catch unreachable;
                if (md.ref < entry.value_ptr.*) {
                    log.warn(
                        "page integrity violation style ref count mismatch id={} expected={} actual={}",
                        .{ entry.key_ptr.*, entry.value_ptr.*, md.ref },
                    );
                    return IntegrityError.MismatchedStyleRef;
                }
            }
        }
    }

    /// Clone the contents of this page. This will allocate new memory
    /// using the page allocator. If you want to manage memory manually,
    /// use cloneBuf.
    pub fn clone(self: *const Page) !Page {
        const backing = try posix.mmap(
            null,
            self.memory.len,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        errdefer posix.munmap(backing);
        return self.cloneBuf(backing);
    }

    /// Clone the entire contents of this page.
    ///
    /// The buffer must be at least the size of self.memory.
    pub fn cloneBuf(self: *const Page, buf: []align(std.mem.page_size) u8) Page {
        assert(buf.len >= self.memory.len);

        // The entire concept behind a page is that everything is stored
        // as offsets so we can do a simple linear copy of the backing
        // memory and copy all the offsets and everything will work.
        var result = self.*;
        result.memory = buf[0..self.memory.len];

        // This is a memcpy. We may want to investigate if there are
        // faster ways to do this (i.e. copy-on-write tricks) but I suspect
        // they'll be slower. I haven't experimented though.
        // std.log.warn("copy bytes={}", .{self.memory.len});
        fastmem.copy(u8, result.memory, self.memory);

        return result;
    }

    pub const CloneFromError = Allocator.Error || style.Set.UpsertError;

    /// Clone the contents of another page into this page. The capacities
    /// can be different, but the size of the other page must fit into
    /// this page.
    ///
    /// The y_start and y_end parameters allow you to clone only a portion
    /// of the other page. This is useful for splitting a page into two
    /// or more pages.
    ///
    /// The column count of this page will always be the same as this page.
    /// If the other page has more columns, the extra columns will be
    /// truncated. If the other page has fewer columns, the extra columns
    /// will be zeroed.
    pub fn cloneFrom(
        self: *Page,
        other: *const Page,
        y_start: usize,
        y_end: usize,
    ) CloneFromError!void {
        assert(y_start <= y_end);
        assert(y_end <= other.size.rows);
        assert(y_end - y_start <= self.size.rows);

        const other_rows = other.rows.ptr(other.memory)[y_start..y_end];
        const rows = self.rows.ptr(self.memory)[0 .. y_end - y_start];
        for (rows, other_rows) |*dst_row, *src_row| try self.cloneRowFrom(
            other,
            dst_row,
            src_row,
        );

        // We should remain consistent
        self.assertIntegrity();
    }

    /// Clone a single row from another page into this page.
    pub fn cloneRowFrom(
        self: *Page,
        other: *const Page,
        dst_row: *Row,
        src_row: *const Row,
    ) CloneFromError!void {
        try self.clonePartialRowFrom(
            other,
            dst_row,
            src_row,
            0,
            self.size.cols,
        );
    }

    /// Clone a single row from another page into this page, supporting
    /// partial copy. cloneRowFrom calls this.
    pub fn clonePartialRowFrom(
        self: *Page,
        other: *const Page,
        dst_row: *Row,
        src_row: *const Row,
        x_start: usize,
        x_end_req: usize,
    ) CloneFromError!void {
        const cell_len = @min(self.size.cols, other.size.cols);
        const x_end = @min(x_end_req, cell_len);
        assert(x_start <= x_end);
        const other_cells = src_row.cells.ptr(other.memory)[x_start..x_end];
        const cells = dst_row.cells.ptr(self.memory)[x_start..x_end];

        // If our destination has styles or graphemes then we need to
        // clear some state.
        if (dst_row.grapheme or dst_row.styled) {
            self.clearCells(dst_row, x_start, x_end);
        }

        // Copy all the row metadata but keep our cells offset
        dst_row.* = copy: {
            var copy = src_row.*;

            // If we're not copying the full row then we want to preserve
            // some original state from our dst row.
            if ((x_end - x_start) < self.size.cols) {
                copy.wrap = dst_row.wrap;
                copy.wrap_continuation = dst_row.wrap_continuation;
                copy.grapheme = dst_row.grapheme;
                copy.styled = dst_row.styled;
            }

            // Our cell offset remains the same
            copy.cells = dst_row.cells;

            break :copy copy;
        };

        // If we have no managed memory in the source, then we can just
        // copy it directly.
        if (!src_row.grapheme and !src_row.styled) {
            fastmem.copy(Cell, cells, other_cells);
        } else {
            // We have managed memory, so we have to do a slower copy to
            // get all of that right.
            for (cells, other_cells) |*dst_cell, *src_cell| {
                dst_cell.* = src_cell.*;
                if (src_cell.hasGrapheme()) {
                    // To prevent integrity checks flipping
                    if (comptime std.debug.runtime_safety) dst_cell.style_id = style.default_id;

                    dst_cell.content_tag = .codepoint; // required for appendGrapheme
                    const cps = other.lookupGrapheme(src_cell).?;
                    for (cps) |cp| try self.appendGrapheme(dst_row, dst_cell, cp);
                }
                if (src_cell.style_id != style.default_id) {
                    const other_style = other.styles.lookupId(other.memory, src_cell.style_id).?.*;
                    const md = try self.styles.upsert(self.memory, other_style);
                    md.ref += 1;
                    dst_cell.style_id = md.id;
                    dst_row.styled = true;
                }
            }
        }

        // If we are growing columns, then we need to ensure spacer heads
        // are cleared.
        if (self.size.cols > other.size.cols) {
            const last = &cells[other.size.cols - 1];
            if (last.wide == .spacer_head) {
                last.wide = .narrow;
            }
        }

        // The final page should remain consistent
        self.assertIntegrity();
    }

    /// Get a single row. y must be valid.
    pub fn getRow(self: *const Page, y: usize) *Row {
        assert(y < self.size.rows);
        return &self.rows.ptr(self.memory)[y];
    }

    /// Get the cells for a row.
    pub fn getCells(self: *const Page, row: *Row) []Cell {
        if (comptime std.debug.runtime_safety) {
            const rows = self.rows.ptr(self.memory);
            const cells = self.cells.ptr(self.memory);
            assert(@intFromPtr(row) >= @intFromPtr(rows));
            assert(@intFromPtr(row) < @intFromPtr(cells));
        }

        const cells = row.cells.ptr(self.memory);
        return cells[0..self.size.cols];
    }

    /// Get the row and cell for the given X/Y within this page.
    pub fn getRowAndCell(self: *const Page, x: usize, y: usize) struct {
        row: *Row,
        cell: *Cell,
    } {
        assert(y < self.size.rows);
        assert(x < self.size.cols);

        const rows = self.rows.ptr(self.memory);
        const row = &rows[y];
        const cell = &row.cells.ptr(self.memory)[x];

        return .{ .row = row, .cell = cell };
    }

    /// Move a cell from one location to another. This will replace the
    /// previous contents with a blank cell. Because this is a move, this
    /// doesn't allocate and can't fail.
    pub fn moveCells(
        self: *Page,
        src_row: *Row,
        src_left: usize,
        dst_row: *Row,
        dst_left: usize,
        len: usize,
    ) void {
        defer self.assertIntegrity();

        const src_cells = src_row.cells.ptr(self.memory)[src_left .. src_left + len];
        const dst_cells = dst_row.cells.ptr(self.memory)[dst_left .. dst_left + len];

        // Clear our destination now matter what
        self.clearCells(dst_row, dst_left, dst_left + len);

        // If src has no graphemes, this is very fast because we can
        // just copy the cells directly because every other attribute
        // is position-independent.
        const src_grapheme = src_row.grapheme or grapheme: {
            for (src_cells) |c| if (c.hasGrapheme()) break :grapheme true;
            break :grapheme false;
        };
        if (!src_grapheme) {
            fastmem.copy(Cell, dst_cells, src_cells);
        } else {
            // Source has graphemes, meaning we have to do a slower
            // cell by cell copy.
            for (src_cells, dst_cells) |*src, *dst| {
                dst.* = src.*;
                if (!src.hasGrapheme()) continue;

                // Required for moveGrapheme assertions
                dst.content_tag = .codepoint;
                self.moveGrapheme(src, dst);
                src.content_tag = .codepoint;
                dst.content_tag = .codepoint_grapheme;
            }

            // The destination row must be marked
            dst_row.grapheme = true;
        }

        // The destination row has styles if any of the cells are styled
        if (!dst_row.styled) dst_row.styled = styled: for (dst_cells) |c| {
            if (c.style_id != style.default_id) break :styled true;
        } else false;

        // Clear our source row now that the copy is complete. We can NOT
        // use clearCells here because clearCells will garbage collect our
        // styles and graphames but we moved them above.
        //
        // Zero the cells as u64s since empirically this seems
        // to be a bit faster than using @memset(src_cells, .{})
        @memset(@as([]u64, @ptrCast(src_cells)), 0);
        if (src_cells.len == self.size.cols) {
            src_row.grapheme = false;
            src_row.styled = false;
        }
    }

    /// Swap two cells within the same row as quickly as possible.
    pub fn swapCells(
        self: *Page,
        src: *Cell,
        dst: *Cell,
    ) void {
        defer self.assertIntegrity();

        // Graphemes are keyed by cell offset so we do have to move them.
        // We do this first so that all our grapheme state is correct.
        if (src.hasGrapheme() or dst.hasGrapheme()) {
            if (src.hasGrapheme() and !dst.hasGrapheme()) {
                self.moveGrapheme(src, dst);
            } else if (!src.hasGrapheme() and dst.hasGrapheme()) {
                self.moveGrapheme(dst, src);
            } else {
                // Both had graphemes, so we have to manually swap
                const src_offset = getOffset(Cell, self.memory, src);
                const dst_offset = getOffset(Cell, self.memory, dst);
                var map = self.grapheme_map.map(self.memory);
                const src_entry = map.getEntry(src_offset).?;
                const dst_entry = map.getEntry(dst_offset).?;
                const src_value = src_entry.value_ptr.*;
                const dst_value = dst_entry.value_ptr.*;
                src_entry.value_ptr.* = dst_value;
                dst_entry.value_ptr.* = src_value;
            }
        }

        // Copy the metadata. Note that we do NOT have to worry about
        // styles because styles are keyed by ID and we're preserving the
        // exact ref count and row state here.
        const old_dst = dst.*;
        dst.* = src.*;
        src.* = old_dst;
    }

    /// Clear the cells in the given row. This will reclaim memory used
    /// by graphemes and styles. Note that if the style cleared is still
    /// active, Page cannot know this and it will still be ref counted down.
    /// The best solution for this is to artificially increment the ref count
    /// prior to calling this function.
    pub fn clearCells(
        self: *Page,
        row: *Row,
        left: usize,
        end: usize,
    ) void {
        defer self.assertIntegrity();

        const cells = row.cells.ptr(self.memory)[left..end];
        if (row.grapheme) {
            for (cells) |*cell| {
                if (cell.hasGrapheme()) self.clearGrapheme(row, cell);
            }
        }

        if (row.styled) {
            for (cells) |*cell| {
                if (cell.style_id == style.default_id) continue;

                if (self.styles.lookupId(self.memory, cell.style_id)) |prev_style| {
                    // Below upsert can't fail because it should already be present
                    const md = self.styles.upsert(self.memory, prev_style.*) catch unreachable;
                    assert(md.ref > 0);
                    md.ref -= 1;
                    if (md.ref == 0) self.styles.remove(self.memory, cell.style_id);
                }
            }

            if (cells.len == self.size.cols) row.styled = false;
        }

        // Zero the cells as u64s since empirically this seems
        // to be a bit faster than using @memset(cells, .{})
        @memset(@as([]u64, @ptrCast(cells)), 0);
    }

    /// Append a codepoint to the given cell as a grapheme.
    pub fn appendGrapheme(self: *Page, row: *Row, cell: *Cell, cp: u21) Allocator.Error!void {
        defer self.assertIntegrity();

        if (comptime std.debug.runtime_safety) assert(cell.hasText());

        const cell_offset = getOffset(Cell, self.memory, cell);
        var map = self.grapheme_map.map(self.memory);

        // If this cell has no graphemes, we can go faster by knowing we
        // need to allocate a new grapheme slice and update the map.
        if (cell.content_tag != .codepoint_grapheme) {
            const cps = try self.grapheme_alloc.alloc(u21, self.memory, 1);
            errdefer self.grapheme_alloc.free(self.memory, cps);
            cps[0] = cp;

            try map.putNoClobber(cell_offset, .{
                .offset = getOffset(u21, self.memory, @ptrCast(cps.ptr)),
                .len = 1,
            });
            errdefer map.remove(cell_offset);

            cell.content_tag = .codepoint_grapheme;
            row.grapheme = true;

            return;
        }

        // The cell already has graphemes. We need to append to the existing
        // grapheme slice and update the map.
        assert(row.grapheme);

        const slice = map.getPtr(cell_offset).?;

        // If our slice len doesn't divide evenly by the grapheme chunk
        // length then we can utilize the additional chunk space.
        if (slice.len % grapheme_chunk_len != 0) {
            const cps = slice.offset.ptr(self.memory);
            cps[slice.len] = cp;
            slice.len += 1;
            return;
        }

        // We are out of chunk space. There is no fast path here. We need
        // to allocate a larger chunk. This is a very slow path. We expect
        // most graphemes to fit within our chunk size.
        const cps = try self.grapheme_alloc.alloc(u21, self.memory, slice.len + 1);
        errdefer self.grapheme_alloc.free(self.memory, cps);
        const old_cps = slice.offset.ptr(self.memory)[0..slice.len];
        fastmem.copy(u21, cps[0..old_cps.len], old_cps);
        cps[slice.len] = cp;
        slice.* = .{
            .offset = getOffset(u21, self.memory, @ptrCast(cps.ptr)),
            .len = slice.len + 1,
        };

        // Free our old chunk
        self.grapheme_alloc.free(self.memory, old_cps);
    }

    /// Returns the codepoints for the given cell. These are the codepoints
    /// in addition to the first codepoint. The first codepoint is NOT
    /// included since it is on the cell itself.
    pub fn lookupGrapheme(self: *const Page, cell: *Cell) ?[]u21 {
        const cell_offset = getOffset(Cell, self.memory, cell);
        const map = self.grapheme_map.map(self.memory);
        const slice = map.get(cell_offset) orelse return null;
        return slice.offset.ptr(self.memory)[0..slice.len];
    }

    /// Move the graphemes from one cell to another. This can't fail
    /// because we avoid any allocations since we're just moving data.
    ///
    /// WARNING: This will NOT change the content_tag on the cells because
    /// there are scenarios where we want to move graphemes without changing
    /// the content tag. Callers beware but assertIntegrity should catch this.
    fn moveGrapheme(self: *Page, src: *Cell, dst: *Cell) void {
        if (comptime std.debug.runtime_safety) {
            assert(src.hasGrapheme());
            assert(!dst.hasGrapheme());
        }

        const src_offset = getOffset(Cell, self.memory, src);
        const dst_offset = getOffset(Cell, self.memory, dst);
        var map = self.grapheme_map.map(self.memory);
        const entry = map.getEntry(src_offset).?;
        const value = entry.value_ptr.*;
        map.removeByPtr(entry.key_ptr);
        map.putAssumeCapacity(dst_offset, value);
    }

    /// Clear the graphemes for a given cell.
    pub fn clearGrapheme(self: *Page, row: *Row, cell: *Cell) void {
        defer self.assertIntegrity();
        if (comptime std.debug.runtime_safety) assert(cell.hasGrapheme());

        // Get our entry in the map, which must exist
        const cell_offset = getOffset(Cell, self.memory, cell);
        var map = self.grapheme_map.map(self.memory);
        const entry = map.getEntry(cell_offset).?;

        // Free our grapheme data
        const cps = entry.value_ptr.offset.ptr(self.memory)[0..entry.value_ptr.len];
        self.grapheme_alloc.free(self.memory, cps);

        // Remove the entry
        map.removeByPtr(entry.key_ptr);

        // Mark that we no longer have graphemes, also search the row
        // to make sure its state is correct.
        cell.content_tag = .codepoint;
        const cells = row.cells.ptr(self.memory)[0..self.size.cols];
        for (cells) |c| if (c.hasGrapheme()) return;
        row.grapheme = false;
    }

    /// Returns the number of graphemes in the page. This isn't the byte
    /// size but the total number of unique cells that have grapheme data.
    pub fn graphemeCount(self: *const Page) usize {
        return self.grapheme_map.map(self.memory).count();
    }

    pub const Layout = struct {
        total_size: usize,
        rows_start: usize,
        rows_size: usize,
        cells_start: usize,
        cells_size: usize,
        styles_start: usize,
        styles_layout: style.Set.Layout,
        grapheme_alloc_start: usize,
        grapheme_alloc_layout: GraphemeAlloc.Layout,
        grapheme_map_start: usize,
        grapheme_map_layout: GraphemeMap.Layout,
        capacity: Capacity,
    };

    /// The memory layout for a page given a desired minimum cols
    /// and rows size.
    pub fn layout(cap: Capacity) Layout {
        const rows_count: usize = @intCast(cap.rows);
        const rows_start = 0;
        const rows_end: usize = rows_start + (rows_count * @sizeOf(Row));

        const cells_count: usize = @intCast(cap.cols * cap.rows);
        const cells_start = alignForward(usize, rows_end, @alignOf(Cell));
        const cells_end = cells_start + (cells_count * @sizeOf(Cell));

        const styles_layout = style.Set.layout(cap.styles);
        const styles_start = alignForward(usize, cells_end, style.Set.base_align);
        const styles_end = styles_start + styles_layout.total_size;

        const grapheme_alloc_layout = GraphemeAlloc.layout(cap.grapheme_bytes);
        const grapheme_alloc_start = alignForward(usize, styles_end, GraphemeAlloc.base_align);
        const grapheme_alloc_end = grapheme_alloc_start + grapheme_alloc_layout.total_size;

        const grapheme_count = @divFloor(cap.grapheme_bytes, grapheme_chunk);
        const grapheme_map_layout = GraphemeMap.layout(@intCast(grapheme_count));
        const grapheme_map_start = alignForward(usize, grapheme_alloc_end, GraphemeMap.base_align);
        const grapheme_map_end = grapheme_map_start + grapheme_map_layout.total_size;

        const total_size = alignForward(usize, grapheme_map_end, std.mem.page_size);

        return .{
            .total_size = total_size,
            .rows_start = rows_start,
            .rows_size = rows_end - rows_start,
            .cells_start = cells_start,
            .cells_size = cells_end - cells_start,
            .styles_start = styles_start,
            .styles_layout = styles_layout,
            .grapheme_alloc_start = grapheme_alloc_start,
            .grapheme_alloc_layout = grapheme_alloc_layout,
            .grapheme_map_start = grapheme_map_start,
            .grapheme_map_layout = grapheme_map_layout,
            .capacity = cap,
        };
    }
};

/// The standard capacity for a page that doesn't have special
/// requirements. This is enough to support a very large number of cells.
/// The standard capacity is chosen as the fast-path for allocation.
pub const std_capacity: Capacity = .{
    .cols = 215,
    .rows = 215,
    .styles = 128,
    .grapheme_bytes = 8192,
};

/// The size of this page.
pub const Size = struct {
    cols: size.CellCountInt,
    rows: size.CellCountInt,
};

/// Capacity of this page.
pub const Capacity = struct {
    /// Number of columns and rows we can know about.
    cols: size.CellCountInt,
    rows: size.CellCountInt,

    /// Number of unique styles that can be used on this page.
    styles: u16 = 16,

    /// Number of bytes to allocate for grapheme data.
    grapheme_bytes: usize = grapheme_bytes_default,

    pub const Adjustment = struct {
        cols: ?size.CellCountInt = null,
    };

    /// Adjust the capacity parameters while retaining the same total size.
    /// Adjustments always happen by limiting the rows in the page. Everything
    /// else can grow. If it is impossible to achieve the desired adjustment,
    /// OutOfMemory is returned.
    pub fn adjust(self: Capacity, req: Adjustment) Allocator.Error!Capacity {
        var adjusted = self;
        if (req.cols) |cols| {
            // The math below only works if there is no alignment gap between
            // the end of the rows array and the start of the cells array.
            //
            // To guarantee this, we assert that Row's size is a multiple of
            // Cell's alignment, so that any length array of Rows will end on
            // a valid alignment for the start of the Cell array.
            assert(@sizeOf(Row) % @alignOf(Cell) == 0);

            const layout = Page.layout(self);

            // In order to determine the amount of space in the page available
            // for rows & cells (which will allow us to calculate the number of
            // rows we can fit at a certain column width) we need to layout the
            // "meta" members of the page (i.e. everything else) from the end.
            const grapheme_map_start = alignBackward(usize, layout.total_size - layout.grapheme_map_layout.total_size, GraphemeMap.base_align);
            const grapheme_alloc_start = alignBackward(usize, grapheme_map_start - layout.grapheme_alloc_layout.total_size, GraphemeAlloc.base_align);
            const styles_start = alignBackward(usize, grapheme_alloc_start - layout.styles_layout.total_size, style.Set.base_align);

            const available_size = styles_start;
            const size_per_row = @sizeOf(Row) + (@sizeOf(Cell) * @as(usize, @intCast(cols)));
            const new_rows = @divFloor(available_size, size_per_row);

            // If our rows go to zero then we can't fit any row metadata
            // for the desired number of columns.
            if (new_rows == 0) return error.OutOfMemory;

            adjusted.cols = cols;
            adjusted.rows = @intCast(new_rows);
        }

        return adjusted;
    }
};

pub const Row = packed struct(u64) {
    /// The cells in the row offset from the page.
    cells: Offset(Cell),

    /// True if this row is soft-wrapped. The first cell of the next
    /// row is a continuation of this row.
    wrap: bool = false,

    /// True if the previous row to this one is soft-wrapped and
    /// this row is a continuation of that row.
    wrap_continuation: bool = false,

    /// True if any of the cells in this row have multi-codepoint
    /// grapheme clusters. If this is true, some fast paths are not
    /// possible because erasing for example may need to clear existing
    /// grapheme data.
    grapheme: bool = false,

    /// True if any of the cells in this row have a ref-counted style.
    /// This can have false positives but never a false negative. Meaning:
    /// this will be set to true the first time a style is used, but it
    /// will not be set to false if the style is no longer used, because
    /// checking for that condition is too expensive.
    ///
    /// Why have this weird false positive flag at all? This makes VT operations
    /// that erase cells (such as insert lines, delete lines, erase chars,
    /// etc.) MUCH MUCH faster in the case that the row was never styled.
    /// At the time of writing this, the speed difference is around 4x.
    styled: bool = false,

    /// The semantic prompt type for this row as specified by the
    /// running program, or "unknown" if it was never set.
    semantic_prompt: SemanticPrompt = .unknown,

    _padding: u25 = 0,

    /// Semantic prompt type.
    pub const SemanticPrompt = enum(u3) {
        /// Unknown, the running application didn't tell us for this line.
        unknown = 0,

        /// This is a prompt line, meaning it only contains the shell prompt.
        /// For poorly behaving shells, this may also be the input.
        prompt = 1,
        prompt_continuation = 2,

        /// This line contains the input area. We don't currently track
        /// where this actually is in the line, so we just assume it is somewhere.
        input = 3,

        /// This line is the start of command output.
        command = 4,

        /// True if this is a prompt or input line.
        pub fn promptOrInput(self: SemanticPrompt) bool {
            return self == .prompt or self == .prompt_continuation or self == .input;
        }
    };
};

/// A cell represents a single terminal grid cell.
///
/// The zero value of this struct must be a valid cell representing empty,
/// since we zero initialize the backing memory for a page.
pub const Cell = packed struct(u64) {
    /// The content tag dictates the active tag in content and possibly
    /// some other behaviors.
    content_tag: ContentTag = .codepoint,

    /// The content of the cell. This is a union based on content_tag.
    content: packed union {
        /// The codepoint that this cell contains. If `grapheme` is false,
        /// then this is the only codepoint in the cell. If `grapheme` is
        /// true, then this is the first codepoint in the grapheme cluster.
        codepoint: u21,

        /// The content is an empty cell with a background color.
        color_palette: u8,
        color_rgb: RGB,
    } = .{ .codepoint = 0 },

    /// The style ID to use for this cell within the style map. Zero
    /// is always the default style so no lookup is required.
    style_id: style.Id = 0,

    /// The wide property of this cell, for wide characters. Characters in
    /// a terminal grid can only be 1 or 2 cells wide. A wide character
    /// is always next to a spacer. This is used to determine both the width
    /// and spacer properties of a cell.
    wide: Wide = .narrow,

    /// Whether this was written with the protection flag set.
    protected: bool = false,

    _padding: u19 = 0,

    pub const ContentTag = enum(u2) {
        /// A single codepoint, could be zero to be empty cell.
        codepoint = 0,

        /// A codepoint that is part of a multi-codepoint grapheme cluster.
        /// The codepoint tag is active in content, but also expect more
        /// codepoints in the grapheme data.
        codepoint_grapheme = 1,

        /// The cell has no text but only a background color. This is an
        /// optimization so that cells with only backgrounds don't take up
        /// style map space and also don't require a style map lookup.
        bg_color_palette = 2,
        bg_color_rgb = 3,
    };

    pub const RGB = packed struct {
        r: u8,
        g: u8,
        b: u8,
    };

    pub const Wide = enum(u2) {
        /// Not a wide character, cell width 1.
        narrow = 0,

        /// Wide character, cell width 2.
        wide = 1,

        /// Spacer after wide character. Do not render.
        spacer_tail = 2,

        /// Spacer at the end of a soft-wrapped line to indicate that a wide
        /// character is continued on the next line.
        spacer_head = 3,
    };

    /// Helper to make a cell that just has a codepoint.
    pub fn init(cp: u21) Cell {
        return .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = cp },
        };
    }

    pub fn hasText(self: Cell) bool {
        return switch (self.content_tag) {
            .codepoint,
            .codepoint_grapheme,
            => self.content.codepoint != 0,

            .bg_color_palette,
            .bg_color_rgb,
            => false,
        };
    }

    pub fn codepoint(self: Cell) u21 {
        return switch (self.content_tag) {
            .codepoint,
            .codepoint_grapheme,
            => self.content.codepoint,

            .bg_color_palette,
            .bg_color_rgb,
            => 0,
        };
    }

    /// The width in grid cells that this cell takes up.
    pub fn gridWidth(self: Cell) u2 {
        return switch (self.wide) {
            .narrow, .spacer_head, .spacer_tail => 1,
            .wide => 2,
        };
    }

    pub fn hasStyling(self: Cell) bool {
        return self.style_id != style.default_id;
    }

    /// Returns true if the cell has no text or styling.
    pub fn isEmpty(self: Cell) bool {
        return switch (self.content_tag) {
            // Textual cells are empty if they have no text and are narrow.
            // The "narrow" requirement is because wide spacers are meaningful.
            .codepoint,
            .codepoint_grapheme,
            => !self.hasText() and self.wide == .narrow,

            .bg_color_palette,
            .bg_color_rgb,
            => false,
        };
    }

    pub fn hasGrapheme(self: Cell) bool {
        return self.content_tag == .codepoint_grapheme;
    }

    /// Returns true if the set of cells has text in it.
    pub fn hasTextAny(cells: []const Cell) bool {
        for (cells) |cell| {
            if (cell.hasText()) return true;
        }

        return false;
    }
};

// Uncomment this when you want to do some math.
// test "Page size calculator" {
//     const total_size = alignForward(
//         usize,
//         Page.layout(.{
//             .cols = 250,
//             .rows = 250,
//             .styles = 128,
//             .grapheme_bytes = 1024,
//         }).total_size,
//         std.mem.page_size,
//     );
//
//     std.log.warn("total_size={} pages={}", .{
//         total_size,
//         total_size / std.mem.page_size,
//     });
// }
//
// test "Page std size" {
//     // We want to ensure that the standard capacity is what we
//     // expect it to be. Changing this is fine but should be done with care
//     // so we fail a test if it changes.
//     const total_size = Page.layout(std_capacity).total_size;
//     try testing.expectEqual(@as(usize, 524_288), total_size); // 512 KiB
//     //const pages = total_size / std.mem.page_size;
// }

test "Page capacity adjust cols down" {
    const original = std_capacity;
    const original_size = Page.layout(original).total_size;
    const adjusted = try original.adjust(.{ .cols = original.cols / 2 });
    const adjusted_size = Page.layout(adjusted).total_size;
    try testing.expectEqual(original_size, adjusted_size);
    // If we layout a page with 1 more row and it's still the same size
    // then adjust is not producing enough rows.
    var bigger = adjusted;
    bigger.rows += 1;
    const bigger_size = Page.layout(bigger).total_size;
    try testing.expect(bigger_size > original_size);
}

test "Page capacity adjust cols down to 1" {
    const original = std_capacity;
    const original_size = Page.layout(original).total_size;
    const adjusted = try original.adjust(.{ .cols = 1 });
    const adjusted_size = Page.layout(adjusted).total_size;
    try testing.expectEqual(original_size, adjusted_size);
    // If we layout a page with 1 more row and it's still the same size
    // then adjust is not producing enough rows.
    var bigger = adjusted;
    bigger.rows += 1;
    const bigger_size = Page.layout(bigger).total_size;
    try testing.expect(bigger_size > original_size);
}

test "Page capacity adjust cols up" {
    const original = std_capacity;
    const original_size = Page.layout(original).total_size;
    const adjusted = try original.adjust(.{ .cols = original.cols * 2 });
    const adjusted_size = Page.layout(adjusted).total_size;
    try testing.expectEqual(original_size, adjusted_size);
    // If we layout a page with 1 more row and it's still the same size
    // then adjust is not producing enough rows.
    var bigger = adjusted;
    bigger.rows += 1;
    const bigger_size = Page.layout(bigger).total_size;
    try testing.expect(bigger_size > original_size);
}

test "Page capacity adjust cols sweep" {
    var cap = std_capacity;
    const original_cols = cap.cols;
    const original_size = Page.layout(cap).total_size;
    for (1..original_cols * 2) |c| {
        cap = try cap.adjust(.{ .cols = @as(u16, @intCast(c)) });
        const adjusted_size = Page.layout(cap).total_size;
        try testing.expectEqual(original_size, adjusted_size);
        // If we layout a page with 1 more row and it's still the same size
        // then adjust is not producing enough rows.
        var bigger = cap;
        bigger.rows += 1;
        const bigger_size = Page.layout(bigger).total_size;
        try testing.expect(bigger_size > original_size);
    }
}

test "Page capacity adjust cols too high" {
    const original = std_capacity;
    try testing.expectError(
        error.OutOfMemory,
        original.adjust(.{ .cols = std.math.maxInt(size.CellCountInt) }),
    );
}

test "Page init" {
    var page = try Page.init(.{
        .cols = 120,
        .rows = 80,
        .styles = 32,
    });
    defer page.deinit();
}

test "Page read and write cells" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(y) },
        };
    }

    // Read it again
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint);
    }
}

test "Page appendGrapheme small" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    const rac = page.getRowAndCell(0, 0);
    rac.cell.* = Cell.init(0x09);

    // One
    try page.appendGrapheme(rac.row, rac.cell, 0x0A);
    try testing.expect(rac.row.grapheme);
    try testing.expect(rac.cell.hasGrapheme());
    try testing.expectEqualSlices(u21, &.{0x0A}, page.lookupGrapheme(rac.cell).?);

    // Two
    try page.appendGrapheme(rac.row, rac.cell, 0x0B);
    try testing.expect(rac.row.grapheme);
    try testing.expect(rac.cell.hasGrapheme());
    try testing.expectEqualSlices(u21, &.{ 0x0A, 0x0B }, page.lookupGrapheme(rac.cell).?);

    // Clear it
    page.clearGrapheme(rac.row, rac.cell);
    try testing.expect(!rac.row.grapheme);
    try testing.expect(!rac.cell.hasGrapheme());
}

test "Page appendGrapheme larger than chunk" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    const rac = page.getRowAndCell(0, 0);
    rac.cell.* = Cell.init(0x09);

    const count = grapheme_chunk_len * 10;
    for (0..count) |i| {
        try page.appendGrapheme(rac.row, rac.cell, @intCast(0x0A + i));
    }

    const cps = page.lookupGrapheme(rac.cell).?;
    try testing.expectEqual(@as(usize, count), cps.len);
    for (0..count) |i| {
        try testing.expectEqual(@as(u21, @intCast(0x0A + i)), cps[i]);
    }
}

test "Page clearGrapheme not all cells" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    const rac = page.getRowAndCell(0, 0);
    rac.cell.* = Cell.init(0x09);
    try page.appendGrapheme(rac.row, rac.cell, 0x0A);

    const rac2 = page.getRowAndCell(1, 0);
    rac2.cell.* = Cell.init(0x09);
    try page.appendGrapheme(rac2.row, rac2.cell, 0x0A);

    // Clear it
    page.clearGrapheme(rac.row, rac.cell);
    try testing.expect(rac.row.grapheme);
    try testing.expect(!rac.cell.hasGrapheme());
    try testing.expect(rac2.cell.hasGrapheme());
}

test "Page clone" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(y) },
        };
    }

    // Clone
    var page2 = try page.clone();
    defer page2.deinit();
    try testing.expectEqual(page2.capacity, page.capacity);

    // Read it again
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint);
    }

    // Write again
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 0 },
        };
    }

    // Read it again, should be unchanged
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint);
    }

    // Read the original
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint);
    }
}

test "Page cloneFrom" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(y) },
        };
    }

    // Clone
    var page2 = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page2.deinit();
    try page2.cloneFrom(&page, 0, page.size.rows);

    // Read it again
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint);
    }

    // Write again
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 0 },
        };
    }

    // Read it again, should be unchanged
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint);
    }

    // Read the original
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint);
    }
}

test "Page cloneFrom shrink columns" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(y) },
        };
    }

    // Clone
    var page2 = try Page.init(.{
        .cols = 5,
        .rows = 10,
        .styles = 8,
    });
    defer page2.deinit();
    try page2.cloneFrom(&page, 0, page.size.rows);
    try testing.expectEqual(@as(size.CellCountInt, 5), page2.size.cols);

    // Read it again
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint);
    }
}

test "Page cloneFrom partial" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(y) },
        };
    }

    // Clone
    var page2 = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page2.deinit();
    try page2.cloneFrom(&page, 0, 5);

    // Read it again
    for (0..5) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint);
    }
    for (5..page2.size.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint);
    }
}

test "Page cloneFrom graphemes" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(y + 1) },
        };
        try page.appendGrapheme(rac.row, rac.cell, 0x0A);
    }

    // Clone
    var page2 = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page2.deinit();
    try page2.cloneFrom(&page, 0, page.size.rows);

    // Read it again
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y + 1)), rac.cell.content.codepoint);
        try testing.expect(rac.row.grapheme);
        try testing.expect(rac.cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{0x0A}, page2.lookupGrapheme(rac.cell).?);
    }

    // Write again
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        page.clearGrapheme(rac.row, rac.cell);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 0 },
        };
    }

    // Read it again, should be unchanged
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y + 1)), rac.cell.content.codepoint);
        try testing.expect(rac.row.grapheme);
        try testing.expect(rac.cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{0x0A}, page2.lookupGrapheme(rac.cell).?);
    }

    // Read the original
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint);
    }
}

test "Page cloneFrom frees dst graphemes" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(y + 1) },
        };
    }

    // Clone
    var page2 = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page2.deinit();
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(y + 1) },
        };
        try page2.appendGrapheme(rac.row, rac.cell, 0x0A);
    }

    // Clone from page which has no graphemes.
    try page2.cloneFrom(&page, 0, page.size.rows);

    // Read it again
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y + 1)), rac.cell.content.codepoint);
        try testing.expect(!rac.row.grapheme);
        try testing.expect(!rac.cell.hasGrapheme());
    }
    try testing.expectEqual(@as(usize, 0), page2.graphemeCount());
}

test "Page cloneRowFrom partial" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write
    {
        const y = 0;
        for (0..page.size.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x + 1) },
            };
        }
    }

    // Clone
    var page2 = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page2.deinit();
    try page2.clonePartialRowFrom(
        &page,
        page2.getRow(0),
        page.getRow(0),
        2,
        8,
    );

    // Read it again
    {
        const y = 0;
        for (0..page2.size.cols) |x| {
            const expected: u21 = if (x >= 2 and x < 8) @intCast(x + 1) else 0;
            const rac = page2.getRowAndCell(x, y);
            try testing.expectEqual(expected, rac.cell.content.codepoint);
        }
    }
}

test "Page cloneRowFrom partial grapheme in non-copied source region" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write
    {
        const y = 0;
        for (0..page.size.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x + 1) },
            };
        }
        {
            const rac = page.getRowAndCell(0, y);
            try page.appendGrapheme(rac.row, rac.cell, 0x0A);
        }
        {
            const rac = page.getRowAndCell(9, y);
            try page.appendGrapheme(rac.row, rac.cell, 0x0A);
        }
    }
    try testing.expectEqual(@as(usize, 2), page.graphemeCount());

    // Clone
    var page2 = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page2.deinit();
    try page2.clonePartialRowFrom(
        &page,
        page2.getRow(0),
        page.getRow(0),
        2,
        8,
    );

    // Read it again
    {
        const y = 0;
        for (0..page2.size.cols) |x| {
            const expected: u21 = if (x >= 2 and x < 8) @intCast(x + 1) else 0;
            const rac = page2.getRowAndCell(x, y);
            try testing.expectEqual(expected, rac.cell.content.codepoint);
            try testing.expect(!rac.cell.hasGrapheme());
        }
        {
            const rac = page2.getRowAndCell(9, y);
            try testing.expect(!rac.row.grapheme);
        }
    }
    try testing.expectEqual(@as(usize, 0), page2.graphemeCount());
}

test "Page cloneRowFrom partial grapheme in non-copied dest region" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write
    {
        const y = 0;
        for (0..page.size.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x + 1) },
            };
        }
    }
    try testing.expectEqual(@as(usize, 0), page.graphemeCount());

    // Clone
    var page2 = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page2.deinit();
    {
        const y = 0;
        for (0..page2.size.cols) |x| {
            const rac = page2.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 0xBB },
            };
        }
        {
            const rac = page2.getRowAndCell(0, y);
            try page2.appendGrapheme(rac.row, rac.cell, 0x0A);
        }
        {
            const rac = page2.getRowAndCell(9, y);
            try page2.appendGrapheme(rac.row, rac.cell, 0x0A);
        }
    }
    try page2.clonePartialRowFrom(
        &page,
        page2.getRow(0),
        page.getRow(0),
        2,
        8,
    );

    // Read it again
    {
        const y = 0;
        for (0..page2.size.cols) |x| {
            const expected: u21 = if (x >= 2 and x < 8) @intCast(x + 1) else 0xBB;
            const rac = page2.getRowAndCell(x, y);
            try testing.expectEqual(expected, rac.cell.content.codepoint);
        }
        {
            const rac = page2.getRowAndCell(9, y);
            try testing.expect(rac.row.grapheme);
        }
    }
    try testing.expectEqual(@as(usize, 2), page2.graphemeCount());
}

test "Page moveCells text-only" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write
    for (0..page.capacity.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(x + 1) },
        };
    }

    const src = page.getRow(0);
    const dst = page.getRow(1);
    page.moveCells(src, 0, dst, 0, page.capacity.cols);

    // New rows should have text
    for (0..page.capacity.cols) |x| {
        const rac = page.getRowAndCell(x, 1);
        try testing.expectEqual(
            @as(u21, @intCast(x + 1)),
            rac.cell.content.codepoint,
        );
    }

    // Old row should be blank
    for (0..page.capacity.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        try testing.expectEqual(
            @as(u21, 0),
            rac.cell.content.codepoint,
        );
    }
}

test "Page moveCells graphemes" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write
    for (0..page.size.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(x + 1) },
        };
        try page.appendGrapheme(rac.row, rac.cell, 0x0A);
    }
    const original_count = page.graphemeCount();

    const src = page.getRow(0);
    const dst = page.getRow(1);
    page.moveCells(src, 0, dst, 0, page.size.cols);
    try testing.expectEqual(original_count, page.graphemeCount());

    // New rows should have text
    for (0..page.size.cols) |x| {
        const rac = page.getRowAndCell(x, 1);
        try testing.expectEqual(
            @as(u21, @intCast(x + 1)),
            rac.cell.content.codepoint,
        );
        try testing.expectEqualSlices(
            u21,
            &.{0x0A},
            page.lookupGrapheme(rac.cell).?,
        );
    }

    // Old row should be blank
    for (0..page.size.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        try testing.expectEqual(
            @as(u21, 0),
            rac.cell.content.codepoint,
        );
    }
}

test "Page verifyIntegrity graphemes good" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write
    for (0..page.size.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(x + 1) },
        };
        try page.appendGrapheme(rac.row, rac.cell, 0x0A);
    }

    try page.verifyIntegrity(testing.allocator);
}

test "Page verifyIntegrity grapheme row not marked" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write
    for (0..page.size.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(x + 1) },
        };
        try page.appendGrapheme(rac.row, rac.cell, 0x0A);
    }

    // Make invalid by unmarking the row
    page.getRow(0).grapheme = false;

    try testing.expectError(
        Page.IntegrityError.UnmarkedGraphemeRow,
        page.verifyIntegrity(testing.allocator),
    );
}

test "Page verifyIntegrity styles good" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Upsert a style we'll use
    const md = try page.styles.upsert(page.memory, .{ .flags = .{
        .bold = true,
    } });

    // Write
    for (0..page.size.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        rac.row.styled = true;
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(x + 1) },
            .style_id = md.id,
        };
        md.ref += 1;
    }

    try page.verifyIntegrity(testing.allocator);
}

test "Page verifyIntegrity styles ref count mismatch" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Upsert a style we'll use
    const md = try page.styles.upsert(page.memory, .{ .flags = .{
        .bold = true,
    } });

    // Write
    for (0..page.size.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        rac.row.styled = true;
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(x + 1) },
            .style_id = md.id,
        };
        md.ref += 1;
    }

    // Miss a ref
    md.ref -= 1;

    try testing.expectError(
        Page.IntegrityError.MismatchedStyleRef,
        page.verifyIntegrity(testing.allocator),
    );
}

test "Page verifyIntegrity zero rows" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    page.size.rows = 0;
    try testing.expectError(
        Page.IntegrityError.ZeroRowCount,
        page.verifyIntegrity(testing.allocator),
    );
}

test "Page verifyIntegrity zero cols" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    page.size.cols = 0;
    try testing.expectError(
        Page.IntegrityError.ZeroColCount,
        page.verifyIntegrity(testing.allocator),
    );
}
