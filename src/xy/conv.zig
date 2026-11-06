//! Zero-heap Bunsetsu-based Kana-Kanji conversion engine for nihos.
//!
//! Uses NFST / MeOS radix dictionary with Viterbi DP to cut Japanese text
//! into natural phrases (bunsetsu), matching stems and function word chains (TAILS).

const std = @import("std");
const dict_mod = @import("dict.zig");
pub const NfstDict = dict_mod.NfstDict;
const code_section = @import("ime_omni.zig").code_section;
const data_section = if (@import("builtin").os.tag == .freestanding) ".flash.xyrodata" else if (@import("builtin").object_format == .macho) "__DATA_CONST,__const" else ".rodata";

pub const max_reading = 128;
pub const max_segments = 32;
pub const max_candidates = 32;
pub const max_cand_pool = 1024;
pub const inf_cost: i32 = 0x3fff_ffff;

pub const TailMask = struct {
    pub const noun: u8 = 1;
    pub const word: u8 = 2;
    pub const any: u8 = 3;
    pub const plain: u8 = 4;
};

pub const ConjClass = struct {
    pub const a: u16 = 1; // mizenkei
    pub const i: u16 = 2; // renyokei
    pub const u: u16 = 4; // shushikei / dictionary form
    pub const e: u16 = 8; // kateikei / ichidan stem
    pub const o: u16 = 16; // volitional
    pub const x: u16 = 32; // sokuon / hatsuon before ta/te
    pub const late: u16 = 64; // can chain after another function word
    pub const adj: u16 = 128; // adjective stem (kawa-i, etc.)
    pub const head: u16 = 0xbf;
};

pub const TailDef = struct {
    str: []const u8,
    mask: u8,
    class: u16,
};

pub const TAILS linksection(data_section) = [_]TailDef{
    // Particles (Plain / Any)
    .{ .str = "を", .mask = TailMask.any, .class = ConjClass.u },
    .{ .str = "に", .mask = TailMask.any, .class = ConjClass.u | ConjClass.i },
    .{ .str = "へ", .mask = TailMask.any, .class = ConjClass.u },
    .{ .str = "や", .mask = TailMask.any, .class = ConjClass.u },
    .{ .str = "まで", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "より", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "だけ", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "しか", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "ほど", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "くらい", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "ぐらい", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "など", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "で", .mask = TailMask.any, .class = ConjClass.u },
    .{ .str = "から", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "ので", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "のに", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "なら", .mask = TailMask.any, .class = ConjClass.u },
    .{ .str = "ならば", .mask = TailMask.any, .class = ConjClass.u },
    .{ .str = "こと", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "ため", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "ように", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    // Late particles
    .{ .str = "は", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "が", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "と", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "も", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "の", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "か", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "ね", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "よ", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "な", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "です", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "でした", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "だ", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "だった", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "である", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "ですか", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "ですね", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    .{ .str = "ですよ", .mask = TailMask.any, .class = ConjClass.u | ConjClass.late },
    // Conjugation endings
    .{ .str = "ない", .mask = TailMask.word, .class = ConjClass.a | ConjClass.e },
    .{ .str = "なかった", .mask = TailMask.word, .class = ConjClass.a | ConjClass.e },
    .{ .str = "なくて", .mask = TailMask.word, .class = ConjClass.a | ConjClass.e },
    .{ .str = "ます", .mask = TailMask.word, .class = ConjClass.i | ConjClass.e },
    .{ .str = "ました", .mask = TailMask.word, .class = ConjClass.i | ConjClass.e },
    .{ .str = "ません", .mask = TailMask.word, .class = ConjClass.i | ConjClass.e },
    .{ .str = "て", .mask = TailMask.word, .class = ConjClass.e | ConjClass.x },
    .{ .str = "た", .mask = TailMask.word, .class = ConjClass.e | ConjClass.x },
    .{ .str = "たら", .mask = TailMask.word, .class = ConjClass.e | ConjClass.x },
    .{ .str = "たり", .mask = TailMask.word, .class = ConjClass.e | ConjClass.x },
    .{ .str = "ている", .mask = TailMask.word, .class = ConjClass.e | ConjClass.x },
    .{ .str = "ていた", .mask = TailMask.word, .class = ConjClass.e | ConjClass.x },
    .{ .str = "ています", .mask = TailMask.word, .class = ConjClass.e | ConjClass.x },
    .{ .str = "てください", .mask = TailMask.word, .class = ConjClass.e | ConjClass.x },
    .{ .str = "たい", .mask = TailMask.word, .class = ConjClass.i | ConjClass.e },
    .{ .str = "る", .mask = TailMask.word, .class = ConjClass.e },
    .{ .str = "ば", .mask = TailMask.word, .class = ConjClass.e },
    .{ .str = "い", .mask = TailMask.word, .class = ConjClass.adj },
    .{ .str = "く", .mask = TailMask.word, .class = ConjClass.adj },
    .{ .str = "くて", .mask = TailMask.word, .class = ConjClass.adj },
    .{ .str = "かった", .mask = TailMask.word, .class = ConjClass.adj },
    // Suru verbs
    .{ .str = "する", .mask = TailMask.noun, .class = 0 },
    .{ .str = "した", .mask = TailMask.noun, .class = 0 },
    .{ .str = "して", .mask = TailMask.noun, .class = 0 },
    .{ .str = "します", .mask = TailMask.noun, .class = 0 },
    .{ .str = "しない", .mask = TailMask.noun, .class = 0 },
    .{ .str = "できる", .mask = TailMask.noun, .class = 0 },
};

pub const Segment = struct {
    start: u8 = 0,
    end: u8 = 0,
    dict_end: u8 = 0,
    is_ari: bool = false,
    cand_count: u8 = 0,
    selected: u8 = 0,
    cands: [max_candidates]u16 = @splat(0), // offsets into candidate pool
};

pub const Engine = struct {
    reading_buf: [max_reading]u8 = @splat(0),
    reading_len: usize = 0,

    segments: [max_segments]Segment = @splat(.{}),
    segment_count: usize = 0,

    cand_pool: [max_cand_pool]u8 = @splat(0),
    cand_pool_len: usize = 0,

    dp_cost: [max_reading + 1]i32 = @splat(0),
    dp_back: [max_reading + 1]u8 = @splat(0),
    dp_dict_end: [max_reading + 1]u8 = @splat(0),
    dp_is_ari: [max_reading + 1]bool = @splat(false),

    pub fn init() linksection(code_section) Engine {
        return .{};
    }

    /// Convert reading (hiragana UTF-8 string) into bunsetsu segments using Viterbi DP.
    pub fn convert(self: *Engine, dict: *const NfstDict, reading: []const u8) linksection(code_section) void {
        const len = @min(reading.len, max_reading);
        @memcpy(self.reading_buf[0..len], reading[0..len]);
        self.reading_len = len;
        self.cand_pool_len = 0;
        self.segment_count = 0;

        if (len == 0) return;

        // DP table initialization
        for (0..len + 1) |i| {
            self.dp_cost[i] = inf_cost;
            self.dp_back[i] = 0;
            self.dp_dict_end[i] = 0;
            self.dp_is_ari[i] = false;
        }
        self.dp_cost[0] = 0;

        // Viterbi DP forward search
        for (0..len) |i| {
            if (self.dp_cost[i] >= inf_cost) continue;

            const max_j = @min(len, i + 48); // limit phrase length
            var j = i + 1;
            while (j <= max_j) : (j += 1) {
                // Ensure valid UTF-8 boundary
                if (j < len and (reading[j] & 0xc0) == 0x80) continue;

                var best_k: u8 = @intCast(i);
                var is_ari = false;
                const cost = self.calcPhraseCost(dict, reading[i..j], @intCast(i), &best_k, &is_ari);
                if (cost < inf_cost) {
                    const total = self.dp_cost[i] + cost;
                    if (total < self.dp_cost[j]) {
                        self.dp_cost[j] = total;
                        self.dp_back[j] = @intCast(i);
                        self.dp_dict_end[j] = best_k;
                        self.dp_is_ari[j] = is_ari;
                    }
                }
            }
        }

        // Backtrack DP path into segments
        var rev_segs: [max_segments]Segment = @splat(.{});
        var rev_count: usize = 0;
        var curr: usize = len;

        while (curr > 0 and rev_count < max_segments) {
            const prev = self.dp_back[curr];
            rev_segs[rev_count] = .{
                .start = prev,
                .end = @intCast(curr),
                .dict_end = self.dp_dict_end[curr],
                .is_ari = self.dp_is_ari[curr],
                .cand_count = 0,
                .selected = 0,
            };
            rev_count += 1;
            curr = prev;
        }

        // Reverse to forward order
        self.segment_count = rev_count;
        for (0..rev_count) |i| {
            self.segments[i] = rev_segs[rev_count - 1 - i];
            self.populateCandidates(dict, &self.segments[i]);
        }
    }

    /// Calculate cost for reading phrase [i..j)
    fn calcPhraseCost(self: *Engine, dict: *const NfstDict, phrase: []const u8, start_offset: u8, best_k: *u8, is_ari: *bool) linksection(code_section) i32 {
        _ = self;
        var min_cost = inf_cost;
        var bk = start_offset;
        var ari = false;

        const seg_base: i32 = 1200;
        const word_bonus: i32 = 150;
        const tail_bonus: i32 = 200;
        const one_kana_penalty: i32 = 700;

        // Try plain dictionary lookup (nasi)
        var k_len: usize = 1;
        while (k_len <= phrase.len) : (k_len += 1) {
            if (k_len < phrase.len and (phrase[k_len] & 0xc0) == 0x80) continue;

            const stem = phrase[0..k_len];
            const tail = phrase[k_len..];

            // 1. Plain noun / word
            var dummy_cand: [1][]const u8 = undefined;
            if (dict.lookup(stem, &dummy_cand) > 0) {
                if (checkTail(tail, TailMask.noun)) {
                    const char_count: i32 = @intCast(std.unicode.utf8CountCodepoints(stem) catch 1);
                    var cost = seg_base - @min(char_count, 6) * word_bonus;
                    if (char_count == 1) cost += one_kana_penalty;
                    if (tail.len > 0) cost -= tail_bonus;
                    if (cost < min_cost) {
                        min_cost = cost;
                        bk = start_offset + @as(u8, @intCast(k_len));
                        ari = false;
                    }
                }
            }

            // 2. Conjugating word (ari): stem + okuri
            if (k_len < phrase.len) {
                // Determine okuri initial consonant
                if (getOkuriConsonant(phrase[k_len..])) |okuri_info| {
                    var ari_key_buf: [64]u8 = undefined;
                    if (stem.len + 1 <= ari_key_buf.len) {
                        @memcpy(ari_key_buf[0..stem.len], stem);
                        ari_key_buf[stem.len] = okuri_info.consonant;
                        const ari_key = ari_key_buf[0 .. stem.len + 1];

                        if (dict.lookup(ari_key, &dummy_cand) > 0) {
                            const rem_tail = phrase[k_len + okuri_info.kana_len ..];
                            if (checkConjugationTail(rem_tail, okuri_info.class)) {
                                const char_count: i32 = @intCast(std.unicode.utf8CountCodepoints(stem) catch 1);
                                var cost = seg_base - @min(char_count + 1, 6) * word_bonus + 150; // Prefer an exact dictionary word over a coincidental inflection.
                                if (rem_tail.len > 0) cost -= tail_bonus;
                                if (cost < min_cost) {
                                    min_cost = cost;
                                    bk = start_offset + @as(u8, @intCast(k_len + okuri_info.kana_len));
                                    ari = true;
                                }
                            }
                        }
                    }
                }
            }
        }

        // Tail-only phrase fallback
        if (min_cost == inf_cost and checkTail(phrase, TailMask.any)) {
            min_cost = 1100;
            bk = start_offset;
            ari = false;
        }

        // Unknown run fallback
        if (min_cost == inf_cost) {
            const cp_count: i32 = @intCast(std.unicode.utf8CountCodepoints(phrase) catch 1);
            min_cost = 1500 + 150 * cp_count;
            bk = start_offset;
            ari = false;
        }

        best_k.* = bk;
        is_ari.* = ari;
        return min_cost;
    }

    fn populateCandidates(self: *Engine, dict: *const NfstDict, seg: *Segment) linksection(code_section) void {
        const phrase = self.reading_buf[seg.start..seg.end];
        const dict_part = self.reading_buf[seg.start..seg.dict_end];
        const tail_part = self.reading_buf[seg.dict_end..seg.end];

        seg.cand_count = 0;

        if (seg.dict_end > seg.start) {
            var cand_list: [max_candidates][]const u8 = undefined;
            if (seg.is_ari) {
                // Conjugating word: dict lookup was stem + consonant
                const stem_len = seg.dict_end - seg.start - (getOkuriKanaLen(phrase) orelse 0);
                const stem = phrase[0..stem_len];
                if (getOkuriConsonant(phrase[stem_len..])) |okuri_info| {
                    var key_buf: [64]u8 = undefined;
                    @memcpy(key_buf[0..stem.len], stem);
                    key_buf[stem.len] = okuri_info.consonant;
                    const count = dict.lookup(key_buf[0 .. stem.len + 1], &cand_list);
                    for (cand_list[0..count]) |cand| {
                        self.addCombinedCandidate(seg, cand, phrase[stem_len..]);
                        if (seg.cand_count >= max_candidates - 2) break;
                    }
                }
            } else {
                // Plain word: dict lookup on dict_part
                const count = dict.lookup(dict_part, &cand_list);
                for (cand_list[0..count]) |cand| {
                    self.addCombinedCandidate(seg, cand, tail_part);
                    if (seg.cand_count >= max_candidates - 2) break;
                }
            }
        }

        // A plain spelling and an inflected verb can have the same reading
        // (いく: 郁 / 行く). Keep both kinds in the candidate list.
        if (!seg.is_ari) {
            var split: usize = 1;
            while (split < phrase.len) : (split += 1) {
                if (phrase[split] & 0xc0 == 0x80) continue;
                const okuri = getOkuriConsonant(phrase[split..]) orelse continue;
                if (!checkConjugationTail(phrase[split + okuri.kana_len ..], okuri.class)) continue;
                var key: [64]u8 = undefined;
                if (split + 1 > key.len) continue;
                @memcpy(key[0..split], phrase[0..split]);
                key[split] = okuri.consonant;
                var found: [max_candidates][]const u8 = undefined;
                const count = dict.lookup(key[0 .. split + 1], &found);
                for (found[0..count]) |cand| {
                    self.addCombinedCandidate(seg, cand, phrase[split..]);
                    if (seg.cand_count >= max_candidates - 2) break;
                }
            }
        }

        // Always append raw hiragana and katakana as candidates
        self.addRawCandidate(seg, phrase);
        self.addKatakanaCandidate(seg, phrase);
    }

    fn addCombinedCandidate(self: *Engine, seg: *Segment, prefix: []const u8, suffix: []const u8) linksection(code_section) void {
        const total_len = prefix.len + suffix.len;
        if (self.cand_pool_len + total_len + 1 > max_cand_pool or seg.cand_count >= max_candidates) return;

        const off: u16 = @intCast(self.cand_pool_len);
        @memcpy(self.cand_pool[off..][0..prefix.len], prefix);
        @memcpy(self.cand_pool[off + prefix.len ..][0..suffix.len], suffix);
        self.cand_pool[off + total_len] = 0;
        self.cand_pool_len += total_len + 1;

        seg.cands[seg.cand_count] = off;
        seg.cand_count += 1;
    }

    fn addRawCandidate(self: *Engine, seg: *Segment, text: []const u8) linksection(code_section) void {
        if (self.cand_pool_len + text.len + 1 > max_cand_pool or seg.cand_count >= max_candidates) return;
        const off: u16 = @intCast(self.cand_pool_len);
        @memcpy(self.cand_pool[off..][0..text.len], text);
        self.cand_pool[off + text.len] = 0;
        self.cand_pool_len += text.len + 1;

        seg.cands[seg.cand_count] = off;
        seg.cand_count += 1;
    }

    fn addKatakanaCandidate(self: *Engine, seg: *Segment, hira: []const u8) linksection(code_section) void {
        var kata_buf: [128]u8 = undefined;
        var kata_len: usize = 0;

        var it = (std.unicode.Utf8View.init(hira) catch return).iterator();
        while (it.nextCodepoint()) |cp| {
            const kcp = if (cp >= 0x3041 and cp <= 0x3096) cp + 0x60 else cp;
            var tmp: [4]u8 = undefined;
            const b = std.unicode.utf8Encode(kcp, &tmp) catch return;
            if (kata_len + b > kata_buf.len) return;
            @memcpy(kata_buf[kata_len..][0..b], tmp[0..b]);
            kata_len += b;
        }

        self.addRawCandidate(seg, kata_buf[0..kata_len]);
    }

    /// Select candidate for a segment
    pub fn selectCandidate(self: *Engine, seg_idx: usize, cand_idx: usize) linksection(code_section) void {
        if (seg_idx < self.segment_count and cand_idx < self.segments[seg_idx].cand_count) {
            self.segments[seg_idx].selected = @intCast(cand_idx);
        }
    }

    /// Next candidate (Space key)
    pub fn nextCandidate(self: *Engine, seg_idx: usize) linksection(code_section) void {
        if (seg_idx < self.segment_count) {
            const seg = &self.segments[seg_idx];
            if (seg.cand_count > 0) {
                seg.selected = (seg.selected + 1) % seg.cand_count;
            }
        }
    }

    /// Previous candidate
    pub fn prevCandidate(self: *Engine, seg_idx: usize) linksection(code_section) void {
        if (seg_idx < self.segment_count) {
            const seg = &self.segments[seg_idx];
            if (seg.cand_count > 0) {
                seg.selected = if (seg.selected == 0) seg.cand_count - 1 else seg.selected - 1;
            }
        }
    }

    /// Get string of candidate at index
    pub fn candidateText(self: *const Engine, seg_idx: usize, cand_idx: usize) linksection(code_section) []const u8 {
        if (seg_idx >= self.segment_count or cand_idx >= self.segments[seg_idx].cand_count) return "";
        const off = self.segments[seg_idx].cands[cand_idx];
        const span = self.cand_pool[off..];
        const len = std.mem.indexOfScalar(u8, span, 0) orelse span.len;
        return span[0..len];
    }

    /// Render entire converted sentence into out_buf
    pub fn render(self: *const Engine, out_buf: []u8) linksection(code_section) []const u8 {
        var pos: usize = 0;
        for (0..self.segment_count) |i| {
            const seg = &self.segments[i];
            const text = self.candidateText(i, seg.selected);
            if (pos + text.len > out_buf.len) break;
            @memcpy(out_buf[pos..][0..text.len], text);
            pos += text.len;
        }
        return out_buf[0..pos];
    }
};

fn checkTail(str: []const u8, mask: u8) linksection(code_section) bool {
    if (str.len == 0) return true;
    for (&TAILS) |tail| {
        if ((tail.mask & mask) != 0 and std.mem.startsWith(u8, str, tail.str)) {
            const rem = str[tail.str.len..];
            if (rem.len == 0 or checkTail(rem, TailMask.any)) return true;
        }
    }
    return false;
}

fn checkConjugationTail(str: []const u8, class: u16) linksection(code_section) bool {
    if (str.len == 0) return true;
    for (&TAILS) |tail| {
        if ((tail.class & class) != 0 and std.mem.startsWith(u8, str, tail.str)) {
            const rem = str[tail.str.len..];
            if (rem.len == 0 or checkTail(rem, TailMask.any)) return true;
        }
    }
    return false;
}

const OkuriInfo = struct {
    consonant: u8,
    class: u16,
    kana_len: usize,
};

fn getOkuriKanaLen(phrase: []const u8) linksection(code_section) ?usize {
    if (phrase.len == 0) return null;
    return std.unicode.utf8ByteSequenceLength(phrase[0]) catch null;
}

fn getOkuriConsonant(str: []const u8) linksection(code_section) ?OkuriInfo {
    var it = (std.unicode.Utf8View.init(str) catch return null).iterator();
    const cp = it.nextCodepoint() orelse return null;
    const len = std.unicode.utf8CodepointSequenceLength(cp) catch 3;

    // k s t n h m y r w
    const mapping = [_]struct { first: u21, cons: u8 }{
        .{ .first = 0x304b, .cons = 'k' }, // かきくけこ
        .{ .first = 0x3055, .cons = 's' }, // さしすせそ
        .{ .first = 0x305f, .cons = 't' }, // たちつてと
        .{ .first = 0x306a, .cons = 'n' }, // なにぬねの
        .{ .first = 0x307e, .cons = 'm' }, // まみむめも
        .{ .first = 0x3089, .cons = 'r' }, // らりるれろ
        .{ .first = 0x304c, .cons = 'g' }, // がぎぐげご
        .{ .first = 0x3070, .cons = 'b' }, // ばびぶべぼ
    };

    for (mapping) |m| {
        if (cp >= m.first and cp < m.first + 5) {
            const v = cp - m.first;
            const cls: u16 = switch (v) {
                0 => ConjClass.a,
                1 => ConjClass.i | ConjClass.adj,
                2 => ConjClass.u,
                3 => ConjClass.e,
                4 => ConjClass.o,
                else => ConjClass.u,
            };
            return .{ .consonant = m.cons, .class = cls, .kana_len = len };
        }
    }

    if (cp == 0x3044) { // い
        return .{ .consonant = 'i', .class = ConjClass.i | ConjClass.u, .kana_len = len };
    }
    if (cp == 0x3063) { // っ
        return .{ .consonant = 't', .class = ConjClass.x, .kana_len = len };
    }

    return null;
}

test "bunsetsu DP conversion with real SKK-S dictionary" {
    const s_bytes = @embedFile("fixtures/jisyo_s_nfst.bin");
    const dict = try NfstDict.init(s_bytes);

    var engine = Engine.init();
    var out_buf: [256]u8 = undefined;

    // Test 1: "きょうはいいてんきですね"
    engine.convert(&dict, "きょうはいいてんきですね");
    const res1 = engine.render(&out_buf);
    std.debug.print("\n[SKK-S Conv 1] 'きょうはいいてんきですね' -> '{s}'\n", .{res1});
    for (0..engine.segment_count) |i| {
        std.debug.print("  seg[{}]: '{s}'\n", .{ i, engine.candidateText(i, engine.segments[i].selected) });
    }
    try std.testing.expect(engine.segment_count >= 2);

    // Test 2: "わたしはがくせいです"
    engine.convert(&dict, "わたしはがくせいです");
    const res2 = engine.render(&out_buf);
    std.debug.print("[SKK-S Conv 2] 'わたしはがくせいです' -> '{s}'\n", .{res2});
    for (0..engine.segment_count) |i| {
        std.debug.print("  seg[{}]: '{s}'\n", .{ i, engine.candidateText(i, engine.segments[i].selected) });
    }

    // Test 3: "とうきょうへいく"
    engine.convert(&dict, "とうきょうへいく");
    const res3 = engine.render(&out_buf);
    std.debug.print("[SKK-S Conv 3] 'とうきょうへいく' -> '{s}'\n", .{res3});
    for (0..engine.segment_count) |i| {
        std.debug.print("  seg[{}]: '{s}'\n", .{ i, engine.candidateText(i, engine.segments[i].selected) });
    }
}
