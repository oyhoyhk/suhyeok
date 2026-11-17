//! A hosted terminal's screen as tmux `capture-pane` gives it: plain text with soft-wrapped rows joined (`-p -J`,
//! what the menu and reply parsers read) and rows with their colors as SGR escapes (`-p -e`, what `/api/term`
//! sends). Also the answers to the terminal queries tmux would otherwise answer for the program.

use serde_json::{json, Value};
use vt100::Color;

/// Text attributes of one cell, the subset `capture-pane -e` carries and the /desk terminal view draws.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Style {
    pub fg: Option<Rgb>,
    pub bg: Option<Rgb>,
    pub bold: bool,
    pub dim: bool,
    pub italic: bool,
    pub underline: bool,
    pub inverse: bool,
}

/// A color as the program set it: a palette index (0-255) or 24-bit.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Rgb {
    Idx(u8),
    True(u8, u8, u8),
}

fn color(c: Color) -> Option<Rgb> {
    match c {
        Color::Default => None,
        Color::Idx(i) => Some(Rgb::Idx(i)),
        Color::Rgb(r, g, b) => Some(Rgb::True(r, g, b)),
    }
}

impl Style {
    /// "\x1b[0;1;31m": a full reset, then this style, so every change stands on its own.
    pub fn sgr(&self) -> String {
        let mut codes: Vec<String> = vec!["0".into()];
        for (on, code) in [(self.bold, "1"), (self.dim, "2"), (self.italic, "3"), (self.underline, "4"), (self.inverse, "7")] {
            if on {
                codes.push(code.into());
            }
        }
        for (c, base, bright, ext) in [(self.fg, 30, 90, 38), (self.bg, 40, 100, 48)] {
            match c {
                Some(Rgb::Idx(i)) if i < 8 => codes.push((base + i as u16).to_string()),
                Some(Rgb::Idx(i)) if i < 16 => codes.push((bright + i as u16 - 8).to_string()),
                Some(Rgb::Idx(i)) => codes.push(format!("{ext};5;{i}")),
                Some(Rgb::True(r, g, b)) => codes.push(format!("{ext};2;{r};{g};{b}")),
                None => {}
            }
        }
        format!("\x1b[{}m", codes.join(";"))
    }

    /// A blank cell in this style still shows something (a colored or inverted bar).
    fn visible_blank(&self) -> bool {
        self.bg.is_some() || self.inverse || self.underline
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Cell {
    /// The grapheme; empty for a never-written cell (shown as a space).
    pub text: String,
    /// 2 for a wide (CJK) character; its continuation cell is not stored.
    pub width: u8,
    pub style: Style,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Row {
    /// Cells up to the last one that shows anything (trailing blanks dropped).
    pub cells: Vec<Cell>,
    /// The row continues on the next one (soft wrap): `-J` joins them.
    pub wrapped: bool,
}

/// One read of a hosted terminal: `history` rows of scrollback (oldest first), then the `height` visible rows.
#[derive(Clone, Debug, PartialEq)]
pub struct Screen {
    pub width: u16,
    pub height: u16,
    /// Cursor column and row within the visible screen (tmux `cursor_x`, `cursor_y`).
    pub cx: u16,
    pub cy: u16,
    /// The program switched to the alternate screen (full-screen TUI; tmux `alternate_on`).
    pub alternate: bool,
    /// The program asked for bracketed paste (DECSET 2004).
    pub bracketed_paste: bool,
    /// The program turned on application cursor keys (DECCKM): arrows go as SS3.
    pub application_cursor: bool,
    pub rows: Vec<Row>,
}

impl Screen {
    /// Reads `history` lines of scrollback (fewer when the terminal has fewer) and the visible screen.
    pub fn capture<CB: vt100::Callbacks>(parser: &mut vt100::Parser<CB>, history: usize) -> Screen {
        let screen = parser.screen_mut();
        let (rows, cols) = screen.size();
        let (rows, cols) = (rows.get(), cols.get());
        let mut out: Vec<Row> = Vec::with_capacity(history.min(screen.scrollback_len()) + rows as usize);
        // vt100 shows scrollback by moving its view up: with the view `k` lines up, visible row 0 is line -k.
        let mut k = history.min(screen.scrollback_len());
        while k > 0 {
            screen.set_scrollback(k);
            let take = k.min(rows as usize);
            for r in 0..take as u16 {
                out.push(read_row(screen, r, cols));
            }
            k -= take;
        }
        screen.set_scrollback(0);
        for r in 0..rows {
            out.push(read_row(screen, r, cols));
        }
        let (cy, cx) = screen.cursor_position();
        Screen {
            width: cols,
            height: rows,
            cx,
            cy,
            alternate: screen.alternate_screen(),
            bracketed_paste: screen.bracketed_paste(),
            application_cursor: screen.application_cursor(),
            rows: out,
        }
    }

    /// Plain text lines, soft-wrapped rows joined into one and trailing spaces trimmed
    /// (`capture-pane -p -J`). Blank rows stay, so the last `height` rows are still the bottom of the screen
    /// unless rows there were joined.
    pub fn lines(&self) -> Vec<String> {
        let mut out = vec![];
        let mut cur = String::new();
        for row in &self.rows {
            for c in &row.cells {
                cur.push_str(if c.text.is_empty() { " " } else { &c.text });
            }
            if row.wrapped {
                // A wrapped row fills the width: pad the dropped trailing blanks back so the join keeps columns.
                let used: usize = row.cells.iter().map(|c| c.width as usize).sum();
                cur.extend(std::iter::repeat_n(' ', (self.width as usize).saturating_sub(used)));
                continue;
            }
            out.push(cur.trim_end().to_string());
            cur.clear();
        }
        if !cur.is_empty() {
            out.push(cur.trim_end().to_string());
        }
        out
    }

    /// `lines()` joined with "\n": what `menu::Term::screen` returns.
    pub fn text(&self) -> String {
        self.lines().join("\n")
    }

    /// One string per terminal row with SGR color escapes (`capture-pane -p -e`). Each row stands on its own:
    /// it starts from the default style and ends with a reset when it changed it.
    pub fn ansi_lines(&self) -> Vec<String> {
        self.rows
            .iter()
            .map(|row| {
                let mut s = String::new();
                let mut cur = Style::default();
                for c in &row.cells {
                    if c.style != cur {
                        s.push_str(&c.style.sgr());
                        cur = c.style;
                    }
                    s.push_str(if c.text.is_empty() { " " } else { &c.text });
                }
                if cur != Style::default() {
                    s.push_str("\x1b[0m");
                }
                s
            })
            .collect()
    }

    /// The `/api/term` body (MobileTerminal.screen): `lines` with colors, the pane size, the cursor within the
    /// visible screen (the last `height` lines) and whether the alternate screen is on.
    pub fn to_json(&self) -> Value {
        json!({
            "lines": self.ansi_lines(),
            "width": self.width,
            "height": self.height,
            "cx": self.cx,
            "cy": self.cy,
            "alternate": self.alternate,
        })
    }
}

fn read_row(screen: &vt100::Screen, r: u16, cols: u16) -> Row {
    let mut cells: Vec<Cell> = Vec::with_capacity(cols as usize);
    let mut keep = 0; // cells up to the last visible one
    for col in 0..cols {
        let Some(c) = screen.cell(r, col) else { break };
        if c.is_wide_continuation() {
            continue;
        }
        let style = Style {
            fg: color(c.fgcolor()),
            bg: color(c.bgcolor()),
            bold: c.bold(),
            dim: c.dim(),
            italic: c.italic(),
            underline: c.underline(),
            inverse: c.inverse(),
        };
        let text = c.contents().to_string();
        let shows = !text.trim().is_empty() || style.visible_blank();
        cells.push(Cell { text, width: if c.is_wide() { 2 } else { 1 }, style });
        if shows {
            keep = cells.len();
        }
    }
    let wrapped = screen.row_wrapped(r);
    if !wrapped {
        cells.truncate(keep);
    }
    Row { cells, wrapped }
}

/// The terminal side of the queries a program sends at start (tmux answers these for its panes): cursor position
/// (DSR 6), status (DSR 5), device attributes (DA1/DA2) and the default colors (OSC 10/11, the /desk view's
/// #e6e6e6 on black). Codex waits for the cursor position before it draws anything.
#[derive(Default)]
pub struct Replies {
    pub out: Vec<u8>,
}

impl vt100::Callbacks for Replies {
    fn unhandled_csi(&mut self, screen: &mut vt100::Screen, i1: Option<u8>, _i2: Option<u8>, params: &[&[u16]], c: char) {
        let p0 = params.first().and_then(|p| p.first()).copied().unwrap_or(0);
        let reply = match (i1, c, p0) {
            (None, 'n', 6) => {
                let (row, col) = screen.cursor_position();
                format!("\x1b[{};{}R", row + 1, col + 1)
            }
            (None, 'n', 5) => "\x1b[0n".into(),
            (None, 'c', 0) => "\x1b[?1;2c".into(),
            (Some(b'>'), 'c', 0) => "\x1b[>84;0;0c".into(),
            _ => return,
        };
        self.out.extend_from_slice(reply.as_bytes());
    }

    fn unhandled_osc(&mut self, _: &mut vt100::Screen, params: &[&[u8]]) {
        let reply = match params {
            [b"10", b"?"] => "\x1b]10;rgb:e6e6/e6e6/e6e6\x1b\\",
            [b"11", b"?"] => "\x1b]11;rgb:0000/0000/0000\x1b\\",
            _ => return,
        };
        self.out.extend_from_slice(reply.as_bytes());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parser(rows: u16, cols: u16) -> vt100::Parser<Replies> {
        let nz = |n: u16| std::num::NonZeroU16::new(n).unwrap();
        vt100::Parser::new_with_callbacks(nz(rows), nz(cols), 100, Replies::default())
    }

    #[test]
    fn answers_cursor_position_and_device_attributes() {
        let mut p = parser(10, 40);
        p.process(b"\x1b[3;5H\x1b[6n\x1b[c\x1b[>c\x1b[5n\x1b]11;?\x07\x1b[?6n");
        let out = String::from_utf8(std::mem::take(&mut p.callbacks_mut().out)).unwrap();
        assert_eq!(out, "\x1b[3;5R\x1b[?1;2c\x1b[>84;0;0c\x1b[0n\x1b]11;rgb:0000/0000/0000\x1b\\");
    }

    #[test]
    fn text_joins_wrapped_rows_and_keeps_blank_rows() {
        let mut p = parser(4, 10);
        p.process(b"hi   \r\n0123456789abc\r\n");
        let s = Screen::capture(&mut p, 0);
        assert_eq!(s.lines(), ["hi", "0123456789abc", ""]);
        assert_eq!((s.cx, s.cy, s.width, s.height), (0, 3, 10, 4));
        assert_eq!(s.ansi_lines(), ["hi", "0123456789", "abc", ""]);
    }

    #[test]
    fn history_comes_before_the_visible_rows() {
        let mut p = parser(3, 10);
        for i in 0..8 {
            p.process(format!("l{i}\r\n").as_bytes());
        }
        // Rows: l0..l7 then an empty cursor row; 3 visible = l6, l7, "".
        let s = Screen::capture(&mut p, 4);
        assert_eq!(s.lines(), ["l2", "l3", "l4", "l5", "l6", "l7", ""]);
        assert_eq!(Screen::capture(&mut p, 0).lines(), ["l6", "l7", ""]);
        assert_eq!(Screen::capture(&mut p, 1000).lines().len(), 6 + 3);
        assert_eq!(p.screen().scrollback(), 0);
    }

    #[test]
    fn colors_become_self_contained_sgr() {
        let mut p = parser(2, 20);
        p.process("\x1b[1;31mRED\x1b[0m 한글 \x1b[38;5;200mX\x1b[48;2;1;2;3m \x1b[0m".as_bytes());
        let s = Screen::capture(&mut p, 0);
        assert_eq!(s.ansi_lines()[0], "\x1b[0;1;31mRED\x1b[0m 한글 \x1b[0;38;5;200mX\x1b[0;38;5;200;48;2;1;2;3m \x1b[0m");
        assert_eq!(s.lines()[0], "RED 한글 X");
        let j = s.to_json();
        assert_eq!(j["height"], 2);
        assert_eq!(j["alternate"], false);
        assert_eq!(j["lines"].as_array().unwrap().len(), 2);
    }
}
