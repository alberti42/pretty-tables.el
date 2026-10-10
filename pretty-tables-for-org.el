;;; pretty-tables-for-org.el --- Aligned, wrapped display of Org tables -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Andrea Alberti

;; Author: Andrea Alberti <a.alberti82@gmail.com>
;; Maintainer: Andrea Alberti <a.alberti82@gmail.com>
;; Assisted-by: Claude:claude-opus-5-5
;; URL: https://github.com/alberti42/pretty-tables.el
;; Version: 0.4.0
;; Package-Requires: ((emacs "31.1") (pretty-tables "0.4.0"))
;; Keywords: text, wp, convenience, outlines
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
;; `pretty-tables-for-org-mode' is a buffer-local minor mode for
;; `org-mode' that changes how Org tables are displayed and nothing
;; else.  The buffer text is never modified.  The drawing is done by
;; `pretty-tables'; this package finds the tables, their rows, their
;; cells and the alignment of their columns.
;;
;; `org-table-align' pads the cells in the buffer text, so a raw Org
;; table is already aligned.  The mode draws a table no wider than
;; `pretty-tables-width', with the cells word-wrapped, and column widths
;; come from the text a reader sees in each cell: the hidden part of a
;; link (`org-link-descriptive') takes no room.  Text hidden by folding
;; is read as if it were shown.
;;
;; A column is aligned as `org-table-align' aligns it: by the first
;; `<l>', `<r>' or `<c>' cookie in it, or else to the right when the
;; share of its non-empty cells that match `org-table-number-regexp' is
;; at least `org-table-number-fraction'.  A row of cookies is drawn as a
;; data row.  Columns that `org-table-shrink' narrows are read as they
;; are displayed, and the table is drawn again when a column is shrunk
;; or expanded; for that, the package advises `org-table-expand' and
;; `org-table--shrink-columns'.  The
;; rows above the first separator are the header
;; when a data row follows that separator.  Table.el tables are not
;; drawn, and neither is a table whose `#+ATTR_ORG' sets
;; `:pretty-tables' to nil:
;;
;;   #+ATTR_ORG: :pretty-tables nil
;;   | a | b |
;;
;; In a narrowed buffer with `font-lock-dont-widen' set, a table that
;; extends past the accessible portion is not drawn.
;;
;; The row point is on is shown as its raw text, so it can be edited.
;; In a read-only buffer it stays drawn, except during an Isearch;
;; `pretty-tables-reveal' changes that.  After a scroll command, a row point moved onto stays drawn until the
;; next command.  Clicking a character of a drawn row moves point to
;; that character in the buffer, and opens the link there with
;; `org-open-at-point' if there is one.

;;; Code:

(require 'org)
(require 'org-element)
(require 'org-fold)
(require 'org-table)
(require 'pretty-tables)

(declare-function org-export-read-attribute "ox"
                  (attribute element &optional property))

;;; Reading the buffer

(defun pretty-tables-for-org--row-cells (beg end)
  "Return the cells of the row from BEG to END as (BEG . END) pairs.
BEG is the first `|' of the row and END the end of its line.  The
bounds exclude the pipes.  The last `|' may be missing."
  (let (pipes cells)
    (save-excursion
      (goto-char beg)
      (while (search-forward "|" end t)
        (push (1- (point)) pipes)))
    (setq pipes (nreverse pipes))
    (unless (eql (car (last pipes)) (1- end))
      (setq pipes (append pipes (list end))))
    (while (cdr pipes)
      (push (cons (1+ (car pipes)) (cadr pipes)) cells)
      (setq pipes (cdr pipes)))
    (nreverse cells)))

(defun pretty-tables-for-org--alignments (rows)
  "Return the column alignments of the table whose rows are ROWS.
Each element is `left', `right' or `center'.  A column takes the
alignment of its first `<l>', `<r>' or `<c>' cookie; a column without
one is `right' when the share of its non-empty cells that match
`org-table-number-regexp' is at least `org-table-number-fraction', and
`left' otherwise.  This is the rule of `org-table-align'."
  (let* ((texts (mapcar (lambda (row)
                          (mapcar (lambda (cell)
                                    (string-trim (buffer-substring-no-properties
                                                  (car cell) (cdr cell))))
                                  (plist-get row :cells)))
                        (seq-remove (lambda (row)
                                      (eq (plist-get row :kind) 'separator))
                                    rows)))
         (ncols (apply #'max 0 (mapcar #'length texts))))
    (mapcar
     (lambda (i)
       (let ((numbers 0) (non-empty 0) cookie)
         (dolist (row texts)
           (let ((cell (or (nth i row) "")))
             (cond (cookie)
                   ((equal cell ""))
                   ((string-match "\\`<\\([lrc]\\)[0-9]*>\\'" cell)
                    (setq cookie (match-string 1 cell)))
                   (t
                    (setq non-empty (1+ non-empty))
                    (when (string-match-p org-table-number-regexp cell)
                      (setq numbers (1+ numbers)))))))
         (pcase cookie
           ("l" 'left)
           ("r" 'right)
           ("c" 'center)
           (_ (if (>= numbers (* org-table-number-fraction non-empty))
                  'right
                'left)))))
     (number-sequence 0 (1- ncols)))))

(defun pretty-tables-for-org-table (starts)
  "Return the Org table whose rows start at STARTS.
STARTS is the position of the first `|' of each row, in buffer order.
A row whose `|' is followed by `-' is a separator.  The rows above the
first separator are the header when a data row follows that
separator.  The value is a table as `pretty-tables-enable' describes
it, from the first row to the end of the last row's line.  An
adaptor of a buffer that shows Org tables outside `org-mode' can call
this."
  (let ((rows (mapcar (lambda (rbeg)
                        (let ((rend (save-excursion (goto-char rbeg) (pos-eol))))
                          (list :kind (if (eq (char-after (1+ rbeg)) ?-)
                                          'separator
                                        'data)
                                :beg rbeg
                                :end rend
                                :cells (pretty-tables-for-org--row-cells
                                        rbeg rend))))
                      starts)))
    ;; The rows above the first separator are the header when a data
    ;; row follows the separator.
    (let ((first (seq-position rows 'separator
                               (lambda (row kind) (eq (plist-get row :kind) kind)))))
      (when (and first
                 (seq-find (lambda (row) (eq (plist-get row :kind) 'data))
                           (nthcdr first rows)))
        (dotimes (i first)
          (plist-put (nth i rows) :kind 'header))))
    (list :beg (car starts)
          :end (plist-get (car (last rows)) :end)
          :alignments (pretty-tables-for-org--alignments rows)
          :rows rows)))

(defun pretty-tables-for-org--table (beg end)
  "Return the table whose rows lie from BEG to END.
BEG is the start of the first row's line and END the end of the last
row's.  The value is a table as `pretty-tables-enable' describes it."
  (let (starts)
    (save-excursion
      (goto-char beg)
      (while (< (point) end)
        (when (looking-at "[ \t]*|")
          (push (1- (match-end 0)) starts))
        (forward-line 1)))
    (pretty-tables-for-org-table (nreverse starts))))

(defun pretty-tables-for-org--raw-p (table)
  "Return non-nil when TABLE, an org-element table, is shown as its text.
That is when its `#+ATTR_ORG' sets `:pretty-tables' to nil."
  (when (org-element-property :attr_org table)
    (require 'ox)
    ;; The value nil is read as nil, as when the property is missing.
    (let ((attributes (org-export-read-attribute :attr_org table)))
      (and (plist-member attributes :pretty-tables)
           (null (plist-get attributes :pretty-tables))))))

(defun pretty-tables-for-org--tables (beg end)
  "Return the Org tables that overlap BEG to END.
Each is a table as `pretty-tables-enable' describes it.  Table.el
tables and lines starting with `|' that are not in a table, as in a
source block, are left out.  A table whose `#+ATTR_ORG' sets
`:pretty-tables' to nil is returned with `:raw' t, and so is a table
that extends past the accessible portion of a narrowed buffer, with
its bounds limited to that portion."
  (save-excursion
    (save-match-data
      (goto-char beg)
      (forward-line 0)
      (let (tables)
        (while (and (< (point) end)
                    (re-search-forward org-table-line-regexp end t))
          (let ((table (org-element-lineage (org-element-at-point) 'table t)))
            (if (and table (eq (org-element-property :type table) 'org))
                (let* ((tbeg (org-element-property :contents-begin table))
                       (tend (org-element-property :contents-end table))
                       (rend (if (eq (char-before tend) ?\n) (1- tend) tend)))
                  ;; `org-element' parses the whole buffer, so in a
                  ;; narrowed buffer a table can extend past
                  ;; `point-min' or `point-max', where its rows cannot
                  ;; be read.
                  (push (if (or (< tbeg (point-min))
                                (> rend (point-max))
                                (pretty-tables-for-org--raw-p table))
                            (list :beg (max tbeg (point-min))
                                  :end (min rend (point-max))
                                  :raw t)
                          (pretty-tables-for-org--table tbeg rend))
                        tables)
                  (goto-char tend))
              (forward-line 1))))
        (nreverse tables)))))

(defun pretty-tables-for-org--extend-region (start _end _old-len)
  "Refontify the first row of the table below a changed keyword line.
A change on a `#+' line, such as `#+ATTR_ORG', is refontified alone,
so a table under it would not be drawn again.  When the line START is
on, and the `#+' lines after it, are followed by a table, this extends
`jit-lock-end' to the end of the table's first line.  Runs from
`jit-lock-after-change-extend-region-functions'."
  (defvar jit-lock-end)
  (save-excursion
    (save-match-data
      (goto-char start)
      (forward-line 0)
      (when (looking-at-p "[ \t]*#\\+")
        (while (looking-at-p "[ \t]*#\\+")
          (forward-line 1))
        (when (looking-at-p org-table-line-regexp)
          (setq jit-lock-end (max jit-lock-end (pos-eol))))))))

(defun pretty-tables-for-org-draw-separator (widths _alignments)
  "Return the string drawing a separator row for the column WIDTHS."
  (concat "|"
          (mapconcat (lambda (w) (make-string (+ 2 w) ?-)) widths "+")
          "|"))

(defun pretty-tables-for-org--invisible-p (pos)
  "Return non-nil when the character at POS takes no room in a cell.
It is the value of `invisible-p', except that text hidden by folding
is read as if it were shown: a folded table is drawn too, and
unfolding it does not draw it again."
  (if (org-fold-folded-p pos)
      ;; `text-properties-at' leaves out the properties that
      ;; `char-property-alias-alist' makes `invisible' stand for, which
      ;; is how folds hide text.
      (invisible-p (plist-get (text-properties-at pos) 'invisible))
    (invisible-p pos)))

;;; Mode

;;;###autoload
(define-minor-mode pretty-tables-for-org-mode
  "Display Org tables with aligned, wrapped columns.
The buffer text is not changed.  The row point is on is shown as its
raw text when `pretty-tables-reveal' says so, except after a scroll
command moved point onto it."
  :lighter nil
  (if pretty-tables-for-org-mode
      (progn
        (add-hook 'jit-lock-after-change-extend-region-functions
                  #'pretty-tables-for-org--extend-region nil t)
        (pretty-tables-enable
         :tables #'pretty-tables-for-org--tables
         :separator #'pretty-tables-for-org-draw-separator
         :face 'org-table
         :invisible #'pretty-tables-for-org--invisible-p
         :follow #'org-open-at-point))
    (remove-hook 'jit-lock-after-change-extend-region-functions
                 #'pretty-tables-for-org--extend-region t)
    (pretty-tables-disable)))

;;; Shrunk columns

(defun pretty-tables-for-org--columns-expanded (&optional begin end)
  "Draw the table from BEGIN to END again after its columns are expanded.
BEGIN and END are the arguments of `org-table-expand', and nil means
the table at point.  An `:after' advice of `org-table-expand'."
  (when pretty-tables-for-org-mode
    (save-excursion
      (save-restriction
        (widen)
        (jit-lock-refontify (or begin (org-table-begin))
                            (or end (org-table-end)))))))

(defun pretty-tables-for-org--columns-shrunk (_columns beg end)
  "Draw the table from BEG to END again after columns are shrunk.
The arguments are those of `org-table--shrink-columns'.  An `:after'
advice of `org-table--shrink-columns'."
  (pretty-tables-for-org--columns-expanded beg end))

;; Shrinking or expanding a column adds or deletes overlays and does not
;; change the text, so jit-lock does not draw the table again, and Org
;; runs no hook.  These advices run only when columns are shrunk or
;; expanded; a check in `post-command-hook' would run after every
;; command.  An advice of `org-table-expand' alone is not enough:
;; `org-table--shrink-columns' calls `font-lock-ensure', which draws the
;; table before the columns are shrunk.  `org-table--shrink-columns' is
;; internal, but every command that shrinks columns calls it, including
;; those that edit a table with shrunk columns and shrink them again.
;; A CI job compares the two functions with a copy in
;; `test/fixtures/org-table-shrink.el' and reports a change.
(advice-add 'org-table-expand :after
            #'pretty-tables-for-org--columns-expanded)
(advice-add 'org-table--shrink-columns :after
            #'pretty-tables-for-org--columns-shrunk)

(defun pretty-tables-for-org-unload-function ()
  "Remove the advices of `org-table-expand' and `org-table--shrink-columns'.
Called by `unload-feature'; nil means unloading continues."
  (advice-remove 'org-table-expand #'pretty-tables-for-org--columns-expanded)
  (advice-remove 'org-table--shrink-columns
                 #'pretty-tables-for-org--columns-shrunk)
  nil)

(provide 'pretty-tables-for-org)
;;; pretty-tables-for-org.el ends here
