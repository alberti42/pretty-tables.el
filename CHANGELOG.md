# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The release workflow publishes the section of a version as the text of its
GitHub release, so before tagging `vX.Y.Z`, move `[Unreleased]` into a
`## [X.Y.Z] - YYYY-MM-DD` heading and set `Version:` in every package file
to `X.Y.Z`.

## [Unreleased]

### Added

- A table whose `#+ATTR_ORG` sets `:pretty-tables` to nil is not drawn
  by `pretty-tables-for-org-mode`.
- The table property `:raw` of `pretty-tables-enable`: a table whose
  `:raw` is non-nil is not drawn, and its rows drawn before are shown as
  text.

### Fixed

- `pretty-tables-for-org-mode` no longer loops forever when a table
  extends past the accessible portion of a narrowed buffer. Tables are
  now drawn with the buffer widened, as font-lock fontifies it.
- In an indented table, the screen lines of a drawn row after the first
  are indented as the first one. Each row string gets a `line-prefix` and
  a `wrap-prefix`: the `line-prefix` of the line the row is on, followed by
  the text from the start of that line to the row.

## [0.2.0] - 2026-10-02

### Added

- `pretty-tables`, the package that draws the tables. It defines no mode:
  an adaptor for one markup finds the tables and calls
  `pretty-tables-enable`. Its options and faces are `pretty-tables-width`,
  `pretty-tables-min-column-width`, `pretty-tables-stripe-rows`,
  `pretty-tables-row-lines`, `pretty-tables-row`, `pretty-tables-stripe`
  and `pretty-tables-row-line`.
- `pretty-tables-for-org-mode`, a buffer-local minor mode for `org-mode`
  that draws Org tables as `pretty-tables-for-markdown-mode` draws Markdown
  tables. A column is aligned as `org-table-align` aligns it, the hidden
  part of a link takes no room, and clicking a link in a drawn row opens it
  with `org-open-at-point`.
- The face `pretty-tables-header`, added to the cell text of the header
  rows of a drawn table. It is bold by default.
- The face `pretty-tables-header-row`, added to the whole of each header
  row, pipes included, for a background. It sets nothing by default.

### Changed

- `markdown-table-view` is now `pretty-tables-for-markdown`, an adaptor that
  requires `pretty-tables`. The names that changed, for users of 0.1.0:

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

  A configuration that requires `markdown-table-view` or turns on
  `markdown-table-view-mode` has to use the new names.
- `pretty-tables-row` and `pretty-tables-stripe` inherit no face. The table
  face of the markup, `markdown-ts-table` for Markdown, is added to the row
  after them.
- Setting `fill-column` or one of the package's options draws the tables
  again. Before, a table changed only when it was drawn again for another
  reason, for example after `M-x font-lock-update`.

### Fixed

- Rows drawn with `markdown-table-view-stripe` were bold in themes that make
  `lazy-highlight` bold, the `|` separators included, because the face
  brought every attribute of `lazy-highlight`. A data row is now drawn with
  its face and only the background of `hl-line` or `lazy-highlight`, read
  when the table is drawn. A background set on the face itself takes their
  place. The tables are drawn again when a theme is enabled or disabled.
- The background of a data row that wraps over several screen lines ended a
  few pixels further right on every screen line but the last. The newlines
  between the screen lines no longer get the row's background.
- `markdown-table-view-row` had no background until something loaded
  `hl-line`, whose background it takes. The package now loads `hl-line`.

## [0.1.0] - 2026-10-01

### Added

- `markdown-table-view-mode`, a buffer-local minor mode for `markdown-ts-mode`
  that draws pipe tables with aligned columns. Column widths come from the
  text a reader sees in each cell.
- Tables wider than `markdown-table-view-width` are narrowed column by column,
  down to `markdown-table-view-min-column-width`, and their cells are
  word-wrapped. `<br>` in a cell starts a new line.
- The row point is on is shown as its raw text. After a scroll command, a row
  point moved onto stays drawn until the next command.
- Clicking a character of a drawn row moves point to that character in the
  buffer, and follows the link there if there is one.
- Table cells are parsed with the `markdown-inline` grammar, so
  `markdown-ts-mode` fontifies their links, emphasis and code and hides their
  markup. The mode adds this rule only when `treesit-range-settings` does not
  already run the grammar on table cells.
- Data rows are drawn with alternating backgrounds: the faces
  `markdown-table-view-row`, which inherits `hl-line`, and
  `markdown-table-view-stripe`, which inherits `lazy-highlight`.
  `markdown-table-view-stripe-rows` turns them off.
- `markdown-table-view-row-lines` draws a line under each data row but the
  last, with the underline of the face `markdown-table-view-row-line`. It is
  off by default.

[Unreleased]: https://github.com/alberti42/pretty-tables.el/compare/v0.2.0...main
[0.2.0]: https://github.com/alberti42/pretty-tables.el/releases/tag/v0.2.0
[0.1.0]: https://github.com/alberti42/pretty-tables.el/releases/tag/v0.1.0
