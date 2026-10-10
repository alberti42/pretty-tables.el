;;; pretty-tables-for-markdown.el --- Aligned, wrapped display of Markdown tables -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-5-5
;; URL: https://github.com/alberti42/pretty-tables.el
;; Version: 0.5.0
;; Package-Requires: ((emacs "31.1") (pretty-tables "0.5.0"))
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
;; `pretty-tables-for-markdown-mode' is a buffer-local minor mode for
;; `markdown-ts-mode' that changes how pipe tables are displayed and
;; nothing else.  The buffer text is never modified.  The drawing is
;; done by `pretty-tables'; this package finds the tables, their rows,
;; their cells and the alignment of their columns.
;;
;; `markdown-ts-mode' runs the `markdown-inline' grammar only on
;; `inline' nodes, and a table cell is not one, so links, emphasis and
;; code in a cell are not fontified and their markup is not hidden.
;; While the mode is on, it runs the grammar on table cells too, and
;; `markdown-ts-mode' fontifies them as it fontifies a paragraph.  The
;; mode adds this rule only when `treesit-range-settings' does not
;; already run the grammar on table cells.
;;
;; Column widths come from the text a reader sees in each cell:
;; characters that are invisible (for example link markup hidden by
;; `markdown-ts-hide-markup') take no room.  `<br>' in a cell starts a
;; new line.  The options of the drawing are those of `pretty-tables':
;; `pretty-tables-width', `pretty-tables-min-column-width',
;; `pretty-tables-stripe-rows' and `pretty-tables-row-lines'.
;;
;; The row point is on is shown as its raw text, so it can be edited and
;; its links followed with RET.  In a read-only buffer it stays drawn,
;; except during an Isearch; `pretty-tables-reveal' changes that.
;; After a scroll command, a row point
;; moved onto stays drawn until the next command.  Clicking a character
;; of a drawn row moves point to that character in the buffer, and
;; follows the link there if there is one.

;;; Code:

(require 'treesit)
(require 'pretty-tables)

(defvar-local pretty-tables-for-markdown--range-settings nil
  "The entries this mode added to `treesit-range-settings', or nil.")

;;; Reading the buffer

(defun pretty-tables-for-markdown--row-end (row)
  "Return the end of table ROW on its first line."
  (min (treesit-node-end row)
       (save-excursion (goto-char (treesit-node-start row)) (pos-eol))))

(defun pretty-tables-for-markdown--row-cells (row)
  "Return the cells of table ROW as a list of (BEG . END) pairs.
The bounds exclude the pipes.  A row may omit its outer pipes."
  (let* ((beg (treesit-node-start row))
         (end (pretty-tables-for-markdown--row-end row))
         (pipes (mapcar #'treesit-node-start
                        (seq-filter (lambda (n) (equal (treesit-node-type n) "|"))
                                    (treesit-node-children row))))
         (bounds (append (unless (eql (car pipes) beg) (list (1- beg)))
                         pipes
                         (unless (eql (car (last pipes)) (1- end)) (list end))))
         cells)
    (while (cdr bounds)
      (push (cons (1+ (car bounds)) (cadr bounds)) cells)
      (setq bounds (cdr bounds)))
    (nreverse cells)))

(defun pretty-tables-for-markdown--alignments (row)
  "Return the column alignments declared by delimiter ROW.
Each element is `left', `right' or `center'."
  (mapcar (lambda (cell)
            (let ((text (string-trim (buffer-substring-no-properties
                                      (car cell) (cdr cell)))))
              (cond ((and (string-prefix-p ":" text) (string-suffix-p ":" text)
                          (> (length text) 1))
                     'center)
                    ((string-suffix-p ":" text) 'right)
                    (t 'left))))
          (pretty-tables-for-markdown--row-cells row)))

(defun pretty-tables-for-markdown--table (table)
  "Return the `pipe_table' node TABLE as `pretty-tables-enable' describes it."
  (let* ((rows (seq-filter
                (lambda (n) (member (treesit-node-type n)
                                    '("pipe_table_header"
                                      "pipe_table_delimiter_row"
                                      "pipe_table_row")))
                (treesit-node-children table)))
         (delimiter (seq-find (lambda (n) (equal (treesit-node-type n)
                                                 "pipe_table_delimiter_row"))
                              rows)))
    (list :beg (treesit-node-start table)
          :end (treesit-node-end table)
          :alignments (and delimiter
                           (pretty-tables-for-markdown--alignments delimiter))
          :rows (mapcar
                 (lambda (row)
                   (list :kind (pcase (treesit-node-type row)
                                 ("pipe_table_header" 'header)
                                 ("pipe_table_delimiter_row" 'separator)
                                 (_ 'data))
                         :beg (treesit-node-start row)
                         :end (pretty-tables-for-markdown--row-end row)
                         :cells (unless (eq row delimiter)
                                  (pretty-tables-for-markdown--row-cells row))))
                 rows))))

(defun pretty-tables-for-markdown--tables (beg end)
  "Return the pipe tables that overlap BEG to END.
Each is a table as `pretty-tables-enable' describes it."
  (when (treesit-parser-list nil 'markdown)
    (mapcar #'pretty-tables-for-markdown--table
            (treesit-query-capture 'markdown '((pipe_table) @table)
                                   beg end t))))

(defun pretty-tables-for-markdown--draw-delimiter (widths alignments)
  "Return the string drawing the delimiter row for WIDTHS and ALIGNMENTS."
  (concat "|"
          (mapconcat
           (lambda (i)
             (let ((dashes (make-string (+ 2 (nth i widths)) ?-)))
               (pcase (nth i alignments)
                 ('right (aset dashes (1- (length dashes)) ?:))
                 ('center (aset dashes 0 ?:)
                          (aset dashes (1- (length dashes)) ?:)))
               (concat dashes "|")))
           (number-sequence 0 (1- (length widths))))))

;;; Parsing cells

(defun pretty-tables-for-markdown--cells-parsed-p ()
  "Return non-nil when `treesit-range-settings' runs `markdown-inline' on cells.
A compiled query cannot be read back, so each query that embeds
`markdown-inline' is run on a small table in a temporary buffer, and
the value is non-nil when one of them captures a `pipe_table_cell'."
  (when-let* ((queries (seq-keep (lambda (setting)
                                   (and (eq (nth 1 setting) 'markdown-inline)
                                        (car setting)))
                                 treesit-range-settings)))
    (with-temp-buffer
      (insert "| a |\n|---|\n| b |\n")
      (let ((root (treesit-parser-root-node (treesit-parser-create 'markdown))))
        (seq-some (lambda (query)
                    (seq-some (lambda (capture)
                                (equal (treesit-node-type (cdr capture))
                                       "pipe_table_cell"))
                              (treesit-query-capture root query)))
                  queries)))))

(defun pretty-tables-for-markdown--parse-cells (on)
  "Run the `markdown-inline' grammar on table cells if ON is non-nil.
The rule is added only when `pretty-tables-for-markdown--cells-parsed-p'
is nil.  When ON is nil, remove the rule this mode added and delete the
parsers made for the cells."
  (when pretty-tables-for-markdown--range-settings
    (setq-local treesit-range-settings
                (seq-difference treesit-range-settings
                                pretty-tables-for-markdown--range-settings #'eq))
    (setq pretty-tables-for-markdown--range-settings nil)
    ;; treesit deletes a local parser it no longer needs only after the
    ;; buffer is modified.
    (dolist (ov (overlays-in (point-min) (point-max)))
      (let ((parser (overlay-get ov 'treesit-parser)))
        (when (and parser
                   (overlay-get ov 'treesit-parser-local-p)
                   (eq (treesit-parser-language parser) 'markdown-inline)
                   (treesit-parent-until
                    (treesit-node-at (overlay-start ov) 'markdown)
                    "\\`pipe_table_cell\\'" t))
          (treesit-parser-delete parser)
          (delete-overlay ov)))))
  (when (and on
             (treesit-parser-list nil 'markdown)
             (treesit-language-available-p 'markdown-inline)
             (not (pretty-tables-for-markdown--cells-parsed-p)))
    (setq pretty-tables-for-markdown--range-settings
          (treesit-range-rules
           :embed 'markdown-inline
           :host 'markdown
           :local t
           '((pipe_table_cell) @markdown-inline)))
    (setq-local treesit-range-settings
                (append treesit-range-settings
                        pretty-tables-for-markdown--range-settings))))

;;; Mode

;;;###autoload
(define-minor-mode pretty-tables-for-markdown-mode
  "Display Markdown pipe tables with aligned, wrapped columns.
The buffer text is not changed.  The row point is on is shown as its
raw text when `pretty-tables-reveal' says so, except after a scroll
command moved point onto it.
Table cells are parsed as inline Markdown, so their links, emphasis and
code are fontified."
  :lighter nil
  (cond
   (pretty-tables-for-markdown-mode
    (pretty-tables-for-markdown--parse-cells t)
    (pretty-tables-enable
     :tables #'pretty-tables-for-markdown--tables
     :separator #'pretty-tables-for-markdown--draw-delimiter
     :line-break "<br[ \t]*/?>"
     :face 'markdown-ts-table))
   (t
    (pretty-tables-for-markdown--parse-cells nil)
    (pretty-tables-disable))))

(provide 'pretty-tables-for-markdown)
;;; pretty-tables-for-markdown.el ends here
