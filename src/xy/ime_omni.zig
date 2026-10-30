//! Module 4: Allocation-Free Minibuffer SKK & Prefix Omni-Completion (`src/xy/ime_omni.zig`)
//!
//! Unifies Japanese IME (SKK), dictionary lookup (`jmdict` / `gjs.db`), IVS/variant
//! selector lookup (`~`), IDS component composition (`&`), FTS5 full-text citation (`@`),
//! OS configuration/metrics inspection (`:`), and live Scheme evaluation (`(...)`) into a
//! single non-destructive `▽` preedit + single-line minibuffer stream.
//!
//! Memory Contract:
//! - Zero heap allocations. All candidate buffers, romaji state, and minibuffer strings
//!   live in fixed-capacity structs.
//! - Never takes pixel snapshots of the framebuffer; renders `▽`/`▼` via `Document.preedit`
//!   and outputs a structured `MinibufferView` for the bottom status/minibuffer line.

const std = @import("std");
const document = @import("document.zig");

pub const InputMode = enum(u8) {
    /// Direct ASCII input (`a` -> `"a"`).
    direct = 0,
    /// Hiragana input (`k` + `a` -> `"か"`, uppercase starts `▽` preedit).
    hiragana = 1,
    /// Katakana input (`k` + `a` -> `"カ"`, toggled with `q` in hiragana mode).
    katakana = 2,
};

pub const OmniPhase = enum(u8) {
    /// Normal typing (no active `▽` or `▼` preedit).
    idle = 0,
    /// Building reading / query in `▽` overlay (`▽かんじ`, `▽~葛`, `▽&木目心`, `▽(+ 1 2)`).
    reading = 1,
    /// Building okurigana after `*` in SKK (`▽うつくし*い`, lookup key `"うつくしi"`).
    okuri = 2,
    /// Cycling candidates in `▼` overlay + minibuffer (`SPC` next, `x` prev, `Enter` commit).
    selecting = 3,
};

pub const PrefixKind = enum(u8) {
    /// Unprefixed `▽かんじ`: Kana-Kanji conversion (`skk_user` + `skk_dict`).
    kanji = 0,
    /// `▽?word`: Dictionary / `gjs.db` character & vocabulary lookup.
    dict = 1,
    /// `▽~char`: `gjs.db` Variant cluster / IVS (`U+E0100..`) / Moji-Labo degeneration lookup.
    variant = 2,
    /// `▽&parts`: `gjs.db` IDS (Ideographic Description Sequence) component search (`&木目心` -> `想`).
    ids = 3,
    /// `▽@query`: `books` / `notes` FTS5 full-text search & citation insertion.
    search = 4,
    /// `▽:key`: `sys_config` / `sys/live-ring` OS config & live metrics lookup.
    system = 5,
    /// `▽(expr ...)`: Live Scheme S-expression evaluation (SKK Program Conversion).
    scheme = 6,
    /// User-registered custom prefix via `(ime/register-prefix! prefix handler)`.
    custom = 7,
};

/// A single candidate item returned by an `OmniProvider` into the caller's fixed arena.
pub const Candidate = struct {
    /// Text to insert into the document upon commit (may include IVS or S-expressions).
    insert_text: []const u8,
    /// Optional annotation shown in the minibuffer (e.g. MJ code, IVS hex, meaning, book title).
    annotation: []const u8 = "",
};

/// Bounded candidate list populated by `OmniProvider.queryFn` without heap allocation.
pub const CandidateList = struct {
    items: [16]Candidate = @splat(.{ .insert_text = "" }),
    count: u8 = 0,
    arena: [1024]u8 = @splat(0),
    arena_used: u16 = 0,

    pub fn clear(self: *CandidateList) void {
        self.count = 0;
        self.arena_used = 0;
    }

    pub fn append(self: *CandidateList, insert_text: []const u8, annotation: []const u8) bool {
        if (self.count >= self.items.len) return false;
        const needed = insert_text.len + annotation.len;
        if (self.arena_used + needed > self.arena.len) return false;

        const ins_start = self.arena_used;
        @memcpy(self.arena[ins_start .. ins_start + insert_text.len], insert_text);
        self.arena_used += @intCast(insert_text.len);

        const ann_start = self.arena_used;
        @memcpy(self.arena[ann_start .. ann_start + annotation.len], annotation);
        self.arena_used += @intCast(annotation.len);

        self.items[self.count] = .{
            .insert_text = self.arena[ins_start .. ins_start + insert_text.len],
            .annotation = self.arena[ann_start .. ann_start + annotation.len],
        };
        self.count += 1;
        return true;
    }
};

/// Pluggable backend interface connecting `ime_omni` to `sqld` (`skk_dict`, `gjs.db`,
/// `books`, `sys_config`) and the Scheme evaluator.
pub const OmniProvider = struct {
    ctx: *anyopaque,
    /// Populate `out` with candidates for `(kind, prefix_char, query_key)`.
    /// For `.kanji` with okurigana (e.g. `▽うつくし*い`), `query_key` is `"うつくしi"`.
    /// For prefixed queries (e.g. `▽~葛`), `query_key` is `"葛"` (without the leading `~`).
    /// For `.scheme` (e.g. `▽(+ 1 2)`), `query_key` is `"(+ 1 2)"`.
    queryFn: *const fn (
        ctx: *anyopaque,
        kind: PrefixKind,
        prefix_char: u8,
        query_key: []const u8,
        out: *CandidateList,
    ) void,
    /// Optional hook invoked when a `.kanji` candidate is committed so `skk_user` can record it.
    learnFn: ?*const fn (ctx: *anyopaque, query_key: []const u8, committed_stem: []const u8) void = null,
};

// ============================================================================
// Allocation-Free Romaji-to-Kana Automaton
// ============================================================================

const RomajiEntry = struct {
    romaji: []const u8,
    hiragana: []const u8,
    katakana: []const u8,
};

const romaji_table = [_]RomajiEntry{
    // 3-letter combinations
    .{ .romaji = "kya", .hiragana = "きゃ", .katakana = "キャ" },
    .{ .romaji = "kyu", .hiragana = "きゅ", .katakana = "キュ" },
    .{ .romaji = "kyo", .hiragana = "きょ", .katakana = "キョ" },
    .{ .romaji = "sha", .hiragana = "しゃ", .katakana = "シャ" },
    .{ .romaji = "shi", .hiragana = "し", .katakana = "シ" },
    .{ .romaji = "shu", .hiragana = "しゅ", .katakana = "シュ" },
    .{ .romaji = "sho", .hiragana = "しょ", .katakana = "ショ" },
    .{ .romaji = "sya", .hiragana = "しゃ", .katakana = "シャ" },
    .{ .romaji = "syu", .hiragana = "しゅ", .katakana = "シュ" },
    .{ .romaji = "syo", .hiragana = "しょ", .katakana = "ショ" },
    .{ .romaji = "cha", .hiragana = "ちゃ", .katakana = "チャ" },
    .{ .romaji = "chi", .hiragana = "ち", .katakana = "チ" },
    .{ .romaji = "chu", .hiragana = "ちゅ", .katakana = "チュ" },
    .{ .romaji = "cho", .hiragana = "ちょ", .katakana = "チョ" },
    .{ .romaji = "tya", .hiragana = "ちゃ", .katakana = "チャ" },
    .{ .romaji = "tyu", .hiragana = "ちゅ", .katakana = "チュ" },
    .{ .romaji = "tyo", .hiragana = "ちょ", .katakana = "チョ" },
    .{ .romaji = "tsu", .hiragana = "つ", .katakana = "ツ" },
    .{ .romaji = "nya", .hiragana = "にゃ", .katakana = "ニャ" },
    .{ .romaji = "nyu", .hiragana = "にゅ", .katakana = "ニュ" },
    .{ .romaji = "nyo", .hiragana = "にょ", .katakana = "ニョ" },
    .{ .romaji = "hya", .hiragana = "ひゃ", .katakana = "ヒャ" },
    .{ .romaji = "hyu", .hiragana = "ひゅ", .katakana = "ヒュ" },
    .{ .romaji = "hyo", .hiragana = "ひょ", .katakana = "ヒョ" },
    .{ .romaji = "mya", .hiragana = "みゃ", .katakana = "ミャ" },
    .{ .romaji = "myu", .hiragana = "みゅ", .katakana = "ミュ" },
    .{ .romaji = "myo", .hiragana = "みょ", .katakana = "ミョ" },
    .{ .romaji = "rya", .hiragana = "りゃ", .katakana = "リャ" },
    .{ .romaji = "ryu", .hiragana = "りゅ", .katakana = "リュ" },
    .{ .romaji = "ryo", .hiragana = "りょ", .katakana = "リョ" },
    .{ .romaji = "gya", .hiragana = "ぎゃ", .katakana = "ギャ" },
    .{ .romaji = "gyu", .hiragana = "ぎゅ", .katakana = "ギュ" },
    .{ .romaji = "gyo", .hiragana = "ぎょ", .katakana = "ギョ" },
    .{ .romaji = "bya", .hiragana = "びゃ", .katakana = "ビャ" },
    .{ .romaji = "byu", .hiragana = "びゅ", .katakana = "ビュ" },
    .{ .romaji = "byo", .hiragana = "びょ", .katakana = "ビョ" },
    .{ .romaji = "pya", .hiragana = "ぴゃ", .katakana = "ピャ" },
    .{ .romaji = "pyu", .hiragana = "ぴゅ", .katakana = "ピュ" },
    .{ .romaji = "pyo", .hiragana = "ぴょ", .katakana = "ピョ" },
    .{ .romaji = "xtu", .hiragana = "っ", .katakana = "ッ" },
    .{ .romaji = "ltu", .hiragana = "っ", .katakana = "ッ" },
    .{ .romaji = "xya", .hiragana = "ゃ", .katakana = "ャ" },
    .{ .romaji = "xyu", .hiragana = "ゅ", .katakana = "ュ" },
    .{ .romaji = "xyo", .hiragana = "ょ", .katakana = "ョ" },
    // 2-letter combinations
    .{ .romaji = "ka", .hiragana = "か", .katakana = "カ" },
    .{ .romaji = "ki", .hiragana = "き", .katakana = "キ" },
    .{ .romaji = "ku", .hiragana = "く", .katakana = "ク" },
    .{ .romaji = "ke", .hiragana = "け", .katakana = "ケ" },
    .{ .romaji = "ko", .hiragana = "こ", .katakana = "コ" },
    .{ .romaji = "sa", .hiragana = "さ", .katakana = "サ" },
    .{ .romaji = "si", .hiragana = "し", .katakana = "シ" },
    .{ .romaji = "su", .hiragana = "す", .katakana = "ス" },
    .{ .romaji = "se", .hiragana = "せ", .katakana = "セ" },
    .{ .romaji = "so", .hiragana = "そ", .katakana = "ソ" },
    .{ .romaji = "ta", .hiragana = "た", .katakana = "タ" },
    .{ .romaji = "ti", .hiragana = "ち", .katakana = "チ" },
    .{ .romaji = "tu", .hiragana = "つ", .katakana = "ツ" },
    .{ .romaji = "te", .hiragana = "て", .katakana = "テ" },
    .{ .romaji = "to", .hiragana = "と", .katakana = "ト" },
    .{ .romaji = "na", .hiragana = "な", .katakana = "ナ" },
    .{ .romaji = "ni", .hiragana = "に", .katakana = "ニ" },
    .{ .romaji = "nu", .hiragana = "ぬ", .katakana = "ヌ" },
    .{ .romaji = "ne", .hiragana = "ね", .katakana = "ネ" },
    .{ .romaji = "no", .hiragana = "の", .katakana = "ノ" },
    .{ .romaji = "ha", .hiragana = "は", .katakana = "ハ" },
    .{ .romaji = "hi", .hiragana = "ひ", .katakana = "ヒ" },
    .{ .romaji = "hu", .hiragana = "ふ", .katakana = "フ" },
    .{ .romaji = "fu", .hiragana = "ふ", .katakana = "フ" },
    .{ .romaji = "he", .hiragana = "へ", .katakana = "ヘ" },
    .{ .romaji = "ho", .hiragana = "ほ", .katakana = "ホ" },
    .{ .romaji = "ma", .hiragana = "ま", .katakana = "マ" },
    .{ .romaji = "mi", .hiragana = "み", .katakana = "ミ" },
    .{ .romaji = "mu", .hiragana = "む", .katakana = "ム" },
    .{ .romaji = "me", .hiragana = "め", .katakana = "メ" },
    .{ .romaji = "mo", .hiragana = "も", .katakana = "モ" },
    .{ .romaji = "ya", .hiragana = "や", .katakana = "ヤ" },
    .{ .romaji = "yu", .hiragana = "ゆ", .katakana = "ユ" },
    .{ .romaji = "yo", .hiragana = "よ", .katakana = "ヨ" },
    .{ .romaji = "ra", .hiragana = "ら", .katakana = "ラ" },
    .{ .romaji = "ri", .hiragana = "り", .katakana = "リ" },
    .{ .romaji = "ru", .hiragana = "る", .katakana = "ル" },
    .{ .romaji = "re", .hiragana = "れ", .katakana = "レ" },
    .{ .romaji = "ro", .hiragana = "ろ", .katakana = "ロ" },
    .{ .romaji = "wa", .hiragana = "わ", .katakana = "ワ" },
    .{ .romaji = "wo", .hiragana = "を", .katakana = "ヲ" },
    .{ .romaji = "nn", .hiragana = "ん", .katakana = "ン" },
    .{ .romaji = "n'", .hiragana = "ん", .katakana = "ン" },
    .{ .romaji = "ga", .hiragana = "が", .katakana = "ガ" },
    .{ .romaji = "gi", .hiragana = "ぎ", .katakana = "ギ" },
    .{ .romaji = "gu", .hiragana = "ぐ", .katakana = "グ" },
    .{ .romaji = "ge", .hiragana = "げ", .katakana = "ゲ" },
    .{ .romaji = "go", .hiragana = "ご", .katakana = "ゴ" },
    .{ .romaji = "za", .hiragana = "ざ", .katakana = "ザ" },
    .{ .romaji = "zi", .hiragana = "じ", .katakana = "ジ" },
    .{ .romaji = "ji", .hiragana = "じ", .katakana = "ジ" },
    .{ .romaji = "zu", .hiragana = "ず", .katakana = "ズ" },
    .{ .romaji = "ze", .hiragana = "ぜ", .katakana = "ゼ" },
    .{ .romaji = "zo", .hiragana = "ぞ", .katakana = "ゾ" },
    .{ .romaji = "ja", .hiragana = "じゃ", .katakana = "ジャ" },
    .{ .romaji = "ju", .hiragana = "じゅ", .katakana = "ジュ" },
    .{ .romaji = "jo", .hiragana = "じょ", .katakana = "ジョ" },
    .{ .romaji = "da", .hiragana = "だ", .katakana = "ダ" },
    .{ .romaji = "di", .hiragana = "ぢ", .katakana = "ヂ" },
    .{ .romaji = "du", .hiragana = "づ", .katakana = "ヅ" },
    .{ .romaji = "de", .hiragana = "で", .katakana = "デ" },
    .{ .romaji = "do", .hiragana = "ど", .katakana = "ド" },
    .{ .romaji = "ba", .hiragana = "ば", .katakana = "バ" },
    .{ .romaji = "bi", .hiragana = "び", .katakana = "ビ" },
    .{ .romaji = "bu", .hiragana = "ぶ", .katakana = "ブ" },
    .{ .romaji = "be", .hiragana = "べ", .katakana = "ベ" },
    .{ .romaji = "bo", .hiragana = "ぼ", .katakana = "ボ" },
    .{ .romaji = "pa", .hiragana = "ぱ", .katakana = "パ" },
    .{ .romaji = "pi", .hiragana = "ぴ", .katakana = "ピ" },
    .{ .romaji = "pu", .hiragana = "ぷ", .katakana = "プ" },
    .{ .romaji = "pe", .hiragana = "ぺ", .katakana = "ペ" },
    .{ .romaji = "po", .hiragana = "ぽ", .katakana = "ポ" },
    .{ .romaji = "vu", .hiragana = "ゔ", .katakana = "ヴ" },
    .{ .romaji = "xa", .hiragana = "ぁ", .katakana = "ァ" },
    .{ .romaji = "xi", .hiragana = "ぃ", .katakana = "ィ" },
    .{ .romaji = "xu", .hiragana = "ぅ", .katakana = "ゥ" },
    .{ .romaji = "xe", .hiragana = "ぇ", .katakana = "ェ" },
    .{ .romaji = "xo", .hiragana = "ぉ", .katakana = "ォ" },
    .{ .romaji = "la", .hiragana = "ぁ", .katakana = "ァ" },
    .{ .romaji = "li", .hiragana = "ぃ", .katakana = "ィ" },
    .{ .romaji = "lu", .hiragana = "ぅ", .katakana = "ゥ" },
    .{ .romaji = "le", .hiragana = "ぇ", .katakana = "ェ" },
    .{ .romaji = "lo", .hiragana = "ぉ", .katakana = "ォ" },
    // Single vowels & punctuation
    .{ .romaji = "a", .hiragana = "あ", .katakana = "ア" },
    .{ .romaji = "i", .hiragana = "い", .katakana = "イ" },
    .{ .romaji = "u", .hiragana = "う", .katakana = "ウ" },
    .{ .romaji = "e", .hiragana = "え", .katakana = "エ" },
    .{ .romaji = "o", .hiragana = "お", .katakana = "オ" },
    .{ .romaji = "-", .hiragana = "ー", .katakana = "ー" },
    .{ .romaji = ".", .hiragana = "。", .katakana = "。" },
    .{ .romaji = ",", .hiragana = "、", .katakana = "、" },
    .{ .romaji = "[", .hiragana = "「", .katakana = "「" },
    .{ .romaji = "]", .hiragana = "」", .katakana = "」" },
};

pub const RomajiFeedResult = struct {
    emitted_buf: [12]u8 = @splat(0),
    emitted_len: u8 = 0,

    pub fn slice(self: *const RomajiFeedResult) []const u8 {
        return self.emitted_buf[0..self.emitted_len];
    }
};

pub const RomajiAutomaton = struct {
    pending: [4]u8 = .{ 0, 0, 0, 0 },
    len: u8 = 0,

    pub fn clear(self: *RomajiAutomaton) void {
        self.len = 0;
    }

    pub fn pendingSlice(self: *const RomajiAutomaton) []const u8 {
        return self.pending[0..self.len];
    }

    fn isVowelOrYOrN(ch: u8) bool {
        return switch (ch) {
            'a', 'i', 'u', 'e', 'o', 'y', 'n', '\'' => true,
            else => false,
        };
    }

    fn isSokuonConsonant(ch: u8) bool {
        return switch (ch) {
            'k', 's', 't', 'h', 'f', 'm', 'r', 'w', 'g', 'z', 'j', 'd', 'b', 'p', 'c', 'v' => true,
            else => false,
        };
    }

    /// Feed a lowercase ASCII character and return any emitted kana bytes (up to 2 syllables, e.g. `"んか"` or `"っか"`).
    pub fn feed(self: *RomajiAutomaton, ch: u8, katakana: bool) RomajiFeedResult {
        var res = RomajiFeedResult{};

        // Rule 1: If `'n'` is pending and `ch` cannot continue an `n*` syllable (`na..no`, `nya..nyo`, `nn`, `n'`),
        // emit `"ん"` / `"ン"` first!
        if (self.len == 1 and self.pending[0] == 'n' and !isVowelOrYOrN(ch)) {
            const hatsuon = if (katakana) "ン" else "ん";
            @memcpy(res.emitted_buf[0..hatsuon.len], hatsuon);
            res.emitted_len = @intCast(hatsuon.len);
            self.len = 0;
        }

        // Rule 2: Double consonant (`kk`, `ss`, `tt`, `pp`, `cc`, etc.) -> emit `"っ"` / `"ッ"` and keep 1 consonant.
        if (self.len == 1 and self.pending[0] == ch and isSokuonConsonant(ch)) {
            const sokuon = if (katakana) "ッ" else "っ";
            @memcpy(res.emitted_buf[res.emitted_len .. res.emitted_len + sokuon.len], sokuon);
            res.emitted_len += @intCast(sokuon.len);
            return res;
        }

        if (self.len < self.pending.len) {
            self.pending[self.len] = ch;
            self.len += 1;
        } else {
            self.pending[0] = ch;
            self.len = 1;
        }

        const cur = self.pendingSlice();
        // Exact match check
        for (romaji_table) |entry| {
            if (std.mem.eql(u8, cur, entry.romaji)) {
                const kana = if (katakana) entry.katakana else entry.hiragana;
                @memcpy(res.emitted_buf[res.emitted_len .. res.emitted_len + kana.len], kana);
                res.emitted_len += @intCast(kana.len);
                self.len = 0;
                return res;
            }
        }

        // Prefix check: can `cur` still grow into a valid `romaji_table` entry?
        for (romaji_table) |entry| {
            if (std.mem.startsWith(u8, entry.romaji, cur)) {
                return res;
            }
        }

        // Otherwise drop unreachable prefix and retry with just `ch`
        self.len = 0;
        self.pending[0] = ch;
        self.len = 1;
        for (romaji_table) |entry| {
            if (std.mem.eql(u8, self.pendingSlice(), entry.romaji)) {
                const kana = if (katakana) entry.katakana else entry.hiragana;
                @memcpy(res.emitted_buf[res.emitted_len .. res.emitted_len + kana.len], kana);
                res.emitted_len += @intCast(kana.len);
                self.len = 0;
                return res;
            }
            if (std.mem.startsWith(u8, entry.romaji, self.pendingSlice())) {
                return res;
            }
        }

        self.len = 0;
        return res;
    }

    /// Flush trailing `'n'` as `"ん"` / `"ン"` before starting conversion or committing.
    pub fn flushTrailingN(self: *RomajiAutomaton, katakana: bool) ?[]const u8 {
        if (self.len == 1 and self.pending[0] == 'n') {
            self.len = 0;
            return if (katakana) "ン" else "ん";
        }
        self.len = 0;
        return null;
    }
};

// ============================================================================
// Minibuffer View & SKK Omni-Completion Engine
// ============================================================================

pub const MinibufferView = struct {
    mode: InputMode,
    phase: OmniPhase,
    prefix_kind: PrefixKind,
    selected_index: u8,
    candidate_count: u8,
    line_buf: [256]u8 = @splat(0),
    line_len: u16 = 0,

    pub fn line(self: *const MinibufferView) []const u8 {
        return self.line_buf[0..self.line_len];
    }
};

pub const CustomPrefixHandler = struct {
    prefix_char: u8 = 0,
    active: bool = false,
};

pub const OmniIme = struct {
    mode: InputMode = .hiragana,
    phase: OmniPhase = .idle,
    romaji: RomajiAutomaton = .{},

    /// Stem / query buffer in `▽` phase (UTF-8, e.g. `"うつくし"`, `"?nihon"`, `"~葛"`, `"&木目心"`, `"(+ 1 2)"`).
    reading_buf: [128]u8 = @splat(0),
    reading_len: u8 = 0,

    /// Okurigana consonant & kana buffer in `.okuri` phase (e.g. `okuri_consonant = 'i'`, `okuri_buf = "い"`).
    okuri_consonant: u8 = 0,
    okuri_buf: [32]u8 = @splat(0),
    okuri_len: u8 = 0,

    /// Sticky-shift (`;` or `/`) armed so the next key starts `▽` reading or prefix query.
    sticky_armed: bool = false,

    /// Candidate list populated on `SPC` transition to `.selecting`.
    candidates: CandidateList = .{},
    selected_index: u8 = 0,

    /// Custom prefixes registered via `(ime/register-prefix! prefix handler)`.
    custom_prefixes: [8]CustomPrefixHandler = @splat(.{}),

    pub fn registerCustomPrefix(self: *OmniIme, prefix_char: u8) bool {
        for (&self.custom_prefixes) |*slot| {
            if (slot.active and slot.prefix_char == prefix_char) return true;
        }
        for (&self.custom_prefixes) |*slot| {
            if (!slot.active) {
                slot.active = true;
                slot.prefix_char = prefix_char;
                return true;
            }
        }
        return false;
    }

    pub fn classifyPrefix(self: *const OmniIme) struct { kind: PrefixKind, prefix_char: u8, body: []const u8 } {
        const raw = self.reading_buf[0..self.reading_len];
        if (raw.len == 0) return .{ .kind = .kanji, .prefix_char = 0, .body = "" };
        const first = raw[0];
        return switch (first) {
            '?' => .{ .kind = .dict, .prefix_char = '?', .body = raw[1..] },
            '~' => .{ .kind = .variant, .prefix_char = '~', .body = raw[1..] },
            '&' => .{ .kind = .ids, .prefix_char = '&', .body = raw[1..] },
            '@' => .{ .kind = .search, .prefix_char = '@', .body = raw[1..] },
            ':' => .{ .kind = .system, .prefix_char = ':', .body = raw[1..] },
            '(' => .{ .kind = .scheme, .prefix_char = '(', .body = raw },
            else => blk: {
                for (self.custom_prefixes) |slot| {
                    if (slot.active and slot.prefix_char == first) {
                        break :blk .{ .kind = .custom, .prefix_char = first, .body = raw[1..] };
                    }
                }
                break :blk .{ .kind = .kanji, .prefix_char = 0, .body = raw };
            },
        };
    }

    fn isRawPrefixKind(kind: PrefixKind) bool {
        return switch (kind) {
            .kanji => false,
            .dict, .variant, .ids, .search, .system, .scheme, .custom => true,
        };
    }

    fn isBuiltinPrefixTrigger(ch: u8) bool {
        return switch (ch) {
            '?', '~', '&', '@', ':', '(' => true,
            else => false,
        };
    }

    fn isCustomPrefixTrigger(self: *const OmniIme, ch: u8) bool {
        for (self.custom_prefixes) |slot| {
            if (slot.active and slot.prefix_char == ch) return true;
        }
        return false;
    }

    fn appendReading(self: *OmniIme, bytes: []const u8) void {
        if (self.reading_len + bytes.len <= self.reading_buf.len) {
            @memcpy(self.reading_buf[self.reading_len .. self.reading_len + bytes.len], bytes);
            self.reading_len += @intCast(bytes.len);
        }
    }

    fn appendOkuri(self: *OmniIme, bytes: []const u8) void {
        if (self.okuri_len + bytes.len <= self.okuri_buf.len) {
            @memcpy(self.okuri_buf[self.okuri_len .. self.okuri_len + bytes.len], bytes);
            self.okuri_len += @intCast(bytes.len);
        }
    }

    /// Synchronize the `Document`'s non-destructive `PreeditOverlay` with the current `OmniIme` state.
    pub fn syncDocumentOverlay(self: *const OmniIme, doc: anytype) !void {
        if (self.phase == .idle) {
            doc.preedit.clear();
            return;
        }
        var buf: [192]u8 = undefined;
        var pos: usize = 0;

        if (self.phase == .selecting and self.selected_index < self.candidates.count) {
            const marker = "▼";
            @memcpy(buf[pos .. pos + marker.len], marker);
            pos += marker.len;
            const cand = self.candidates.items[self.selected_index].insert_text;
            const n = @min(cand.len, buf.len - pos);
            @memcpy(buf[pos .. pos + n], cand[0..n]);
            pos += n;
            if (self.okuri_len > 0 and pos + self.okuri_len <= buf.len) {
                @memcpy(buf[pos .. pos + self.okuri_len], self.okuri_buf[0..self.okuri_len]);
                pos += self.okuri_len;
            }
            try doc.setPreedit(.selecting, buf[0..pos]);
        } else {
            const marker = "▽";
            @memcpy(buf[pos .. pos + marker.len], marker);
            pos += marker.len;
            const r = self.reading_buf[0..self.reading_len];
            const n = @min(r.len, buf.len - pos);
            @memcpy(buf[pos .. pos + n], r[0..n]);
            pos += n;
            if (self.phase == .okuri and pos < buf.len) {
                buf[pos] = '*';
                pos += 1;
                const ok = self.okuri_buf[0..self.okuri_len];
                const ok_n = @min(ok.len, buf.len - pos);
                @memcpy(buf[pos .. pos + ok_n], ok[0..ok_n]);
                pos += ok_n;
            }
            const pend = self.romaji.pendingSlice();
            if (pend.len > 0 and pos + pend.len <= buf.len) {
                @memcpy(buf[pos .. pos + pend.len], pend);
                pos += pend.len;
            }
            try doc.setPreedit(.reading, buf[0..pos]);
        }
    }

    /// Directly append UTF-8 text (e.g. a pasted/selected kanji `"葛"` or IDS `"木目心"`) to the active `▽` reading buffer.
    pub fn feedUtf8ToReading(self: *OmniIme, doc: anytype, utf8_text: []const u8) !void {
        if (self.phase == .idle) {
            self.phase = .reading;
            self.reading_len = 0;
            self.okuri_len = 0;
            self.okuri_consonant = 0;
        }
        self.appendReading(utf8_text);
        try self.syncDocumentOverlay(doc);
    }

    fn triggerConversion(self: *OmniIme, doc: anytype, provider: OmniProvider) !void {
        // Flush any trailing 'n' -> 'ん' before querying
        if (!isRawPrefixKind(self.classifyPrefix().kind)) {
            if (self.romaji.flushTrailingN(false)) |hatsuon| {
                if (self.phase == .okuri) {
                    self.appendOkuri(hatsuon);
                } else {
                    self.appendReading(hatsuon);
                }
            }
        } else {
            self.romaji.clear();
        }

        const classified = self.classifyPrefix();
        var query_key_buf: [132]u8 = undefined;
        var query_key: []const u8 = classified.body;
        if (classified.kind == .kanji and self.okuri_consonant != 0) {
            const n = @min(classified.body.len, query_key_buf.len - 1);
            @memcpy(query_key_buf[0..n], classified.body[0..n]);
            query_key_buf[n] = self.okuri_consonant;
            query_key = query_key_buf[0 .. n + 1];
        }

        self.candidates.clear();
        provider.queryFn(provider.ctx, classified.kind, classified.prefix_char, query_key, &self.candidates);
        if (self.candidates.count > 0) {
            self.phase = .selecting;
            self.selected_index = 0;
        }
        try self.syncDocumentOverlay(doc);
    }

    fn commitSelected(self: *OmniIme, doc: anytype, provider: OmniProvider) !void {
        var commit_buf: [256]u8 = undefined;
        var commit_len: usize = 0;

        if (self.phase == .selecting and self.selected_index < self.candidates.count) {
            const stem = self.candidates.items[self.selected_index].insert_text;
            const classified = self.classifyPrefix();
            if (classified.kind == .kanji) {
                if (provider.learnFn) |learn| {
                    var q_buf: [132]u8 = undefined;
                    var q_key: []const u8 = classified.body;
                    if (self.okuri_consonant != 0) {
                        const n = @min(classified.body.len, q_buf.len - 1);
                        @memcpy(q_buf[0..n], classified.body[0..n]);
                        q_buf[n] = self.okuri_consonant;
                        q_key = q_buf[0 .. n + 1];
                    }
                    learn(provider.ctx, q_key, stem);
                }
            }
            @memcpy(commit_buf[0..stem.len], stem);
            commit_len = stem.len;
            if (self.okuri_len > 0 and commit_len + self.okuri_len <= commit_buf.len) {
                @memcpy(commit_buf[commit_len .. commit_len + self.okuri_len], self.okuri_buf[0..self.okuri_len]);
                commit_len += self.okuri_len;
            }
        } else {
            if (!isRawPrefixKind(self.classifyPrefix().kind)) {
                if (self.romaji.flushTrailingN(false)) |hatsuon| {
                    self.appendReading(hatsuon);
                }
            }
            @memcpy(commit_buf[0..self.reading_len], self.reading_buf[0..self.reading_len]);
            commit_len = self.reading_len;
            if (self.okuri_len > 0 and commit_len + self.okuri_len <= commit_buf.len) {
                @memcpy(commit_buf[commit_len .. commit_len + self.okuri_len], self.okuri_buf[0..self.okuri_len]);
                commit_len += self.okuri_len;
            }
        }

        self.phase = .idle;
        self.reading_len = 0;
        self.okuri_len = 0;
        self.okuri_consonant = 0;
        self.romaji.clear();
        self.candidates.clear();
        try doc.commitPreedit(commit_buf[0..commit_len]);
    }

    /// Process a single ASCII / control key event and update `doc` and the minibuffer state.
    /// Control codes:
    /// - `0x07` (`C-g`): Cancel selection -> reading, or reading -> idle
    /// - `0x0A` (`C-j` / `\n` / `\r`): Commit active `▽`/`▼` or switch to `.hiragana` mode
    /// - `0x08` / `0x7F` (`Backspace`): Delete pending romaji / preedit char / document grapheme
    pub fn handleKey(self: *OmniIme, doc: anytype, provider: OmniProvider, key: u8) !void {
        // 1. C-g (0x07) Cancel
        if (key == 0x07) {
            self.sticky_armed = false;
            self.romaji.clear();
            if (self.phase == .selecting) {
                self.phase = if (self.okuri_len > 0) .okuri else .reading;
                self.candidates.clear();
                try self.syncDocumentOverlay(doc);
            } else if (self.phase != .idle) {
                self.phase = .idle;
                self.reading_len = 0;
                self.okuri_len = 0;
                self.okuri_consonant = 0;
                try self.syncDocumentOverlay(doc);
            }
            return;
        }

        // 2. Selecting phase (`▼`)
        if (self.phase == .selecting) {
            if (key == ' ') {
                if (self.candidates.count > 0) {
                    self.selected_index = (self.selected_index + 1) % self.candidates.count;
                }
                try self.syncDocumentOverlay(doc);
                return;
            }
            if (key == 'x') {
                if (self.candidates.count > 0) {
                    self.selected_index = if (self.selected_index == 0)
                        self.candidates.count - 1
                    else
                        self.selected_index - 1;
                }
                try self.syncDocumentOverlay(doc);
                return;
            }
            if (key == '\n' or key == '\r' or key == 0x0A) {
                try self.commitSelected(doc, provider);
                return;
            }
            // Any other printable key commits the selected candidate first, then falls through!
            try self.commitSelected(doc, provider);
        }

        // 3. Reading / Okuri phase (`▽`)
        if (self.phase == .reading or self.phase == .okuri) {
            const classified = self.classifyPrefix();
            const raw_mode = isRawPrefixKind(classified.kind);

            if (key == '\n' or key == '\r' or key == 0x0A) {
                try self.commitSelected(doc, provider);
                return;
            }

            if (key == 0x08 or key == 0x7F) {
                if (self.romaji.len > 0) {
                    self.romaji.len -= 1;
                } else if (self.phase == .okuri and self.okuri_len > 0) {
                    const prev = document.prevClusterStart(self.okuri_buf[0..self.okuri_len], self.okuri_len) catch 0;
                    self.okuri_len = @intCast(prev);
                    if (self.okuri_len == 0) {
                        self.phase = .reading;
                        self.okuri_consonant = 0;
                    }
                } else if (self.reading_len > 0) {
                    const prev = document.prevClusterStart(self.reading_buf[0..self.reading_len], self.reading_len) catch 0;
                    self.reading_len = @intCast(prev);
                    if (self.reading_len == 0) {
                        self.phase = .idle;
                    }
                } else {
                    self.phase = .idle;
                }
                try self.syncDocumentOverlay(doc);
                return;
            }

            // In `.scheme` mode `▽(...)`, spaces are allowed inside the S-expression until balanced parentheses
            // and pressing `SPC` after balanced `)` triggers evaluation!
            if (key == ' ') {
                if (classified.kind == .scheme and !isBalancedSexp(classified.body)) {
                    self.appendReading(&[_]u8{' '});
                    try self.syncDocumentOverlay(doc);
                    return;
                }
                try self.triggerConversion(doc, provider);
                return;
            }

            if (raw_mode) {
                // Raw ASCII/UTF-8 query body for `?`, `~`, `&`, `@`, `:`, `(...)`, or custom prefix
                self.appendReading(&[_]u8{key});
                try self.syncDocumentOverlay(doc);
                return;
            }

            // If `reading_len == 0` (just entered `▽` via `;` sticky shift) and key is a prefix character:
            if (self.reading_len == 0 and self.romaji.len == 0 and (isBuiltinPrefixTrigger(key) or self.isCustomPrefixTrigger(key))) {
                self.appendReading(&[_]u8{key});
                try self.syncDocumentOverlay(doc);
                return;
            }

            // Uppercase letter inside `.reading` when stem is non-empty -> starts `.okuri`!
            if (self.phase == .reading and self.reading_len > 0 and std.ascii.isUpper(key)) {
                if (self.romaji.flushTrailingN(false)) |hatsuon| {
                    self.appendReading(hatsuon);
                }
                const lower = std.ascii.toLower(key);
                self.phase = .okuri;
                self.okuri_consonant = lower;
                self.okuri_len = 0;
                const fed = self.romaji.feed(lower, false);
                if (fed.emitted_len > 0) {
                    self.appendOkuri(fed.slice());
                    // Auto-trigger conversion once the okurigana kana is complete!
                    try self.triggerConversion(doc, provider);
                    return;
                }
                try self.syncDocumentOverlay(doc);
                return;
            }

            const lower = std.ascii.toLower(key);
            const fed = self.romaji.feed(lower, false);
            if (fed.emitted_len > 0) {
                if (self.phase == .okuri) {
                    self.appendOkuri(fed.slice());
                    try self.triggerConversion(doc, provider);
                    return;
                } else {
                    self.appendReading(fed.slice());
                }
            }
            try self.syncDocumentOverlay(doc);
            return;
        }

        // 4. Idle phase (`.direct`, `.hiragana`, `.katakana`)
        if (key == 0x0A) { // C-j switches to Hiragana mode
            self.mode = .hiragana;
            self.romaji.clear();
            return;
        }
        if (key == 0x08 or key == 0x7F) {
            if (self.romaji.len > 0) {
                self.romaji.len -= 1;
            } else {
                _ = try doc.deleteBackwardGrapheme();
            }
            return;
        }

        if (self.mode == .direct) {
            try doc.insertUtf8(&[_]u8{key});
            return;
        }

        // Mode toggles in Hiragana / Katakana when no romaji is pending
        if (self.romaji.len == 0 and !self.sticky_armed) {
            if (key == 'l') {
                self.mode = .direct;
                return;
            }
            if (key == 'q') {
                self.mode = if (self.mode == .hiragana) .katakana else .hiragana;
                return;
            }
            // `;` arms sticky `▽` (starts preedit on next key, including `?`, `~`, `&`, `@`, `:`, `(`)
            if (key == ';') {
                self.sticky_armed = true;
                self.phase = .reading;
                self.reading_len = 0;
                self.okuri_len = 0;
                self.okuri_consonant = 0;
                try self.syncDocumentOverlay(doc);
                return;
            }
            // Direct prefix triggers in Hiragana mode (`?`, `~`, `&`, `@`, `:`, `(` or custom) start `▽` immediately
            if (isBuiltinPrefixTrigger(key) or self.isCustomPrefixTrigger(key)) {
                self.phase = .reading;
                self.reading_len = 0;
                self.okuri_len = 0;
                self.okuri_consonant = 0;
                self.appendReading(&[_]u8{key});
                try self.syncDocumentOverlay(doc);
                return;
            }
        }

        // Uppercase letter in Hiragana/Katakana mode starts `▽` reading
        if (std.ascii.isUpper(key)) {
            if (self.romaji.flushTrailingN(self.mode == .katakana)) |hatsuon| {
                try doc.insertUtf8(hatsuon);
            }
            self.phase = .reading;
            self.reading_len = 0;
            self.okuri_len = 0;
            self.okuri_consonant = 0;
            const fed = self.romaji.feed(std.ascii.toLower(key), false);
            if (fed.emitted_len > 0) {
                self.appendReading(fed.slice());
            }
            try self.syncDocumentOverlay(doc);
            return;
        }

        // Normal lowercase romaji in `.hiragana` or `.katakana`
        const fed = self.romaji.feed(key, self.mode == .katakana);
        if (fed.emitted_len > 0) {
            try doc.insertUtf8(fed.slice());
        }
    }

    /// Format the current single-line minibuffer view for display at the bottom of `xy`.
    pub fn formatMinibuffer(self: *const OmniIme) MinibufferView {
        const classified = self.classifyPrefix();
        var view = MinibufferView{
            .mode = self.mode,
            .phase = self.phase,
            .prefix_kind = classified.kind,
            .selected_index = self.selected_index,
            .candidate_count = self.candidates.count,
        };

        const mode_tag = switch (self.mode) {
            .direct => "[ASCII]",
            .hiragana => "[あ]",
            .katakana => "[ア]",
        };
        const kind_tag = switch (classified.kind) {
            .kanji => "SKK:漢字",
            .dict => "Omni:?辞書",
            .variant => "Omni:~異体字/IVS",
            .ids => "Omni:&部品合成",
            .search => "Omni:@全文検索",
            .system => "Omni::システム設定",
            .scheme => "Omni:(Scheme評価)",
            .custom => "Omni:拡張",
        };

        var pos: usize = 0;
        if (self.phase == .idle) {
            const s = std.fmt.bufPrint(view.line_buf[pos..], "{s} xy ready (;-prefix / ?dict / ~IVS / &IDS / @search / :sys / (eval))", .{mode_tag}) catch "";
            pos += s.len;
        } else if (self.phase == .selecting) {
            const s0 = std.fmt.bufPrint(view.line_buf[pos..], "[{s}] ({d}/{d})", .{ kind_tag, self.selected_index + 1, self.candidates.count }) catch "";
            pos += s0.len;
            for (self.candidates.items[0..self.candidates.count], 0..) |cand, idx| {
                const marker: []const u8 = if (idx == self.selected_index) " [" else "  ";
                const close: []const u8 = if (idx == self.selected_index) "]" else "";
                if (cand.annotation.len > 0) {
                    const s = std.fmt.bufPrint(view.line_buf[pos..], "{s}{d}:{s} <{s}>{s}", .{ marker, idx + 1, cand.insert_text, cand.annotation, close }) catch "";
                    pos += s.len;
                } else {
                    const s = std.fmt.bufPrint(view.line_buf[pos..], "{s}{d}:{s}{s}", .{ marker, idx + 1, cand.insert_text, close }) catch "";
                    pos += s.len;
                }
            }
        } else {
            const s0 = std.fmt.bufPrint(view.line_buf[pos..], "[{s}] ▽{s}", .{ kind_tag, self.reading_buf[0..self.reading_len] }) catch "";
            pos += s0.len;
            if (self.phase == .okuri) {
                const s1 = std.fmt.bufPrint(view.line_buf[pos..], "*{s}", .{self.okuri_buf[0..self.okuri_len]}) catch "";
                pos += s1.len;
            }
            if (self.romaji.len > 0) {
                const s2 = std.fmt.bufPrint(view.line_buf[pos..], "{s}", .{self.romaji.pendingSlice()}) catch "";
                pos += s2.len;
            }
        }
        view.line_len = @intCast(pos);
        return view;
    }
};

fn isBalancedSexp(s: []const u8) bool {
    var depth: i32 = 0;
    var in_string = false;
    var escaped = false;
    for (s) |ch| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (ch == '\\' and in_string) {
            escaped = true;
            continue;
        }
        if (ch == '"') {
            in_string = !in_string;
            continue;
        }
        if (!in_string) {
            if (ch == '(') depth += 1;
            if (ch == ')') depth -= 1;
        }
    }
    return depth <= 0 and s.len >= 2;
}

// ============================================================================
// Unit Tests
// ============================================================================

const MockDb = struct {
    last_learned_key: [64]u8 = @splat(0),
    last_learned_key_len: usize = 0,
    last_learned_stem: [64]u8 = @splat(0),
    last_learned_stem_len: usize = 0,

    fn query(
        ctx: *anyopaque,
        kind: PrefixKind,
        prefix_char: u8,
        query_key: []const u8,
        out: *CandidateList,
    ) void {
        _ = ctx;
        _ = prefix_char;
        switch (kind) {
            .kanji => {
                if (std.mem.eql(u8, query_key, "かんじ")) {
                    _ = out.append("漢字", "常用");
                    _ = out.append("感じ", "名詞");
                    _ = out.append("幹事", "名詞");
                } else if (std.mem.eql(u8, query_key, "うつくしi")) {
                    _ = out.append("美し", "形容詞");
                    _ = out.append("愛し", "古語");
                }
            },
            .dict => {
                if (std.mem.eql(u8, query_key, "nihon")) {
                    _ = out.append("日本 (Japan)", "JMdict #1463770");
                }
            },
            .variant => {
                if (std.mem.eql(u8, query_key, "葛")) {
                    _ = out.append("葛\u{E0100}", "MJ023642 葛飾区(人名・標準)");
                    _ = out.append("葛\u{E0101}", "MJ023643 葛城市(ヒ上部)");
                }
            },
            .ids => {
                if (std.mem.eql(u8, query_key, "木目心")) {
                    _ = out.append("想", "IDS: ⿱相心 (U+60F3)");
                }
            },
            .search => {
                if (std.mem.eql(u8, query_key, "猫")) {
                    _ = out.append("(ref 'aozora/wagahai 1 \"吾輩は猫である。名前はまだ無い。\")", "夏目漱石『吾輩は猫である』");
                }
            },
            .system => {
                if (std.mem.eql(u8, query_key, "font-size")) {
                    _ = out.append("(view/set! #:size 28)", "current: 24px (gen 12)");
                }
            },
            .scheme => {
                if (std.mem.eql(u8, query_key, "(+ 20 26)")) {
                    _ = out.append("46", "eval result");
                }
            },
            .custom => {
                if (std.mem.eql(u8, query_key, "todo")) {
                    _ = out.append("- [ ] ", "custom task prefix");
                }
            },
        }
    }

    fn learn(ctx: *anyopaque, query_key: []const u8, committed_stem: []const u8) void {
        const self: *MockDb = @ptrCast(@alignCast(ctx));
        @memcpy(self.last_learned_key[0..query_key.len], query_key);
        self.last_learned_key_len = query_key.len;
        @memcpy(self.last_learned_stem[0..committed_stem.len], committed_stem);
        self.last_learned_stem_len = committed_stem.len;
    }

    fn provider(self: *MockDb) OmniProvider {
        return .{
            .ctx = self,
            .queryFn = query,
            .learnFn = learn,
        };
    }
};

fn feedAsciiString(ime: *OmniIme, doc: anytype, prov: OmniProvider, s: []const u8) !void {
    for (s) |ch| {
        try ime.handleKey(doc, prov, ch);
    }
}

test "SKK normal kana-kanji conversion, okurigana auto-trigger, and user dict learning" {
    const DocType = document.Document(1024, 32, 512, 16, 256);
    var doc: DocType = .{};
    var db: MockDb = .{};
    const prov = db.provider();
    var ime: OmniIme = .{};

    // Type "UtsukushiI" -> "▽うつくし*い" -> auto-triggers conversion to "▼美しい"
    try feedAsciiString(&ime, &doc, prov, "UtsukushiI");
    try std.testing.expectEqual(OmniPhase.selecting, ime.phase);
    try std.testing.expectEqualStrings("▼美しい", doc.preedit.slice());
    try std.testing.expectEqualStrings("", doc.slice()); // Non-destructive until commit!

    // Press Enter to commit "美しい" and verify user dictionary learning callback
    try ime.handleKey(&doc, prov, '\n');
    try std.testing.expectEqual(OmniPhase.idle, ime.phase);
    try std.testing.expectEqualStrings("美しい", doc.slice());
    try std.testing.expectEqualStrings("うつくしi", db.last_learned_key[0..db.last_learned_key_len]);
    try std.testing.expectEqualStrings("美し", db.last_learned_stem[0..db.last_learned_stem_len]);

    // Type "Kanji " -> "▼漢字", press ' ' -> "▼感じ", then type "." ("。") to commit "感じ" + insert "。"
    try feedAsciiString(&ime, &doc, prov, "Kanji ");
    try std.testing.expectEqualStrings("▼漢字", doc.preedit.slice());
    try ime.handleKey(&doc, prov, ' ');
    try std.testing.expectEqualStrings("▼感じ", doc.preedit.slice());
    try ime.handleKey(&doc, prov, '.');
    try std.testing.expectEqualStrings("美しい感じ。", doc.slice());
}

test "Omni-Completion prefixes: ~IVS variant, &IDS composition, @FTS5 citation, :sys_config, and (Scheme)" {
    const DocType = document.Document(1024, 32, 512, 16, 256);
    var doc: DocType = .{};
    var db: MockDb = .{};
    const prov = db.provider();
    var ime: OmniIme = .{};

    // 1. `~` Variant / IVS selector lookup (`▽~葛` -> `葛\u{E0100}` / `葛\u{E0101}`)
    try ime.handleKey(&doc, prov, '~');
    try ime.feedUtf8ToReading(&doc, "葛");
    try std.testing.expectEqualStrings("▽~葛", doc.preedit.slice());
    try ime.handleKey(&doc, prov, ' ');
    const mb_ivs = ime.formatMinibuffer();
    try std.testing.expect(std.mem.indexOf(u8, mb_ivs.line(), "[Omni:~異体字/IVS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, mb_ivs.line(), "MJ023642") != null);
    // Select 2nd IVS candidate (`葛\u{E0101}`) and commit
    try ime.handleKey(&doc, prov, ' ');
    try ime.handleKey(&doc, prov, '\n');
    try std.testing.expectEqualStrings("葛\u{E0101}", doc.slice());

    // 2. `&` IDS component search (`▽&木目心` -> `想`)
    try ime.handleKey(&doc, prov, '&');
    try ime.feedUtf8ToReading(&doc, "木目心");
    try ime.handleKey(&doc, prov, ' ');
    try ime.handleKey(&doc, prov, '\n');
    try std.testing.expectEqualStrings("葛\u{E0101}想", doc.slice());

    // 3. `(...)` SKK Program Conversion (`▽(+ 20 26)` -> `"46"`)
    try feedAsciiString(&ime, &doc, prov, "(+ 20 26)");
    try std.testing.expectEqualStrings("▽(+ 20 26)", doc.preedit.slice());
    try ime.handleKey(&doc, prov, ' ');
    try ime.handleKey(&doc, prov, '\n');
    try std.testing.expectEqualStrings("葛\u{E0101}想46", doc.slice());

    // 4. `:` OS config lookup (`▽:font-size` -> `"(view/set! #:size 28)"`)
    doc.clear();
    try feedAsciiString(&ime, &doc, prov, ":font-size ");
    try ime.handleKey(&doc, prov, '\n');
    try std.testing.expectEqualStrings("(view/set! #:size 28)", doc.slice());

    // 5. Custom prefix registered via `registerCustomPrefix('#')`
    doc.clear();
    try std.testing.expect(ime.registerCustomPrefix('#'));
    try feedAsciiString(&ime, &doc, prov, "#todo ");
    try ime.handleKey(&doc, prov, '\n');
    try std.testing.expectEqualStrings("- [ ] ", doc.slice());
}

test "Romaji sokuon, hatsuon, katakana toggle, and C-g cancel restore document cleanly" {
    const DocType = document.Document(1024, 32, 512, 16, 256);
    var doc: DocType = .{};
    var db: MockDb = .{};
    const prov = db.provider();
    var ime: OmniIme = .{};

    // Sokuon + hatsuon in hiragana: "nippon" + "ka" -> "にっぽんか"
    try feedAsciiString(&ime, &doc, prov, "nipponka");
    try std.testing.expectEqualStrings("にっぽんか", doc.slice());

    // Toggle to katakana with 'q': "gakkou" -> "ガッコウ", then 'q' back to hiragana
    try feedAsciiString(&ime, &doc, prov, "qgakkouq");
    try std.testing.expectEqualStrings("にっぽんかガッコウ", doc.slice());

    // Start SKK conversion "Kanji " -> "▼漢字", press C-g (0x07) -> back to "▽かんじ", press C-g -> idle
    try feedAsciiString(&ime, &doc, prov, "Kanji ");
    try std.testing.expectEqual(OmniPhase.selecting, ime.phase);
    try std.testing.expectEqualStrings("▼漢字", doc.preedit.slice());
    try ime.handleKey(&doc, prov, 0x07);
    try std.testing.expectEqual(OmniPhase.reading, ime.phase);
    try std.testing.expectEqualStrings("▽かんじ", doc.preedit.slice());
    try ime.handleKey(&doc, prov, 0x07);
    try std.testing.expectEqual(OmniPhase.idle, ime.phase);
    try std.testing.expectEqual(document.PreeditPhase.none, doc.preedit.phase);
    try std.testing.expectEqualStrings("にっぽんかガッコウ", doc.slice());
}
