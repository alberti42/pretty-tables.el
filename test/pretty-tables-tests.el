;;; pretty-tables-tests.el --- Tests for pretty-tables -*- lexical-binding: t; -*-

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
;; Run with `make test'.  The tests that draw tables use a test adaptor,
;; `pretty-tables-tests-mode': a table is a run of lines starting with
;; `|', a line starting with `|-' is a separator, and font-lock hides
;; text between braces and makes text between stars bold.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'pretty-tables)

;;; The test adaptor

(defconst pretty-tables-tests--keywords
  '(("{[^}\n]*}" 0 '(face nil invisible t))
    ("\\*\\([^*\n]+\\)\\*" (1 'bold)))
  "Font-lock keywords of `pretty-tables-tests-mode'.")

(define-derived-mode pretty-tables-tests-mode text-mode "PT-Test"
  "Major mode whose tables the test adaptor finds."
  (setq-local font-lock-defaults '(pretty-tables-tests--keywords t))
  (setq-local font-lock-extra-managed-props '(invisible)))

(defun pretty-tables-tests--row-cells (beg end)
  "Return the cells of the row from BEG to END as (BEG . END) pairs."
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

(defun pretty-tables-tests--tables (beg end)
  "Return the tables that overlap BEG to END."
  (save-excursion
    (goto-char beg)
    (forward-line 0)
    (while (and (looking-at-p "[ \t]*|") (not (bobp)))
      (forward-line -1))
    (let (tables)
      (while (and (< (point) end) (not (eobp)))
        (if (not (looking-at-p "[ \t]*|"))
            (forward-line 1)
          (let ((tbeg (point)) rows)
            (while (looking-at "[ \t]*\\(|\\)\\(-\\)?")
              (let ((rbeg (match-beginning 1)))
                (push (list :kind (if (match-beginning 2) 'separator 'data)
                            :beg rbeg :end (pos-eol)
                            :cells (pretty-tables-tests--row-cells
                                    rbeg (pos-eol)))
                      rows))
              (forward-line 1))
            (setq rows (nreverse rows))
            ;; The rows before the first separator are the header.
            (when (seq-find (lambda (r) (eq (plist-get r :kind) 'separator)) rows)
              (seq-do (lambda (r) (plist-put r :kind 'header))
                      (seq-take-while
                       (lambda (r) (not (eq (plist-get r :kind) 'separator)))
                       rows)))
            (push (list :beg tbeg :end (point) :rows rows) tables))))
      (nreverse tables))))

(defun pretty-tables-tests--separator (widths _alignments)
  "Return a separator row for the column WIDTHS."
  (concat "|" (mapconcat (lambda (w) (concat (make-string (+ 2 w) ?-) "|"))
                         widths)))

(defmacro pretty-tables-tests--with-buffer (text &rest body)
  "Run BODY in a `pretty-tables-tests-mode' buffer holding TEXT.
Font-lock and the test adaptor are on, the table width is 80, and
point is at the start of the buffer."
  (declare (indent 1) (debug t))
  `(let ((buf (generate-new-buffer "pretty-tables-test")))
     (unwind-protect
         (with-current-buffer buf
           (insert ,text)
           (pretty-tables-tests-mode)
           ;; `font-lock-mode' does not turn on in batch mode.
           (let ((noninteractive nil))
             (font-lock-mode 1))
           (setq-local pretty-tables-width 80)
           (pretty-tables-enable :tables #'pretty-tables-tests--tables
                                 :separator #'pretty-tables-tests--separator
                                 :line-break "<br>")
           (goto-char (point-min))
           (jit-lock-fontify-now)
           ,@body)
       (kill-buffer buf))))

(defun pretty-tables-tests--overlays ()
  "Return the row overlays in the buffer, in buffer order."
  (sort (seq-filter (lambda (ov) (overlay-get ov 'pretty-tables))
                    (overlays-in (point-min) (point-max)))
        (lambda (a b) (< (overlay-start a) (overlay-start b)))))

(defun pretty-tables-tests--rows ()
  "Return the string drawing each row, without text properties."
  (mapcar (lambda (ov)
            (substring-no-properties (overlay-get ov 'pretty-tables-string)))
          (pretty-tables-tests--overlays)))

(defun pretty-tables-tests--row-strings ()
  "Return the string drawing each row, with its text properties."
  (mapcar (lambda (ov) (overlay-get ov 'pretty-tables-string))
          (pretty-tables-tests--overlays)))

(defun pretty-tables-tests--goto-row (n)
  "Move point to the start of table row N, counting from 0."
  (goto-char (overlay-start (nth n (pretty-tables-tests--overlays)))))

(defconst pretty-tables-tests--hidden-table
  "Title

| Name | Link |
|------|------|
| one | {https://x.org}Emacs |
| two | plain |

End.
"
  "A table whose second column holds text hidden by font-lock.")

(defconst pretty-tables-tests--four-rows
  "Title\n\n| a | b |\n|---|---|\n| r0 | x |\n| r1 | y |\n| r2 | z<br>w |\n| r3 | v |\n"
  "A table with four data rows; the third is two screen lines tall.")

;;; Layout

(ert-deftest pretty-tables-test-column-widths-fit ()
  "Widths that fit the target are returned unchanged."
  (should (equal (pretty-tables--column-widths '(10 20 5) 80)
                 '(10 20 5))))

(ert-deftest pretty-tables-test-column-widths-narrow ()
  "The widest column is narrowed until the table fits."
  ;; 3 columns take 10 columns of pipes and spaces, leaving 30.
  (should (equal (pretty-tables--column-widths '(10 30 5) 40)
                 '(10 15 5))))

(ert-deftest pretty-tables-test-column-widths-floor ()
  "No column is narrowed below `pretty-tables-min-column-width'."
  (let ((pretty-tables-min-column-width 8))
    (should (equal (pretty-tables--column-widths '(10 30 5) 30)
                   '(8 8 5)))))

(ert-deftest pretty-tables-test-column-widths-minimums ()
  "Columns with a minimum are narrowed first, and not below it."
  ;; 2 columns take 7 columns of pipes and spaces.
  (let ((pretty-tables-min-column-width 8))
    (dolist (case '((100 (30 50)) (70 (30 33)) (60 (30 23)) (40 (13 20))
                    (20 (8 20))))
      (should (equal (pretty-tables--column-widths '(30 50) (car case)
                                                   '(nil 20))
                     (cadr case))))
    ;; A minimum below `pretty-tables-min-column-width' is the floor.
    (should (equal (pretty-tables--column-widths '(30 50) 20 '(nil 5))
                   '(8 5)))
    ;; A column narrower than its minimum keeps its width.
    (should (equal (pretty-tables--column-widths '(30 10) 20 '(nil 20))
                   '(8 10)))))

(ert-deftest pretty-tables-test-break-word ()
  "A word is split into pieces no wider than the width."
  (should (equal (pretty-tables--break-word "abcdefgh" 3)
                 '("abc" "def" "gh")))
  (should (equal (pretty-tables--break-word "日本語" 4)
                 '("日本" "語"))))

(ert-deftest pretty-tables-test-wrap ()
  "A paragraph is word-wrapped, and a word wider than the width is broken."
  (should (equal (pretty-tables--wrap "the quick brown fox" 9)
                 '("the quick" "brown fox")))
  (should (equal (pretty-tables--wrap "a abcdefghij b" 4)
                 '("a" "abcd" "efgh" "ij b")))
  (should (equal (pretty-tables--wrap "" 4) '(""))))

(ert-deftest pretty-tables-test-wrap-keeps-properties ()
  "Wrapped lines keep the text properties of the paragraph."
  (let* ((paragraph (concat "aaa " (propertize "bbb" 'face 'bold)))
         (lines (pretty-tables--wrap paragraph 3)))
    (should (equal lines '("aaa" "bbb")))
    (should (eq (get-text-property 0 'face (nth 1 lines)) 'bold))))

(ert-deftest pretty-tables-test-pad ()
  "Text is padded to the width according to the alignment."
  (should (equal (pretty-tables--pad "ab" 6 'left) "ab    "))
  (should (equal (pretty-tables--pad "ab" 6 'right) "    ab"))
  (should (equal (pretty-tables--pad "ab" 6 'center) "  ab  "))
  (should (equal (pretty-tables--pad "abcdef" 4 'left) "abcdef")))

(ert-deftest pretty-tables-test-draw-row ()
  "A row is as tall as its tallest cell."
  (should (equal (pretty-tables--draw-row
                  '(("a") ("b" "c")) '(3 3) '(left right))
                 "| a   |   b |\n|     |   c |")))

;;; Reading the buffer

(ert-deftest pretty-tables-test-visible-string ()
  "The text is read as it is displayed."
  (with-temp-buffer
    (insert "abcdef")
    (put-text-property 2 3 'invisible t)
    (put-text-property 3 4 'display "XY")
    (put-text-property 4 5 'display '(space :width 3))
    (let ((s (pretty-tables--visible-string 1 7)))
      (should (equal (substring-no-properties s) "aXY   ef"))
      (should (equal (mapcar (lambda (i)
                               (get-text-property i 'pretty-tables-pos s))
                             (number-sequence 0 (1- (length s))))
                     '(1 3 3 4 4 4 5 6))))))

(ert-deftest pretty-tables-test-visible-string-adaptor-invisible ()
  "The adaptor's `:invisible' function decides what takes no room."
  (with-temp-buffer
    (insert "abcdef")
    (put-text-property 2 3 'invisible 'shown)
    (put-text-property 3 4 'invisible 'hidden)
    (setq-local pretty-tables--adaptor
                (list :invisible (lambda (pos)
                                   (eq (get-char-property pos 'invisible)
                                       'hidden))))
    (should (equal (substring-no-properties
                    (pretty-tables--visible-string 1 7))
                   "abdef"))))

(ert-deftest pretty-tables-test-visible-string-under-overlay ()
  "The `:invisible' function sees each `invisible' text property.
An overlay's `invisible' property hides them from
`next-single-char-property-change'."
  (with-temp-buffer
    (insert "abcdef")
    (overlay-put (make-overlay 1 7) 'invisible 'fold)
    (put-text-property 3 5 'invisible 'hidden)
    (setq-local pretty-tables--adaptor
                (list :invisible (lambda (pos)
                                   (eq (plist-get (text-properties-at pos)
                                                  'invisible)
                                       'hidden))))
    (should (equal (substring-no-properties
                    (pretty-tables--visible-string 1 7))
                   "abef"))))

;;; Drawing tables

(ert-deftest pretty-tables-test-draw-table ()
  "Columns are aligned to their widest cell."
  (pretty-tables-tests--with-buffer
      "Title\n\n| a | bb |\n|---|---|\n| ccc | d |\n"
    (should (equal (pretty-tables-tests--rows)
                   '("| a   | bb |"
                     "|-----|----|"
                     "| ccc | d  |")))))

(ert-deftest pretty-tables-test-indented-table ()
  "The screen lines of a row are indented as its first one.
The prefix is the line's `line-prefix' and the text before the row."
  (pretty-tables-tests--with-buffer
      "Title\n\n  | a | b |\n  |---|---|\n  | one<br>two | x |\n"
    (setq-local line-prefix ">")
    (font-lock-flush)
    (jit-lock-fontify-now)
    (let ((row (car (last (pretty-tables-tests--row-strings)))))
      (should (equal (substring-no-properties row) "| one | x |\n| two |   |"))
      (should (equal (get-text-property 0 'line-prefix row) ">  "))
      (should (equal (get-text-property 0 'wrap-prefix row) ">  ")))))

(ert-deftest pretty-tables-test-prefix-function ()
  "The adaptor's `:prefix' function gives the prefix of a row."
  (pretty-tables-tests--with-buffer
      "Title\n\n  | a | b |\n  |---|---|\n  | one<br>two | x |\n"
    (pretty-tables-enable :tables #'pretty-tables-tests--tables
                          :separator #'pretty-tables-tests--separator
                          :line-break "<br>"
                          :prefix (lambda (pos) (format "%d:" pos)))
    (jit-lock-fontify-now)
    (let* ((ov (car (last (pretty-tables-tests--overlays))))
           (row (overlay-get ov 'pretty-tables-string))
           (prefix (format "%d:" (overlay-start ov))))
      (should (equal (get-text-property 0 'line-prefix row) prefix))
      (should (equal (get-text-property 0 'wrap-prefix row) prefix)))))

(ert-deftest pretty-tables-test-option-without-keywords ()
  "Setting an option draws the tables again in a buffer without keywords.
There `font-lock-fontified' is nil, and `font-lock-flush' does nothing."
  (let ((buf (generate-new-buffer "pretty-tables-test")))
    (unwind-protect
        (with-current-buffer buf
          (insert "| aaaa bbbb | c |\n")
          (text-mode)
          (let ((noninteractive nil))
            (font-lock-mode 1))
          (should-not font-lock-fontified)
          (setq-local pretty-tables-width 80)
          (pretty-tables-enable :tables #'pretty-tables-tests--tables
                                :separator #'pretty-tables-tests--separator)
          (jit-lock-fontify-now)
          (should (equal (pretty-tables-tests--rows) '("| aaaa bbbb | c |")))
          (setq-local pretty-tables-width 12)
          (jit-lock-fontify-now)
          (should (equal (pretty-tables-tests--rows)
                         '("| aaaa     | c |\n| bbbb     |   |"))))
      (kill-buffer buf))))

(ert-deftest pretty-tables-test-safe-local-variables ()
  "The options are safe as file-local variables with a value of their type."
  (dolist (case '((pretty-tables-width nil t) (pretty-tables-width 72 t)
                  (pretty-tables-width -1 nil) (pretty-tables-width "72" nil)
                  (pretty-tables-min-column-width 8 t)
                  (pretty-tables-min-column-width -1 nil)
                  (pretty-tables-stripe-rows nil t) (pretty-tables-stripe-rows 1 nil)
                  (pretty-tables-row-lines t t) (pretty-tables-row-lines "t" nil)
                  (pretty-tables-reveal always t) (pretty-tables-reveal writable t)
                  (pretty-tables-reveal nil t) (pretty-tables-reveal yes nil)))
    (should (eq (and (safe-local-variable-p (nth 0 case) (nth 1 case)) t)
                (nth 2 case)))))

(ert-deftest pretty-tables-test-alignments ()
  "The table's alignments place the cells in their columns."
  (pretty-tables-tests--with-buffer
      "Title\n\n| a | b | c |\n| xxxxx | yyyyy | zzzzz |\n"
    (cl-letf* ((tables (symbol-function 'pretty-tables-tests--tables))
               ((symbol-function 'pretty-tables-tests--tables)
                (lambda (beg end)
                  (mapcar (lambda (table)
                            (plist-put table :alignments '(left right center)))
                          (funcall tables beg end)))))
      (font-lock-flush)
      (jit-lock-fontify-now)
      (should (equal (car (pretty-tables-tests--rows))
                     "| a     |     b |   c   |")))))

(ert-deftest pretty-tables-test-line-break ()
  "The adaptor's `:line-break' starts a new line in a cell."
  (pretty-tables-tests--with-buffer
      "Title\n\n| a | b |\n|---|---|\n| one<br>two | x |\n"
    (should (equal (car (last (pretty-tables-tests--rows)))
                   "| one | x |\n| two |   |"))))

(ert-deftest pretty-tables-test-wrap-to-width ()
  "A table wider than `pretty-tables-width' is wrapped."
  (pretty-tables-tests--with-buffer
      "Title\n\n| a | b |\n|---|---|\n| x | one two three four |\n"
    (setq-local pretty-tables-width 20)
    (jit-lock-fontify-now)
    (should (equal (pretty-tables-tests--rows)
                   '("| a | b            |"
                     "|---|--------------|"
                     "| x | one two      |\n|   | three four   |")))))

(ert-deftest pretty-tables-test-min-widths ()
  "A column with a minimum width is narrowed first, down to it."
  (pretty-tables-tests--with-buffer
      "Title\n\n| aaaa bbbb cccc | dddd eeee ffff |\n"
    (setq-local pretty-tables-width 30)
    (cl-letf* ((tables (symbol-function 'pretty-tables-tests--tables))
               ((symbol-function 'pretty-tables-tests--tables)
                (lambda (beg end)
                  (mapcar (lambda (table)
                            (plist-put table :min-widths '(9 nil)))
                          (funcall tables beg end)))))
      (jit-lock-fontify-now)
      (should (equal (pretty-tables-tests--rows)
                     '("| aaaa bbbb | dddd eeee ffff |\n| cccc      |                |"))))))

(ert-deftest pretty-tables-test-invisible-text ()
  "Text font-lock makes invisible takes no room."
  (pretty-tables-tests--with-buffer pretty-tables-tests--hidden-table
    (should (equal (pretty-tables-tests--rows)
                   '("| Name | Link  |"
                     "|------|-------|"
                     "| one  | Emacs |"
                     "| two  | plain |")))))

(ert-deftest pretty-tables-test-partial-chunk ()
  "Fontifying part of a table draws the whole table from the buffer text.
The rows outside the region still have their overlays when the table
is read, as they do when jit-lock fontifies a window in chunks."
  (pretty-tables-tests--with-buffer pretty-tables-tests--hidden-table
    (let ((expected (pretty-tables-tests--rows))
          (last-row (overlay-start (car (last (pretty-tables-tests--overlays))))))
      (font-lock-flush)
      (jit-lock-fontify-now last-row (point-max))
      (should (equal (pretty-tables-tests--rows) expected)))))

(ert-deftest pretty-tables-test-disable ()
  "`pretty-tables-disable' removes the row overlays."
  (pretty-tables-tests--with-buffer pretty-tables-tests--hidden-table
    (should (pretty-tables-tests--overlays))
    (pretty-tables-disable)
    (should-not (pretty-tables-tests--overlays))
    (should-not pretty-tables--adaptor)))

(ert-deftest pretty-tables-test-table-face ()
  "The adaptor's `:face' comes after every other face of a row."
  (pretty-tables-tests--with-buffer pretty-tables-tests--four-rows
    (setq-local pretty-tables--adaptor
                (append pretty-tables--adaptor '(:face italic)))
    (font-lock-flush)
    (jit-lock-fontify-now)
    (dolist (row (pretty-tables-tests--row-strings))
      (should (eq (car (last (ensure-list (get-text-property 0 'face row))))
                  'italic)))))

;;; Options

(ert-deftest pretty-tables-test-fill-column-redraws ()
  "Setting `fill-column' draws the table again with the new width."
  (pretty-tables-tests--with-buffer
      "Title\n\n| a | b |\n|---|---|\n| x | one two three four |\n"
    (setq-local pretty-tables-width nil)
    (setq-local fill-column 80)
    (jit-lock-fontify-now)
    (should (equal (car (last (pretty-tables-tests--rows)))
                   "| x | one two three four |"))
    (setq-local fill-column 20)
    (jit-lock-fontify-now)
    (should (equal (car (last (pretty-tables-tests--rows)))
                   "| x | one two      |\n|   | three four   |"))))

;; Batch frames have no colours, so the faces whose background the data
;; rows take get one for the tests.
(defconst pretty-tables-tests--row-colour "#eeeeee"
  "Background given to `hl-line' in the tests.")

(defconst pretty-tables-tests--stripe-colour "#c0cfe1"
  "Background given to `lazy-highlight' in the tests.")

(set-face-attribute 'hl-line nil :background pretty-tables-tests--row-colour)
(set-face-attribute 'lazy-highlight nil
                    :background pretty-tables-tests--stripe-colour)

(defun pretty-tables-tests--faces (string)
  "Return the faces anywhere in STRING, as one flat list."
  (let (faces)
    (dotimes (i (length string))
      (let ((face (get-text-property i 'face string)))
        (setq faces (append (if (keywordp (car-safe face))
                                (list face)
                              (ensure-list face))
                            faces))))
    (delete-dups faces)))

(defun pretty-tables-tests--row-kind (faces)
  "Return `row' or `stripe' for the row face among FACES, or nil."
  (seq-some (lambda (face)
              (and (consp face)
                   (pcase (plist-get face :inherit)
                     ('pretty-tables-row 'row)
                     ('pretty-tables-stripe 'stripe))))
            faces))

(ert-deftest pretty-tables-test-option-redraws ()
  "Setting an option of the package draws the table again."
  (pretty-tables-tests--with-buffer pretty-tables-tests--four-rows
    (should (seq-some (lambda (row)
                        (pretty-tables-tests--row-kind
                         (pretty-tables-tests--faces row)))
                      (pretty-tables-tests--row-strings)))
    (setq-local pretty-tables-stripe-rows nil)
    (jit-lock-fontify-now)
    (should-not (seq-some (lambda (row)
                            (pretty-tables-tests--row-kind
                             (pretty-tables-tests--faces row)))
                          (pretty-tables-tests--row-strings)))))

(defvar pretty-tables-tests--option nil
  "An option of the test adaptor, given in its `:options'.")

(ert-deftest pretty-tables-test-adaptor-option-redraws ()
  "Setting a variable of the adaptor's `:options' draws the table again."
  (pretty-tables-tests--with-buffer "Title\n\n| a | b |\n"
    (pretty-tables-enable :tables #'pretty-tables-tests--tables
                          :separator #'pretty-tables-tests--separator
                          :options '(pretty-tables-tests--option))
    (jit-lock-fontify-now)
    (should (get-text-property (point-min) 'fontified))
    (setq-local pretty-tables-tests--option t)
    (should-not (get-text-property (point-min) 'fontified))))

;;; Stripes and row lines

(ert-deftest pretty-tables-test-stripes ()
  "Data rows alternate between the row and stripe faces.
The header and the separator row get neither."
  (pretty-tables-tests--with-buffer pretty-tables-tests--four-rows
    (should (equal (mapcar (lambda (row)
                             (pretty-tables-tests--row-kind
                              (pretty-tables-tests--faces row)))
                           (pretty-tables-tests--row-strings))
                   '(nil nil row stripe row stripe)))))

(ert-deftest pretty-tables-test-stripes-count-data-rows ()
  "A separator between data rows does not change which face a row gets."
  (pretty-tables-tests--with-buffer
      "Title\n\n| a |\n|---|\n| r0 |\n| r1 |\n|---|\n| r2 |\n"
    (should (equal (mapcar (lambda (row)
                             (pretty-tables-tests--row-kind
                              (pretty-tables-tests--faces row)))
                           (pretty-tables-tests--row-strings))
                   '(nil nil row stripe nil row)))))

(ert-deftest pretty-tables-test-header-face ()
  "The cell text of header rows gets `pretty-tables-header'.
The pipes do not, and the cell's own face comes first."
  (pretty-tables-tests--with-buffer
      "Title\n\n| a *b* | x |\n|---|---|\n| r0 | y |\n"
    (let* ((rows (pretty-tables-tests--row-strings))
           (header (car rows))
           (has (lambda (s face) (and (memq face (pretty-tables-tests--faces s))
                                      t))))
      (should (equal (mapcar (lambda (r) (funcall has r 'pretty-tables-header))
                             rows)
                     '(t nil nil)))
      (should (funcall has (substring header 2 3) 'pretty-tables-header))
      (should-not (funcall has (substring header 0 1) 'pretty-tables-header))
      (let ((face (get-text-property (string-search "b" header) 'face header)))
        (should (< (seq-position face 'bold)
                   (seq-position face 'pretty-tables-header)))))))

(ert-deftest pretty-tables-test-header-row-face ()
  "Each screen line of a header row gets `pretty-tables-header-row'.
The pipes get it too; the newlines between screen lines do not."
  (pretty-tables-tests--with-buffer
      "Title\n\n| a<br>b | x |\n|---|---|\n| r0 | y |\n"
    (let* ((rows (pretty-tables-tests--row-strings))
           (header (car rows))
           (newline (string-search "\n" header))
           (has (lambda (s) (and (memq 'pretty-tables-header-row
                                       (pretty-tables-tests--faces s))
                                 t))))
      (should (equal (mapcar has rows) '(t nil nil)))
      (should (funcall has (substring header 0 1)))
      (should (funcall has (substring header (1+ newline))))
      (should-not (funcall has (substring header newline (1+ newline)))))))

(ert-deftest pretty-tables-test-row-face ()
  "A row face inherits the package's face and takes only a background.
The background is the one of `hl-line' or `lazy-highlight', whatever
else the theme gives those faces; a background set on the package's
face takes its place."
  (let ((weight (face-attribute 'lazy-highlight :weight))
        (foreground (face-attribute 'lazy-highlight :foreground)))
    (unwind-protect
        (progn
          (set-face-attribute 'lazy-highlight nil :weight 'bold :foreground "red")
          (should (equal (pretty-tables--row-face t)
                         (list :inherit 'pretty-tables-stripe
                               :background pretty-tables-tests--stripe-colour)))
          (should (equal (pretty-tables--row-face nil)
                         (list :inherit 'pretty-tables-row
                               :background pretty-tables-tests--row-colour)))
          (should-not (eq (face-attribute 'pretty-tables-stripe :weight nil t)
                          'bold))
          (set-face-attribute 'pretty-tables-row nil :background "#123456")
          (should (equal (plist-get (pretty-tables--row-face nil) :background)
                         "#123456")))
      (set-face-attribute 'lazy-highlight nil :weight weight :foreground foreground)
      (set-face-attribute 'pretty-tables-row nil :background 'unspecified))))

(ert-deftest pretty-tables-test-theme-redraws ()
  "Enabling a theme draws the tables again with the new background."
  (pretty-tables-tests--with-buffer pretty-tables-tests--four-rows
    (unwind-protect
        (progn
          (set-face-attribute 'hl-line nil :background "#654321")
          (run-hook-with-args 'enable-theme-functions 'user)
          (jit-lock-fontify-now)
          (should (member (list :inherit 'pretty-tables-row
                                :background "#654321")
                          (pretty-tables-tests--faces
                           (nth 2 (pretty-tables-tests--row-strings))))))
      (set-face-attribute 'hl-line nil
                          :background pretty-tables-tests--row-colour))))

(ert-deftest pretty-tables-test-stripes-not-on-newlines ()
  "The newlines between the screen lines of a row get no row face."
  (pretty-tables-tests--with-buffer pretty-tables-tests--four-rows
    (let* ((row (nth 4 (pretty-tables-tests--row-strings)))
           (newline (string-search "\n" row))
           (kind (lambda (pos)
                   (pretty-tables-tests--row-kind
                    (pretty-tables-tests--faces (substring row pos (1+ pos)))))))
      (should newline)
      (should (eq (funcall kind (1- newline)) 'row))
      (should (eq (funcall kind (1+ newline)) 'row))
      (should-not (funcall kind newline)))))

(ert-deftest pretty-tables-test-row-face-defined ()
  "The faces whose background the rows take are defined once the package is."
  (should (facep 'hl-line))
  (should (facep 'lazy-highlight)))

(ert-deftest pretty-tables-test-stripes-off ()
  "With `pretty-tables-stripe-rows' nil, no row gets a row face."
  (let ((pretty-tables-stripe-rows nil))
    (pretty-tables-tests--with-buffer pretty-tables-tests--four-rows
      (should-not (seq-some (lambda (row)
                              (pretty-tables-tests--row-kind
                               (pretty-tables-tests--faces row)))
                            (pretty-tables-tests--row-strings))))))

(ert-deftest pretty-tables-test-row-lines ()
  "The last screen line of each data row but the last has the row-line face."
  (let ((pretty-tables-row-lines t))
    (pretty-tables-tests--with-buffer pretty-tables-tests--four-rows
      (let* ((rows (pretty-tables-tests--row-strings))
             (lined (lambda (s)
                      (and (memq 'pretty-tables-row-line
                                 (pretty-tables-tests--faces s))
                           t))))
        (should (equal (mapcar lined rows) '(nil nil t t t nil)))
        ;; In the two-line row, only the second screen line is underlined.
        (let* ((row (nth 4 rows))
               (newline (string-search "\n" row)))
          (should-not (funcall lined (substring row 0 newline)))
          (should (funcall lined (substring row (1+ newline)))))))))

(ert-deftest pretty-tables-test-row-lines-off ()
  "By default no row line is drawn."
  (pretty-tables-tests--with-buffer pretty-tables-tests--four-rows
    (should-not (seq-some (lambda (row)
                            (memq 'pretty-tables-row-line
                                  (pretty-tables-tests--faces row)))
                          (pretty-tables-tests--row-strings)))))

(ert-deftest pretty-tables-test-stripe-under-cell-faces ()
  "The row face comes after the faces of the cell text."
  (pretty-tables-tests--with-buffer
      "Title\n\n| a |\n|---|\n| x |\n| *b* |\n"
    (let* ((row (car (last (pretty-tables-tests--row-strings))))
           (pos (string-search "b" row))
           (face (get-text-property pos 'face row))
           (row-face (seq-position face 'pretty-tables-stripe
                                   (lambda (f stripe)
                                     (and (consp f)
                                          (eq (plist-get f :inherit) stripe))))))
      (should row-face)
      (should (< (seq-position face 'bold) row-face)))))

;;; Point

(ert-deftest pretty-tables-test-reveal ()
  "The row point is on is shown raw; the row point left is drawn again."
  (pretty-tables-tests--with-buffer pretty-tables-tests--hidden-table
    (let ((ovs (pretty-tables-tests--overlays))
          (this-command 'next-line))
      (should (seq-every-p (lambda (ov) (overlay-get ov 'display)) ovs))
      (pretty-tables-tests--goto-row 2)
      (pretty-tables--reveal)
      (should-not (overlay-get (nth 2 ovs) 'display))
      (pretty-tables-tests--goto-row 3)
      (pretty-tables--reveal)
      (should (overlay-get (nth 2 ovs) 'display))
      (should-not (overlay-get (nth 3 ovs) 'display)))))

(ert-deftest pretty-tables-test-reveal-read-only ()
  "In a read-only buffer the row point is on stays drawn by default.
A row revealed before the buffer became read-only is drawn again."
  (pretty-tables-tests--with-buffer pretty-tables-tests--hidden-table
    (let ((ovs (pretty-tables-tests--overlays))
          (this-command 'next-line))
      (pretty-tables-tests--goto-row 2)
      (pretty-tables--reveal)
      (should-not (overlay-get (nth 2 ovs) 'display))
      (setq buffer-read-only t)
      (pretty-tables--reveal)
      (should (overlay-get (nth 2 ovs) 'display))
      (pretty-tables-tests--goto-row 3)
      (pretty-tables--reveal)
      (should (overlay-get (nth 3 ovs) 'display))
      (should-not pretty-tables--revealed))))

(ert-deftest pretty-tables-test-reveal-always ()
  "With `pretty-tables-reveal' `always', a read-only row is revealed."
  (pretty-tables-tests--with-buffer pretty-tables-tests--hidden-table
    (let ((ovs (pretty-tables-tests--overlays))
          (this-command 'next-line)
          (pretty-tables-reveal 'always))
      (setq buffer-read-only t)
      (pretty-tables-tests--goto-row 2)
      (pretty-tables--reveal)
      (should-not (overlay-get (nth 2 ovs) 'display)))))

(ert-deftest pretty-tables-test-reveal-never ()
  "With `pretty-tables-reveal' nil, no row is revealed, except in Isearch."
  (pretty-tables-tests--with-buffer pretty-tables-tests--hidden-table
    (let ((ovs (pretty-tables-tests--overlays))
          (this-command 'next-line)
          (pretty-tables-reveal nil))
      (pretty-tables-tests--goto-row 2)
      (pretty-tables--reveal)
      (should (overlay-get (nth 2 ovs) 'display))
      (let ((isearch-mode " Isearch"))
        (pretty-tables--reveal))
      (should-not (overlay-get (nth 2 ovs) 'display))
      (pretty-tables--reveal)
      (should (overlay-get (nth 2 ovs) 'display)))))

(ert-deftest pretty-tables-test-redraw-keeps-revealed ()
  "Drawing a table again leaves the revealed row raw.
`jit-lock-fontify-now' moves point to the start of the region, so the
drawing cannot find the row from point."
  (pretty-tables-tests--with-buffer pretty-tables-tests--hidden-table
    (pretty-tables-tests--goto-row 2)
    (let ((this-command 'next-line))
      (pretty-tables--reveal))
    (font-lock-flush)
    (jit-lock-fontify-now)
    (let ((ovs (pretty-tables-tests--overlays)))
      (should-not (overlay-get (nth 2 ovs) 'display))
      (should (eq pretty-tables--revealed (nth 2 ovs))))))

(ert-deftest pretty-tables-test-scroll-keeps-drawn ()
  "After a scroll command, a row point moved onto stays drawn."
  (pretty-tables-tests--with-buffer pretty-tables-tests--hidden-table
    (let ((ovs (pretty-tables-tests--overlays))
          (this-command 'scroll-up-command))
      (pretty-tables-tests--goto-row 2)
      (pretty-tables--reveal)
      (should (overlay-get (nth 2 ovs) 'display))
      (should-not pretty-tables--revealed))))

(ert-deftest pretty-tables-test-scroll-keeps-revealed ()
  "After a scroll command, a row that was already revealed stays revealed."
  (pretty-tables-tests--with-buffer pretty-tables-tests--hidden-table
    (let ((ovs (pretty-tables-tests--overlays)))
      (pretty-tables-tests--goto-row 2)
      (let ((this-command 'next-line))
        (pretty-tables--reveal))
      (let ((this-command 'mwheel-scroll))
        (pretty-tables--reveal))
      (should-not (overlay-get (nth 2 ovs) 'display))
      (should (eq pretty-tables--revealed (nth 2 ovs))))))

(provide 'pretty-tables-tests)
;;; pretty-tables-tests.el ends here
