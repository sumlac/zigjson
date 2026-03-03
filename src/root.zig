const std = @import("std");

pub const Integer = union(enum) {
    small: i64,
    big: std.math.big.int.Managed,

    // Public API: eqlI64.
    pub fn eqlI64(self: Integer, expected: i64) bool {
        return switch (self) {
            .small => |value| value == expected,
            .big => |value| (value.toConst().toInt(i64) catch return false) == expected,
        };
    }

    // Public API: toDecimalAlloc.
    pub fn toDecimalAlloc(self: Integer, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return switch (self) {
            .small => |value| std.fmt.allocPrint(allocator, "{d}", .{value}),
            .big => |value| value.toString(allocator, 10, .lower) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidBase => unreachable,
            },
        };
    }
};

pub const JsonValue = union(enum) {
    null,
    bool: bool,
    integer: Integer,
    float: f64,
    string: []const u8,
    array: Array,
    object: ObjectMap,
};

pub const Array = std.array_list.Managed(JsonValue);
pub const ObjectMap = std.StringArrayHashMap(JsonValue);

pub const ObjectPair = struct {
    key: []const u8,
    value: JsonValue,
};

pub const ParsedJson = struct {
    arena: *std.heap.ArenaAllocator,
    value: JsonValue,

    // Public API: deinit.
    pub fn deinit(self: @This()) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
    }
};

pub const LoadsError = std.mem.Allocator.Error || error{
    SyntaxError,
    TrailingData,
    DepthLimitExceeded,
    UnexpectedUtf8Bom,
    InvalidEncoding,
};

pub const ParseNumberHook = *const fn (allocator: std.mem.Allocator, literal: []const u8) LoadsError!JsonValue;
pub const ParseConstantHook = *const fn (allocator: std.mem.Allocator, literal: []const u8) LoadsError!JsonValue;
pub const ObjectHook = *const fn (allocator: std.mem.Allocator, object: JsonValue) LoadsError!JsonValue;
pub const ObjectPairsHook = *const fn (allocator: std.mem.Allocator, pairs: []const ObjectPair) LoadsError!JsonValue;
pub const DecoderHook = *const fn (allocator: std.mem.Allocator, source: []const u8, options: LoadsOptions) LoadsError!JsonValue;

pub const LoadsOptions = struct {
    /// Python's `strict` argument on `json.loads`.
    strict_strings: bool = true,
    /// Max nested array/object depth.
    max_depth: usize = 1024,
    /// If true, copy source once into parse arena so borrowed substrings stay valid.
    copy_input: bool = true,
    /// Python compatibility default: allow `NaN`, `Infinity`, `-Infinity`.
    /// Set to false to reject them unless `parse_constant` is provided.
    allow_nan: bool = true,

    parse_int: ?ParseNumberHook = null,
    parse_float: ?ParseNumberHook = null,
    parse_constant: ?ParseConstantHook = null,
    object_hook: ?ObjectHook = null,
    object_pairs_hook: ?ObjectPairsHook = null,
    /// `cls`-style override: if set, this decoder is used instead of the built-in parser.
    decoder: ?DecoderHook = null,
};

/// Python-str-like API: expects UTF-8 text bytes. Leading UTF-8 BOM is rejected.
// Public API: loads.
pub fn loads(allocator: std.mem.Allocator, source: []const u8) LoadsError!ParsedJson {
    return loadsWithOptions(allocator, source, .{});
}

// Public API: loadsWithOptions.
pub fn loadsWithOptions(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: LoadsOptions,
) LoadsError!ParsedJson {
    if (startsWithUtf8Bom(source)) return error.UnexpectedUtf8Bom;

    var parsed = ParsedJson{
        .arena = try allocator.create(std.heap.ArenaAllocator),
        .value = undefined,
    };
    errdefer allocator.destroy(parsed.arena);

    parsed.arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer parsed.arena.deinit();

    const arena = parsed.arena.allocator();
    const parse_source = if (options.copy_input) try arena.dupe(u8, source) else source;
    parsed.value = try loadsLeaky(arena, parse_source, options);
    return parsed;
}

/// Python-bytes-like API: detects UTF-8/16/32 and BOM, then parses.
// Public API: loadsBytes.
pub fn loadsBytes(allocator: std.mem.Allocator, source: []const u8) LoadsError!ParsedJson {
    return loadsBytesWithOptions(allocator, source, .{});
}

// Public API: loadsBytesWithOptions.
pub fn loadsBytesWithOptions(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: LoadsOptions,
) LoadsError!ParsedJson {
    var parsed = ParsedJson{
        .arena = try allocator.create(std.heap.ArenaAllocator),
        .value = undefined,
    };
    errdefer allocator.destroy(parsed.arena);

    parsed.arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer parsed.arena.deinit();

    const arena = parsed.arena.allocator();
    const utf8 = try decodeJsonBytesToWtf8(arena, source);

    var effective = options;
    effective.copy_input = false;
    parsed.value = try loadsLeaky(arena, utf8, effective);
    return parsed;
}

/// Ultra-low-latency variant: no source copy. Caller keeps source alive.
// Public API: loadsBorrowed.
pub fn loadsBorrowed(allocator: std.mem.Allocator, source: []const u8) LoadsError!ParsedJson {
    var options = LoadsOptions{};
    options.copy_input = false;
    return loadsWithOptions(allocator, source, options);
}

/// Parse into caller-managed memory.
// Public API: loadsLeaky.
pub fn loadsLeaky(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: LoadsOptions,
) LoadsError!JsonValue {
    if (options.decoder) |decoder| {
        return decoder(allocator, source, options);
    }

    var parser = Parser{
        .allocator = allocator,
        .source = source,
        .index = 0,
        .options = options,
    };
    return parser.parse();
}

const Encoding = enum {
    utf8,
    utf16_le,
    utf16_be,
    utf32_le,
    utf32_be,
};

// Internal helper: decodeJsonBytesToWtf8.
fn decodeJsonBytesToWtf8(allocator: std.mem.Allocator, source: []const u8) LoadsError![]const u8 {
    const encoding = detectEncoding(source);
    return switch (encoding) {
        .utf8 => {
            const payload = if (startsWithUtf8Bom(source)) source[3..] else source;
            _ = std.unicode.Wtf8View.init(payload) catch return error.InvalidEncoding;
            return try allocator.dupe(u8, payload);
        },
        .utf16_le => try decodeUtf16(allocator, source, .little),
        .utf16_be => try decodeUtf16(allocator, source, .big),
        .utf32_le => try decodeUtf32(allocator, source, .little),
        .utf32_be => try decodeUtf32(allocator, source, .big),
    };
}

// Internal helper: decodeUtf16.
fn decodeUtf16(
    allocator: std.mem.Allocator,
    source: []const u8,
    endian: std.builtin.Endian,
) LoadsError![]const u8 {
    const start: usize = blk: {
        if (source.len >= 2) {
            if (endian == .little and source[0] == 0xFF and source[1] == 0xFE) break :blk 2;
            if (endian == .big and source[0] == 0xFE and source[1] == 0xFF) break :blk 2;
        }
        break :blk 0;
    };

    const bytes = source[start..];
    if (bytes.len % 2 != 0) return error.InvalidEncoding;

    const count = bytes.len / 2;
    const units = try allocator.alloc(u16, count);
    defer allocator.free(units);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const b0 = bytes[2 * i];
        const b1 = bytes[2 * i + 1];
        units[i] = if (endian == .little)
            (@as(u16, b0) | (@as(u16, b1) << 8))
        else
            (@as(u16, b1) | (@as(u16, b0) << 8));
    }

    return try std.unicode.wtf16LeToWtf8Alloc(allocator, units);
}

// Internal helper: decodeUtf32.
fn decodeUtf32(
    allocator: std.mem.Allocator,
    source: []const u8,
    endian: std.builtin.Endian,
) LoadsError![]const u8 {
    const start: usize = blk: {
        if (source.len >= 4) {
            if (endian == .little and source[0] == 0xFF and source[1] == 0xFE and source[2] == 0x00 and source[3] == 0x00) break :blk 4;
            if (endian == .big and source[0] == 0x00 and source[1] == 0x00 and source[2] == 0xFE and source[3] == 0xFF) break :blk 4;
        }
        break :blk 0;
    };

    const bytes = source[start..];
    if (bytes.len % 4 != 0) return error.InvalidEncoding;

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try out.ensureTotalCapacity(bytes.len);

    var i: usize = 0;
    while (i < bytes.len) : (i += 4) {
        const cp_u32: u32 = if (endian == .little)
            (@as(u32, bytes[i]) |
                (@as(u32, bytes[i + 1]) << 8) |
                (@as(u32, bytes[i + 2]) << 16) |
                (@as(u32, bytes[i + 3]) << 24))
        else
            (@as(u32, bytes[i + 3]) |
                (@as(u32, bytes[i + 2]) << 8) |
                (@as(u32, bytes[i + 1]) << 16) |
                (@as(u32, bytes[i]) << 24));

        if (cp_u32 > 0x10FFFF) return error.InvalidEncoding;

        var tmp: [4]u8 = undefined;
        const n = std.unicode.wtf8Encode(@as(u21, @intCast(cp_u32)), &tmp) catch return error.InvalidEncoding;
        try out.appendSlice(tmp[0..n]);
    }

    return out.toOwnedSlice();
}

// Internal helper: detectEncoding.
fn detectEncoding(source: []const u8) Encoding {
    if (source.len >= 4) {
        if (source[0] == 0x00 and source[1] == 0x00 and source[2] == 0xFE and source[3] == 0xFF) return .utf32_be;
        if (source[0] == 0xFF and source[1] == 0xFE and source[2] == 0x00 and source[3] == 0x00) return .utf32_le;
    }

    if (source.len >= 2) {
        if (source[0] == 0xFE and source[1] == 0xFF) return .utf16_be;
        if (source[0] == 0xFF and source[1] == 0xFE) return .utf16_le;
    }

    if (startsWithUtf8Bom(source)) return .utf8;

    if (source.len >= 4) {
        if (source[0] == 0x00) {
            if (source[1] == 0x00) return .utf32_be;
            return .utf16_be;
        }

        if (source[1] == 0x00) {
            if (source[2] == 0x00 and source[3] != 0x00) return .utf32_le;
            return .utf16_le;
        }
    } else if (source.len == 2) {
        if (source[0] == 0x00 and source[1] != 0x00) return .utf16_be;
        if (source[1] == 0x00 and source[0] != 0x00) return .utf16_le;
    }

    return .utf8;
}

// Internal helper: startsWithUtf8Bom.
fn startsWithUtf8Bom(source: []const u8) bool {
    return source.len >= 3 and source[0] == 0xEF and source[1] == 0xBB and source[2] == 0xBF;
}

const Parser = struct {
    const ByteList = std.array_list.Managed(u8);
    const PairList = std.array_list.Managed(ObjectPair);

    allocator: std.mem.Allocator,
    source: []const u8,
    index: usize,
    options: LoadsOptions,

    // Internal helper: parse.
    fn parse(self: *Parser) LoadsError!JsonValue {
        const value = try self.parseValue(0);
        self.skipWhitespace();
        if (self.index != self.source.len) return error.TrailingData;
        return value;
    }

    // Internal helper: parseValue.
    fn parseValue(self: *Parser, depth: usize) LoadsError!JsonValue {
        self.skipWhitespace();

        const c = self.peek() orelse return error.SyntaxError;
        return switch (c) {
            '{' => try self.parseObject(depth),
            '[' => try self.parseArray(depth),
            '"' => JsonValue{ .string = try self.parseString() },
            't' => blk: {
                if (!self.matchLiteral("true")) return error.SyntaxError;
                self.index += 4;
                break :blk JsonValue{ .bool = true };
            },
            'f' => blk: {
                if (!self.matchLiteral("false")) return error.SyntaxError;
                self.index += 5;
                break :blk JsonValue{ .bool = false };
            },
            'n' => blk: {
                if (!self.matchLiteral("null")) return error.SyntaxError;
                self.index += 4;
                break :blk JsonValue.null;
            },
            'N' => blk: {
                if (!self.matchLiteral("NaN")) return error.SyntaxError;
                self.index += 3;

                if (self.options.parse_constant) |hook| {
                    break :blk try hook(self.allocator, "NaN");
                }
                if (!self.options.allow_nan) return error.SyntaxError;
                break :blk JsonValue{ .float = std.math.nan(f64) };
            },
            'I' => blk: {
                if (!self.matchLiteral("Infinity")) return error.SyntaxError;
                self.index += 8;

                if (self.options.parse_constant) |hook| {
                    break :blk try hook(self.allocator, "Infinity");
                }
                if (!self.options.allow_nan) return error.SyntaxError;
                break :blk JsonValue{ .float = std.math.inf(f64) };
            },
            '-' => blk: {
                if (self.matchLiteral("-Infinity")) {
                    self.index += 9;
                    if (self.options.parse_constant) |hook| {
                        break :blk try hook(self.allocator, "-Infinity");
                    }
                    if (!self.options.allow_nan) return error.SyntaxError;
                    break :blk JsonValue{ .float = -std.math.inf(f64) };
                }
                break :blk try self.parseNumber();
            },
            '0'...'9' => try self.parseNumber(),
            else => error.SyntaxError,
        };
    }

    // Internal helper: parseObject.
    fn parseObject(self: *Parser, depth: usize) LoadsError!JsonValue {
        if (depth >= self.options.max_depth) return error.DepthLimitExceeded;

        self.index += 1; // '{'
        self.skipWhitespace();

        if (self.options.object_pairs_hook) |pairs_hook| {
            var pairs = PairList.init(self.allocator);
            defer pairs.deinit();

            if (!self.consumeByte('}')) {
                while (true) {
                    if (self.peek() != '"') return error.SyntaxError;
                    const key = try self.parseString();

                    self.skipWhitespace();
                    if (!self.consumeByte(':')) return error.SyntaxError;

                    const value = try self.parseValue(depth + 1);
                    try pairs.append(.{ .key = key, .value = value });

                    self.skipWhitespace();
                    if (self.consumeByte('}')) break;
                    if (!self.consumeByte(',')) return error.SyntaxError;
                }
            }

            return pairs_hook(self.allocator, pairs.items);
        }

        var object = ObjectMap.init(self.allocator);

        if (!self.consumeByte('}')) {
            while (true) {
                if (self.peek() != '"') return error.SyntaxError;
                const key = try self.parseString();

                self.skipWhitespace();
                if (!self.consumeByte(':')) return error.SyntaxError;

                const value = try self.parseValue(depth + 1);

                const gop = try object.getOrPut(key);
                gop.value_ptr.* = value;

                self.skipWhitespace();
                if (self.consumeByte('}')) break;
                if (!self.consumeByte(',')) return error.SyntaxError;
            }
        }

        const obj_value = JsonValue{ .object = object };
        if (self.options.object_hook) |hook| {
            return hook(self.allocator, obj_value);
        }
        return obj_value;
    }

    // Internal helper: parseArray.
    fn parseArray(self: *Parser, depth: usize) LoadsError!JsonValue {
        if (depth >= self.options.max_depth) return error.DepthLimitExceeded;

        self.index += 1; // '['
        self.skipWhitespace();

        var array = Array.init(self.allocator);

        if (self.consumeByte(']')) {
            return JsonValue{ .array = array };
        }

        while (true) {
            const value = try self.parseValue(depth + 1);
            try array.append(value);

            self.skipWhitespace();
            if (self.consumeByte(']')) break;
            if (!self.consumeByte(',')) return error.SyntaxError;
        }

        return JsonValue{ .array = array };
    }

    // Internal helper: parseString.
    fn parseString(self: *Parser) LoadsError![]const u8 {
        if (!self.consumeByte('"')) return error.SyntaxError;

        const start = self.index;
        var i = start;
        while (i < self.source.len) : (i += 1) {
            const c = self.source[i];
            if (c == '"') {
                self.index = i + 1;
                return self.source[start..i];
            }
            if (c == '\\' or (self.options.strict_strings and c < 0x20)) break;
        }

        if (i >= self.source.len) return error.SyntaxError;

        var out = ByteList.init(self.allocator);
        try out.appendSlice(self.source[start..i]);
        self.index = i;

        while (self.index < self.source.len) {
            const chunk_start = self.index;
            var j = chunk_start;
            while (j < self.source.len) : (j += 1) {
                const cj = self.source[j];
                if (cj == '"' or cj == '\\' or (self.options.strict_strings and cj < 0x20)) break;
            }
            if (j > chunk_start) {
                try out.appendSlice(self.source[chunk_start..j]);
                self.index = j;
            }

            if (self.index >= self.source.len) return error.SyntaxError;
            const c = self.source[self.index];
            switch (c) {
                '"' => {
                    self.index += 1;
                    return try out.toOwnedSlice();
                },
                '\\' => {
                    self.index += 1;
                    const esc = self.peek() orelse return error.SyntaxError;
                    self.index += 1;

                    switch (esc) {
                        '"' => try out.append('"'),
                        '\\' => try out.append('\\'),
                        '/' => try out.append('/'),
                        'b' => try out.append(0x08),
                        'f' => try out.append(0x0C),
                        'n' => try out.append('\n'),
                        'r' => try out.append('\r'),
                        't' => try out.append('\t'),
                        'u' => try self.parseUnicodeEscape(&out),
                        else => return error.SyntaxError,
                    }
                },
                0...0x1F => {
                    if (self.options.strict_strings) return error.SyntaxError;
                    try out.append(c);
                    self.index += 1;
                },
                else => unreachable,
            }
        }

        return error.SyntaxError;
    }

    // Internal helper: parseUnicodeEscape.
    fn parseUnicodeEscape(self: *Parser, out: *ByteList) LoadsError!void {
        const first = try self.parseHex4();

        if (first >= 0xD800 and first <= 0xDBFF) {
            // Pair only if the next escape is a valid low surrogate.
            if (self.index + 6 <= self.source.len and self.source[self.index] == '\\' and self.source[self.index + 1] == 'u') {
                const second = parseHex4Slice(self.source[self.index + 2 .. self.index + 6]) orelse {
                    try self.appendCodepoint(out, @as(u21, first));
                    return;
                };

                if (second >= 0xDC00 and second <= 0xDFFF) {
                    self.index += 6;
                    const high10: u21 = @as(u21, first - 0xD800);
                    const low10: u21 = @as(u21, second - 0xDC00);
                    const codepoint: u21 = 0x10000 + (high10 << 10) + low10;
                    try self.appendCodepoint(out, codepoint);
                    return;
                }
            }

            try self.appendCodepoint(out, @as(u21, first));
            return;
        }

        // Python preserves lone low surrogates too.
        try self.appendCodepoint(out, @as(u21, first));
    }

    // Internal helper: appendCodepoint.
    fn appendCodepoint(self: *Parser, out: *ByteList, cp: u21) LoadsError!void {
        _ = self;
        var buf: [4]u8 = undefined;
        const len = std.unicode.wtf8Encode(cp, &buf) catch return error.SyntaxError;
        try out.appendSlice(buf[0..len]);
    }

    // Internal helper: parseHex4.
    fn parseHex4(self: *Parser) LoadsError!u16 {
        if (self.index + 4 > self.source.len) return error.SyntaxError;

        const slice = self.source[self.index .. self.index + 4];
        const value = parseHex4Slice(slice) orelse return error.SyntaxError;
        self.index += 4;
        return value;
    }

    // Internal helper: parseNumber.
    fn parseNumber(self: *Parser) LoadsError!JsonValue {
        const start = self.index;
        var negative = false;
        var int_accum: u64 = 0;
        var int_overflow = false;

        if (self.consumeByte('-')) {
            negative = true;
            if (self.index >= self.source.len) return error.SyntaxError;
        }

        if (self.consumeByte('0')) {
            if (self.index < self.source.len and isDigit(self.source[self.index])) return error.SyntaxError;
        } else {
            const first = self.peek() orelse return error.SyntaxError;
            if (first < '1' or first > '9') return error.SyntaxError;
            while (self.index < self.source.len and isDigit(self.source[self.index])) {
                const digit: u64 = @as(u64, self.source[self.index] - '0');
                if (!int_overflow) {
                    if (int_accum > (std.math.maxInt(u64) - digit) / 10) {
                        int_overflow = true;
                    } else {
                        int_accum = int_accum * 10 + digit;
                    }
                }
                self.index += 1;
            }
        }

        var is_float = false;

        if (self.consumeByte('.')) {
            is_float = true;
            const first_frac = self.peek() orelse return error.SyntaxError;
            if (!isDigit(first_frac)) return error.SyntaxError;

            self.index += 1;
            while (self.index < self.source.len and isDigit(self.source[self.index])) {
                self.index += 1;
            }
        }

        if (self.index < self.source.len and (self.source[self.index] == 'e' or self.source[self.index] == 'E')) {
            is_float = true;
            self.index += 1;

            if (self.index < self.source.len and (self.source[self.index] == '+' or self.source[self.index] == '-')) {
                self.index += 1;
            }

            const first_exp = self.peek() orelse return error.SyntaxError;
            if (!isDigit(first_exp)) return error.SyntaxError;

            self.index += 1;
            while (self.index < self.source.len and isDigit(self.source[self.index])) {
                self.index += 1;
            }
        }

        const number_slice = self.source[start..self.index];

        if (is_float) {
            if (self.options.parse_float) |hook| {
                return hook(self.allocator, number_slice);
            }
            const value = std.fmt.parseFloat(f64, number_slice) catch return error.SyntaxError;
            return JsonValue{ .float = value };
        }

        if (self.options.parse_int) |hook| {
            return hook(self.allocator, number_slice);
        }

        if (!int_overflow) {
            const max_pos: u64 = @as(u64, @intCast(std.math.maxInt(i64)));
            if (negative) {
                const min_magnitude = max_pos + 1;
                if (int_accum <= max_pos) {
                    const signed: i64 = -@as(i64, @intCast(int_accum));
                    return JsonValue{ .integer = .{ .small = signed } };
                }
                if (int_accum == min_magnitude) {
                    return JsonValue{ .integer = .{ .small = std.math.minInt(i64) } };
                }
            } else if (int_accum <= max_pos) {
                return JsonValue{ .integer = .{ .small = @as(i64, @intCast(int_accum)) } };
            }
        }

        var big = try std.math.big.int.Managed.init(self.allocator);
        big.setString(10, number_slice) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCharacter, error.InvalidBase => return error.SyntaxError,
        };
        return JsonValue{ .integer = .{ .big = big } };
    }

    // Internal helper: skipWhitespace.
    fn skipWhitespace(self: *Parser) void {
        while (self.index < self.source.len) {
            switch (self.source[self.index]) {
                ' ', '\t', '\n', '\r' => self.index += 1,
                else => return,
            }
        }
    }

    // Internal helper: peek.
    fn peek(self: *Parser) ?u8 {
        if (self.index < self.source.len) return self.source[self.index];
        return null;
    }

    // Internal helper: consumeByte.
    fn consumeByte(self: *Parser, byte: u8) bool {
        if (self.index < self.source.len and self.source[self.index] == byte) {
            self.index += 1;
            return true;
        }
        return false;
    }

    // Internal helper: matchLiteral.
    fn matchLiteral(self: *Parser, literal: []const u8) bool {
        return self.index + literal.len <= self.source.len and
            std.mem.eql(u8, self.source[self.index .. self.index + literal.len], literal);
    }
};

// Internal helper: parseHex4Slice.
fn parseHex4Slice(slice: []const u8) ?u16 {
    if (slice.len != 4) return null;

    var result: u16 = 0;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const nibble = hexNibble(slice[i]) orelse return null;
        result = (result << 4) | nibble;
    }
    return result;
}

// Internal helper: hexNibble.
fn hexNibble(c: u8) ?u16 {
    return switch (c) {
        '0'...'9' => @as(u16, c - '0'),
        'a'...'f' => 10 + @as(u16, c - 'a'),
        'A'...'F' => 10 + @as(u16, c - 'A'),
        else => null,
    };
}

// Internal helper: isDigit.
fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

// Internal helper: parseIntAsStringHook.
fn parseIntAsStringHook(_: std.mem.Allocator, literal: []const u8) LoadsError!JsonValue {
    return JsonValue{ .string = literal };
}

// Internal helper: parseFloatAsStringHook.
fn parseFloatAsStringHook(_: std.mem.Allocator, literal: []const u8) LoadsError!JsonValue {
    return JsonValue{ .string = literal };
}

// Internal helper: rejectConstantHook.
fn rejectConstantHook(_: std.mem.Allocator, _: []const u8) LoadsError!JsonValue {
    return error.SyntaxError;
}

// Internal helper: objectHookToString.
fn objectHookToString(_: std.mem.Allocator, _: JsonValue) LoadsError!JsonValue {
    return JsonValue{ .string = "object_hook" };
}

// Internal helper: objectPairsHookKeys.
fn objectPairsHookKeys(allocator: std.mem.Allocator, pairs: []const ObjectPair) LoadsError!JsonValue {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < pairs.len) : (i += 1) {
        if (i != 0) try out.append(',');
        try out.appendSlice(pairs[i].key);
    }

    return JsonValue{ .string = try out.toOwnedSlice() };
}

// Internal helper: decoderHookLiteral.
fn decoderHookLiteral(_: std.mem.Allocator, _: []const u8, _: LoadsOptions) LoadsError!JsonValue {
    return JsonValue{ .string = "decoder_hook" };
}

// Test case coverage for parser parity and safety.
test "loads parses nested JSON values" {
    const parsed = try loads(
        std.testing.allocator,
        "{\"null_value\":null,\"flag\":true,\"count\":7,\"ratio\":3.5,\"name\":\"zig\",\"list\":[1,2,3],\"nested\":{\"answer\":42}}",
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    const object = parsed.value.object;

    const null_value = object.get("null_value") orelse return error.TestUnexpectedResult;
    try std.testing.expect(null_value == .null);

    const flag = object.get("flag") orelse return error.TestUnexpectedResult;
    try std.testing.expect(flag == .bool);
    try std.testing.expectEqual(true, flag.bool);

    const count = object.get("count") orelse return error.TestUnexpectedResult;
    try std.testing.expect(count == .integer);
    try std.testing.expect(count.integer.eqlI64(7));

    const ratio = object.get("ratio") orelse return error.TestUnexpectedResult;
    try std.testing.expect(ratio == .float);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), ratio.float, 1e-12);

    const name = object.get("name") orelse return error.TestUnexpectedResult;
    try std.testing.expect(name == .string);
    try std.testing.expectEqualStrings("zig", name.string);

    const list = object.get("list") orelse return error.TestUnexpectedResult;
    try std.testing.expect(list == .array);
    try std.testing.expectEqual(@as(usize, 3), list.array.items.len);
    try std.testing.expect(list.array.items[0].integer.eqlI64(1));
    try std.testing.expect(list.array.items[1].integer.eqlI64(2));
    try std.testing.expect(list.array.items[2].integer.eqlI64(3));

    const nested = object.get("nested") orelse return error.TestUnexpectedResult;
    try std.testing.expect(nested == .object);
    const answer = nested.object.get("answer") orelse return error.TestUnexpectedResult;
    try std.testing.expect(answer == .integer);
    try std.testing.expect(answer.integer.eqlI64(42));
}

// Test case coverage for parser parity and safety.
test "default duplicate key behavior matches Python (last key wins)" {
    const parsed = try loads(std.testing.allocator, "{\"x\":1,\"x\":2}");
    defer parsed.deinit();

    const x = parsed.value.object.get("x") orelse return error.TestUnexpectedResult;
    try std.testing.expect(x == .integer);
    try std.testing.expect(x.integer.eqlI64(2));
}

// Test case coverage for parser parity and safety.
test "arbitrary precision integer parity" {
    const parsed = try loads(std.testing.allocator, "922337203685477580812345678901234567890");
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .integer);
    const text = try parsed.value.integer.toDecimalAlloc(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("922337203685477580812345678901234567890", text);
}

// Test case coverage for parser parity and safety.
test "loads accepts NaN and Infinity by default" {
    const parsed = try loads(std.testing.allocator, "[NaN,Infinity,-Infinity]");
    defer parsed.deinit();

    const items = parsed.value.array.items;
    try std.testing.expect(std.math.isNan(items[0].float));
    try std.testing.expect(items[1].float == std.math.inf(f64));
    try std.testing.expect(items[2].float == -std.math.inf(f64));
}

// Test case coverage for parser parity and safety.
test "parse_constant hook can reject constants" {
    try std.testing.expectError(
        error.SyntaxError,
        loadsWithOptions(std.testing.allocator, "NaN", .{ .parse_constant = rejectConstantHook }),
    );
}

// Test case coverage for parser parity and safety.
test "parse_int and parse_float hooks receive raw literals" {
    const ints = try loadsWithOptions(std.testing.allocator, "[-0,12345678901234567890]", .{
        .parse_int = parseIntAsStringHook,
    });
    defer ints.deinit();

    try std.testing.expectEqualStrings("-0", ints.value.array.items[0].string);
    try std.testing.expectEqualStrings("12345678901234567890", ints.value.array.items[1].string);

    const floats = try loadsWithOptions(std.testing.allocator, "[1.25,-2e+03]", .{
        .parse_float = parseFloatAsStringHook,
    });
    defer floats.deinit();

    try std.testing.expectEqualStrings("1.25", floats.value.array.items[0].string);
    try std.testing.expectEqualStrings("-2e+03", floats.value.array.items[1].string);
}

// Test case coverage for parser parity and safety.
test "object_hook and object_pairs_hook parity" {
    const pairs_first = try loadsWithOptions(std.testing.allocator, "{\"x\":1,\"x\":2,\"y\":3}", .{
        .object_hook = objectHookToString,
        .object_pairs_hook = objectPairsHookKeys,
    });
    defer pairs_first.deinit();

    try std.testing.expect(pairs_first.value == .string);
    try std.testing.expectEqualStrings("x,x,y", pairs_first.value.string);

    const object_only = try loadsWithOptions(std.testing.allocator, "{\"x\":1}", .{
        .object_hook = objectHookToString,
    });
    defer object_only.deinit();

    try std.testing.expect(object_only.value == .string);
    try std.testing.expectEqualStrings("object_hook", object_only.value.string);
}

// Test case coverage for parser parity and safety.
test "cls-like decoder hook can override parsing" {
    const parsed = try loadsWithOptions(std.testing.allocator, "{\"x\":1}", .{
        .decoder = decoderHookLiteral,
    });
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .string);
    try std.testing.expectEqualStrings("decoder_hook", parsed.value.string);
}

// Test case coverage for parser parity and safety.
test "unicode escape parity includes lone surrogates" {
    const paired = try loads(std.testing.allocator, "\"\\uD83D\\uDE80\"");
    defer paired.deinit();
    try std.testing.expectEqualStrings("\xF0\x9F\x9A\x80", paired.value.string);

    const lone = try loads(std.testing.allocator, "\"\\uD800\"");
    defer lone.deinit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xED, 0xA0, 0x80 }, lone.value.string);
}

// Test case coverage for parser parity and safety.
test "strict string behavior parity" {
    try std.testing.expectError(error.SyntaxError, loads(std.testing.allocator, "\"\x01\""));

    const parsed = try loadsWithOptions(
        std.testing.allocator,
        "\"a\x01b\"",
        .{ .strict_strings = false },
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("a\x01b", parsed.value.string);
}

// Test case coverage for parser parity and safety.
test "loads rejects UTF-8 BOM for text input" {
    try std.testing.expectError(
        error.UnexpectedUtf8Bom,
        loads(std.testing.allocator, "\xEF\xBB\xBF{}"),
    );
}

// Test case coverage for parser parity and safety.
test "loadsBytes handles utf-8, utf-16, utf-32" {
    const utf8 = try loadsBytes(std.testing.allocator, "\xEF\xBB\xBF{\"x\":1}");
    defer utf8.deinit();
    try std.testing.expect((utf8.value.object.get("x") orelse return error.TestUnexpectedResult).integer.eqlI64(1));

    const utf16le = [_]u8{ 0xFF, 0xFE, '{', 0, '"', 0, 'x', 0, '"', 0, ':', 0, '1', 0, '}', 0 };
    const parsed16 = try loadsBytes(std.testing.allocator, &utf16le);
    defer parsed16.deinit();
    try std.testing.expect((parsed16.value.object.get("x") orelse return error.TestUnexpectedResult).integer.eqlI64(1));

    const utf32be = [_]u8{
        0x00, 0x00, 0xFE, 0xFF,
        0x00, 0x00, 0x00, '{',
        0x00, 0x00, 0x00, '"',
        0x00, 0x00, 0x00, 'x',
        0x00, 0x00, 0x00, '"',
        0x00, 0x00, 0x00, ':',
        0x00, 0x00, 0x00, '1',
        0x00, 0x00, 0x00, '}',
    };
    const parsed32 = try loadsBytes(std.testing.allocator, &utf32be);
    defer parsed32.deinit();
    try std.testing.expect((parsed32.value.object.get("x") orelse return error.TestUnexpectedResult).integer.eqlI64(1));

    const invalid_utf8 = [_]u8{ 0x80, '{', '}' };
    try std.testing.expectError(error.InvalidEncoding, loadsBytes(std.testing.allocator, &invalid_utf8));
}

// Test case coverage for parser parity and safety.
test "loads returns syntax and trailing data errors" {
    try std.testing.expectError(error.SyntaxError, loads(std.testing.allocator, "{\"x\":}"));
    try std.testing.expectError(error.SyntaxError, loads(std.testing.allocator, "[1,]"));
    try std.testing.expectError(error.TrailingData, loads(std.testing.allocator, "{} {}"));
}

// Test case coverage for parser parity and safety.
test "loads enforces depth limits" {
    try std.testing.expectError(
        error.DepthLimitExceeded,
        loadsWithOptions(std.testing.allocator, "[[[0]]]", .{ .max_depth = 2 }),
    );
}

// Test case coverage for parser parity and safety.
test "loadsBorrowed reuses source bytes and default loads copies" {
    const source = "{\"x\":\"hello\"}";

    const borrowed = try loadsBorrowed(std.testing.allocator, source);
    defer borrowed.deinit();
    const bx = borrowed.value.object.get("x") orelse return error.TestUnexpectedResult;
    try std.testing.expect(@intFromPtr(bx.string.ptr) == @intFromPtr(source[6..11].ptr));

    const copied = try loads(std.testing.allocator, source);
    defer copied.deinit();
    const cx = copied.value.object.get("x") orelse return error.TestUnexpectedResult;
    try std.testing.expect(@intFromPtr(cx.string.ptr) != @intFromPtr(source[6..11].ptr));
}
