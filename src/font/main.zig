const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");

pub const Atlas = @import("Atlas.zig");
pub const discovery = @import("discovery.zig");
pub const face = @import("face.zig");
pub const CodepointMap = @import("CodepointMap.zig");
pub const DeferredFace = @import("DeferredFace.zig");
pub const Face = face.Face;
pub const Group = @import("Group.zig");
pub const GroupCache = @import("GroupCache.zig");
pub const Glyph = @import("Glyph.zig");
pub const shape = @import("shape.zig");
pub const Shaper = shape.Shaper;
pub const sprite = @import("sprite.zig");
pub const Sprite = sprite.Sprite;
pub const Descriptor = discovery.Descriptor;
pub const Discover = discovery.Discover;
pub usingnamespace @import("library.zig");

/// If we're targeting wasm then we export some wasm APIs.
pub usingnamespace if (builtin.target.isWasm()) struct {
    pub usingnamespace Atlas.Wasm;
    pub usingnamespace DeferredFace.Wasm;
    pub usingnamespace Group.Wasm;
    pub usingnamespace GroupCache.Wasm;
    pub usingnamespace face.web_canvas.Wasm;
    pub usingnamespace shape.web_canvas.Wasm;
} else struct {};

/// Build options
pub const options: struct {
    backend: Backend,
} = .{
    // TODO: we need to modify the build config for wasm builds. the issue
    // is we're sharing the build config options between all exes in build.zig.
    // We need to construct it per target.
    .backend = if (builtin.target.isWasm()) .web_canvas else build_config.font_backend,
};

pub const Backend = enum {
    const WasmTarget = @import("../os/wasm/target.zig").Target;

    /// FreeType for font rendering with no font discovery enabled.
    freetype,

    /// Fontconfig for font discovery and FreeType for font rendering.
    fontconfig_freetype,

    /// CoreText for both font discovery for rendering (macOS).
    coretext,

    /// CoreText for font discovery and FreeType for rendering (macOS).
    coretext_freetype,

    /// Use the browser font system and the Canvas API (wasm). This limits
    /// the available fonts to browser fonts (anything Canvas natively
    /// supports).
    web_canvas,

    /// Returns the default backend for a build environment. This is
    /// meant to be called at comptime by the build.zig script. To get the
    /// backend look at build_options.
    pub fn default(
        target: std.Target,
        wasm_target: WasmTarget,
    ) Backend {
        if (target.cpu.arch == .wasm32) {
            return switch (wasm_target) {
                .browser => .web_canvas,
            };
        }

        // macOS also supports "coretext_freetype" but there is no scenario
        // that is the default. It is only used by people who want to
        // self-compile Ghostty and prefer the freetype aesthetic.
        return if (target.isDarwin()) .coretext else .fontconfig_freetype;
    }

    // All the functions below can be called at comptime or runtime to
    // determine if we have a certain dependency.

    pub fn hasFreetype(self: Backend) bool {
        return switch (self) {
            .freetype,
            .fontconfig_freetype,
            .coretext_freetype,
            => true,
            .coretext, .web_canvas => false,
        };
    }

    pub fn hasCoretext(self: Backend) bool {
        return switch (self) {
            .coretext,
            .coretext_freetype,
            => true,

            .freetype,
            .fontconfig_freetype,
            .web_canvas,
            => false,
        };
    }

    pub fn hasFontconfig(self: Backend) bool {
        return switch (self) {
            .fontconfig_freetype => true,

            .freetype,
            .coretext,
            .coretext_freetype,
            .web_canvas,
            => false,
        };
    }

    pub fn hasHarfbuzz(self: Backend) bool {
        return switch (self) {
            .freetype,
            .fontconfig_freetype,
            .coretext_freetype,
            => true,

            .coretext,
            .web_canvas,
            => false,
        };
    }
};

/// The styles that a family can take.
pub const Style = enum(u3) {
    regular = 0,
    bold = 1,
    italic = 2,
    bold_italic = 3,
};

/// The presentation for a an emoji.
pub const Presentation = enum(u1) {
    text = 0, // U+FE0E
    emoji = 1, // U+FEOF
};

/// A FontIndex that can be used to use the sprite font directly.
pub const sprite_index = Group.FontIndex.initSpecial(.sprite);

test {
    // For non-wasm we want to test everything we can
    if (!comptime builtin.target.isWasm()) {
        @import("std").testing.refAllDecls(@This());
        return;
    }

    _ = Atlas;
}
