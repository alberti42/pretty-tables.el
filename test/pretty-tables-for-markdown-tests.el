;;; pretty-tables-for-markdown-tests.el --- Tests for pretty-tables-for-markdown -*- lexical-binding: t; -*-

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
;; Run with `make test'.  The tests that draw tables need the `markdown'
;; and `markdown-inline' tree-sitter grammars and are skipped without
;; them.  The drawing itself is tested in `pretty-tables-tests'.

;;; Code:

(require 'ert)
(require 'pretty-tables-for-markdown)
(require 'markdown-ts-mode)

;;; Helpers

(defmacro pretty-tables-for-markdown-tests--with-buffer (text &rest body)
  "Run BODY in a `markdown-ts-mode' buffer holding TEXT.
Font-lock and `pretty-tables-for-markdown-mode' are on, the table
width is 80, and point is at the start of the buffer."
  (declare (indent 1) (debug t))
  `(progn
     (skip-unless (and (treesit-language-available-p 'markdown)
                       (treesit-language-available-p 'markdown-inline)))
     (let ((buf (generate-new-buffer "pretty-tables-for-markdown-test")))
       (unwind-protect
           (with-current-buffer buf
             (insert ,text)
             (markdown-ts-mode)
             ;; `font-lock-mode' does not turn on in batch mode.
             (let ((noninteractive nil))
               (font-lock-mode 1))
             (setq-local pretty-tables-width 80)
             (pretty-tables-for-markdown-mode 1)
             (goto-char (point-min))
             (jit-lock-fontify-now)
             ,@body)
         (kill-buffer buf)))))

(defun pretty-tables-for-markdown-tests--overlays ()
  "Return the row overlays in the buffer, in buffer order."
  (sort (seq-filter (lambda (ov) (overlay-get ov 'pretty-tables))
                    (overlays-in (point-min) (point-max)))
        (lambda (a b) (< (overlay-start a) (overlay-start b)))))

(defun pretty-tables-for-markdown-tests--rows ()
  "Return the string drawing each row, without text properties."
  (mapcar (lambda (ov)
            (substring-no-properties (overlay-get ov 'pretty-tables-string)))
          (pretty-tables-for-markdown-tests--overlays)))

(defun pretty-tables-for-markdown-tests--hide-markup (value)
  "Set `markdown-ts-hide-markup' to VALUE and fontify the buffer again."
  (setq-local markdown-ts-hide-markup value)
  (markdown-ts--set-hide-markup value)
  (jit-lock-fontify-now))

(defconst pretty-tables-for-markdown-tests--link-table
  "# Title

| Name | Link |
|------|------|
| one | [Emacs](https://www.gnu.org/software/emacs/) |
| two | plain |

End.
"
  "A table whose second column holds a link.")

(defun pretty-tables-for-markdown-tests--row-face-p (face)
  "Return non-nil when FACE is a row face.
Without a background colour, as in a batch frame, the row face is a
symbol."
  (memq (if (consp face) (plist-get face :inherit) face)
        '(pretty-tables-row pretty-tables-stripe)))

;;; Finding tables

(ert-deftest pretty-tables-for-markdown-test-table-query ()
  "The table query is compiled and captures what the list query captures."
  (pretty-tables-for-markdown-tests--with-buffer
      "# Title\n\n| a | b |\n|---|---|\n| c | d |\n\nText.\n\n| e |\n|---|\n"
    (should (treesit-compiled-query-p pretty-tables-for-markdown--table-query))
    (let ((compiled (treesit-query-capture
                     'markdown pretty-tables-for-markdown--table-query))
          (listed (treesit-query-capture 'markdown '((pipe_table) @table))))
      (should (= (length compiled) 2))
      (should (equal compiled listed)))
    (should (equal (mapcar (lambda (table) (plist-get table :beg))
                           (pretty-tables-for-markdown--tables
                            (point-min) (point-max)))
                   (list (progn (goto-char (point-min))
                                (search-forward "| a")
                                (pos-bol))
                         (progn (search-forward "| e")
                                (pos-bol)))))))

;;; Drawing tables

(ert-deftest pretty-tables-for-markdown-test-draw-delimiter ()
  "The delimiter row shows each column's alignment."
  (should (equal (pretty-tables-for-markdown--draw-delimiter
                  '(3 4 5) '(left right center))
                 "|-----|-----:|:-----:|")))

(ert-deftest pretty-tables-for-markdown-test-draw-table ()
  "Columns are aligned to their widest cell."
  (pretty-tables-for-markdown-tests--with-buffer
      "# Title\n\n| a | bb |\n|---|---|\n| ccc | d |\n"
    (should (equal (pretty-tables-for-markdown-tests--rows)
                   '("| a   | bb |"
                     "|-----|----|"
                     "| ccc | d  |")))))

(ert-deftest pretty-tables-for-markdown-test-outer-pipes ()
  "A row may omit its outer pipes."
  (pretty-tables-for-markdown-tests--with-buffer
      "# Title\n\na | bb\n---|---\nccc | d\n"
    (should (equal (pretty-tables-for-markdown-tests--rows)
                   '("| a   | bb |"
                     "|-----|----|"
                     "| ccc | d  |")))))

(ert-deftest pretty-tables-for-markdown-test-alignment ()
  "The delimiter row sets each column's alignment."
  (pretty-tables-for-markdown-tests--with-buffer
      "# Title\n\n| a | b | c |\n|:--|--:|:-:|\n| xxxxx | yyyyy | zzzzz |\n"
    (should (equal (pretty-tables-for-markdown-tests--rows)
                   '("| a     |     b |   c   |"
                     "|-------|------:|:-----:|"
                     "| xxxxx | yyyyy | zzzzz |")))))

(ert-deftest pretty-tables-for-markdown-test-br ()
  "`<br>' starts a new line in a cell."
  (pretty-tables-for-markdown-tests--with-buffer
      "# Title\n\n| a | b |\n|---|---|\n| one<br>two | x |\n| three<BR/>four | y |\n"
    (should (equal (nthcdr 2 (pretty-tables-for-markdown-tests--rows))
                   '("| one   | x |\n| two   |   |"
                     "| three | y |\n| four  |   |")))))

(ert-deftest pretty-tables-for-markdown-test-hide-markup ()
  "Hidden link markup takes no room, and the table follows the toggle."
  (pretty-tables-for-markdown-tests--with-buffer
      pretty-tables-for-markdown-tests--link-table
    (pretty-tables-for-markdown-tests--hide-markup t)
    (should (equal (pretty-tables-for-markdown-tests--rows)
                   '("| Name | Link  |"
                     "|------|-------|"
                     "| one  | Emacs |"
                     "| two  | plain |")))
    (pretty-tables-for-markdown-tests--hide-markup nil)
    (should (equal (nth 2 (pretty-tables-for-markdown-tests--rows))
                   "| one  | [Emacs](https://www.gnu.org/software/emacs/) |"))))

(ert-deftest pretty-tables-for-markdown-test-partial-chunk ()
  "Fontifying part of a table draws the whole table from the buffer text.
The rows outside the region still have their overlays when the table
is read, as they do when jit-lock fontifies a window in chunks."
  (pretty-tables-for-markdown-tests--with-buffer
      pretty-tables-for-markdown-tests--link-table
    (let ((expected (pretty-tables-for-markdown-tests--rows))
          (last-row (overlay-start
                     (car (last (pretty-tables-for-markdown-tests--overlays))))))
      (font-lock-flush)
      (jit-lock-fontify-now last-row (point-max))
      (should (equal (pretty-tables-for-markdown-tests--rows) expected)))))

(ert-deftest pretty-tables-for-markdown-test-mode-off ()
  "Turning the mode off removes its overlays."
  (pretty-tables-for-markdown-tests--with-buffer
      pretty-tables-for-markdown-tests--link-table
    (should (pretty-tables-for-markdown-tests--overlays))
    (pretty-tables-for-markdown-mode -1)
    (should-not (pretty-tables-for-markdown-tests--overlays))))

(ert-deftest pretty-tables-for-markdown-test-stripes ()
  "Only the data rows get a row face; the header and delimiter get none."
  (pretty-tables-for-markdown-tests--with-buffer
      pretty-tables-for-markdown-tests--link-table
    (should (equal (mapcar (lambda (ov)
                             (let ((face (get-text-property
                                          2 'face (overlay-get ov 'pretty-tables-string))))
                               (and (seq-some
                                     #'pretty-tables-for-markdown-tests--row-face-p
                                     (ensure-list face))
                                    t)))
                           (pretty-tables-for-markdown-tests--overlays))
                   '(nil nil t t)))))

(ert-deftest pretty-tables-for-markdown-test-table-face ()
  "`markdown-ts-table' is the last face of every drawn row."
  (pretty-tables-for-markdown-tests--with-buffer
      pretty-tables-for-markdown-tests--link-table
    (dolist (ov (pretty-tables-for-markdown-tests--overlays))
      (let ((string (overlay-get ov 'pretty-tables-string)))
        (should (eq (car (last (ensure-list (get-text-property 0 'face string))))
                    'markdown-ts-table))))))

(ert-deftest pretty-tables-for-markdown-test-cell-faces ()
  "The faces `markdown-ts-mode' gives the cell text come before the row face."
  (pretty-tables-for-markdown-tests--with-buffer
      "# Title\n\n| a |\n|---|\n| x |\n| **b** |\n"
    (let* ((row (overlay-get (car (last (pretty-tables-for-markdown-tests--overlays)))
                             'pretty-tables-string))
           (face (get-text-property (string-search "b" row) 'face row))
           (row-face (seq-position
                      face nil
                      (lambda (f _)
                        (pretty-tables-for-markdown-tests--row-face-p f)))))
      (should row-face)
      (should (< (seq-position face 'markdown-ts-bold) row-face)))))

;;; Parsing cells

(defun pretty-tables-for-markdown-tests--cell-pos (text)
  "Return the position of the first occurrence of TEXT after the table header."
  (save-excursion
    (goto-char (point-min))
    (search-forward "|--")
    (search-forward text)
    (match-beginning 0)))

(ert-deftest pretty-tables-for-markdown-test-parse-cells ()
  "Links and emphasis in cells are fontified and their markup hidden."
  (pretty-tables-for-markdown-tests--with-buffer
      "# Title\n\n| a | b |\n|---|---|\n| **bold** | [Emacs](https://x.org) |\n"
    (should (get-text-property (pretty-tables-for-markdown-tests--cell-pos "Emacs")
                               'button))
    (pretty-tables-for-markdown-tests--hide-markup t)
    (should (equal (car (last (pretty-tables-for-markdown-tests--rows)))
                   "| bold | Emacs |"))))

(ert-deftest pretty-tables-for-markdown-test-cells-parsed-p ()
  "`markdown-ts-mode' alone does not run `markdown-inline' on cells."
  (pretty-tables-for-markdown-tests--with-buffer "# Title\n"
    (pretty-tables-for-markdown-mode -1)
    (should-not (pretty-tables-for-markdown--cells-parsed-p))
    (pretty-tables-for-markdown-mode 1)
    (should (pretty-tables-for-markdown--cells-parsed-p))))

(ert-deftest pretty-tables-for-markdown-test-parse-cells-installed ()
  "A rule that already parses cells is used, and the mode adds none.
The rule has the form a fixed `markdown-ts-mode' would install."
  (pretty-tables-for-markdown-tests--with-buffer
      "# Title\n\n| a | b |\n|---|---|\n| **bold** | [Emacs](https://x.org) |\n"
    (pretty-tables-for-markdown-mode -1)
    (setq-local treesit-range-settings
                (append treesit-range-settings
                        (treesit-range-rules
                         :embed 'markdown-inline
                         :host 'markdown
                         :local t
                         '([(inline) (pipe_table_cell)] @markdown-inline))))
    (let ((settings treesit-range-settings))
      (pretty-tables-for-markdown-mode 1)
      (should-not pretty-tables-for-markdown--range-settings)
      (should (eq treesit-range-settings settings))
      (pretty-tables-for-markdown-tests--hide-markup t)
      (should (equal (car (last (pretty-tables-for-markdown-tests--rows)))
                     "| bold | Emacs |"))
      (pretty-tables-for-markdown-mode -1)
      (should (eq treesit-range-settings settings))
      (should (treesit-local-parsers-at
               (pretty-tables-for-markdown-tests--cell-pos "Emacs")
               'markdown-inline)))))

(ert-deftest pretty-tables-for-markdown-test-parse-cells-mode-off ()
  "Turning the mode off removes the range rule and the cell parsers."
  (pretty-tables-for-markdown-tests--with-buffer
      "# Title\n\n| a | b |\n|---|---|\n| x | [Emacs](https://x.org) |\n\nA [link](https://y.org).\n"
    (let ((cell (pretty-tables-for-markdown-tests--cell-pos "Emacs"))
          (paragraph (pretty-tables-for-markdown-tests--cell-pos "link")))
      (should (treesit-local-parsers-at cell 'markdown-inline))
      (pretty-tables-for-markdown-mode -1)
      (jit-lock-fontify-now)
      (should-not pretty-tables-for-markdown--range-settings)
      (should-not (treesit-local-parsers-at cell 'markdown-inline))
      (should-not (get-text-property cell 'button))
      (should (treesit-local-parsers-at paragraph 'markdown-inline))
      (should (get-text-property paragraph 'button)))))

;;; Point

(ert-deftest pretty-tables-for-markdown-test-reveal ()
  "The row point is on is shown raw; the row point left is drawn again."
  (pretty-tables-for-markdown-tests--with-buffer
      pretty-tables-for-markdown-tests--link-table
    (let ((ovs (pretty-tables-for-markdown-tests--overlays))
          (this-command 'next-line))
      (goto-char (overlay-start (nth 2 ovs)))
      (pretty-tables--reveal)
      (should-not (overlay-get (nth 2 ovs) 'display))
      (goto-char (overlay-start (nth 3 ovs)))
      (pretty-tables--reveal)
      (should (overlay-get (nth 2 ovs) 'display))
      (should-not (overlay-get (nth 3 ovs) 'display)))))

(provide 'pretty-tables-for-markdown-tests)
;;; pretty-tables-for-markdown-tests.el ends here
