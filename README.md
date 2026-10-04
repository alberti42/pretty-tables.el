# pretty-tables.el

![Made for GNU Emacs](https://img.shields.io/badge/Made%20for-GNU%20Emacs-7F5AB6?logo=gnuemacs&logoColor=white)
[![melpazoid](https://github.com/alberti42/pretty-tables.el/actions/workflows/melpazoid.yml/badge.svg)](https://github.com/alberti42/pretty-tables.el/actions/workflows/melpazoid.yml)
[![CI](https://github.com/alberti42/pretty-tables.el/actions/workflows/ci.yml/badge.svg)](https://github.com/alberti42/pretty-tables.el/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/github/license/alberti42/pretty-tables.el)](LICENSE)

`pretty-tables` draws the tables of an Emacs buffer with aligned, wrapped columns. It changes how tables are displayed and nothing else: the buffer text is never modified. This repository ships three packages: `pretty-tables`, the drawing, and the two adaptors that use it:

- **pretty-tables-for-markdown**: provides `pretty-tables-for-markdown-mode`, prettifying the tables of `markdown-ts-mode`, which is bundled with Emacs 31.
- **pretty-tables-for-org**: provides `pretty-tables-for-org-mode`, prettifying the tables of `org-mode`.

Each mode is a buffer-local minor mode, and nothing of `markdown-ts-mode` or `org-mode` is replaced or advised.

Column widths come from the text a reader sees in each cell: characters that are invisible (for example link markup hidden by `markdown-ts-hide-markup`, or the hidden part of an Org link) take no room. When the table is wider than `pretty-tables-width`, the widest columns are narrowed and their cells are word-wrapped onto several screen lines. In Markdown, `<br>` in a cell starts a new line.

`pretty-tables-for-markdown` was called `markdown-table-view` up to version 0.1.0. [`CHANGELOG.md`](CHANGELOG.md) lists the names that changed.

## Why

A table is there to give an overview: the reader sees the rows and columns together and compares them. Markdown writes each table row on one line, and once the cells hold links, a row is several times wider than the window. Emacs can show such a row in two ways, and both lose the overview:

- With long lines wrapped, a row fills several screen lines, and nothing shows where one row ends and the next begins.
- With long lines truncated, each row stays on one line and the window shows only its first columns: the reader scrolls sideways to read a row and never sees the whole table.

The modes draw the table no wider than `pretty-tables-width` (by default `fill-column`). Each cell stays in its column and wraps inside it, hidden link markup takes no room, and data rows alternate their backgrounds, so each row can be told from the next. The buffer text is never modified, so the file stays a plain Markdown or Org table for every other tool.

Org writes each table row on one line too. `org-table-align` pads the cells in the buffer text, so a raw Org table is already aligned, but each row is as wide as its widest cells together. The gain in Org is the wrapping, and widths without the hidden part of the links.

The pipe tables of GitHub Flavored Markdown, which `markdown-ts-mode` reads, have no syntax for writing one row over several lines. A proposal to add one, with continuation lines that begin with `┆` or `|~`, is under discussion on the CommonMark forum: [Let table rows wrap over several lines](https://talk.commonmark.org/t/let-table-rows-wrap-over-several-lines/9133). It would fix the problem at its root, in the source text, so that a table could be read with no viewer such as this package. It is mentioned here only as that alternative: this package does not implement it, and draws only tables whose rows are written on one line each. The most likely outcome is that no such syntax is adopted. If one is, the files already written with one row per line remain, and they need a viewer for some time.

## Example

[`examples/field-guide.md`](examples/field-guide.md) holds an invented field guide. Markdown writes each table row on one line, so in a window 72 columns wide, with long lines wrapped, its first two data rows look like this:

```markdown
| Creature | Habitat | Guide entry | Last sighting |
|---|---|---|---|
| Ash dragon | Volcanic caves above the [Cinder
Pass](atlas/regions/cinder-pass.md#caves) | [Ash dragons and their
hoards](bestiary/dragons.md#ash-dragon); [Fire safety for
travellers](handbook/fire.md#dragons) | Spring 1123, by the ranger
[Ilse Morrow](people/rangers.md#ilse-morrow) |
| Marsh kraken | Deep pools of the [Sallow
Fens](atlas/regions/sallow-fens.md#pools) | [The kraken of fresh
water](bestiary/sea-beasts.md#marsh-kraken) | A capsized ferry at
[Reedmouth](atlas/towns/reedmouth.md#harbour), autumn 1122 |
```

With `markdown-ts-hide-markup` on and `fill-column` set to 72, `pretty-tables-for-markdown-mode` draws those rows as:

```text
| Creature       | Habitat         | Guide entry     | Last sighting   |
|----------------|-----------------|-----------------|-----------------|
| Ash dragon     | Volcanic caves  | Ash dragons and | Spring 1123, by |
|                | above the       | their hoards;   | the ranger Ilse |
|                | Cinder Pass     | Fire safety for | Morrow          |
|                |                 | travellers      |                 |
| Marsh kraken   | Deep pools of   | The kraken of   | A capsized      |
|                | the Sallow Fens | fresh water     | ferry at        |
|                |                 |                 | Reedmouth,      |
|                |                 |                 | autumn 1122     |
```

The link labels keep the faces `markdown-ts-mode` gives them, and clicking one follows the link. Data rows are drawn with alternating backgrounds, which a text block cannot show; the screenshot below shows them.

![The table of examples/field-guide.md drawn by pretty-tables-for-markdown-mode](Screenshot-md.png)

The screenshot shows [`examples/field-guide.md`](examples/field-guide.md) in a graphical frame, with the doom-opera-light theme, `fill-column` set to 72, and markup hidden with `C-c C-x C-m` (`markdown-ts-toggle-hide-markup`).

[`examples/field-guide.org`](examples/field-guide.org) holds the same table in Org, aligned by `org-table-align`. The screenshot below shows it drawn by `pretty-tables-for-org-mode`, with the same theme and `fill-column` set to 72.

![The table of examples/field-guide.org drawn by pretty-tables-for-org-mode](Screenshot-org.png)

## Requirements

- Emacs 31.1 or later.
- For `pretty-tables-for-markdown`: the `markdown-ts-mode` of Emacs 31, and the `markdown` and `markdown-inline` tree-sitter grammars, which `markdown-ts-mode` needs too. `M-x treesit-install-language-grammar` installs them.
- For `pretty-tables-for-org`: the Org bundled with Emacs.

All of these are part of Emacs or fetched by it; the packages need nothing else.

## Installation

The packages are not published yet. Clone the repository and add it to `load-path`:

```elisp
(use-package pretty-tables-for-markdown
  :load-path "~/path/to/pretty-tables"
  :hook (markdown-ts-mode-hook . pretty-tables-for-markdown-mode))

(use-package pretty-tables-for-org
  :load-path "~/path/to/pretty-tables"
  :hook (org-mode-hook . pretty-tables-for-org-mode))
```

With straight.el, from a local clone, one recipe per package, `pretty-tables` first:

```elisp
(use-package pretty-tables
  :straight (pretty-tables
             :type git
             :local-repo "~/path/to/pretty-tables"
             :files ("pretty-tables.el")))

(use-package pretty-tables-for-markdown
  :straight (pretty-tables-for-markdown
             :type git
             :local-repo "~/path/to/pretty-tables"
             :files ("pretty-tables-for-markdown.el"))
  :hook (markdown-ts-mode-hook . pretty-tables-for-markdown-mode))

(use-package pretty-tables-for-org
  :straight (pretty-tables-for-org
             :type git
             :local-repo "~/path/to/pretty-tables"
             :files ("pretty-tables-for-org.el"))
  :hook (org-mode-hook . pretty-tables-for-org-mode))
```

## Usage

`M-x pretty-tables-for-markdown-mode` or `M-x pretty-tables-for-org-mode` turns the mode on in the current buffer; the hooks above turn it on in every `markdown-ts-mode` or `org-mode` buffer.

- The row point is on is shown as its raw text, so it can be edited and its links followed.
- After a scroll command, a row point moved onto stays drawn until the next command. A scroll command is one with a non-nil `scroll-command` property: `mwheel-scroll`, `pixel-scroll-precision`, `scroll-up-command`, `scroll-down-command` and the other scroll commands of Emacs.
- Clicking a character of a drawn row moves point to that character in the buffer, and follows the link there if there is one. In Markdown the link is followed with the command RET runs there; in Org it is opened with `org-open-at-point`.
- In Markdown, `markdown-ts-toggle-hide-markup` (`C-c C-x C-m`) shows and hides the markup; the tables are drawn again with the new widths.

## Options

The options and faces belong to `pretty-tables`, so they apply to both modes.

|Option                          |Default|Meaning                                                                      |
|--------------------------------|-------|-----------------------------------------------------------------------------|
|`pretty-tables-width`           |`nil`  |Maximum width, in columns, of a displayed table. When nil, use `fill-column`.|
|`pretty-tables-min-column-width`|`8`    |Width below which a column is not narrowed to fit the table width.           |
|`pretty-tables-stripe-rows`     |`t`    |Non-nil means data rows are drawn with alternating backgrounds.              |
|`pretty-tables-row-lines`       |`nil`  |Non-nil means a line is drawn under each data row but the last.              |

Setting `fill-column` (`C-x f`) or one of these options draws the tables again in the buffers where a mode is on.

The first, third, ... data rows are drawn with the face `pretty-tables-row` and the background of `hl-line`; the others with `pretty-tables-stripe` and the background of `lazy-highlight`, the face agent-shell's tables use. Only the background is taken from `hl-line` and `lazy-highlight`, so a theme that makes `lazy-highlight` bold does not make the rows bold. The theme sets both backgrounds, for a light theme and a dark one alike, and the tables are drawn again when a theme is enabled. A background set on `pretty-tables-row` or `pretty-tables-stripe` takes the place of the theme's. The line is the underline of the face `pretty-tables-row-line`, so it takes no screen line of its own; in a terminal it is an ordinary underline. Both faces are added after the faces of the cell text, so a link or a code span keeps its own colours. The table face of the markup, `markdown-ts-table` or `org-table`, is added after them.

The cell text of header rows is drawn with the face `pretty-tables-header`, which inherits `bold`; it too is added after the faces of the cell text. To draw the header without bold, remove the inheritance:

```elisp
(set-face-attribute 'pretty-tables-header nil :inherit 'unspecified)
```

The face `pretty-tables-header-row` covers the whole header row, pipes included, and sets nothing by default: a background set on it fills the row.

## Markdown: links and emphasis in table cells

`markdown-ts-mode` runs the `markdown-inline` grammar only on `inline` nodes, and a table cell is not one, so links, emphasis and code in a cell are not fontified and their markup is not hidden. While the mode is on, it runs the grammar on table cells too, and `markdown-ts-mode` fontifies them as it fontifies a paragraph. The mode adds this rule only when `treesit-range-settings` does not already run the grammar on table cells, so once `markdown-ts-mode` parses table cells itself, the mode adds nothing. Turning the mode off removes the rule.

## Org tables

- A column is aligned as `org-table-align` aligns it: by the first `<l>`, `<r>` or `<c>` cookie in it, or else to the right when the share of its non-empty cells that match `org-table-number-regexp` is at least `org-table-number-fraction`. A row of cookies is drawn as a data row.
- The rows above the first separator are the header when a data row follows that separator. A separator can stand between any two rows; the data rows on both sides alternate their backgrounds as if it were not there.
- Columns that `org-table-shrink` narrows are read as they are displayed.
- Text hidden by folding is read as if it were shown, so a table drawn while its heading was folded has the right widths when the heading is unfolded.
- Table.el tables, `#+TBLFM` lines, and lines starting with `|` in a source block are not drawn.
- A table whose `#+ATTR_ORG` sets `:pretty-tables` to nil is not drawn:

  ```org
  #+ATTR_ORG: :pretty-tables nil
  | a | b |
  ```
- In a narrowed buffer with `font-lock-dont-widen` set, a table that extends past the accessible portion is not drawn.
- The row point is on is shown raw, and `org-table-align` keeps that row aligned with the other raw rows, not with the drawn ones.

## Hiding link markup with spaces

A configuration that hides link markup with `(space :width N)`, to keep raw tables aligned, makes that markup count as N spaces here. Such a configuration should use `invisible` while a mode is on.

## Writing an adaptor

An adaptor for another markup calls `pretty-tables-enable` from its minor mode, with a function that returns, for a region of the buffer, each table that overlaps it: the bounds of the table and of each row, the kind of each row (header, separator or data), the bounds of each cell, and an alignment per column. The docstring of `pretty-tables-enable` describes the data and the other keys. `pretty-tables-disable` turns the drawing off.

## Tests

```sh
make test
```

The tests run in `emacs --batch --quick`. The tests of `pretty-tables-for-markdown` need the `markdown` and `markdown-inline` grammars and are skipped without them.

The CI workflow installs both grammars and runs byte-compilation, checkdoc and the tests on Emacs 31.1 and on Emacs master. The melpazoid workflow runs the checks MELPA's reviewers run, once per package.

## Versions and changes

The three packages share one version number. Version numbers follow [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html). [`CHANGELOG.md`](CHANGELOG.md) follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/), and the text of each GitHub release is its version's section there.

## Verifying a release

Each GitHub release carries `pretty-tables-X.Y.Z.tar.gz`, built from the tag with `git archive`, the files `pretty-tables.el`, `pretty-tables-for-markdown.el` and `pretty-tables-for-org.el`, and `SHA256SUMS`. The release workflow attests the provenance of all but `SHA256SUMS`: a signed statement that the workflow produced these bytes from the tag's commit. To check a downloaded file:

```sh
gh attestation verify pretty-tables-X.Y.Z.tar.gz --repo alberti42/pretty-tables.el
```

Release 0.1.0 was published as `markdown-table-view`, before the repository was renamed, and its attestations name the old repository. Its files verify with `--repo alberti42/markdown-table-view.el` and fail with `--repo alberti42/pretty-tables.el`:

```sh
gh attestation verify markdown-table-view-0.1.0.tar.gz --repo alberti42/markdown-table-view.el
```

`SHA256SUMS` only shows that a download is not corrupted, because it is published beside the files it describes. The attestation is kept in GitHub's attestation store, so replacing a release asset does not replace its attestation.

## License

GPL-3.0-or-later. Copyright (C) 2026 Andrea Alberti.
