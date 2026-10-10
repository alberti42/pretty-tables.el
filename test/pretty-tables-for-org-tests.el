;;; pretty-tables-for-org-tests.el --- Tests for pretty-tables-for-org -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Andrea Alberti

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
;; Run with `make test'.  The drawing itself is tested in
;; `pretty-tables-tests'.

;;; Code:

(require 'ert)
(require 'pretty-tables-for-org)

;;; Helpers

(defmacro pretty-tables-for-org-tests--with-buffer (text &rest body)
  "Run BODY in an `org-mode' buffer holding TEXT.
Font-lock and `pretty-tables-for-org-mode' are on, the table width is
80, and point is at the start of the buffer."
  (declare (indent 1) (debug t))
  `(let ((buf (generate-new-buffer "pretty-tables-for-org-test")))
     (unwind-protect
         (with-current-buffer buf
           (insert ,text)
           (org-mode)
           ;; `font-lock-mode' does not turn on in batch mode.
           (let ((noninteractive nil))
             (font-lock-mode 1))
           (setq-local pretty-tables-width 80)
           (pretty-tables-for-org-mode 1)
           (goto-char (point-min))
           (jit-lock-fontify-now)
           ,@body)
       (kill-buffer buf))))

(defun pretty-tables-for-org-tests--overlays ()
  "Return the row overlays in the buffer, in buffer order."
  (sort (seq-filter (lambda (ov) (overlay-get ov 'pretty-tables))
                    (overlays-in (point-min) (point-max)))
        (lambda (a b) (< (overlay-start a) (overlay-start b)))))

(defun pretty-tables-for-org-tests--rows ()
  "Return the string drawing each row, without text properties."
  (mapcar (lambda (ov)
            (substring-no-properties (overlay-get ov 'pretty-tables-string)))
          (pretty-tables-for-org-tests--overlays)))

(defun pretty-tables-for-org-tests--striped ()
  "Return, for each drawn row, whether it has a row face."
  (mapcar (lambda (ov)
            (let ((face (get-text-property
                         2 'face (overlay-get ov 'pretty-tables-string))))
              ;; Without a background colour the row face is a symbol.
              (and (seq-some (lambda (f)
                               (memq (if (consp f) (plist-get f :inherit) f)
                                     '(pretty-tables-row pretty-tables-stripe)))
                             (ensure-list face))
                   t)))
          (pretty-tables-for-org-tests--overlays)))

;;; Drawing tables

(ert-deftest pretty-tables-for-org-test-draw-separator ()
  "A separator row joins the columns with `+'."
  (should (equal (pretty-tables-for-org-draw-separator '(3 1) '(left left))
                 "|-----+---|")))

(ert-deftest pretty-tables-for-org-test-draw-table ()
  "Columns are aligned to their widest cell."
  (pretty-tables-for-org-tests--with-buffer
      "* Title\n\n| a | bb |\n|---+---|\n| ccc | d |\n"
    (should (equal (pretty-tables-for-org-tests--rows)
                   '("| a   | bb |"
                     "|-----+----|"
                     "| ccc | d  |")))))

(ert-deftest pretty-tables-for-org-test-indented ()
  "The indentation before a row is not covered."
  (pretty-tables-for-org-tests--with-buffer
      "* Title\n\n  | a | bb |\n  | ccc | d |\n"
    (goto-char (overlay-start (car (pretty-tables-for-org-tests--overlays))))
    (should (eq (char-after) ?|))
    (should (equal (buffer-substring (pos-bol) (point)) "  "))))

(ert-deftest pretty-tables-for-org-test-missing-last-pipe ()
  "A row may omit its last pipe."
  (pretty-tables-for-org-tests--with-buffer
      "* Title\n\n| a | bb\n| ccc | d |\n"
    (should (equal (pretty-tables-for-org-tests--rows)
                   '("| a   | bb |"
                     "| ccc | d  |")))))

(ert-deftest pretty-tables-for-org-test-numbers-right ()
  "A column of numbers is aligned to the right, as `org-table-align' does."
  (pretty-tables-for-org-tests--with-buffer
      "* Title\n\n| name | n |\n|------+---|\n| x | 1 |\n| y | 100 |\n"
    (should (equal (pretty-tables-for-org-tests--rows)
                   '("| name |   n |"
                     "|------+-----|"
                     "| x    |   1 |"
                     "| y    | 100 |")))))

(ert-deftest pretty-tables-for-org-test-cookies ()
  "An alignment cookie sets the alignment of its column."
  (pretty-tables-for-org-tests--with-buffer
      "* Title\n\n| <c> | <l> |\n| a | 1 |\n| xxxxx | 2 |\n"
    (should (equal (pretty-tables-for-org-tests--rows)
                   '("|  <c>  | <l> |"
                     "|   a   | 1   |"
                     "| xxxxx | 2   |")))))

(ert-deftest pretty-tables-for-org-test-link ()
  "The hidden part of a link takes no room."
  (pretty-tables-for-org-tests--with-buffer
      "* Title\n\n| Name | Link |\n|---+---|\n| one | [[https://www.gnu.org/software/emacs/][Emacs]] |\n"
    (should (equal (pretty-tables-for-org-tests--rows)
                   '("| Name | Link  |"
                     "|------+-------|"
                     "| one  | Emacs |")))))

(ert-deftest pretty-tables-for-org-test-wrap-to-width ()
  "A table wider than `pretty-tables-width' is wrapped."
  (pretty-tables-for-org-tests--with-buffer
      "* Title\n\n| a | b |\n|---+---|\n| x | one two three four |\n"
    (setq-local pretty-tables-width 20)
    (jit-lock-fontify-now)
    (should (equal (pretty-tables-for-org-tests--rows)
                   '("| a | b            |"
                     "|---+--------------|"
                     "| x | one two      |\n|   | three four   |")))))

(ert-deftest pretty-tables-for-org-test-header ()
  "The rows above the first separator are the header and get no row face."
  (pretty-tables-for-org-tests--with-buffer
      "* Title\n\n| a |\n|---|\n| r0 |\n| r1 |\n|---|\n| r2 |\n"
    (should (equal (pretty-tables-for-org-tests--striped)
                   '(nil nil t t nil t)))))

(ert-deftest pretty-tables-for-org-test-no-header ()
  "Without a separator followed by a data row, every row is a data row."
  (pretty-tables-for-org-tests--with-buffer
      "* Title\n\n| r0 |\n| r1 |\n|---|\n"
    (should (equal (pretty-tables-for-org-tests--striped)
                   '(t t nil)))))

(ert-deftest pretty-tables-for-org-test-tblfm ()
  "A `#+TBLFM' line is not a row."
  (pretty-tables-for-org-tests--with-buffer
      "* Title\n\n| 1 | 2 |\n#+TBLFM: $2=$1+1\n"
    (should (equal (pretty-tables-for-org-tests--rows) '("| 1 | 2 |")))))

(ert-deftest pretty-tables-for-org-test-not-tables ()
  "Table.el tables and lines in a source block are not drawn."
  (pretty-tables-for-org-tests--with-buffer
      "* Title

+---+----+
| a | bb |
+---+----+

#+begin_src text
| a | bb |
#+end_src

| x | yy |
"
    (should (equal (pretty-tables-for-org-tests--rows) '("| x | yy |")))))

(ert-deftest pretty-tables-for-org-test-folded ()
  "A table drawn while folded has the widths of its text."
  (pretty-tables-for-org-tests--with-buffer
      "* Title\n| Name | Link |\n|---+---|\n| one | [[https://x.org][Emacs]] |\n* Next\n"
    (org-fold-hide-subtree)
    (should (org-fold-folded-p (overlay-start
                                (car (pretty-tables-for-org-tests--overlays)))))
    (font-lock-flush)
    (jit-lock-fontify-now)
    (should (equal (pretty-tables-for-org-tests--rows)
                   '("| Name | Link  |"
                     "|------+-------|"
                     "| one  | Emacs |")))))

(ert-deftest pretty-tables-for-org-test-shrink ()
  "Shrinking or expanding a column draws the table again."
  (pretty-tables-for-org-tests--with-buffer
      "* Title\n\n| <5> | b |\n| hello wide world | xyz |\n"
    (search-forward "|")
    (org-table-shrink)
    (jit-lock-fontify-now)
    (should (equal (pretty-tables-for-org-tests--rows)
                   '("| <5>  … | b   |"
                     "| hello… | xyz |")))
    (org-table-toggle-column-width "2")
    (jit-lock-fontify-now)
    (should (equal (pretty-tables-for-org-tests--rows)
                   '("| <5>  … | … |"
                     "| hello… | … |")))
    (org-table-expand)
    (jit-lock-fontify-now)
    (should (equal (pretty-tables-for-org-tests--rows)
                   '("| <5>              | b   |"
                     "| hello wide world | xyz |")))))

(ert-deftest pretty-tables-for-org-test-shrink-edit ()
  "Editing a table with shrunk columns draws them shrunk."
  (pretty-tables-for-org-tests--with-buffer
      "* Title\n\n| <5> | b |\n| hello wide world | xyz |\n"
    (search-forward "|")
    (org-table-shrink)
    (search-forward "b")
    (org-table-insert-column)
    (jit-lock-fontify-now)
    (should (equal (pretty-tables-for-org-tests--rows)
                   '("| <5>  … |   | b   |"
                     "| hello… |   | xyz |")))))

(ert-deftest pretty-tables-for-org-test-table-face ()
  "`org-table' is the last face of every drawn row."
  (pretty-tables-for-org-tests--with-buffer
      "* Title\n\n| a | bb |\n|---+---|\n| ccc | d |\n"
    (dolist (ov (pretty-tables-for-org-tests--overlays))
      (let ((string (overlay-get ov 'pretty-tables-string)))
        (should (eq (car (last (ensure-list (get-text-property 0 'face string))))
                    'org-table))))))

(ert-deftest pretty-tables-for-org-test-edit ()
  "Editing a row draws the table again from the new text."
  (pretty-tables-for-org-tests--with-buffer
      "* Title\n\n| a | bb |\n| ccc | d |\n"
    (goto-char (point-min))
    (search-forward "d")
    (insert "ddddd")
    (jit-lock-fontify-now)
    (should (equal (pretty-tables-for-org-tests--rows)
                   '("| a   | bb     |"
                     "| ccc | dddddd |")))))

(ert-deftest pretty-tables-for-org-test-mode-off ()
  "Turning the mode off removes its overlays."
  (pretty-tables-for-org-tests--with-buffer
      "* Title\n\n| a | bb |\n| ccc | d |\n"
    (should (pretty-tables-for-org-tests--overlays))
    (pretty-tables-for-org-mode -1)
    (should-not (pretty-tables-for-org-tests--overlays))
    (should-not pretty-tables--adaptor)))

(ert-deftest pretty-tables-for-org-test-attribute-raw ()
  "A table whose `#+ATTR_ORG' sets `:pretty-tables' to nil is not drawn."
  (pretty-tables-for-org-tests--with-buffer
      "* Title\n\n#+ATTR_ORG: :pretty-tables nil\n| a | bb |\n\n| c | d |\n"
    (should (equal (pretty-tables-for-org-tests--rows) '("| c | d |")))))

(ert-deftest pretty-tables-for-org-test-attribute-other ()
  "A table is drawn when `#+ATTR_ORG' does not set `:pretty-tables' to nil."
  (dolist (attribute '("#+ATTR_ORG: :width 30\n"
                       "#+ATTR_ORG: :pretty-tables t\n"))
    (pretty-tables-for-org-tests--with-buffer
        (concat "* Title\n\n" attribute "| a | bb |\n")
      (should (equal (pretty-tables-for-org-tests--rows) '("| a | bb |"))))))

(ert-deftest pretty-tables-for-org-test-attribute-edit ()
  "Adding the attribute shows the table as text; removing it draws it."
  (pretty-tables-for-org-tests--with-buffer
      "* Title\n\n| a | bb |\n| ccc | d |\n"
    (should (pretty-tables-for-org-tests--overlays))
    (goto-char (point-min))
    (search-forward "\n\n")
    (insert "#+ATTR_ORG: :pretty-tables nil\n")
    (jit-lock-fontify-now)
    (should-not (pretty-tables-for-org-tests--overlays))
    (delete-region (pos-bol 0) (point))
    (jit-lock-fontify-now)
    (should (equal (length (pretty-tables-for-org-tests--overlays)) 2))))

(ert-deftest pretty-tables-for-org-test-attribute-change ()
  "Changing the value of the attribute draws the table again."
  (pretty-tables-for-org-tests--with-buffer
      "* Title\n\n#+ATTR_ORG: :pretty-tables nil\n| a | bb |\n| ccc | d |\n"
    (should-not (pretty-tables-for-org-tests--overlays))
    (goto-char (point-min))
    (search-forward ":pretty-tables ")
    (delete-char 3)
    (insert "t")
    (jit-lock-fontify-now)
    (should (equal (length (pretty-tables-for-org-tests--overlays)) 2))
    (delete-char -1)
    (insert "nil")
    (jit-lock-fontify-now)
    (should-not (pretty-tables-for-org-tests--overlays))))

(defun pretty-tables-for-org-tests--narrow-into-table (edge)
  "Narrow the buffer so that its EDGE, `start' or `end', cuts the table.
The table's separator row is the last line kept or the first."
  (goto-char (point-min))
  (search-forward "|---")
  (if (eq edge 'end)
      (narrow-to-region (point-min) (pos-eol))
    (narrow-to-region (pos-bol) (point-max))))

(ert-deftest pretty-tables-for-org-test-narrowed ()
  "A table cut by narrowing is drawn whole."
  (dolist (edge '(start end))
    (pretty-tables-for-org-tests--with-buffer
        "* Title\n\n| a | bb |\n|---+---|\n| ccc | d |\n\nText\n"
      (pretty-tables-for-org-tests--narrow-into-table edge)
      (font-lock-flush)
      (jit-lock-fontify-now)
      (widen)
      (should (equal (pretty-tables-for-org-tests--rows)
                     '("| a   | bb |"
                       "|-----+----|"
                       "| ccc | d  |"))))))

(ert-deftest pretty-tables-for-org-test-narrowed-dont-widen ()
  "With `font-lock-dont-widen', a table cut by narrowing is not drawn."
  (dolist (edge '(start end))
    (pretty-tables-for-org-tests--with-buffer
        "* Title\n\n| a | bb |\n|---+---|\n| ccc | d |\n\nText\n"
      (setq-local font-lock-dont-widen t)
      (pretty-tables-for-org-tests--narrow-into-table edge)
      (font-lock-flush)
      (jit-lock-fontify-now)
      (should-not (pretty-tables-for-org-tests--overlays)))))

;;; Tables outside `org-mode'

(ert-deftest pretty-tables-for-org-test-table-from-starts ()
  "`pretty-tables-for-org-table' reads a table from its row starts.
The buffer is not in `org-mode', and text precedes each row."
  (with-temp-buffer
    (insert "> | a | b |\n> |---+---|\n> | 1 | x |\n")
    (let* ((table (pretty-tables-for-org-table '(3 15 27)))
           (rows (plist-get table :rows)))
      (should (equal (plist-get table :beg) 3))
      (should (equal (plist-get table :end) 36))
      (should (equal (mapcar (lambda (row) (plist-get row :kind)) rows)
                     '(header separator data)))
      (should (equal (plist-get (nth 2 rows) :cells) '((28 . 31) (32 . 35))))
      (should (equal (plist-get table :alignments) '(right left))))))

(provide 'pretty-tables-for-org-tests)
;;; pretty-tables-for-org-tests.el ends here
