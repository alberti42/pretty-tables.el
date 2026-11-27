# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The release workflow publishes the section of a version as the text of its
GitHub release, so before tagging `vX.Y.Z`, move `[Unreleased]` into a
`## [X.Y.Z] - YYYY-MM-DD` heading and set `Version:` in every package file
to `X.Y.Z`.

## [Unreleased]

### Fixed

- With `org-indent-mode`, an Org table is drawn again once `org-indent-mode` has put its `line-prefix` on the lines, and again when it is turned off. Before, a table drawn before `org-indent-mode` had indented the buffer, as when a file is opened, took no room for the indentation: with soft wrap, each drawn row as wide as the text area spilled onto a second screen line, and the wrapped lines of a row were not indented.

## [0.8.0] - 2026-11-25

### Added

- `pretty-tables-toggle-hook`: runs when the Org or the Markdown mode is turned on or off, before that mode's own hook. Settings shared by both go there.
- `pretty-tables-active-p`: non-nil when a pretty-tables mode is on in the current buffer.
- `pretty-tables-define-mode`: a macro that defines an adaptor, a minor mode that draws the tables of another major mode. Both adaptors use it.

### Changed

- Striped rows take the background of `hl-line`, and the other rows keep the buffer's background. Before, the stripes took `lazy-highlight`, a search-match colour on which cell text could be hard to read.

## [0.7.1] - 2026-11-24

### Added

- The command `pretty-tables-redraw` draws the tables of the current buffer again, after measuring the width of its windows. Call it from the hook of a package that changes the width the tables have, such as one that sets window margins, when the tables are not drawn again after that change. It ignores its arguments, so any hook can call it.

### Fixed

- With a package that sets window margins after a window changes, such as one that wraps lines at a column, a table stayed as wide as the window without its margins. The width is now measured again after the other packages have run their window hooks.

## [0.7.0] - 2026-11-24

### Added

- A table is no wider than the window showing it. In a window narrower than the table, the columns are narrowed and their cells wrapped; before, the rows ran past the window's edge. The width leaves out the window's margins, fringes and line numbers, and the table's indentation; when several windows show the buffer, the narrowest counts. The tables are drawn again when a window is resized or split, or starts showing another buffer. A column is still not narrowed below its width cookie, `pretty-tables-min-column-width` or its widest image.
- The value `text-area` of `pretty-tables-width`: tables take the whole width of the window, whatever `fill-column` is. In a buffer no window shows, it means `fill-column`.
- The value `fill-column` of `pretty-tables-width`, now the default. nil, the old default, means the same.

### Changed

- On a graphical display, each cell is measured in the fonts it is drawn with. The columns stay aligned with a variable-pitch font, and with a character the table's font lacks, such as `★`, which Emacs draws in a wider fallback font. With a fixed-pitch font, tables look as before. `pretty-tables-width` and `pretty-tables-min-column-width` still count characters of the table's font (`markdown-ts-table`, `org-table`). With `ascii` borders, the `-` of a separator row can stop up to one `-` short of the next `|` or `+`. On a text terminal, nothing changes.
- An image in a cell takes its own width in pixels; before, its column was rounded up to whole characters. The image spec no longer needs a `:width`.
- Building the drawing of a table takes less time. With the package byte-compiled, the drawing of a table of 55 rows is built in 16 ms on a graphical display, against 58 ms before, and in 3.7 ms on a text terminal, against 32 ms.
- While you type in a row, the rest of its table keeps its drawing; when point leaves the row, the table is drawn again with the widths of the new text. An edit that adds or deletes a line, or changes another row, draws the table at once.
- With `lines` borders, Emacs redisplays a window showing a drawn table in less time: a full redisplay of a window showing a table of 55 rows took 16.7 ms and takes 11.6–13.3 ms. With the mode off, it takes 9–10 ms.
- In a cell, link markup that a configuration hides as a space of a given width, `(space :width N)`, takes that width on a graphical display; before, it took N characters of the table's font.
- The tables are drawn again after `text-scale-adjust`, `buffer-face-mode` or another command that changes the fonts of the buffer, and after the frame's font is set.

### Deprecated

- The value nil of `pretty-tables-width`: use `fill-column`, which means the same. nil still works.

## [0.6.0] - 2026-11-08

### Added

- An image taller than a line of text, such as an equation with a fraction, gets space above and below it, so it no longer touches the rows above and below. The option `pretty-tables-image-spacing` (default 0.5) sets the most space, in units of the height of a line of text, split evenly above and below the image. An image that fits within the letters of a line gets no space, so its row is no taller than a row of text. An image that reaches past them gets `pretty-tables-image-spacing-factor` (default 2) pixels of space per pixel it reaches past them, up to the most. With the factor 0 no image gets space; with t every image that reaches past the letters gets the most; with nil every image gets the most. An image that already has a `:margin` is left as it is.

### Fixed

- After a new version of the package is loaded in a running Emacs, setting an option the new version adds draws the tables again, also in buffers where a mode was already on.

## [0.5.0] - 2026-11-07

### Added

- The option `pretty-tables-borders`: `ascii` (the default) draws the lines between the cells with `|`, `-` and `+`; `lines` draws lines that join from one screen line to the next, in the face `pretty-tables-border`. On a graphical display a vertical line is 1 pixel wide and runs the full height of each screen line. A separator row under a row other than a separator takes no screen line of its own: it is drawn as a line under that row. On a text terminal the lines are box-drawing characters.
- The option `pretty-tables-separator-spacing` (default 0.25): with `lines` borders, the space between a row and the line under it, in units of the height of a line of text.
- In an Org table wider than `pretty-tables-width`, the columns with a width cookie (`<N>`, `<lN>`, `<rN>` or `<cN>`) are narrowed first, and none is narrowed below the width Org shows it at when the column is shrunk: N characters and `org-table-shrunk-column-indicator`. A table that fits keeps the natural widths of its columns. The option `pretty-tables-for-org-width-cookies` (default t) turns this off.
- An image in a cell, such as an equation preview, is drawn in the table when its image spec gives its width in pixels as `:width`. The image takes the fewest columns that hold its `:width` times its `:scale`, and its column is not narrowed below them.
- The options `pretty-tables-width`, `pretty-tables-min-column-width`, `pretty-tables-stripe-rows`, `pretty-tables-row-lines`, `pretty-tables-reveal`, `pretty-tables-borders` and `pretty-tables-separator-spacing` can be set as file-local and directory-local variables without a prompt, when the value has the option's type.
- For an adaptor: the table property `:min-widths` of `pretty-tables-enable`, a list with a width or nil per column. When the table is wider than `pretty-tables-width`, the columns with a width are narrowed first, and none is narrowed below its width.
- For an adaptor: the key `:options` of `pretty-tables-enable`, a list of variables the adaptor's tables depend on. Setting one draws the tables again, as setting `pretty-tables-width` does.

### Changed

- An image in a cell is shown in the drawn row; before, the drawn row showed the text under the image.
- With `read-extended-command-predicate` set to `command-completion-default-include-p`, `M-x` offers `pretty-tables-for-markdown-mode` only in `markdown-ts-mode` buffers and `pretty-tables-for-org-mode` only in `org-mode` buffers, or in buffers of a mode derived from them.

### Fixed

- A cell holding display math shown by latex-to-svg ended the drawn row's screen line in the middle of the cell. The newline that latex-to-svg shows in the spaces around display math is now read as a space.
- An Org table is drawn again when a column is shrunk or expanded, for example with `C-c TAB` (`org-table-toggle-column-width`), and after a command such as `org-table-insert-column` edits a table with shrunk columns. For this, `pretty-tables-for-org` advises `org-table-expand` and `org-table--shrink-columns`.

## [0.4.0] - 2026-10-08

### Added

- For an adaptor: the key `:prefix` of `pretty-tables-enable`, a function called with the start of a row that returns the `line-prefix` and `wrap-prefix` of its drawing, which indent the screen lines of the row after the first.
- For an adaptor of a buffer that shows Org tables outside `org-mode`: `pretty-tables-for-org-table`, which returns the Org table whose rows start at the given positions, and `pretty-tables-for-org-draw-separator`.

### Changed

- In a read-only buffer, the row point is on stays drawn, except during an Isearch. The new option `pretty-tables-reveal` sets when that row is shown as its raw text: `always`, `writable` (the default: in a buffer that is not read-only) or nil (never). During an Isearch it is shown whatever the value.

### Fixed

- In a buffer without font-lock keywords, such as the results buffer of org-semantic, the tables were not drawn again after an option or the theme changed.

## [0.3.0] - 2026-10-04

### Added

- An Org table whose `#+ATTR_ORG` line sets `:pretty-tables` to nil is shown as its text, not drawn.
- For an adaptor: the table property `:raw` of `pretty-tables-enable`. A table whose `:raw` is non-nil is shown as its text, and its rows drawn before are shown as text again.

### Fixed

- `pretty-tables-for-org-mode` hung Emacs when a table extended past the visible part of a narrowed buffer.
- In an indented table, the screen lines of a wrapped row after the first are indented like the first.

## [0.2.0] - 2026-10-02

### Added

- `pretty-tables`, the package that draws the tables. It defines no mode: an adaptor for one markup finds the tables and calls `pretty-tables-enable`. Its options and faces are `pretty-tables-width`, `pretty-tables-min-column-width`, `pretty-tables-stripe-rows`, `pretty-tables-row-lines`, `pretty-tables-row`, `pretty-tables-stripe` and `pretty-tables-row-line`.
- `pretty-tables-for-org-mode`, a buffer-local minor mode for `org-mode` that draws Org tables as `pretty-tables-for-markdown-mode` draws Markdown tables. A column is aligned as `org-table-align` aligns it, the hidden part of a link takes no room, and clicking a link in a drawn row opens it with `org-open-at-point`.
- The face `pretty-tables-header`, added to the cell text of the header rows of a drawn table. It is bold by default.
- The face `pretty-tables-header-row`, added to the whole of each header row, pipes included, for a background. It sets nothing by default.

### Changed

- `markdown-table-view` is now `pretty-tables-for-markdown`, an adaptor that requires `pretty-tables`. The names that changed, for users of 0.1.0:

  | 0.1.0 | Now |
  |---|---|
  | `markdown-table-view-mode` | `pretty-tables-for-markdown-mode` |
  | `markdown-table-view-width` | `pretty-tables-width` |
  | `markdown-table-view-min-column-width` | `pretty-tables-min-column-width` |
  | `markdown-table-view-stripe-rows` | `pretty-tables-stripe-rows` |
  | `markdown-table-view-row-lines` | `pretty-tables-row-lines` |
  | `markdown-table-view-row` | `pretty-tables-row` |
  | `markdown-table-view-stripe` | `pretty-tables-stripe` |
  | `markdown-table-view-row-line` | `pretty-tables-row-line` |
  | `markdown-table-view-row-map` | `pretty-tables-row-map` |
  | `markdown-table-view-mouse-follow` | `pretty-tables-mouse-follow` |

  A configuration that requires `markdown-table-view` or turns on `markdown-table-view-mode` has to use the new names.
- The faces `pretty-tables-row` and `pretty-tables-stripe` inherit no face. A drawn row also gets the table face of its markup, `markdown-ts-table` for Markdown, after them.
- Setting `fill-column` or one of the package's options draws the tables again. Before, a table changed only when it was drawn again for another reason, for example after `M-x font-lock-update`.

### Fixed

- In themes that make `lazy-highlight` bold, the striped rows were bold, the `|` included, because the stripe face took every attribute of `lazy-highlight`. A data row now takes only the background of `hl-line` or `lazy-highlight`, and a background set on the row's face takes their place. The tables are drawn again when a theme is enabled or disabled.
- The background of a data row that wraps over several screen lines ended a few pixels further right on every screen line but the last.
- `markdown-table-view-row` had no background until something loaded `hl-line`, whose background it takes. The package now loads `hl-line`.

## [0.1.0] - 2026-10-01

### Added

- `markdown-table-view-mode`, a buffer-local minor mode for `markdown-ts-mode` that draws pipe tables with aligned columns. Column widths come from the text a reader sees in each cell.
- Tables wider than `markdown-table-view-width` are narrowed column by column, down to `markdown-table-view-min-column-width`, and their cells are word-wrapped. `<br>` in a cell starts a new line.
- The row point is on is shown as its raw text. After a scroll command, a row point moved onto stays drawn until the next command.
- Clicking a character of a drawn row moves point to that character in the buffer, and follows the link there if there is one.
- Links, emphasis and code in table cells are fontified and their markup hidden, as in a paragraph. The mode makes `markdown-ts-mode` parse table cells with the `markdown-inline` grammar, unless `markdown-ts-mode` already does.
- Data rows are drawn with alternating backgrounds: the faces `markdown-table-view-row`, which inherits `hl-line`, and `markdown-table-view-stripe`, which inherits `lazy-highlight`. `markdown-table-view-stripe-rows` turns them off.
- `markdown-table-view-row-lines` draws a line under each data row but the last, with the underline of the face `markdown-table-view-row-line`. It is off by default.

[Unreleased]: https://github.com/alberti42/pretty-tables.el/compare/v0.8.0...main
[0.8.0]: https://github.com/alberti42/pretty-tables.el/releases/tag/v0.8.0
[0.7.1]: https://github.com/alberti42/pretty-tables.el/releases/tag/v0.7.1
[0.7.0]: https://github.com/alberti42/pretty-tables.el/releases/tag/v0.7.0
[0.6.0]: https://github.com/alberti42/pretty-tables.el/releases/tag/v0.6.0
[0.5.0]: https://github.com/alberti42/pretty-tables.el/releases/tag/v0.5.0
[0.4.0]: https://github.com/alberti42/pretty-tables.el/releases/tag/v0.4.0
[0.3.0]: https://github.com/alberti42/pretty-tables.el/releases/tag/v0.3.0
[0.2.0]: https://github.com/alberti42/pretty-tables.el/releases/tag/v0.2.0
[0.1.0]: https://github.com/alberti42/pretty-tables.el/releases/tag/v0.1.0
