//! Small device navigation state. The editor document is never a book buffer.
const std = @import("std");
const config = @import("view_config");
pub const Key = union(enum) { text: u8, enter, backspace, left, right, up, down, escape, cancel, eof, clear, undo };
pub const section = config.section;
const theme_key linksection(config.data_section) = "theme".*;
const dark_name linksection(config.data_section) = "dark".*;
const light_name linksection(config.data_section) = "light".*;
pub const Screen = enum(u8) { document, home, chapters, reading, settings, credits };
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
    previous: [256]u32 = @splat(0),
    previous_count: u16 = 0,
    return_screen: Screen = .home,
    error_code: u32 = 0,

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
        self.screen = .chapters;
    }
    pub fn selectChapter(self: *State) linksection(section) void {
        self.chapter = self.selected_chapter;
        self.offset = 0;
        self.end = 0;
        self.previous_count = 0;
        self.screen = .reading;
    }
    pub fn next(self: *State) linksection(section) void {
        if (self.end > self.offset and self.end < self.text_length) {
            if (self.previous_count == self.previous.len) {
                for (1..self.previous.len) |i| self.previous[i - 1] = self.previous[i];
                self.previous_count -= 1;
            }
            self.previous[self.previous_count] = self.offset;
            self.previous_count += 1;
            self.offset = self.end;
        } else if (self.end == self.text_length and self.chapter + 1 < self.chapter_count[self.book]) {
            self.selected_chapter = self.chapter + 1;
            self.selectChapter();
        }
    }
    pub fn back(self: *State) linksection(section) void {
        if (self.previous_count > 0) {
            self.previous_count -= 1;
            self.offset = self.previous[self.previous_count];
        } else if (self.chapter > 0) {
            self.selected_chapter = self.chapter - 1;
            self.selectChapter();
        }
    }
    pub fn handle(self: *State, key: Key, view: *config.Config) linksection(section) void {
        self.error_code = 0;
        if (key == .escape or key == .cancel) {
            if (self.screen == .credits) self.screen = .reading else self.home();
            return;
        }
        switch (self.screen) {
            .document => {},
            .home => switch (key) {
                .up, .left => self.home_selection -|= 1,
                .down, .right => self.home_selection = @min(5, self.home_selection + 1),
                .enter => self.activateHome(),
                .text => |byte| switch (byte) {
                    'n', 'N' => self.screen = .document,
                    '1'...'4' => self.open(byte - '1'),
                    's', 'S' => {
                        self.return_screen = .home;
                        self.screen = .settings;
                    },
                    'r', 'R' => self.screen = .reading,
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
            .credits => if (key == .enter) {
                self.screen = .reading;
            },
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
            6 => self.screen = .reading,
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
                if (x < 480) self.back() else if (x < 760) self.next() else if (x < 1030) self.screen = .chapters else {
                    self.return_screen = .reading;
                    self.screen = .settings;
                }
            }
            return;
        }
        switch (self.screen) {
            .home => {
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
                if (y >= 160 and y < 240) self.handle(.{ .text = if (x < 640) '-' else '+' }, view) else if (y >= 260 and y < 340) self.handle(.{ .text = 'v' }, view) else if (y >= 360 and y < 440) self.handle(.{ .text = 'f' }, view) else if (y >= 460 and y < 540) self.handle(.{ .text = 't' }, view) else if (y >= 560) self.screen = self.return_screen;
            },
            .credits => self.screen = .reading,
            .document => self.home(),
        }
    }
};

test "device navigation preserves reading position through home and settings" {
    var state = State{};
    var view = config.Config{};
    state.home();
    state.handle(.{ .text = '2' }, &view);
    try std.testing.expectEqual(Screen.chapters, state.screen);
    state.handle(.enter, &view);
    state.end = 123;
    state.text_length = 999;
    state.handle(.right, &view);
    try std.testing.expectEqual(@as(u32, 123), state.offset);
    state.handle(.{ .text = 's' }, &view);
    state.handle(.{ .text = 'v' }, &view);
    state.handle(.enter, &view);
    try std.testing.expectEqual(Screen.reading, state.screen);
    try std.testing.expectEqual(@as(u32, 123), state.offset);
    state.back();
    try std.testing.expectEqual(@as(u32, 0), state.offset);
    state.touch(200, 1000, &view); // left reading region
    state.home();
    state.touch(880, 220, &view); // upper right card
    try std.testing.expectEqual(@as(u8, 0), state.book);
}
