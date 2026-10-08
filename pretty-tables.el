;;; pretty-tables.el --- Aligned, wrapped display of tables -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-5-5
;; URL: https://github.com/alberti42/pretty-tables.el
;; Version: 0.4.0
;; Package-Requires: ((emacs "31.1"))
;; Keywords: text, wp, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; `pretty-tables' draws the tables of a buffer with aligned columns
;; and changes nothing else.  The buffer text is never modified.  It
;; defines no mode: an adaptor for one markup finds the tables and
;; calls `pretty-tables-enable'.  `pretty-tables-for-markdown' is the
;; adaptor for `markdown-ts-mode', `pretty-tables-for-org' the one for
;; `org-mode'.
;;
;; Each table row is covered by an overlay whose `display' property is a
;; string drawing the row with aligned columns.  Column widths come from
;; the text a reader sees in each cell: characters that are invisible
;; (for example hidden link markup) take no room.  When the table is
;; wider than `pretty-tables-width', the widest columns are narrowed and
;; their cells are word-wrapped onto several screen lines.  Data rows
;; are drawn with alternating backgrounds (`pretty-tables-stripe-rows'),
;; and a line can be drawn under each data row
;; (`pretty-tables-row-lines').  The text of header rows is drawn with
;; the face `pretty-tables-header', bold by default.
;;
;; The row point is on is shown as its raw text, so it can be edited and
;; its links followed.  In a read-only buffer it stays drawn, except
;; during an Isearch; `pretty-tables-reveal' changes that.  After a
;; scroll command, a row point moved onto
;; stays drawn until the next command.  Clicking a character of a drawn
;; row moves point to that character in the buffer, and follows the link
;; there if there is one.

;;; Code:

(require 'jit-lock)
(require 'subr-x)
;; Defines the `hl-line' face, whose background `pretty-tables-row' takes.
(require 'hl-line)

(defgroup pretty-tables nil
  "Aligned, wrapped display of tables."
  :group 'text
  :prefix "pretty-tables-")

(defcustom pretty-tables-width nil
  "Maximum width, in columns, of a displayed table.
When nil, use `fill-column'."
  :type '(choice (const :tag "fill-column" nil) natnum))

(defcustom pretty-tables-min-column-width 8
  "Width below which a column is not narrowed to fit the table width."
  :type 'natnum)

(defcustom pretty-tables-stripe-rows t
  "Non-nil means data rows are drawn with alternating backgrounds.
The first, third, ... data rows get the face `pretty-tables-row',
the others `pretty-tables-stripe'."
  :type 'boolean)

(defcustom pretty-tables-row-lines nil
  "Non-nil means a line is drawn under each data row but the last.
The line is the underline of the face `pretty-tables-row-line',
so it takes no screen line of its own."
  :type 'boolean)

(defcustom pretty-tables-reveal 'writable
  "When the row point is on is shown as its raw text.
`always' means in every buffer, `writable' in a buffer that is not
read-only, and nil never.  During an Isearch the row point is on is
shown as its raw text whatever the value, so a match in it can be
seen."
  :type '(choice (const :tag "In every buffer" always)
                 (const :tag "In a buffer that is not read-only" writable)
                 (const :tag "Never" nil)))

(defface pretty-tables-row
  '((t))
  "Face of the first, third, ... data rows of a drawn table.
The row is drawn with this face and the background of `hl-line', so
the theme sets the colour.  A background set on this face itself
takes the place of the one of `hl-line'.  See
`pretty-tables-stripe-rows'.")

(defface pretty-tables-stripe
  '((t))
  "Face of the second, fourth, ... data rows of a drawn table.
The row is drawn with this face and the background of
`lazy-highlight', so the theme sets the colour.  A background set on
this face itself takes the place of the one of `lazy-highlight'.  See
`pretty-tables-stripe-rows'.")

(defface pretty-tables-row-line
  '((((class color) (min-colors 88) (background light))
     :underline (:color "gray75" :position t))
    (((class color) (min-colors 88) (background dark))
     :underline (:color "gray40" :position t))
    (t :underline t))
  "Face added to the last screen line of each data row but the last.
See `pretty-tables-row-lines'.")

(defface pretty-tables-header
  '((t :inherit bold))
  "Face added to the cell text of the header rows of a drawn table.
It is added after the faces of the cell text, so a link in a header
keeps its colours.  The pipes and the padding do not get it; see
`pretty-tables-header-row'.")

(defface pretty-tables-header-row
  '((t))
  "Face added to the whole of each header row of a drawn table.
It covers the pipes and the padding too, so a background set on it
fills the row.  It sets nothing by default.")

(defvar-local pretty-tables--adaptor nil
  "The adaptor `pretty-tables-enable' was called with, or nil.
A plist; non-nil means the tables of the buffer are drawn.")

(defvar-local pretty-tables--revealed nil
  "Row overlay currently shown as raw text, or nil.")

(defvar pretty-tables--rendering nil
  "Non-nil while a table is being drawn.
Stops the nested `jit-lock-fontify-now' from running the drawing
function again.")

(defvar-keymap pretty-tables-row-map
  :doc "Keymap on the strings that draw table rows."
  "<down-mouse-1>" #'ignore
  "<mouse-1>" #'pretty-tables-mouse-follow
  "<down-mouse-2>" #'ignore
  "<mouse-2>" #'pretty-tables-mouse-follow)

;;; Reading the buffer

(defun pretty-tables--visible-string (beg end)
  "Return the text between BEG and END as it is displayed.
Invisible characters are dropped and a `display' string replaces the
text it covers.  Whether a character is invisible is decided by the
adaptor's `:invisible' function, by default `invisible-p'.  Each
character carries the buffer position it came from in the
`pretty-tables-pos' property."
  (let ((invisible (or (plist-get pretty-tables--adaptor :invisible)
                       #'invisible-p))
        (pos beg) parts)
    (while (< pos end)
      ;; An overlay hides the `invisible' text properties under it from
      ;; `next-single-char-property-change', and the `:invisible'
      ;; function may read them.
      (let ((next (min (next-single-char-property-change pos 'invisible nil end)
                       (next-single-property-change pos 'invisible nil end)
                       (next-single-char-property-change pos 'display nil end)))
            (display (get-char-property pos 'display)))
        (cond
         ((funcall invisible pos))
         ((stringp display)
          (push (propertize (copy-sequence display) 'pretty-tables-pos pos)
                parts))
         ((and (eq (car-safe display) 'space)
               (natnump (plist-get (cdr display) :width)))
          (push (propertize (make-string (plist-get (cdr display) :width) ?\s)
                            'pretty-tables-pos pos)
                parts))
         (t
          (let ((s (buffer-substring pos next)))
            (dotimes (i (length s))
              (put-text-property i (1+ i) 'pretty-tables-pos (+ pos i) s))
            (push s parts))))
        (setq pos next)))
    (apply #'concat (nreverse parts))))

(defun pretty-tables--cell-paragraphs (beg end)
  "Return the displayed text of the cell from BEG to END.
The value is a list of strings, one per piece separated by the
adaptor's `:line-break' regexp, or a list of one string when the
adaptor has none."
  (let ((text (pretty-tables--visible-string beg end))
        (line-break (plist-get pretty-tables--adaptor :line-break))
        (case-fold-search t))
    (mapcar #'string-trim
            (if line-break (split-string text line-break) (list text)))))

;;; Layout

(defun pretty-tables--column-widths (natural target)
  "Narrow the NATURAL column widths until the table fits TARGET columns.
A table with N columns of widths W takes sum(W) + 3N + 1 columns.  The
widest column is narrowed by one until the table fits or every column
is at `pretty-tables-min-column-width'."
  (let* ((widths (copy-sequence natural))
         (n (length widths))
         (floor pretty-tables-min-column-width))
    (while (and (> (+ (apply #'+ widths) (* 3 n) 1) target)
                (seq-some (lambda (w) (> w floor)) widths))
      (let ((i (seq-position widths (apply #'max widths))))
        (setf (nth i widths) (1- (nth i widths)))))
    widths))

(defun pretty-tables--break-word (word width)
  "Split WORD into pieces no wider than WIDTH."
  (let (pieces)
    (while (> (string-width word) width)
      (let ((head (truncate-string-to-width word width)))
        (when (string-empty-p head)
          (setq head (substring word 0 1)))
        (push head pieces)
        (setq word (substring word (length head)))))
    (nreverse (cons word pieces))))

(defun pretty-tables--wrap (paragraph width)
  "Word-wrap PARAGRAPH into lines no wider than WIDTH.
Lines are substrings of PARAGRAPH, so they keep its text properties."
  (let ((pos 0) (line-beg nil) (line-end nil) lines)
    (while (string-match "[^ \t]+" paragraph pos)
      (let ((wbeg (match-beginning 0))
            (wend (match-end 0)))
        (cond
         ((and line-beg
               (<= (string-width (substring paragraph line-beg wend)) width))
          (setq line-end wend))
         (t
          (when line-beg
            (push (substring paragraph line-beg line-end) lines))
          (let ((word (substring paragraph wbeg wend)))
            (if (<= (string-width word) width)
                (setq line-beg wbeg line-end wend)
              (let ((pieces (pretty-tables--break-word word width)))
                (setq lines (append (reverse (butlast pieces)) lines))
                (setq line-end wend
                      line-beg (- wend (length (car (last pieces)))))))))))
      (setq pos (match-end 0)))
    (when line-beg
      (push (substring paragraph line-beg line-end) lines))
    (or (nreverse lines) (list ""))))

(defun pretty-tables--pad (text width alignment)
  "Pad TEXT with spaces to WIDTH, placing it according to ALIGNMENT."
  (let* ((gap (max 0 (- width (string-width text))))
         (left (pcase alignment
                 ('right gap)
                 ('center (/ gap 2))
                 (_ 0))))
    (concat (make-string left ?\s) text (make-string (- gap left) ?\s))))

(defun pretty-tables--draw-row (cells widths alignments)
  "Return the string drawing a row whose cells are CELLS.
CELLS is a list of cells, each a list of paragraphs.  WIDTHS and
ALIGNMENTS give each column's width and alignment."
  (let* ((wrapped (seq-map-indexed
                   (lambda (width i)
                     (mapcan (lambda (p) (pretty-tables--wrap p width))
                             (nth i cells)))
                   widths))
         (height (apply #'max 1 (mapcar #'length wrapped)))
         lines)
    (dotimes (k height)
      (push (concat "|"
                    (mapconcat
                     (lambda (i)
                       (concat " "
                               (pretty-tables--pad
                                (or (nth k (nth i wrapped)) "")
                                (nth i widths) (nth i alignments))
                               " |"))
                     (number-sequence 0 (1- (length widths)))))
            lines))
    (mapconcat #'identity (nreverse lines) "\n")))

;;; Drawing a table

(defun pretty-tables--delete-overlays (beg end)
  "Delete the row overlays that overlap BEG to END."
  (dolist (ov (overlays-in beg end))
    (when (overlay-get ov 'pretty-tables)
      (delete-overlay ov))))

(defun pretty-tables--row-face (stripe)
  "Return the face of a data row: the stripe face if STRIPE is non-nil.
The value is `(:inherit FACE :background COLOUR)', FACE being
`pretty-tables-stripe' or `pretty-tables-row'.  COLOUR is the
background set on FACE itself, or else the resolved background of
`lazy-highlight' or `hl-line'.  Only the background of those two faces
is taken: some themes make `lazy-highlight' bold, for example.  On a
terminal without colours COLOUR is nil, and the value is FACE."
  (let* ((face (if stripe 'pretty-tables-stripe 'pretty-tables-row))
         (own (face-attribute face :background nil nil))
         (colour (if (stringp own)
                     own
                   (face-background (if stripe 'lazy-highlight 'hl-line) nil t))))
    (if colour
        (list :inherit face :background colour)
      face)))

(defun pretty-tables--add-line-face (string face)
  "Append FACE to each screen line of STRING, a drawn row.
The newlines between the screen lines get no face: Emacs paints a
newline with its face, which would widen every screen line but the
last, whose newline is the buffer's."
  (let ((start 0))
    (dolist (line (split-string string "\n"))
      (add-face-text-property start (+ start (length line)) face t string)
      (setq start (+ start (length line) 1)))))

(defun pretty-tables--decorate-row (string index last)
  "Add the row face and the row-line face to STRING, a data row.
INDEX counts the data rows of the table from 0.  LAST is non-nil for
the last data row, which gets no row line.  The faces are appended, so
the faces of the cell text take precedence.
The row face is `pretty-tables-row' or `pretty-tables-stripe' with a
background, see `pretty-tables--row-face'.  It is added with
`pretty-tables--add-line-face'."
  (when pretty-tables-stripe-rows
    (pretty-tables--add-line-face
     string (pretty-tables--row-face (= (% index 2) 1))))
  (when (and pretty-tables-row-lines (not last))
    ;; The last screen line of the row: `.' does not match a newline.
    (string-match ".*\\'" string)
    (add-face-text-property (match-beginning 0) (length string)
                            'pretty-tables-row-line t string)))

(defun pretty-tables--prefix (pos)
  "Return the prefix of the screen lines of a row drawn from POS.
It is the `line-prefix' of the line POS is on, followed by the text
from the start of that line to POS, such as the indentation of the
table.  The first screen line of the row has both from the buffer;
the prefix gives the same indentation to the other screen lines.
A `line-prefix' that is not a string is a display specification, and
is put in the prefix as the `display' of a space."
  (let* ((bol (save-excursion (goto-char pos) (line-beginning-position)))
         (line (or (get-char-property bol 'line-prefix) line-prefix)))
    (concat (cond ((null line) "")
                  ((stringp line) line)
                  (t (propertize " " 'display line)))
            (buffer-substring bol pos))))

(defun pretty-tables--render-table (table revealed)
  "Cover each row of TABLE with an overlay that draws it aligned.
TABLE is a table as `pretty-tables-enable' describes it.  The row
starting at REVEALED is left as raw text."
  ;; The old overlays go first: the cells are read with
  ;; `get-char-property', which would return their `display' strings.
  (pretty-tables--delete-overlays (plist-get table :beg) (plist-get table :end))
  (let* ((rows (plist-get table :rows))
         (data (mapcar (lambda (row)
                         (unless (eq (plist-get row :kind) 'separator)
                           (mapcar (lambda (cell)
                                     (pretty-tables--cell-paragraphs
                                      (car cell) (cdr cell)))
                                   (plist-get row :cells))))
                       rows))
         (ncols (apply #'max 1 (mapcar #'length data)))
         (natural (mapcar (lambda (i)
                            (apply #'max 1
                                   (mapcar (lambda (cells)
                                             (apply #'max 0
                                                    (mapcar #'string-width
                                                            (nth i cells))))
                                           data)))
                          (number-sequence 0 (1- ncols))))
         (widths (pretty-tables--column-widths
                  natural (or pretty-tables-width fill-column)))
         (alignments (let ((a (plist-get table :alignments)))
                       (mapcar (lambda (i) (or (nth i a) 'left))
                               (number-sequence 0 (1- ncols)))))
         (ndata (seq-count (lambda (row) (eq (plist-get row :kind) 'data))
                           rows))
         (separator (plist-get pretty-tables--adaptor :separator))
         (table-face (plist-get pretty-tables--adaptor :face))
         (index -1))
    (seq-mapn
     (lambda (row cells)
       (let* ((beg (plist-get row :beg))
              (kind (plist-get row :kind))
              (string (progn
                        (when (eq kind 'header)
                          (dolist (paragraph (apply #'append cells))
                            (add-face-text-property
                             0 (length paragraph) 'pretty-tables-header t
                             paragraph)))
                        (if (eq kind 'separator)
                            (funcall separator widths alignments)
                          (pretty-tables--draw-row cells widths alignments))))
              (ov (make-overlay beg (plist-get row :end) nil t nil)))
         (pcase kind
           ('data
            (setq index (1+ index))
            (pretty-tables--decorate-row string index (= index (1- ndata))))
           ('header
            (pretty-tables--add-line-face string 'pretty-tables-header-row)))
         (when table-face
           (add-face-text-property 0 (length string) table-face t string))
         (let ((prefix (funcall (or (plist-get pretty-tables--adaptor :prefix)
                                    #'pretty-tables--prefix)
                                beg)))
           (add-text-properties 0 (length string)
                                (list 'keymap pretty-tables-row-map
                                      'pointer 'arrow
                                      'line-prefix prefix
                                      'wrap-prefix prefix)
                                string))
         (overlay-put ov 'pretty-tables t)
         (overlay-put ov 'pretty-tables-string string)
         (overlay-put ov 'evaporate t)
         (if (eql beg revealed)
             (setq pretty-tables--revealed ov)
           (overlay-put ov 'display string))))
     rows data)))

(defun pretty-tables--fontify (beg end)
  "Draw every table that overlaps BEG to END.
Runs from `jit-lock-functions' after font-lock, since the drawing reads
the faces and invisibility font-lock puts on the cells.  A table is
drawn whole, so the parts of it outside BEG to END are fontified
first.  The buffer is widened unless `font-lock-dont-widen' is
non-nil, as font-lock does, so a table is drawn whole in a narrowed
buffer too.
A table whose `:raw' is non-nil is not drawn, and its row overlays
are deleted.  The row `pretty-tables--reveal' revealed stays raw.
Point is not used: `jit-lock-fontify-now' moves it to the start of the
chunk."
  (unless pretty-tables--rendering
    (save-restriction
      (unless font-lock-dont-widen (widen))
      (let ((pretty-tables--rendering t)
            (revealed (and pretty-tables--revealed
                           (overlay-start pretty-tables--revealed))))
        (pretty-tables--delete-overlays beg end)
        (dolist (table (funcall (plist-get pretty-tables--adaptor :tables)
                                beg end))
          (if (plist-get table :raw)
              (pretty-tables--delete-overlays (plist-get table :beg)
                                              (plist-get table :end))
            (jit-lock-fontify-now (plist-get table :beg) (plist-get table :end))
            (pretty-tables--render-table table revealed)))))))

;;; Point and mouse

(defun pretty-tables--row-overlay-at-point ()
  "Return the row overlay on the line of point, or nil."
  (seq-find (lambda (ov) (overlay-get ov 'pretty-tables))
            (overlays-in (pos-bol) (pos-eol))))

(defun pretty-tables--reveal ()
  "Show the row point is on as raw text, and draw the one point left.
The row is shown as raw text when `pretty-tables-reveal' says so, or
during an Isearch.  After a command with a non-nil `scroll-command'
property, a row point moved onto stays drawn."
  (let ((ov (pretty-tables--row-overlay-at-point))
        (old pretty-tables--revealed))
    (unless (or isearch-mode
                (pcase pretty-tables-reveal
                  ('always t)
                  ('writable (not buffer-read-only))))
      (setq ov nil))
    (when (and (symbolp this-command) (get this-command 'scroll-command)
               (not (eq ov old)))
      (setq ov nil))
    (unless (eq ov old)
      (when (and old (overlay-buffer old))
        (overlay-put old 'display (overlay-get old 'pretty-tables-string)))
      (when ov
        (overlay-put ov 'display nil))
      (setq pretty-tables--revealed ov))))

(defun pretty-tables--follow-link ()
  "Run the command RET runs at point.
The default `:follow' function of an adaptor."
  (let ((command (key-binding (kbd "RET") t nil (point))))
    (when (commandp command)
      (call-interactively command))))

(defun pretty-tables-mouse-follow (event)
  "Move point to the buffer text under the drawn row clicked in EVENT.
When that text has a `mouse-face', it is a link, and the adaptor's
`:follow' function follows it; by default that runs the command RET
runs there."
  (interactive "e")
  (let* ((posn (event-start event))
         (string (posn-string posn))
         (pos (or (and string
                       (get-text-property (cdr string) 'pretty-tables-pos
                                          (car string)))
                  (posn-point posn))))
    (select-window (posn-window posn))
    (goto-char pos)
    (pretty-tables--reveal)
    (when (get-char-property pos 'mouse-face)
      (funcall (or (plist-get pretty-tables--adaptor :follow)
                   #'pretty-tables--follow-link)))))

;;; Options

(defconst pretty-tables--options
  '(fill-column
    pretty-tables-width
    pretty-tables-min-column-width
    pretty-tables-stripe-rows
    pretty-tables-row-lines)
  "Variables the drawing of a table depends on.
Setting one draws the tables again; see
`pretty-tables--option-changed'.")

(defun pretty-tables--option-changed (_symbol _value operation where)
  "Draw the tables again after one of `pretty-tables--options' is set.
A variable watcher: OPERATION is how the variable changed, and WHERE
is the buffer whose local value changed, or nil for the default value.
The tables are drawn again in WHERE, or in every buffer when the
default value changed, if an adaptor is on there.  A `let' binding
does not draw them again.  The watcher runs before the value changes;
`jit-lock-refontify' only marks the text, and jit-lock draws the tables
at the next redisplay, when the new value is in place."
  (when (memq operation '(set makunbound))
    (dolist (buffer (if (buffer-live-p where) (list where) (buffer-list)))
      (with-current-buffer buffer
        (when pretty-tables--adaptor
          (jit-lock-refontify))))))

(defun pretty-tables--theme-changed (_theme)
  "Draw the tables again after a theme is enabled or disabled.
The drawn rows hold the backgrounds `pretty-tables--row-face' read
from the theme, so a new theme shows only once the tables are drawn
again.  Runs from `enable-theme-functions' and
`disable-theme-functions'."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when pretty-tables--adaptor
        (jit-lock-refontify)))))

;;; Interface

(defun pretty-tables-enable (&rest adaptor)
  "Draw the tables of the current buffer with aligned, wrapped columns.
An adaptor calls this from its minor mode.  ADAPTOR is a plist:

`:tables'     A function called with BEG and END that returns each
              table overlapping BEG to END, as described below.
              Required.
`:separator'  A function called with the column WIDTHS and
              ALIGNMENTS that returns a new string drawing a
              separator row.  Required.
`:line-break' A regexp, matched ignoring case, that splits a cell
              into lines, or nil.
`:face'       A face appended to every drawn row, after the cell's
              own faces, the row faces and the header faces, or nil.
`:invisible'  A function called with a buffer position that returns
              non-nil when the character there takes no room.  The
              default is `invisible-p'.
`:follow'     A function called with no arguments, point on a link
              of a clicked row, that follows the link.  The default
              runs the command RET runs there.
`:prefix'     A function called with the start of a row that
              returns the `line-prefix' and `wrap-prefix' of the
              string drawing it, which start its screen lines after
              the first.  The default is the `line-prefix' of the
              row's line followed by the text from the start of
              that line to the row.

A table is a plist with these properties:

`:beg', `:end'  The bounds of the table.
`:rows'         The rows, in buffer order.
`:alignments'   A list with an alignment per column: `left', `right'
                or `center'.  A column with none is `left'.
`:raw'          Non-nil to show the table as its text: it is not
                drawn, and its rows drawn before are shown as text.
                `:rows' and `:alignments' are then not used.

A row is a plist with these properties:

`:kind'         `header', `separator' or `data'.  Only data rows get
                the row faces, and only header rows the faces
                `pretty-tables-header' and `pretty-tables-header-row'.
`:beg', `:end'  The bounds of the text the drawn row replaces, on one
                line.
`:cells'        A list of (BEG . END), the bounds of each cell's text
                without the column separators.  Ignored for a
                separator row.

The drawing reads the faces and invisibility font-lock puts on the
cells, so it runs from `jit-lock-functions' after font-lock."
  (setq pretty-tables--adaptor adaptor)
  (jit-lock-register #'pretty-tables--fontify)
  ;; `jit-lock-register' puts the function first; it has to run after
  ;; font-lock, whose faces and invisibility it reads.
  (remove-hook 'jit-lock-functions #'pretty-tables--fontify t)
  (add-hook 'jit-lock-functions #'pretty-tables--fontify 90 t)
  (add-hook 'post-command-hook #'pretty-tables--reveal nil t)
  ;; `add-variable-watcher' adds a function only once.
  (dolist (option pretty-tables--options)
    (add-variable-watcher option #'pretty-tables--option-changed))
  (add-hook 'enable-theme-functions #'pretty-tables--theme-changed)
  (add-hook 'disable-theme-functions #'pretty-tables--theme-changed)
  ;; Not `font-lock-flush', which does nothing in a buffer without
  ;; font-lock keywords; in a buffer with them, it calls this.
  (jit-lock-refontify))

(defun pretty-tables-disable ()
  "Stop drawing the tables of the current buffer, and show their text."
  (jit-lock-unregister #'pretty-tables--fontify)
  (remove-hook 'post-command-hook #'pretty-tables--reveal t)
  (pretty-tables--delete-overlays (point-min) (point-max))
  (setq pretty-tables--revealed nil
        pretty-tables--adaptor nil)
  (font-lock-flush))

(provide 'pretty-tables)
;;; pretty-tables.el ends here
