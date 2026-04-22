const config = @import("config.zig");

pub const fields = config.fields;
pub const build_components = config.build_components;
pub const get_components = config.get_components;

pub const tables = [_]config.Table{
    .{
        .name = "runtime",
        .fields = &.{
            "grapheme_break",
            "grapheme_break_no_control",
            "wcwidth_standalone",
            "wcwidth_zero_in_grapheme",
            "is_emoji_vs_base",
        },
    },
};
