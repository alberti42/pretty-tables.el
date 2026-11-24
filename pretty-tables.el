;;; pretty-tables.el --- Aligned, wrapped display of tables -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-5-5
;; URL: https://github.com/alberti42/pretty-tables.el
;; Version: 0.6.0
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
;; Each table row is covered by an overlay whose `before-string' draws
;; the row with aligned columns, and whose `display' of "" hides the
;; row's text.  Column widths come from
;; the text a reader sees in each cell: characters that are invisible
;; (for example hidden link markup) take no room.  On a graphical
;; display the cells are measured in pixels, in the faces they are
;; drawn with, so a variable-pitch font, or a character drawn in a
;; fallback font, keeps the columns aligned; on a text terminal they
;; are counted in columns.  When the table is
;; wider than `pretty-tables-width', the widest columns are narrowed and
;; their cells are word-wrapped onto several screen lines.  Data rows
;; are drawn with alternating backgrounds (`pretty-tables-stripe-rows'),
;; and a line can be drawn under each data row
;; (`pretty-tables-row-lines').  The text of header rows is drawn with
;; the face `pretty-tables-header', bold by default.  The lines between
;; the cells are `|' and `-' characters, or, with `pretty-tables-borders'
;; set to `lines', lines that join from one screen line to the next.
;;
;; The row point is on is shown as its raw text, so it can be edited and
;; its links followed.  In a read-only buffer it stays drawn, except
;; during an Isearch; `pretty-tables-reveal' changes that.  After a
;; scroll command, a row point moved onto
;; stays drawn until the next command.  Clicking a character of a drawn
;; row moves point to that character in the buffer, and follows the link
;; there if there is one.

;;; Code:

(require 'image)
(require 'jit-lock)
(require 'subr-x)
;; Defines the `hl-line' face, whose background `pretty-tables-row' takes.
(require 'hl-line)

(defgroup pretty-tables nil
  "Aligned, wrapped display of tables."
  :group 'text
  :prefix "pretty-tables-")

(defcustom pretty-tables-width 'fill-column
  "Maximum width, in columns, of a displayed table.
`fill-column' means the value of `fill-column'; a number means that
many columns; `text-area' means no width of its own.  nil, the value
versions before 0.7.0 used for `fill-column', means `fill-column' too;
it is deprecated.
In every case a table is no wider than the text area of the narrowest
window showing the buffer: the window without its margins and fringes,
less the line numbers, less the column of the continuation glyph when
the window has no fringes, and less the table's indentation and
`line-prefix'.  When that width changes, as when a window is resized
or split, the tables are drawn again.  In a buffer no window shows,
`text-area' means `fill-column'.  On a graphical display a column is
the width of the font of the adaptor's table face, such as
`org-table'.
The width bounds how far columns are narrowed; no column is narrowed
below its floor (see `pretty-tables--column-widths'), so a table whose
columns are at their floors can be wider than this width, and a table
narrower than it is not widened."
  :type '(choice (const :tag "fill-column" fill-column)
                 (const :tag "The text area" text-area)
                 natnum
                 (const :tag "fill-column (nil, deprecated)" nil))
  :safe (lambda (value) (or (memq value '(nil fill-column text-area))
                            (natnump value))))

(defcustom pretty-tables-min-column-width 8
  "Width below which a column is not narrowed to fit the table width."
  :type 'natnum
  :safe #'natnump)

(defcustom pretty-tables-stripe-rows t
  "Non-nil means data rows are drawn with alternating backgrounds.
The first, third, ... data rows get the face `pretty-tables-row',
the others `pretty-tables-stripe'."
  :type 'boolean
  :safe #'booleanp)

(defcustom pretty-tables-row-lines nil
  "Non-nil means a line is drawn under each data row but the last.
The line is the underline of the face `pretty-tables-row-line',
so it takes no screen line of its own."
  :type 'boolean
  :safe #'booleanp)

(defcustom pretty-tables-borders 'ascii
  "How the lines between the cells of a drawn table are drawn.
`ascii' means with the characters `|', `-' and `+', or those of the
adaptor's separator row.  `lines' means with lines that join from one
screen line to the next, in the face `pretty-tables-border'.  On a
graphical display a vertical line is 1 pixel wide and spans the whole
height of each screen line.  A separator row that follows a row other
than a separator takes no screen line: it is hidden, and the row
before it is underlined on the bottom pixel row of its last screen
line, against the row below.  Another separator row is a horizontal
line on the bottom pixel row of its own screen line.  With
`display-line-numbers', the number of a hidden separator row is not
shown.  On a text terminal the lines are the box-drawing
characters `│', `─', `├', `┼' and `┤'.  With `lines', a Markdown
delimiter row does not show the alignment of its columns."
  :type '(choice (const :tag "ASCII characters" ascii)
                 (const :tag "Continuous lines" lines))
  :safe (lambda (value) (memq value '(ascii lines))))

(defcustom pretty-tables-separator-spacing 0.25
  "Space between a row and the line of the separator row under it.
In units of the height of a line of text.  Used when
`pretty-tables-borders' is `lines', below a row that is underlined in
place of the separator row after it: the space is the `line-spacing'
of the newline that ends the row, so the line stays against the row
below and the vertical lines cross the space."
  :type 'number
  :safe (lambda (value) (and (numberp value) (>= value 0))))

(defcustom pretty-tables-image-spacing 0.5
  "Most space above and below an image in a cell of a drawn table.
In units of the height of a line of text, split evenly above and
below the image.  An image gets this space only as far as it reaches
past the letters of the line: one that fits within the font's ascent
and descent gets none, and one that reaches past them by a few pixels
gets `pretty-tables-image-spacing-factor' times as many.  The space
is a vertical `:margin' of the copy of the image that draws it, so a
tall image does not touch the rows above and below it, and its
`:ascent' is changed so that it stays on the same baseline.  An image
that already has a `:margin' is left as it is."
  :type 'number
  :safe (lambda (value) (and (numberp value) (>= value 0))))

(defcustom pretty-tables-image-spacing-factor 2
  "Pixels of space per pixel an image reaches past the letters of the line.
An image in a cell gets this factor times the number of pixels it
reaches past the font's ascent or descent, as space above and below
it, up to the most that `pretty-tables-image-spacing' gives.  0 means
no space for any image.  t means the most space for every image that
reaches past the font, and none for one that fits within it.  An
image reaches past the font by a whole number of pixels, at least 1,
so a factor at least as large as that most space in pixels, such as
1000, gives the same result as t.  nil means the most space for every
image, also one that fits."
  :type '(choice (const :tag "The most space for every image" nil)
                 (const :tag "The most space for an image past the font" t)
                 number)
  :safe (lambda (value) (or (booleanp value)
                            (and (numberp value) (>= value 0)))))

(defcustom pretty-tables-reveal 'writable
  "When the row point is on is shown as its raw text.
`always' means in every buffer, `writable' in a buffer that is not
read-only, and nil never.  During an Isearch the row point is on is
shown as its raw text whatever the value, so a match in it can be
seen."
  :type '(choice (const :tag "In every buffer" always)
                 (const :tag "In a buffer that is not read-only" writable)
                 (const :tag "Never" nil))
  :safe (lambda (value) (memq value '(always writable nil))))

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

(defface pretty-tables-border
  '((t :inherit shadow))
  "Face of the lines between the cells of a drawn table.
Its foreground is the colour of the lines.  Used when
`pretty-tables-borders' is `lines'.")

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

(defvar-local pretty-tables--edited nil
  "How the buffer changed since the table of the revealed row was drawn.
Nil when it did not change, `row' when every change lay on the line
of the revealed row and added or deleted no newline, `other' else.
Set by `pretty-tables--note-change'.  With `row',
`pretty-tables--fontify' does not draw that table again;
`pretty-tables--reveal' has it drawn when point leaves the row.")

(defvar-local pretty-tables--remapping nil
  "A copy of `face-remapping-alist' when it was last compared.
See `pretty-tables--check-remapping'.")

(defvar pretty-tables--rendering nil
  "Non-nil while a table is being drawn.
Stops the nested `jit-lock-fontify-now' from running the drawing
function again.")

(defvar pretty-tables--unit nil
  "Width in pixels of a column while tables are laid out in pixels, or nil.
`pretty-tables--fontify' binds it on a graphical display; see
`pretty-tables--column-pixels'.  Nil means the tables are laid out in
columns, with `string-width'.")

(defvar pretty-tables--line nil
  "Width in pixels of a vertical line `|' while a table is drawn, or nil.
Bound while a table is laid out in pixels with `pretty-tables-borders'
`ascii': the widest of `|' and the characters the adaptor's
`:separator' puts where its vertical lines cross the separator row.
Each of them is centred in that width.  See
`pretty-tables--line-width'.")

(defvar pretty-tables--widths nil
  "Hash table of the strings `pretty-tables--width' measured, or nil.
Its keys are the strings themselves, compared with `eq': the cell of a
row is measured for the width of its column, for wrapping and for
padding.  Bound to a new table while tables are drawn.")

(defvar-keymap pretty-tables-row-map
  :doc "Keymap on the strings that draw table rows."
  "<down-mouse-1>" #'ignore
  "<mouse-1>" #'pretty-tables-mouse-follow
  "<down-mouse-2>" #'ignore
  "<mouse-2>" #'pretty-tables-mouse-follow)

;;; Measuring

(defun pretty-tables--pixel-width (string)
  "Return the width in pixels of STRING as a drawn row shows it.
The adaptor's `:face' is appended to a copy of STRING, as it is to a
drawn row, and the copy is measured with `string-pixel-width' in the
current buffer, so the buffer's face remapping applies."
  (let ((face (plist-get pretty-tables--adaptor :face)))
    (when face
      (setq string (copy-sequence string))
      (add-face-text-property 0 (length string) face t string))
    (string-pixel-width string (current-buffer))))

(defun pretty-tables--width (string)
  "Return the width of STRING in the unit of the layout.
In pixels, with `pretty-tables--pixel-width', when
`pretty-tables--unit' is non-nil; else in columns, with
`string-width'.  A string is measured in pixels once while it is in
`pretty-tables--widths': a string must not be changed after it is
measured."
  (cond
   ((not pretty-tables--unit) (string-width string))
   ((not pretty-tables--widths) (pretty-tables--pixel-width string))
   (t (or (gethash string pretty-tables--widths)
          (puthash string (pretty-tables--pixel-width string)
                   pretty-tables--widths)))))

(defun pretty-tables--column-pixels ()
  "Return the width in pixels of a column of a drawn table.
It is the `width' unit of a stretch in the adaptor's `:face': the
width of the face's font, which the vertical lines of
`pretty-tables--border' are drawn in.  At least 1."
  (max 1 (pretty-tables--pixel-width
          (propertize " " 'display '(space :width (1 . width))))))

(defun pretty-tables--space (pixels)
  "Return a string showing a space PIXELS wide.
Its `display' is a new list each time: Emacs shows adjacent characters
whose `display' is the same object as one space."
  (propertize " " 'display `(space :width (,pixels))))

(defun pretty-tables--fill (string width)
  "Return STRING followed by the space that makes it WIDTH pixels wide.
STRING itself when it is WIDTH pixels wide or wider."
  (let ((gap (- width (pretty-tables--pixel-width string))))
    (if (> gap 0)
        (concat string (pretty-tables--space gap))
      string)))

(defun pretty-tables--center (string width)
  "Return STRING between the spaces that make it WIDTH pixels wide.
STRING itself when it is WIDTH pixels wide or wider."
  (let* ((gap (- width (pretty-tables--pixel-width string)))
         (left (/ (max gap 0) 2)))
    (if (> gap 0)
        (concat (if (> left 0) (pretty-tables--space left) "")
                string
                (pretty-tables--space (- gap left)))
      string)))

;;; Reading the buffer

(defun pretty-tables--font-metrics ()
  "Return (ASCENT . DESCENT) of the font of the `default' face, or nil.
Nil when there is no such font, as in batch mode, or no `font-info',
as in an Emacs built without a window system."
  (when (fboundp 'font-info)
    (when-let* ((font (font-info (face-font 'default))))
      (cons (aref font 8) (aref font 9)))))

(defun pretty-tables--image-ascent (image height font)
  "Return the ascent in pixels of IMAGE, HEIGHT pixels tall, with no margin.
It is computed as `image_ascent' in Emacs's image.c computes it: from
the `:ascent' of IMAGE, a percentage, `center', or none, which stands
for 50.  `center' uses FONT, the (ASCENT . DESCENT) of
`pretty-tables--font-metrics', or centres on HEIGHT when FONT is nil."
  (let ((ascent (or (image-property image :ascent) 50)))
    (if (eq ascent 'center)
        (if font
            (floor (+ height (car font) (- (cdr font)) 1) 2)
          (floor height 2))
      (truncate (* height (/ ascent 100.0))))))

(defun pretty-tables--image-with-margin (image)
  "Return a copy of IMAGE with a vertical margin.
S = `pretty-tables-image-spacing' times the height of a line of text,
halved and rounded, is the most margin.  E is how many pixels the
image reaches past the font of the `default' face: the image's ascent
minus the font's, or its descent minus the font's, whichever is more,
and 0 when the image fits within the font.  The margin is M, the
smaller of S and `pretty-tables-image-spacing-factor' times E,
rounded, above and below the image, so an image that fits in a line of
text gets none, and its row is no taller than one of text.  With the
factor t, M is S when E is not 0.  M is S when the factor is nil, and
without a font, as in batch mode.  Emacs
computes the ascent of an image with a margin from the image's height
plus one margin, while the image takes its height plus two, so the
copy's `:ascent' is the percentage that puts the image where it was
without a margin: the image's own ascent plus M, out of its height
plus M.  The percentage is rounded up, because Emacs truncates the
ascent it computes from it.  IMAGE itself is returned when M is 0,
IMAGE has a `:margin', or Emacs has no `image-size', as when it is
built without image support."
  (let ((most (round (* pretty-tables-image-spacing (default-line-height))
                     2)))
    (if (and (> most 0) (not (image-property image :margin))
             (fboundp 'image-size))
        (let* ((height (cdr (image-size image t)))
               (font (pretty-tables--font-metrics))
               (own (pretty-tables--image-ascent image height font))
               (factor pretty-tables-image-spacing-factor)
               (overhang (if font
                             (max 0 (- own (car font)) (- height own (cdr font)))
                           0))
               (margin (cond ((or (not font) (null factor)) most)
                             ;; Before multiplying: a factor of
                             ;; `1.0e+INF' times 0 is NaN.
                             ((zerop overhang) 0)
                             ((eq factor t) most)
                             ;; The smaller first: `round' signals an
                             ;; error on an infinite product.
                             (t (round (min most (* factor overhang)))))))
          (if (<= margin 0)
              image
            (let ((spec (copy-sequence (cdr image))))
              (setq spec (plist-put spec :margin (cons 0 margin)))
              (setq spec (plist-put
                          spec :ascent
                          (min 100 (max 0 (ceiling (* 100 (+ own margin))
                                                   (+ height margin))))))
              (cons 'image spec))))
      image)))

(defun pretty-tables--position (string index)
  "Return the buffer position character INDEX of STRING comes from, or nil.
The position is read from `pretty-tables-pos', which a cell string
has on runs of characters: an integer P on a run of buffer text that
starts at P, each character one position after the one before it; a
list (P) on a run whose characters all come from P, such as the text
of a `display' string or an image."
  (let ((value (get-text-property index 'pretty-tables-pos string)))
    (cond
     ((consp value) (car value))
     (value (+ value (- index (or (previous-single-property-change
                                   (1+ index) 'pretty-tables-pos string)
                                  0)))))))

(defun pretty-tables--substring (string from &optional to)
  "Return the substring of STRING from FROM to TO, keeping its positions.
When FROM is inside a run of buffer text in `pretty-tables-pos', the
part of that run in the substring gets the position of its first
character, so `pretty-tables--position' reads the same positions in
the substring as in STRING.  TO nil means the end of STRING."
  (let ((value (and (< from (length string))
                    (get-text-property from 'pretty-tables-pos string)))
        (result (substring string from to)))
    (when (integerp value)
      (let ((position (pretty-tables--position string from)))
        (unless (= position value)
          (put-text-property 0 (next-single-property-change
                                0 'pretty-tables-pos result (length result))
                             'pretty-tables-pos position result))))
    result))

(defun pretty-tables--trim (string)
  "Return STRING without the whitespace at its start and end.
It is cut with `pretty-tables--substring'."
  (let ((start (if (string-match "\\`[ \t\n\r]+" string) (match-end 0) 0))
        (end (if (string-match "[ \t\n\r]+\\'" string)
                 (match-beginning 0)
               (length string))))
    (pretty-tables--substring string start (max start end))))

(defun pretty-tables--image-string (image pos)
  "Return the string that shows IMAGE in a cell.
It is one character, showing the copy of IMAGE that
`pretty-tables--image-with-margin' returns.  It has (POS) in
`pretty-tables-pos', and in `pretty-tables-image' a list of its
width in pixels, measured with `pretty-tables--width'."
  (let ((string (propertize "x" 'display (pretty-tables--image-with-margin image)
                            'pretty-tables-pos (list pos))))
    (put-text-property 0 1 'pretty-tables-image
                       (list (pretty-tables--width string)) string)
    string))

(defun pretty-tables--visible-string (beg end)
  "Return the text between BEG and END as it is displayed.
Invisible characters are dropped and a `display' string replaces the
text it covers, with its newlines read as spaces.  A `display' image
is shown as an image, see `pretty-tables--image-string', when the
table is laid out in pixels (`pretty-tables--unit' is non-nil) on a
display that can show images.  A `space' display with a `:width' is
kept as it is in pixels, and is read as N spaces in columns when its
`:width' is a number N.  Whether a
character is invisible is decided by the adaptor's `:invisible'
function, by default `invisible-p'.  The buffer position each
character comes from is in the `pretty-tables-pos' property, by run;
see `pretty-tables--position'.  A value per character would make
each character an interval of its own, and `substring' and `concat'
copy each interval and its property list."
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
         ((and (eq (car-safe display) 'image)
               pretty-tables--unit
               (display-images-p))
          (push (pretty-tables--image-string display pos) parts))
         ((stringp display)
          ;; A newline would end the drawn row's screen line inside a
          ;; cell.  latex-to-svg shows the spaces around display math
          ;; as one.
          (push (propertize (subst-char-in-string ?\n ?\s display)
                            'pretty-tables-pos (list pos))
                parts))
         ((and pretty-tables--unit
               (eq (car-safe display) 'space)
               (plist-get (cdr display) :width))
          ;; A copy: two stretches side by side whose `display' is the
          ;; same object are shown as one.
          (push (propertize " " 'display (copy-sequence display)
                            'pretty-tables-pos (list pos))
                parts))
         ((and (eq (car-safe display) 'space)
               (natnump (plist-get (cdr display) :width)))
          (push (propertize (make-string (plist-get (cdr display) :width) ?\s)
                            'pretty-tables-pos (list pos))
                parts))
         (t
          (let ((s (buffer-substring pos next)))
            (put-text-property 0 (length s) 'pretty-tables-pos pos s)
            (push s parts))))
        (setq pos next)))
    (apply #'concat (nreverse parts))))

(defun pretty-tables--cell-paragraphs (beg end)
  "Return the displayed text of the cell from BEG to END.
The value is a list of strings, one per piece separated by the
adaptor's `:line-break' regexp, or a list of one string when the
adaptor has none.  The pieces are cut, and their whitespace trimmed,
with `pretty-tables--substring', so they keep their positions."
  (let ((text (pretty-tables--visible-string beg end))
        (line-break (plist-get pretty-tables--adaptor :line-break))
        (case-fold-search t)
        (start 0)
        pieces)
    (while (and line-break (string-match line-break text start))
      (push (pretty-tables--substring text start (match-beginning 0)) pieces)
      (setq start (match-end 0)))
    (push (pretty-tables--substring text start) pieces)
    (mapcar #'pretty-tables--trim (nreverse pieces))))

;;; Layout

(defun pretty-tables--narrow-widest (widths floors &optional step)
  "Narrow by STEP the widest of WIDTHS that is wider than its floor.
STEP is 1 when nil.  A column is not narrowed below its floor.
FLOORS has an entry per column, a width or nil; a column whose entry
is nil is not narrowed.  WIDTHS is changed in place.  Return nil when
no column is wider than its floor."
  (let (best)
    (seq-do-indexed (lambda (floor i)
                      (when (and floor (> (nth i widths) floor)
                                 (or (null best)
                                     (> (nth i widths) (nth best widths))))
                        (setq best i)))
                    floors)
    (when best
      (setf (nth best widths) (max (nth best floors)
                                   (- (nth best widths) (or step 1)))))))

(defun pretty-tables--text-area-width ()
  "Return the width of the narrowest text area showing the buffer, or nil.
In pixels, which on a text terminal are columns.  The text area of a
window is its body, `window-body-width', less the line numbers, and
less one character of the `default' face for the continuation glyph
unless a line can end in the right fringe, as `window-max-chars-per-line'
counts it.  Nil when no window shows the buffer."
  (when-let* ((windows (get-buffer-window-list nil 'nomini t)))
    (apply #'min
           (mapcar (lambda (window)
                     ;; `line-number-display-width' reads the selected
                     ;; window.
                     (with-selected-window window
                       (let ((fringes (window-fringes window)))
                         (- (window-body-width window t)
                            (line-number-display-width t)
                            (if (and (display-graphic-p)
                                     ;; Not defined in an Emacs built
                                     ;; without a window system.
                                     (bound-and-true-p
                                      overflow-newline-into-fringe)
                                     (not (eq (car fringes) 0))
                                     (not (eq (nth 1 fringes) 0)))
                                0
                              (window-font-width window))))))
                   windows))))

(defvar-local pretty-tables--text-area nil
  "The value of `pretty-tables--text-area-width' when the windows last changed.
Kept so that drawing a table, which runs during redisplay, reads no
window.")

(defun pretty-tables--target-width (prefix)
  "Return the width a table is drawn to fit, in the unit of the layout.
That is the width of `pretty-tables-width', but no more than the text
area in `pretty-tables--text-area' less PREFIX, the width of the widest
prefix of the table's rows, which takes room before the table.  The
unit is the pixel when `pretty-tables--unit' is non-nil, else the
column; the text area is in pixels, which on a text terminal, where
the layout is in columns, are columns."
  (let* ((unit (or pretty-tables--unit 1))
         (own (pcase pretty-tables-width
                ('text-area nil)
                ((pred natnump) (* pretty-tables-width unit))
                (_ (* fill-column unit))))
         (area (and pretty-tables--text-area
                    (- pretty-tables--text-area prefix))))
    (cond ((and own area) (min own area))
          (own)
          (area)
          (t (* fill-column unit)))))

(defun pretty-tables--column-widths (natural target &optional minimums images
                                             overhead)
  "Narrow the NATURAL column widths until the table fits TARGET.
A table whose columns have widths W takes sum(W) + OVERHEAD, the
width of its vertical lines and of the space on each side of each
cell.  OVERHEAD is 3N + 1 when nil, N being the number of columns.
MINIMUMS has an entry per column, a width or nil.  First the widest
column with an entry is narrowed by one column, until the table fits
or each such column is at its entry.  Then the widest column is
narrowed by one column until the table fits or every column is at its
entry or, without one, at `pretty-tables-min-column-width' columns.
IMAGES has an entry per column, the width of its widest image or nil,
and no column is narrowed below it.  The widths are in columns, or in
pixels when `pretty-tables--unit' is non-nil, a column being that many
pixels."
  (let* ((widths (copy-sequence natural))
         (n (length widths))
         (unit (or pretty-tables--unit 1))
         (overhead (or overhead (+ (* 3 n) 1)))
         (images (mapcar (lambda (i) (or (nth i images) 0))
                         (number-sequence 0 (1- n))))
         (minimums (seq-mapn (lambda (m image) (and m (max m image)))
                             (mapcar (lambda (i) (nth i minimums))
                                     (number-sequence 0 (1- n)))
                             images))
         (floors (seq-mapn (lambda (m image)
                             (or m (max (* pretty-tables-min-column-width unit)
                                        image)))
                           minimums images)))
    (dolist (floors (list minimums floors))
      (while (and (> (+ (apply #'+ widths) overhead) target)
                  (pretty-tables--narrow-widest widths floors unit))))
    widths))

(defun pretty-tables--fit (string width)
  "Return the length of the longest start of STRING no wider than WIDTH.
The width is that of `pretty-tables--width'."
  (if pretty-tables--unit
      (let ((low 0) (high (length string)))
        ;; The longest start that fits is LOW characters or longer, and
        ;; HIGH characters or shorter.
        (while (< low high)
          (let ((middle (/ (+ low high 1) 2)))
            (if (<= (pretty-tables--width (substring string 0 middle)) width)
                (setq low middle)
              (setq high (1- middle)))))
        low)
    (length (truncate-string-to-width string width))))

(defun pretty-tables--break-word (word width)
  "Split WORD into pieces no wider than WIDTH.
A piece is at least one character, so a character wider than WIDTH,
such as an image, is a piece of its own."
  (let (pieces)
    (while (> (pretty-tables--width word) width)
      (let ((cut (pretty-tables--fit word width)))
        (when (= cut 0)
          (setq cut 1))
        (push (pretty-tables--substring word 0 cut) pieces)
        (setq word (pretty-tables--substring word cut))))
    (nreverse (cons word pieces))))

(defun pretty-tables--widest-image (paragraph)
  "Return the width of the widest image in PARAGRAPH, or 0.
The images are those of `pretty-tables--image-string', and the width
is the one in their `pretty-tables-image'."
  (let ((pos 0) (widest 0))
    (while (setq pos (text-property-not-all pos (length paragraph)
                                            'pretty-tables-image nil
                                            paragraph))
      (setq widest (max widest (car (get-text-property
                                     pos 'pretty-tables-image paragraph)))
            pos (next-single-property-change pos 'pretty-tables-image
                                             paragraph (length paragraph))))
    widest))

(defun pretty-tables--wrap (paragraph width)
  "Word-wrap PARAGRAPH into lines no wider than WIDTH.
Lines are substrings of PARAGRAPH, so they keep its text properties.
The width is that of `pretty-tables--width'.  Each line holds as many
words as fit; a longer start of a paragraph is never narrower, so the
last word that fits is found by a binary search over the ends of the
words, which measures about log2 of their number lines.  A word wider
than WIDTH is split by `pretty-tables--break-word', and its last piece
starts the next line.  In pixels, a PARAGRAPH no wider than WIDTH is
returned whole."
  (if (and pretty-tables--unit
           (<= (pretty-tables--width paragraph) width))
      (list paragraph)
    (let ((pos 0) (words nil) (i 0) (line-beg nil) lines)
      (while (string-match "[^ \t]+" paragraph pos)
        (push (cons (match-beginning 0) (match-end 0)) words)
        (setq pos (match-end 0)))
      (setq words (vconcat (nreverse words)))
      (while (< i (length words))
        (unless line-beg
          (setq line-beg (car (aref words i))))
        (let ((fits (lambda (j)
                      (<= (pretty-tables--width
                           (substring paragraph line-beg (cdr (aref words j))))
                          width))))
          (if (funcall fits i)
              (let ((low i) (high (1- (length words))))
                ;; The last word that fits is LOW or after, HIGH or before.
                (while (< low high)
                  (let ((middle (/ (+ low high 1) 2)))
                    (if (funcall fits middle)
                        (setq low middle)
                      (setq high (1- middle)))))
                (push (pretty-tables--substring paragraph line-beg
                                                (cdr (aref words low)))
                      lines)
                (setq i (1+ low)
                      line-beg nil))
            (let* ((end (cdr (aref words i)))
                   (pieces (pretty-tables--break-word
                            (pretty-tables--substring paragraph line-beg end)
                            width))
                   (last (car (last pieces))))
              (setq lines (append (reverse (butlast pieces)) lines))
              (if (string-empty-p last)
                  (setq i (1+ i)
                        line-beg nil)
                (setq line-beg (- end (length last))))))))
      (or (nreverse lines) (list "")))))

(defun pretty-tables--pad (text width alignment)
  "Pad TEXT with spaces to WIDTH, placing it according to ALIGNMENT.
In columns; in pixels a row is built by `pretty-tables--pixel-line'."
  (let* ((gap (max 0 (- width (string-width text))))
         (left (pcase alignment
                 ('right gap)
                 ('center (/ gap 2))
                 (_ 0))))
    (concat (make-string left ?\s) text (make-string (- gap left) ?\s))))

(defun pretty-tables--border (edge &optional rule)
  "Return the string drawing a vertical line of a table.
EDGE is `left' for the line at the left of the first column, `right'
for the one at the right of the last column, and nil for a line
between two columns.  RULE non-nil means the line crosses a separator
row.  The string is one column wide.

With `pretty-tables-borders' `ascii' it is `|'.  With `lines', on a
graphical display, it holds a 1-pixel stretch drawn in the foreground
of `pretty-tables-border', and stretches for the rest of the column.
Between two columns the line is in the middle of the column; at the
left and right edges it is on the outer side, so the background of a
row ends at the line.  The `width' unit is the width of the face's
font, so the column follows `text-scale-adjust'.  A glyph's
background fills the height of its screen line, so the 1-pixel
stretch draws a line that joins the one of the screen line below.
With RULE the other stretches have an underline at the descent line,
which is the bottom pixel row of the screen line: the horizontal line
of the separator row.  On a text terminal the string is `│', or
with RULE `├', `┼' or `┤'."
  (cond
   ((not (eq pretty-tables-borders 'lines)) "|")
   ((display-graphic-p)
    (let ((line (propertize " " 'display '(space :width (1))
                            'face (list :inherit 'pretty-tables-border
                                        :inverse-video t)))
          (face (if rule (list :inherit 'pretty-tables-border
                               :underline '(:position t)))))
      (pcase edge
        ('left (concat line (propertize " " 'display '(space :width (- width (1)))
                                        'face face)))
        ('right (concat (propertize " " 'display '(space :width (- width (1)))
                                    'face face)
                        line))
        (_ (concat (propertize " " 'display '(space :width (0.5 . width))
                               'face face)
                   line
                   ;; A stretch's width is truncated to whole pixels:
                   ;; with the half pixel taken off, the three add up to
                   ;; one column whether the font width is odd or even.
                   (propertize " " 'display '(space :width (- (0.5 . width) (0.5)))
                               'face face))))))
   (t (propertize (cond ((not rule) "│")
                        ((eq edge 'left) "├")
                        ((eq edge 'right) "┤")
                        (t "┼"))
                  'face 'pretty-tables-border))))

(defun pretty-tables--draw-rule (widths)
  "Return the string drawing a separator row of the column WIDTHS.
It is a horizontal line across the row, crossed by the vertical lines
of `pretty-tables--border'.  Used when `pretty-tables-borders' is
`lines', in place of the adaptor's `:separator'."
  (let ((graphic (display-graphic-p)))
    (concat (pretty-tables--border 'left t)
            (mapconcat
             (lambda (w)
               (if graphic
                   (propertize " " 'display
                               (if pretty-tables--unit
                                   `(space :width (,(+ w (* 2 pretty-tables--unit))))
                                 `(space :width (,(+ 2 w) . width)))
                               'face (list :inherit 'pretty-tables-border
                                           :underline '(:position t)))
                 (propertize (make-string (+ 2 w) ?─)
                             'face 'pretty-tables-border)))
             widths (pretty-tables--border nil t))
            (pretty-tables--border 'right t))))

(defun pretty-tables--line-width (ncols alignments)
  "Return the width in pixels of the vertical lines of a table, or nil.
NCOLS is the number of columns of the table, ALIGNMENTS their
alignments.  The width is that of the widest of `|' and the
characters the adaptor's `:separator' puts where the vertical lines
cross the separator row, called with columns 0 characters wide.  Nil
unless the table is laid out in pixels with `pretty-tables-borders'
`ascii'."
  (when (and pretty-tables--unit (not (eq pretty-tables-borders 'lines)))
    (let ((string (funcall (plist-get pretty-tables--adaptor :separator)
                           (make-list ncols 0) alignments)))
      (apply #'max (pretty-tables--pixel-width "|")
             (and (= (length string) (1+ (* 3 ncols)))
                  (mapcar (lambda (i)
                            (pretty-tables--pixel-width
                             (substring string (* 3 i) (1+ (* 3 i)))))
                          (number-sequence 0 ncols)))))))

(defun pretty-tables--separator (widths alignments)
  "Return the adaptor's separator row for the column WIDTHS and ALIGNMENTS.
In columns, it is the string the adaptor's `:separator' returns.  In
pixels, when `pretty-tables--unit' is non-nil, `:separator' is called
with, for each column, the number of characters `-' that fit in the
column and the space on each side of it, minus 2, as it would draw a
column that many characters wide.  Its string has one character at
each vertical line and that many plus 2 for each column.  Each
character at a vertical line is centred in `pretty-tables--line'
pixels, with `pretty-tables--center', and the characters of each
column are filled to its width and the spaces on each side, with
`pretty-tables--fill', so they can end short of the next vertical line
by less than the width of one `-'.  A string of another length is
returned as it is."
  (let ((separator (plist-get pretty-tables--adaptor :separator)))
    (if (not pretty-tables--unit)
        (funcall separator widths alignments)
      (let* ((space (* 2 pretty-tables--unit))
             (dash (max 1 (pretty-tables--pixel-width "-")))
             (counts (mapcar (lambda (w) (max 0 (- (floor (+ w space) dash) 2)))
                             widths))
             (string (funcall separator counts alignments))
             (line (lambda (pos)
                     (let ((char (substring string pos (1+ pos))))
                       (if pretty-tables--line
                           (pretty-tables--center char pretty-tables--line)
                         char))))
             (pos 1))
        (if (/= (length string)
                (+ 1 (apply #'+ (mapcar (lambda (c) (+ c 3)) counts))))
            string
          (apply #'concat
                 (funcall line 0)
                 (seq-mapn
                  (lambda (w c)
                    (prog1 (concat (pretty-tables--fill
                                    (substring string pos (+ pos c 2))
                                    (+ w space))
                                   (funcall line (+ pos c 2)))
                      (setq pos (+ pos c 3))))
                  widths counts)))))))

(defun pretty-tables--pixel-line (texts widths alignments)
  "Return one screen line of a row laid out in pixels.
TEXTS has the text of each cell on that line, WIDTHS and ALIGNMENTS
the width in pixels and the alignment of each column.  The pieces are
those of `pretty-tables--draw-row' in columns: a vertical line, the
space of `pretty-tables--unit' pixels on each side of a cell, the
cell's text padded to its width.  All the space between two pieces of
text or two vertical lines is one stretch, of the sum of its pixels:
the display engine handles each stretch on its own, and redisplay of a
window showing a table took about 10 microseconds per stretch.  A
vertical line is the 1-pixel stretch of `pretty-tables--border', in a
column of `pretty-tables--unit' pixels, with `pretty-tables-borders'
`lines', and `|' centred in `pretty-tables--line' pixels with
`ascii'."
  (let* ((unit pretty-tables--unit)
         (lines (eq pretty-tables-borders 'lines))
         (bar (unless lines (pretty-tables--pixel-width "|")))
         (column (unless lines (or pretty-tables--line bar)))
         (gap 0)
         (parts nil)
         (space (lambda (pixels) (setq gap (+ gap (max 0 pixels)))))
         (emit (lambda (string)
                 (when (> gap 0)
                   (push (pretty-tables--space gap) parts)
                   (setq gap 0))
                 (push string parts)))
         (vertical
          (lambda (edge)
            (if lines
                ;; At the edges the line is on the outer side of its
                ;; column, so the background of a row ends at the line.
                (let ((left (pcase edge
                              ('left 0)
                              ('right (1- unit))
                              (_ (/ unit 2)))))
                  (funcall space left)
                  (funcall emit (propertize
                                 " " 'display (list 'space :width (list 1))
                                 'face (list :inherit 'pretty-tables-border
                                             :inverse-video t)))
                  (funcall space (- unit 1 left)))
              (let ((left (/ (- column bar) 2)))
                (funcall space left)
                (funcall emit "|")
                (funcall space (- column bar left)))))))
    (funcall vertical 'left)
    (let ((n (length widths)))
      (dotimes (i n)
        (let* ((text (or (nth i texts) ""))
               (pad (max 0 (- (nth i widths) (pretty-tables--width text))))
               (left (pcase (nth i alignments)
                       ('right pad)
                       ('center (/ pad 2))
                       (_ 0))))
          (funcall space (+ unit left))
          (unless (string-empty-p text)
            (funcall emit text))
          (funcall space (+ (- pad left) unit))
          (funcall vertical (if (= i (1- n)) 'right nil)))))
    (when (> gap 0)
      (push (pretty-tables--space gap) parts))
    (apply #'concat (nreverse parts))))

(defun pretty-tables--draw-row (cells widths alignments)
  "Return the string drawing a row whose cells are CELLS.
CELLS is a list of cells, each a list of paragraphs.  WIDTHS and
ALIGNMENTS give each column's width and alignment.  In pixels each
screen line is built by `pretty-tables--pixel-line'.  In columns the
lines between the cells are those of `pretty-tables--border', and each
cell has a space on each side."
  (let* ((wrapped (seq-map-indexed
                   (lambda (width i)
                     (mapcan (lambda (p) (pretty-tables--wrap p width))
                             (nth i cells)))
                   widths))
         (height (apply #'max 1 (mapcar #'length wrapped)))
         lines)
    (dotimes (k height)
      (push (if pretty-tables--unit
                (pretty-tables--pixel-line
                 (mapcar (lambda (column) (nth k column)) wrapped)
                 widths alignments)
              (concat (pretty-tables--border 'left)
                      (mapconcat
                       (lambda (i)
                         (concat " "
                                 (pretty-tables--pad
                                  (or (nth k (nth i wrapped)) "")
                                  (nth i widths) (nth i alignments))
                                 " "))
                       (number-sequence 0 (1- (length widths)))
                       (pretty-tables--border nil))
                      (pretty-tables--border 'right)))
            lines))
    (mapconcat #'identity (nreverse lines) "\n")))

;;; Drawing a table

(defun pretty-tables--delete-overlays (beg end)
  "Delete the row overlays that overlap BEG to END.
The overlays of `pretty-tables--add-spacing' go too.  The markers of
their `pretty-tables-table' are set to point nowhere, so they no longer
slow down editing."
  (dolist (ov (overlays-in beg end))
    (when (or (overlay-get ov 'pretty-tables)
              (overlay-get ov 'pretty-tables-spacing))
      (when-let* ((bounds (overlay-get ov 'pretty-tables-table)))
        (set-marker (car bounds) nil)
        (set-marker (cdr bounds) nil))
      (delete-overlay ov))))

(defun pretty-tables--add-spacing (pos)
  "Put `pretty-tables-separator-spacing' below the line ending at POS.
POS is the position of the newline that ends the line.  An overlay on
the newline gets a `line-spacing' of `(t . RATIO)', RATIO times the
height of the newline's face, so the space follows
`text-scale-adjust'.  Emacs puts the space below the line and counts
it in the line's height: the backgrounds of the line's glyphs, and so
the vertical lines, fill it, and an underline at the descent line is
drawn below it.  Nothing is added when the option is 0 or there is no
newline at POS."
  (when (and (> pretty-tables-separator-spacing 0)
             (eql (char-after pos) ?\n))
    (let ((ov (make-overlay pos (1+ pos) nil t nil)))
      (overlay-put ov 'pretty-tables-spacing t)
      (overlay-put ov 'evaporate t)
      (overlay-put ov 'line-spacing
                   (cons t pretty-tables-separator-spacing)))))

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

(defun pretty-tables--underline-last-line (string)
  "Draw a horizontal line under the last screen line of STRING, a row.
The line is an underline at the descent line, on the bottom pixel row
of the screen line, in the foreground of `pretty-tables-border'.  It
is added before the faces of the cell text, so it is drawn under a
link too.  It takes the place of a separator row that
`pretty-tables--render-table' hides when `pretty-tables-borders' is
`lines'."
  (let ((colour (face-foreground 'pretty-tables-border nil t)))
    ;; The last screen line of the row: `.' does not match a newline.
    (string-match ".*\\'" string)
    (add-face-text-property (match-beginning 0) (length string)
                            (list :underline (if colour
                                                 (list :color colour :position t)
                                               '(:position t)))
                            nil string)))

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

(defun pretty-tables--show-drawn (ov drawn)
  "Show the row overlay OV drawn when DRAWN is non-nil, else as its text.
The drawn row is the overlay's `before-string', its string in
`pretty-tables-string', and a `display' of \"\" hides the text of
the row.  A `display' string would not do: Emacs ignores the
`display' properties inside a string that is itself a `display', and
an image in a cell is one (see `pretty-tables--image-string')."
  (overlay-put ov 'display (and drawn ""))
  (overlay-put ov 'before-string
               (and drawn (overlay-get ov 'pretty-tables-string))))

(defun pretty-tables--render-table (table revealed)
  "Cover each row of TABLE with an overlay that draws it aligned.
TABLE is a table as `pretty-tables-enable' describes it.  The row
starting at REVEALED is left as raw text.
When `pretty-tables-borders' is `lines', a separator row that follows
a row other than a separator is hidden with its newline, so it takes
no screen line, and the row before it is underlined in its place; see
`pretty-tables--underline-last-line'.  The line ending that row gets
the space of `pretty-tables--add-spacing'."
  ;; The old overlays go first: the cells are read with
  ;; `get-char-property', which would return their `display' of "".
  (pretty-tables--delete-overlays (plist-get table :beg) (plist-get table :end))
  (let* ((rows (plist-get table :rows))
         ;; Shared by the row overlays; see `pretty-tables--fontify'.
         (bounds (cons (copy-marker (plist-get table :beg))
                       (copy-marker (plist-get table :end) t)))
         (unit (or pretty-tables--unit 1))
         (data (mapcar (lambda (row)
                         (unless (eq (plist-get row :kind) 'separator)
                           (let ((cells (mapcar (lambda (cell)
                                                  (pretty-tables--cell-paragraphs
                                                   (car cell) (cdr cell)))
                                                (plist-get row :cells))))
                             ;; Before the cells are measured: a bold
                             ;; font can be wider.
                             (when (eq (plist-get row :kind) 'header)
                               (dolist (paragraph (apply #'append cells))
                                 (add-face-text-property
                                  0 (length paragraph) 'pretty-tables-header t
                                  paragraph)))
                             cells)))
                       rows))
         (ncols (apply #'max 1 (mapcar #'length data)))
         (natural (mapcar (lambda (i)
                            (apply #'max unit
                                   (mapcar (lambda (cells)
                                             (apply #'max 0
                                                    (mapcar #'pretty-tables--width
                                                            (nth i cells))))
                                           data)))
                          (number-sequence 0 (1- ncols))))
         (images (mapcar (lambda (i)
                           (apply #'max 0
                                  (mapcar (lambda (cells)
                                            (apply #'max 0
                                                   (mapcar #'pretty-tables--widest-image
                                                           (nth i cells))))
                                          data)))
                         (number-sequence 0 (1- ncols))))
         (prefixes (mapcar (lambda (row)
                             (funcall (or (plist-get pretty-tables--adaptor
                                                     :prefix)
                                          #'pretty-tables--prefix)
                                      (plist-get row :beg)))
                           rows))
         (alignments (let ((a (plist-get table :alignments)))
                       (mapcar (lambda (i) (or (nth i a) 'left))
                               (number-sequence 0 (1- ncols)))))
         (pretty-tables--line (pretty-tables--line-width ncols alignments))
         (widths (pretty-tables--column-widths
                  natural (pretty-tables--target-width
                           (apply #'max 0
                                  (mapcar (lambda (prefix)
                                            (cond
                                             ((string-empty-p prefix) 0)
                                             (pretty-tables--unit
                                              (string-pixel-width
                                               prefix (current-buffer)))
                                             (t (string-width prefix))))
                                          (seq-uniq prefixes))))
                  (mapcar (lambda (m) (and m (* m unit)))
                          (plist-get table :min-widths))
                  images
                  ;; The width of a row whose columns are 0 wide.
                  (pretty-tables--width
                   (pretty-tables--draw-row nil (make-list ncols 0) alignments))))
         (ndata (seq-count (lambda (row) (eq (plist-get row :kind) 'data))
                           rows))
         (table-face (plist-get pretty-tables--adaptor :face))
         (kinds (mapcar (lambda (row) (plist-get row :kind)) rows))
         (hidden (seq-mapn (lambda (previous kind)
                             (and (eq pretty-tables-borders 'lines)
                                  (eq kind 'separator)
                                  previous
                                  (not (eq previous 'separator))))
                           (cons nil kinds) kinds))
         (index -1))
    (seq-mapn
     (lambda (row cells hide underline prefix)
       (let* ((beg (plist-get row :beg))
              (end (plist-get row :end))
              (kind (plist-get row :kind))
              (string (cond
                       (hide "")
                       ((not (eq kind 'separator))
                        (pretty-tables--draw-row cells widths alignments))
                       ((eq pretty-tables-borders 'lines)
                        (pretty-tables--draw-rule widths))
                       (t (pretty-tables--separator widths alignments))))
              (ov (make-overlay beg
                                (if (and hide (eql (char-after end) ?\n))
                                    (1+ end)
                                  end)
                                nil t nil)))
         (when underline
           (pretty-tables--underline-last-line string)
           (pretty-tables--add-spacing end))
         (pcase kind
           ('data
            (setq index (1+ index))
            (pretty-tables--decorate-row string index (= index (1- ndata))))
           ('header
            (pretty-tables--add-line-face string 'pretty-tables-header-row)))
         (when table-face
           (add-face-text-property 0 (length string) table-face t string))
         (unless hide
           (add-text-properties 0 (length string)
                                (list 'keymap pretty-tables-row-map
                                      'pointer 'arrow
                                      'line-prefix prefix
                                      'wrap-prefix prefix)
                                string)
           ;; Point at the start of a drawn row shows the cursor at the
           ;; start of the string, not after it.
           (put-text-property 0 1 'cursor t string))
         (overlay-put ov 'pretty-tables t)
         (overlay-put ov 'pretty-tables-table bounds)
         (overlay-put ov 'pretty-tables-string string)
         (overlay-put ov 'evaporate t)
         (if (eql beg revealed)
             (setq pretty-tables--revealed ov)
           (pretty-tables--show-drawn ov t))))
     rows data hidden (append (cdr hidden) (list nil)) prefixes)))

(defun pretty-tables--note-change (beg end &optional _length)
  "Note in `pretty-tables--edited' a change of the text from BEG to END.
In `before-change-functions', BEG to END is the text about to be
replaced; in `after-change-functions', the new text.  When a row is
revealed, the change is `row' if the text lies on the row's line and
holds no newline, and `other' else; `other' stays until the table is
drawn."
  (let ((ov pretty-tables--revealed))
    (when (and ov (overlay-buffer ov))
      (setq pretty-tables--edited
            (if (and (not (eq pretty-tables--edited 'other))
                     (save-excursion
                       (goto-char (overlay-start ov))
                       (and (<= (pos-bol) beg) (<= end (pos-eol))))
                     (not (string-search "\n" (buffer-substring-no-properties
                                               beg end))))
                'row
              'other)))))

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
chunk.
When the buffer changed only on the line of the revealed row
\(`pretty-tables--edited' is `row'), as when typing in it, the table of
that row is not drawn: the row is shown as its text, and the other
rows keep their drawing until point leaves the row, when
`pretty-tables--reveal' has the table drawn with the widths of the new
text.  When BEG to END lies within that table, whose bounds are the
markers of the row overlays' `pretty-tables-table', the adaptor is not
asked for the tables."
  (cond
   (pretty-tables--rendering)
   ;; Typing in the revealed row: the adaptor is not asked for the
   ;; tables when BEG to END lies within the row's table.
   ((and (eq pretty-tables--edited 'row)
         pretty-tables--revealed
         (overlay-buffer pretty-tables--revealed)
         (let ((bounds (overlay-get pretty-tables--revealed
                                    'pretty-tables-table)))
           (and bounds (marker-position (car bounds))
                (<= (car bounds) beg) (<= end (cdr bounds))))))
   (t
    (save-restriction
      (unless font-lock-dont-widen (widen))
      (let* ((pretty-tables--rendering t)
             (pretty-tables--unit (and (display-graphic-p)
                                       (pretty-tables--column-pixels)))
             (pretty-tables--widths (make-hash-table :test #'eq :weakness 'key))
             (revealed (and pretty-tables--revealed
                            (overlay-start pretty-tables--revealed)))
             (tables (funcall (plist-get pretty-tables--adaptor :tables)
                              beg end))
             (holds-revealed (lambda (table)
                               (and revealed
                                    (<= (plist-get table :beg) revealed)
                                    (< revealed (plist-get table :end)))))
             ;; The table of the revealed row, when only that row changed.
             (kept (and (eq pretty-tables--edited 'row)
                        (seq-find holds-revealed tables))))
        (if (not kept)
            (pretty-tables--delete-overlays beg end)
          (when (< beg (plist-get kept :beg))
            (pretty-tables--delete-overlays beg (plist-get kept :beg)))
          (when (< (plist-get kept :end) end)
            (pretty-tables--delete-overlays (plist-get kept :end) end)))
        (dolist (table tables)
          (cond
           ((eq table kept))
           ((plist-get table :raw)
            (pretty-tables--delete-overlays (plist-get table :beg)
                                            (plist-get table :end)))
           (t
            (jit-lock-fontify-now (plist-get table :beg)
                                  (plist-get table :end))
            (pretty-tables--render-table table revealed)
            (when (funcall holds-revealed table)
              (setq pretty-tables--edited nil))))))))))

;;; Point and mouse

(defun pretty-tables--row-overlay-at-point ()
  "Return the row overlay on the line of point, or nil."
  (seq-find (lambda (ov) (overlay-get ov 'pretty-tables))
            (overlays-in (pos-bol) (pos-eol))))

(defun pretty-tables--reveal ()
  "Show the row point is on as raw text, and draw the one point left.
The row is shown as raw text when `pretty-tables-reveal' says so, or
during an Isearch.  After a command with a non-nil `scroll-command'
property, a row point moved onto stays drawn.  When the buffer
changed since the table of the row point left was drawn
\(`pretty-tables--edited'), that row's line is fontified again, and
`pretty-tables--fontify' draws its table with the new text."
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
      (cond
       (pretty-tables--edited
        (setq pretty-tables--edited nil)
        (if (and old (overlay-buffer old))
            (jit-lock-refontify (overlay-start old) (overlay-end old))
          (jit-lock-refontify)))
       ((and old (overlay-buffer old))
        (pretty-tables--show-drawn old t)))
      (when ov
        (pretty-tables--show-drawn ov nil))
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
                       (pretty-tables--position (car string) (cdr string)))
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
    pretty-tables-row-lines
    pretty-tables-borders
    pretty-tables-separator-spacing
    pretty-tables-image-spacing
    pretty-tables-image-spacing-factor)
  "Variables the drawing of a table depends on.
Setting one draws the tables again; see
`pretty-tables--option-changed'.")

(defun pretty-tables--option-changed (_symbol _value operation where)
  "Draw the tables again after an option of the drawing is set.
The options are `pretty-tables--options' and the `:options' of the
adaptors.
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

;; Added when the file loads, not by `pretty-tables-enable', so that
;; loading a new version of the file in a running Emacs watches the
;; options it adds, also in buffers where a mode is already on.
(dolist (option pretty-tables--options)
  (add-variable-watcher option #'pretty-tables--option-changed))

(defun pretty-tables--update-text-area ()
  "Update `pretty-tables--text-area' of the current buffer.
When it changes, draw the tables again: the text area bounds the width
of every table, see `pretty-tables-width'."
  (let ((width (pretty-tables--text-area-width)))
    (unless (eql width pretty-tables--text-area)
      (setq pretty-tables--text-area width)
      (jit-lock-refontify))))

(defun pretty-tables--windows-changed (_frame)
  "Update `pretty-tables--text-area' in every buffer an adaptor is on.
Runs from the default values of `window-size-change-functions' and
`window-buffer-change-functions'.  Their buffer-local values would not
run for a buffer when a window stops showing it, which can widen the
narrowest window that still does."
  (dolist (buffer (buffer-list))
    (when (buffer-local-value 'pretty-tables--adaptor buffer)
      (with-current-buffer buffer
        (pretty-tables--update-text-area)))))

(defun pretty-tables--redraw-all (&rest _)
  "Draw the tables of every buffer again.
Runs from `enable-theme-functions' and `disable-theme-functions': the
drawn rows hold the backgrounds `pretty-tables--row-face' read from
the theme, so a new theme shows only once the tables are drawn again.
Runs from `after-setting-font-hook' too: a table laid out in pixels is
measured in the frame's fonts."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when pretty-tables--adaptor
        (jit-lock-refontify)))))

(defun pretty-tables--check-remapping ()
  "Draw the tables again when the buffer's face remapping has changed.
A table laid out in pixels is measured in the buffer's faces, which
`text-scale-adjust', `buffer-face-mode' and `face-remap-add-relative'
change through `face-remapping-alist'.  `face-remap-add-relative'
changes the list in place when the face has an entry already, so no
variable watcher sees it: the list is compared with the copy in
`pretty-tables--remapping'.  Runs from `post-command-hook'."
  (unless (equal face-remapping-alist pretty-tables--remapping)
    (setq pretty-tables--remapping (copy-tree face-remapping-alist))
    (jit-lock-refontify)))

;;; Interface

(defun pretty-tables-enable (&rest adaptor)
  "Draw the tables of the current buffer with aligned, wrapped columns.
An adaptor calls this from its minor mode.  ADAPTOR is a plist:

`:tables'     A function called with BEG and END that returns each
              table overlapping BEG to END, as described below.
              Required.
`:separator'  A function called with the column WIDTHS and
              ALIGNMENTS that returns a new string drawing a
              separator row.  Not called when `pretty-tables-borders'
              is `lines'.  Required.
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
`:options'    A list of variables the adaptor's tables depend on.
              Setting one draws the tables again, as setting
              `pretty-tables-width' does.

A table is a plist with these properties:

`:beg', `:end'  The bounds of the table.
`:rows'         The rows, in buffer order.
`:alignments'   A list with an alignment per column: `left', `right'
                or `center'.  A column with none is `left'.
`:min-widths'   A list with a width or nil per column, or nil.  When
                the table is wider than `pretty-tables-width', the
                columns with a width are narrowed first, and none is
                narrowed below its width.
`:raw'         Non-nil to show the table as its text: it is not
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
  (setq pretty-tables--remapping (copy-tree face-remapping-alist))
  (add-hook 'post-command-hook #'pretty-tables--check-remapping nil t)
  (add-hook 'before-change-functions #'pretty-tables--note-change nil t)
  (add-hook 'after-change-functions #'pretty-tables--note-change nil t)
  (add-hook 'window-size-change-functions #'pretty-tables--windows-changed)
  (add-hook 'window-buffer-change-functions #'pretty-tables--windows-changed)
  (setq pretty-tables--text-area (pretty-tables--text-area-width))
  ;; `add-variable-watcher' adds a function only once.  The watchers
  ;; of `pretty-tables--options' are added when the file loads.
  (dolist (option (plist-get adaptor :options))
    (add-variable-watcher option #'pretty-tables--option-changed))
  (add-hook 'enable-theme-functions #'pretty-tables--redraw-all)
  (add-hook 'disable-theme-functions #'pretty-tables--redraw-all)
  (add-hook 'after-setting-font-hook #'pretty-tables--redraw-all)
  ;; Not `font-lock-flush', which does nothing in a buffer without
  ;; font-lock keywords; in a buffer with them, it calls this.
  (jit-lock-refontify))

(defun pretty-tables-disable ()
  "Stop drawing the tables of the current buffer, and show their text."
  (jit-lock-unregister #'pretty-tables--fontify)
  (remove-hook 'post-command-hook #'pretty-tables--reveal t)
  (remove-hook 'post-command-hook #'pretty-tables--check-remapping t)
  (remove-hook 'before-change-functions #'pretty-tables--note-change t)
  (remove-hook 'after-change-functions #'pretty-tables--note-change t)
  (pretty-tables--delete-overlays (point-min) (point-max))
  (setq pretty-tables--text-area nil
        pretty-tables--revealed nil
        pretty-tables--edited nil
        pretty-tables--adaptor nil)
  (font-lock-flush))

(defun pretty-tables-unload-function ()
  "Remove the variable watchers and the hooks the file added.
The watchers are those of `pretty-tables--options'.  Called by
`unload-feature'; nil means unloading continues."
  (dolist (option pretty-tables--options)
    (remove-variable-watcher option #'pretty-tables--option-changed))
  (remove-hook 'enable-theme-functions #'pretty-tables--redraw-all)
  (remove-hook 'disable-theme-functions #'pretty-tables--redraw-all)
  (remove-hook 'after-setting-font-hook #'pretty-tables--redraw-all)
  (remove-hook 'window-size-change-functions #'pretty-tables--windows-changed)
  (remove-hook 'window-buffer-change-functions #'pretty-tables--windows-changed)
  nil)

(provide 'pretty-tables)
;;; pretty-tables.el ends here
