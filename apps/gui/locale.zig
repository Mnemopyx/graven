//! The user's language and measurement system, as the system reports them.
//!
//! Zig's standard library has no locale support, so this reads the
//! platform directly:
//!
//! * Languages: the caller passes the preferred list (SDL's
//!   `SDL_GetPreferredLocales`, which reads LANGUAGE, LC_ALL, LC_MESSAGES
//!   and LANG on Linux, the preferred languages on macOS and Windows).
//! * Measurement: on Windows, the user's locale setting
//!   (`GetLocaleInfoEx`, LOCALE_IMEASURE); on Linux and other Unix, the
//!   country of LC_ALL, else LC_MEASUREMENT, else LANG (as glibc decides
//!   it); on macOS, not read yet. Where none answers, the country of the
//!   first preferred language decides: the United States, Liberia and
//!   Myanmar measure in US customary units, everywhere else is metric.
//!
//! Window-free, so it is tested on its own and checked for every target.

const std = @import("std");
const builtin = @import("builtin");

pub const Measurement = enum { metric, imperial };

/// A language, and the country it is used in if one is given ("en", "GB").
pub const Locale = struct {
    language: []const u8,
    country: ?[]const u8 = null,

    /// As a tag, "en-GB" or "en", into `buf`.
    pub fn tag(l: Locale, buf: []u8) []const u8 {
        if (l.country) |c| return std.fmt.bufPrint(buf, "{s}-{s}", .{ l.language, c }) catch l.language;
        return l.language;
    }
};

/// Where a measurement system came from, for showing the user.
pub const Source = enum { config, system, country, default };

/// The measurement system in daily use in country `country` (ISO 3166
/// alpha-2): US customary in the United States, Liberia and Myanmar.
pub fn measurementOfCountry(country: []const u8) Measurement {
    for ([_][]const u8{ "US", "LR", "MM" }) |c| {
        if (std.ascii.eqlIgnoreCase(country, c)) return .imperial;
    }
    return .metric;
}

/// A POSIX locale name ("en_US.UTF-8", "de_DE@euro", "fr") as a language
/// and country; null for "C", "POSIX" and empty names, which say nothing.
pub fn parsePosix(name: []const u8) ?Locale {
    var s = name;
    if (std.mem.indexOfAny(u8, s, ".@")) |i| s = s[0..i];
    if (s.len == 0 or std.mem.eql(u8, s, "C") or std.mem.eql(u8, s, "POSIX")) return null;
    if (std.mem.indexOfAny(u8, s, "_-")) |i| {
        const country = s[i + 1 ..];
        return .{ .language = s[0..i], .country = if (country.len > 0) country else null };
    }
    return .{ .language = s };
}

/// Language tags as a config file writes them ("en-GB", "en_GB", "de").
pub fn parseTag(t: []const u8) ?Locale {
    return parsePosix(t);
}

/// What the system says the measurement system is, where it says.
pub fn systemMeasurement() ?Measurement {
    switch (builtin.os.tag) {
        .windows => {
            const LOCALE_IMEASURE: u32 = 0x0D;
            const LOCALE_RETURN_NUMBER: u32 = 0x20000000;
            var value: u32 = 0;
            // With LOCALE_RETURN_NUMBER the answer is a number written into
            // the buffer: 0 metric, 1 US.
            const n = GetLocaleInfoEx(null, LOCALE_IMEASURE | LOCALE_RETURN_NUMBER, @ptrCast(&value), @sizeOf(u32) / 2);
            if (n == 0) return null;
            return if (value == 1) .imperial else .metric;
        },
        .macos, .ios => return null,
        else => {
            // LC_ALL wins over LC_MEASUREMENT, which wins over LANG.
            for ([_][*:0]const u8{ "LC_ALL", "LC_MEASUREMENT", "LANG" }) |name| {
                const v = std.c.getenv(name) orelse continue;
                const s = std.mem.span(v);
                if (s.len == 0) continue;
                const l = parsePosix(s) orelse return null;
                return measurementOfCountry(l.country orelse return null);
            }
            return null;
        },
    }
}

extern "kernel32" fn GetLocaleInfoEx(name: ?[*:0]const u16, lc_type: u32, data: ?[*]u16, len: c_int) callconv(.winapi) c_int;

/// The measurement system to use: the config's, else the system's, else
/// the first preferred language's country's, else metric.
pub fn decide(config: ?Measurement, system: ?Measurement, languages: []const Locale) struct { measurement: Measurement, source: Source } {
    if (config) |m| return .{ .measurement = m, .source = .config };
    if (system) |m| return .{ .measurement = m, .source = .system };
    for (languages) |l| if (l.country) |c| return .{ .measurement = measurementOfCountry(c), .source = .country };
    return .{ .measurement = .metric, .source = .default };
}

const testing = std.testing;

test "POSIX locale names give a language and a country" {
    const us = parsePosix("en_US.UTF-8").?;
    try testing.expectEqualStrings("en", us.language);
    try testing.expectEqualStrings("US", us.country.?);
    const de = parsePosix("de_DE@euro").?;
    try testing.expectEqualStrings("DE", de.country.?);
    try testing.expectEqual(null, parsePosix("fr").?.country);
    try testing.expectEqual(null, parsePosix("C.UTF-8"));
    try testing.expectEqual(null, parsePosix("POSIX"));
    try testing.expectEqualStrings("GB", parseTag("en-GB").?.country.?);
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("en-GB", (Locale{ .language = "en", .country = "GB" }).tag(&buf));
}

test "the US, Liberia and Myanmar measure in US units; everywhere else is metric" {
    try testing.expectEqual(.imperial, measurementOfCountry("US"));
    try testing.expectEqual(.imperial, measurementOfCountry("lr"));
    try testing.expectEqual(.imperial, measurementOfCountry("MM"));
    try testing.expectEqual(.metric, measurementOfCountry("GB"));
    try testing.expectEqual(.metric, measurementOfCountry("CA"));
}

test "the config wins, then the system, then the first language's country" {
    const langs = [_]Locale{ .{ .language = "de" }, .{ .language = "en", .country = "US" } };
    try testing.expectEqual(.metric, decide(.metric, .imperial, &langs).measurement);
    try testing.expectEqual(.config, decide(.metric, .imperial, &langs).source);
    try testing.expectEqual(.imperial, decide(null, .imperial, &langs).measurement);
    // No system answer: the first language with a country decides.
    const d = decide(null, null, &langs);
    try testing.expectEqual(.imperial, d.measurement);
    try testing.expectEqual(.country, d.source);
    try testing.expectEqual(.default, decide(null, null, &.{.{ .language = "fr" }}).source);
}
