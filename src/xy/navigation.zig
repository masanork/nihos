//! Small device navigation state. The editor document is never a book buffer.
const std = @import("std");
const config = @import("view_config");
pub const Key = union(enum) { text: u8, enter, backspace, left, right, up, down, escape, cancel, eof, clear, undo };
pub const section = config.section;
const theme_key linksection(config.data_section) = "theme".*;
const dark_name linksection(config.data_section) = "dark".*;
const light_name linksection(config.data_section) = "light".*;
pub const Screen = enum(u8) { document, home, chapters, reading, settings, credits, examples, exercise, card_view, certification, ssh };
pub const SshFailure = enum(u8) { none, host_key_mismatch, connection_failed };
pub const PageLocation = struct { chapter: u16 = 0, offset: u32 = 0 };

pub const CardViewData = struct {
    valid: bool = false,
    name: [64]u8 = @splat(0),
    name_len: u8 = 0,
    address: [128]u8 = @splat(0),
    address_len: u8 = 0,
    birth: [16]u8 = @splat(0),
    birth_len: u8 = 0,
    gender: [8]u8 = @splat(0),
    gender_len: u8 = 0,
    has_photo: bool = false,

    pub fn nameSlice(self: *const CardViewData) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn addressSlice(self: *const CardViewData) []const u8 {
        return self.address[0..self.address_len];
    }
    pub fn birthSlice(self: *const CardViewData) []const u8 {
        return self.birth[0..self.birth_len];
    }
    pub fn genderSlice(self: *const CardViewData) []const u8 {
        return self.gender[0..self.gender_len];
    }
    pub fn clear(self: *CardViewData) void {
        @memset(&self.name, 0);
        @memset(&self.address, 0);
        @memset(&self.birth, 0);
        @memset(&self.gender, 0);
        self.name_len = 0;
        self.address_len = 0;
        self.birth_len = 0;
        self.gender_len = 0;
        self.valid = false;
        self.has_photo = false;
    }
};

pub const State = struct {
    screen: Screen = .document,
    home_selection: u8 = 0,
    book: u8 = 0,
    chapter: u16 = 0,
    chapter_count: [4]u16 = .{ 3, 13, 3, 32 },
    selected_chapter: u16 = 0,
    offset: u32 = 0,
    end: u32 = 0,
    text_length: u32 = 0,
    previous: [256]PageLocation = @splat(.{}),
    previous_count: u16 = 0,
    return_screen: Screen = .home,
    error_code: u32 = 0,
    ssh_failure: SshFailure = .none,
    can_try: bool = false,
    card: CardViewData = .{},

    pub fn home(self: *State) linksection(section) void {
        self.screen = .home;
    }
    pub fn open(self: *State, book: u8) linksection(section) void {
        self.book = book;
        self.chapter = 0;
        self.selected_chapter = 0;
        self.offset = 0;
        self.end = 0;
        self.previous_count = 0;
        self.can_try = false;
        self.screen = .reading;
    }
    pub fn selectChapter(self: *State) linksection(section) void {
        self.chapter = self.selected_chapter;
        self.offset = 0;
        self.end = 0;
        self.previous_count = 0;
        self.screen = .reading;
    }
    pub fn next(self: *State) linksection(section) void {
        if (self.end <= self.offset or self.end > self.text_length) return;
        const next_chapter = self.end == self.text_length;
        if (next_chapter and self.chapter + 1 >= self.chapter_count[self.book]) return;
        if (self.previous_count == self.previous.len) {
            for (1..self.previous.len) |i| self.previous[i - 1] = self.previous[i];
            self.previous_count -= 1;
        }
        self.previous[self.previous_count] = .{ .chapter = self.chapter, .offset = self.offset };
        self.previous_count += 1;
        if (next_chapter) {
            self.chapter += 1;
            self.selected_chapter = self.chapter;
            self.offset = 0;
        } else self.offset = self.end;
        self.end = 0; // Another Next needs a completed page in the new location.
    }
    pub fn back(self: *State) linksection(section) void {
        if (self.previous_count > 0) {
            self.previous_count -= 1;
            const location = self.previous[self.previous_count];
            self.chapter = location.chapter;
            self.selected_chapter = location.chapter;
            self.offset = location.offset;
            self.end = 0;
        } else if (self.chapter > 0) {
            self.selected_chapter = self.chapter - 1;
            self.selectChapter();
        }
    }
    pub fn handle(self: *State, key: Key, view: *config.Config) linksection(section) void {
        self.error_code = 0;
        if (key == .escape or key == .cancel) {
            if (self.screen == .certification) self.screen = .settings else if (self.screen == .credits) self.screen = .reading else self.home();
            return;
        }
        switch (self.screen) {
            .examples, .exercise => {},
            .document => {},
            .home => switch (key) {
                .up, .left => self.home_selection -|= 1,
                .down, .right => self.home_selection = @min(6, self.home_selection + 1),
                .enter => self.activateHome(),
                .text => |byte| switch (byte) {
                    'n', 'N' => self.screen = .document,
                    '1'...'4' => self.open(byte - '1'),
                    's', 'S' => {
                        self.return_screen = .home;
                        self.screen = .settings;
                    },
                    'r', 'R' => self.screen = .reading,
                    't', 'T' => self.screen = .ssh,
                    else => {},
                },
                else => {},
            },
            .chapters => switch (key) {
                .up, .left => self.selected_chapter -|= 1,
                .down, .right => self.selected_chapter = @min(self.chapter_count[self.book] - 1, self.selected_chapter + 1),
                .enter => self.selectChapter(),
                else => {},
            },
            .reading => switch (key) {
                .right, .down, .enter => self.next(),
                .left, .up, .backspace => self.back(),
                .text => |byte| switch (byte) {
                    ' ', 'n' => self.next(),
                    'p' => self.back(),
                    'c' => {
                        self.selected_chapter = self.chapter;
                        self.screen = .chapters;
                    },
                    's' => {
                        self.return_screen = .reading;
                        self.screen = .settings;
                    },
                    'i' => self.screen = .credits,
                    'e' => if (self.can_try) {
                        self.screen = .examples;
                    },
                    'h' => self.home(),
                    else => {},
                },
                else => {},
            },
            .settings => switch (key) {
                .enter => self.screen = self.return_screen,
                .left => view.style.axis = 0,
                .right => view.style.axis = 1,
                .up => view.style.body_px = @min(64, view.style.body_px + 4),
                .down => view.style.body_px = @max(16, view.style.body_px -| 4),
                .text => |byte| switch (byte) {
                    'g', 'G' => self.screen = .certification,
                    'v' => view.style.axis = 1 - view.style.axis,
                    'f' => view.style.style_id = 1 - view.style.style_id,
                    't' => {
                        view.set(&theme_key, .{ .symbol = if (view.appearance.background == 0xfaf6ee) &dark_name else &light_name }) catch {
                            self.error_code = 1;
                        };
                    },
                    '+' => view.style.body_px = @min(64, view.style.body_px + 4),
                    '-' => view.style.body_px = @max(16, view.style.body_px -| 4),
                    else => {},
                },
                else => {},
            },
            .certification => if (key == .enter) {
                self.screen = .settings;
            },
            .credits => if (key == .enter) {
                self.screen = .reading;
            },
            .card_view => switch (key) {
                .escape, .cancel => self.screen = self.return_screen,
                .enter => self.screen = .document,
                else => {},
            },
            .ssh => {},
        }
        view.style.ruby_px = @max(8, view.style.body_px / 2);
    }
    fn activateHome(self: *State) linksection(section) void {
        switch (self.home_selection) {
            0 => self.screen = .document,
            1...4 => self.open(self.home_selection - 1),
            5 => {
                self.return_screen = .home;
                self.screen = .settings;
            },
            6 => self.screen = .ssh,
            else => {},
        }
    }
    /// Portrait Home cards share this geometry with the portrait renderer.
    pub const portrait_home_x: u32 = 36;
    pub const portrait_home_width: u32 = 648;
    pub const portrait_home_top: u32 = 170;
    pub const portrait_home_pitch: u32 = 156;
    pub const portrait_home_card_height: u32 = 132;
    pub const portrait_ssh_top: u32 = 1108;
    pub const portrait_ssh_height: u32 = 80;
    pub const landscape_ssh_x: u32 = 664;
    pub const landscape_ssh_y: u32 = 566;
    pub const landscape_ssh_width: u32 = 568;
    pub const landscape_ssh_height: u32 = 64;

    /// Handles only the portrait Home screen until the other scenes are adapted.
    pub fn touchPortraitHome(self: *State, x: u32, y: u32) linksection(section) void {
        if (self.screen != .home or x < portrait_home_x or x >= portrait_home_x + portrait_home_width or y < portrait_home_top) return;
        if (y >= portrait_ssh_top and y < portrait_ssh_top + portrait_ssh_height) {
            self.home_selection = 6;
            return self.activateHome();
        }
        const offset = y - portrait_home_top;
        const index = offset / portrait_home_pitch;
        if (index >= 6 or offset % portrait_home_pitch >= portrait_home_card_height) return;
        self.home_selection = @intCast(index);
        self.activateHome();
    }
    /// Portrait controls use 720x1280 logical coordinates.
    pub fn touchPortrait(self: *State, x: u32, y: u32, view: *config.Config) linksection(section) void {
        if (x >= 720 or y >= 1280) return;
        if (self.screen == .home) return self.touchPortraitHome(x, y);
        if (y >= 1208) {
            const button = x / 120;
            if (button == 0) return self.home();
            if (self.screen == .chapters) {
                if (button <= 2) self.selected_chapter -|= 8 else self.selected_chapter = @min(self.chapter_count[self.book] - 1, self.selected_chapter + 8);
            } else if (self.screen == .reading) switch (button) {
                1 => self.back(),
                2 => self.next(),
                3 => if (self.can_try) {
                    self.screen = .examples;
                },
                4 => {
                    self.selected_chapter = self.chapter;
                    self.screen = .chapters;
                },
                5 => {
                    self.return_screen = .reading;
                    self.screen = .settings;
                },
                else => {},
            };
            return;
        }
        switch (self.screen) {
            .chapters => if (y >= 132 and y < 1012) {
                const offset = y - 132;
                if (offset % 110 >= 90) return;
                const selected: u16 = (self.selected_chapter / 8) * 8 + @as(u16, @intCast(offset / 110));
                if (selected < self.chapter_count[self.book]) {
                    self.selected_chapter = selected;
                    self.selectChapter();
                }
            },
            .reading => if (x < 360) self.back() else self.next(),
            .settings => {
                if (y >= 80 and y < 150) self.screen = .certification else if (y >= 160 and y < 240) self.handle(.{ .text = if (x < 360) '-' else '+' }, view) else if (y >= 260 and y < 340) self.handle(.{ .text = 'v' }, view) else if (y >= 360 and y < 440) self.handle(.{ .text = 'f' }, view) else if (y >= 460 and y < 540) self.handle(.{ .text = 't' }, view) else if (y >= 560 and y < 640) self.screen = self.return_screen;
            },
            .certification => self.screen = .settings,
            .credits => self.screen = .reading,
            .card_view => self.screen = self.return_screen,
            .document => self.home(),
            else => {},
        }
    }
    /// Validated logical landscape coordinates from the pointer service.
    pub fn touch(self: *State, x: u32, y: u32, view: *config.Config) linksection(section) void {
        if (x >= 1280 or y >= 720) return;
        if (y >= 648) {
            if (x < 200) self.home() else if (self.screen == .chapters) {
                if (x < 480) self.selected_chapter -|= 8 else if (x < 760) self.selected_chapter = @min(self.chapter_count[self.book] - 1, self.selected_chapter + 8);
            } else if (self.screen == .reading) {
                if (x < 480) {
                    self.back();
                } else if (self.can_try and x >= 680 and x < 760) {
                    self.screen = .examples;
                } else if (x < 760) {
                    self.next();
                } else if (x < 1030) {
                    self.selected_chapter = self.chapter;
                    self.screen = .chapters;
                } else {
                    self.return_screen = .reading;
                    self.screen = .settings;
                }
            }
            return;
        }
        switch (self.screen) {
            .home => {
                if (x >= landscape_ssh_x and x < landscape_ssh_x + landscape_ssh_width and y >= landscape_ssh_y and y < landscape_ssh_y + landscape_ssh_height) {
                    self.home_selection = 6;
                    return self.activateHome();
                }
                if (y >= 170 and y < 570 and x >= 48 and x < 1232) {
                    const col: u8 = if (x < 640) 0 else 1;
                    const row: u8 = @intCast((y - 170) / 130);
                    if (row < 3) {
                        self.home_selection = row * 2 + col;
                        self.activateHome();
                    }
                }
            },
            .chapters => {
                if (y >= 132 and y < 612) {
                    const top = (self.selected_chapter / 8) * 8;
                    const selected: u16 = top + @as(u16, @intCast((y - 132) / 60));
                    if (selected < self.chapter_count[self.book]) {
                        self.selected_chapter = selected;
                        self.selectChapter();
                    }
                }
            },
            .reading => if (x < 640) self.back() else self.next(),
            .settings => {
                if (y >= 80 and y < 150) self.screen = .certification else if (y >= 160 and y < 240) self.handle(.{ .text = if (x < 640) '-' else '+' }, view) else if (y >= 260 and y < 340) self.handle(.{ .text = 'v' }, view) else if (y >= 360 and y < 440) self.handle(.{ .text = 'f' }, view) else if (y >= 460 and y < 540) self.handle(.{ .text = 't' }, view) else if (y >= 560) self.screen = self.return_screen;
            },
            .certification => self.screen = .settings,
            .credits => self.screen = .reading,
            .card_view => self.screen = self.return_screen,
            .examples, .exercise, .ssh => {},
            .document => self.home(),
        }
    }
};

test "previous restores chapter boundaries and keeps earlier pages" {
    var state = State{};
    state.open(1);
    state.selectChapter();
    state.next(); // No completed frame must not skip an unread chapter.
    try std.testing.expectEqual(@as(u16, 0), state.chapter);
    state.text_length = 200;
    state.end = 100;
    state.next();
    state.end = 200;
    state.next();
    try std.testing.expectEqual(@as(u16, 1), state.chapter);
    state.back();
    try std.testing.expectEqual(@as(u16, 0), state.chapter);
    try std.testing.expectEqual(@as(u32, 100), state.offset);
    state.back();
    try std.testing.expectEqual(@as(u32, 0), state.offset);
}

test "device navigation preserves reading position through home and settings" {
    var state = State{};
    var view = config.Config{};
    state.home();
    state.handle(.{ .text = '2' }, &view);
    try std.testing.expectEqual(Screen.reading, state.screen);
    state.end = 123;
    state.text_length = 999;
    state.handle(.right, &view);
    try std.testing.expectEqual(@as(u32, 123), state.offset);
    state.handle(.{ .text = 's' }, &view);
    state.handle(.{ .text = 'v' }, &view);
    state.handle(.enter, &view);
    try std.testing.expectEqual(Screen.reading, state.screen);
    try std.testing.expectEqual(@as(u32, 123), state.offset);
    state.handle(.{ .text = 'c' }, &view);
    try std.testing.expectEqual(Screen.chapters, state.screen);
    state.handle(.enter, &view);
    try std.testing.expectEqual(Screen.reading, state.screen);
    try std.testing.expectEqual(@as(u32, 0), state.offset);
    state.back();
    try std.testing.expectEqual(@as(u32, 0), state.offset);
    state.touch(200, 1000, &view); // left reading region
    state.home();
    state.touch(880, 220, &view); // upper right card
    try std.testing.expectEqual(@as(u8, 0), state.book);
}

test "portrait home cards select every destination and gaps do nothing" {
    for (0..6) |i| {
        var state = State{};
        state.home();
        state.touchPortraitHome(State.portrait_home_x + 5, State.portrait_home_top + @as(u32, @intCast(i)) * State.portrait_home_pitch + 10);
        try std.testing.expectEqual(@as(u8, @intCast(i)), state.home_selection);
        try std.testing.expectEqual(if (i == 0) Screen.document else if (i == 5) Screen.settings else Screen.reading, state.screen);
        if (i > 0 and i < 5) try std.testing.expectEqual(@as(u8, @intCast(i - 1)), state.book);
    }
    var state = State{};
    state.home();
    state.touchPortraitHome(State.portrait_home_x, State.portrait_home_top + State.portrait_home_card_height);
    state.touchPortraitHome(0, State.portrait_home_top);
    try std.testing.expectEqual(Screen.home, state.screen);
}

test "SSH entry is reachable from home by touch and keyboard" {
    var view: config.Config = .{};
    var state: State = .{};
    state.home();
    state.touchPortraitHome(State.portrait_home_x + 1, State.portrait_ssh_top + 1);
    try std.testing.expectEqual(Screen.ssh, state.screen);
    state.handle(.escape, &view);
    try std.testing.expectEqual(Screen.home, state.screen);
    state.touch(State.landscape_ssh_x + 1, State.landscape_ssh_y + 1, &view);
    try std.testing.expectEqual(Screen.ssh, state.screen);
    state.handle(.escape, &view);
    state.handle(.{ .text = 't' }, &view);
    try std.testing.expectEqual(Screen.ssh, state.screen);
    state.handle(.escape, &view);
    state.home_selection = 5;
    state.handle(.down, &view);
    state.handle(.enter, &view);
    try std.testing.expectEqual(Screen.ssh, state.screen);
}

test "certification screen opens from settings and returns" {
    var state = State{};
    var view = config.Config{};
    state.home();
    state.handle(.{ .text = 's' }, &view);
    state.handle(.{ .text = 'g' }, &view);
    try std.testing.expectEqual(Screen.certification, state.screen);
    state.handle(.escape, &view);
    try std.testing.expectEqual(Screen.settings, state.screen);
    state.touchPortrait(100, 100, &view);
    try std.testing.expectEqual(Screen.certification, state.screen);
    state.handle(.enter, &view);
    state.touch(100, 100, &view);
    try std.testing.expectEqual(Screen.certification, state.screen);
}
