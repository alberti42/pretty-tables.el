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

;; Defined with the macro the adaptors use; BODY records each call.
(defvar pretty-tables-tests--calls nil
  "What ran when `pretty-tables-tests-adaptor-mode' changed, last first.")

(pretty-tables-define-mode pretty-tables-tests-adaptor-mode
  "The test adaptor as a minor mode."
  :tables #'pretty-tables-tests--tables
  :separator #'pretty-tables-tests--separator
  :line-break "<br>"
  (push (list 'body pretty-tables-tests-adaptor-mode (pretty-tables-active-p))
        pretty-tables-tests--calls))

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

;;; The pixel layout

(defvar pretty-tables-tests--char-pixels '((?i . 4))
  "Widths in pixels of the characters that are not 10 pixels a column.
See `pretty-tables-tests--pixel-width'.")

(defun pretty-tables-tests--space-pixels (width)
  "Return the pixels of WIDTH, the `:width' of a `space' display.
A column is 10 pixels wide."
  (pcase width
    ((pred numberp) (* 10 width))
    ('width 10)
    (`(,(and n (pred numberp))) n)
    (`(,(and n (pred numberp)) . width) (* 10 n))
    (`(- ,first . ,rest)
     (apply #'- (pretty-tables-tests--space-pixels first)
            (mapcar #'pretty-tables-tests--space-pixels rest)))
    (`(+ . ,rest) (apply #'+ (mapcar #'pretty-tables-tests--space-pixels rest)))))

(defun pretty-tables-tests--pixel-width (string)
  "Return the width of STRING in pixels, on a display of 10-pixel columns.
A `space' display is the pixels of `pretty-tables-tests--space-pixels',
an image its `:width', and a character the pixels in
`pretty-tables-tests--char-pixels', or 10 per column of its
`char-width'.  It replaces `pretty-tables--pixel-width' in the tests,
which cannot measure text in batch mode."
  (let ((i 0) (width 0))
    (while (< i (length string))
      (let ((display (get-text-property i 'display string))
            (next (next-single-property-change i 'display string (length string))))
        (pcase display
          (`(space :width ,w)
           (setq width (+ width (pretty-tables-tests--space-pixels w))))
          (`(image . ,props) (setq width (+ width (plist-get props :width))))
          (_ (dotimes (k (- next i))
               (let ((char (aref string (+ i k))))
                 (setq width (+ width (or (alist-get char pretty-tables-tests--char-pixels)
                                          (* 10 (char-width char)))))))))
        (setq i next)))
    width))

(defmacro pretty-tables-tests--with-pixels (&rest body)
  "Run BODY as on a graphical display whose columns are 10 pixels wide.
Tables are laid out in pixels, measured with
`pretty-tables-tests--pixel-width'."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'display-graphic-p) #'always)
             ((symbol-function 'pretty-tables--pixel-width)
              #'pretty-tables-tests--pixel-width))
     ,@body))

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

;;; Adaptor modes

(ert-deftest pretty-tables-test-define-mode ()
  "A mode defined with `pretty-tables-define-mode' draws the tables.
Its body runs before the drawing is turned on or off, then
`pretty-tables-toggle-hook', then the mode's own hook."
  (let ((buf (generate-new-buffer "pretty-tables-test"))
        (pretty-tables-tests--calls nil)
        (record (lambda (name)
                  (lambda ()
                    (push (list name pretty-tables-tests-adaptor-mode
                                (pretty-tables-active-p))
                          pretty-tables-tests--calls)))))
    (unwind-protect
        (with-current-buffer buf
          (insert pretty-tables-tests--four-rows)
          (pretty-tables-tests-mode)
          (let ((noninteractive nil))
            (font-lock-mode 1))
          (add-hook 'pretty-tables-toggle-hook (funcall record 'toggle) nil t)
          (add-hook 'pretty-tables-tests-adaptor-mode-hook
                    (funcall record 'mode) nil t)
          (should-not (pretty-tables-active-p))
          (pretty-tables-tests-adaptor-mode 1)
          (jit-lock-fontify-now)
          (should (pretty-tables-active-p))
          (should (pretty-tables-tests--rows))
          (pretty-tables-tests-adaptor-mode -1)
          (should-not (pretty-tables-active-p))
          (should-not (pretty-tables-tests--rows))
          (should (equal (reverse pretty-tables-tests--calls)
                         '((body t nil) (toggle t t) (mode t t)
                           (body nil t) (toggle nil nil) (mode nil nil)))))
      (kill-buffer buf))))

(ert-deftest pretty-tables-test-define-mode-lighter ()
  "A mode defined with `pretty-tables-define-mode' has no lighter."
  (should-not (cadr (assq 'pretty-tables-tests-adaptor-mode minor-mode-alist))))

(ert-deftest pretty-tables-test-adaptor-autoloads ()
  "The autoloads of each adaptor can be loaded without `pretty-tables'.
straight and package.el load them before `pretty-tables.el', so each
form must be an `autoload' or one that needs only Emacs."
  (require 'loaddefs-gen)
  (dolist (mode '(pretty-tables-for-markdown-mode pretty-tables-for-org-mode))
    (let* ((name (string-remove-suffix "-mode" (symbol-name mode)))
           (dir (make-temp-file "pretty-tables-autoloads" t))
           (out (expand-file-name "autoloads.el" dir))
           (inhibit-message t)
           forms)
      (unwind-protect
          (progn
            (copy-file (locate-library (concat name ".el"))
                       (file-name-as-directory dir))
            (loaddefs-generate dir out)
            (with-temp-buffer
              (insert-file-contents out)
              (condition-case nil
                  (while t (push (read (current-buffer)) forms))
                (end-of-file nil))))
        (delete-directory dir t))
      (dolist (form forms)
        (should (memq (car form)
                      '(autoload register-definition-prefixes provide))))
      (should (cl-find-if (lambda (form)
                            (and (eq (car form) 'autoload)
                                 (equal (nth 1 form) `',mode)))
                          forms)))))

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
                               (pretty-tables--position s i))
                             (number-sequence 0 (1- (length s))))
                     '(1 3 3 4 4 4 5 6))))))

(defconst pretty-tables-tests--image
  '(image :type svg :data "<svg/>" :width 25 :scale 1.0)
  "An image spec 25 pixels wide.
Batch mode cannot show it, so it is never loaded.")

(defmacro pretty-tables-tests--with-images (&rest body)
  "Run BODY as on a graphical display that shows images.
Tables are laid out in pixels, see `pretty-tables-tests--with-pixels',
and `pretty-tables--unit' is 10.  `pretty-tables-image-spacing' is 0,
so the images are not copied; `pretty-tables-test-image-margin' tests
the copy.  `default-line-height' is 20: batch mode has no font."
  (declare (indent 0) (debug t))
  `(pretty-tables-tests--with-pixels
     (cl-letf (((symbol-function 'display-images-p) #'always)
               ((symbol-function 'default-line-height) (lambda () 20)))
       (let ((pretty-tables-image-spacing 0)
             (pretty-tables--unit 10))
         ,@body))))

(defvar pretty-tables-tests--image-height 30
  "Height in pixels that `image-size' returns in the margin tests.")

(ert-deftest pretty-tables-test-image-margin ()
  "An image that reaches past the font is copied with a vertical margin.
The most margin is half the option times the line height, here
0.25 x 24 / 2 = 3 pixels; the font has ascent 16 and descent 4.  The
margin is the smaller of 3 and the factor times how far the image
reaches past the font; the factor is 1 except where a case sets it.  The copy's ascent puts the image on the same baseline: its
ascent plus the margin, out of its height plus the margin, rounded
up."
  (cl-letf (((symbol-function 'default-line-height) (lambda () 24))
            ((symbol-function 'image-size)
             (lambda (&rest _) (cons 40 pretty-tables-tests--image-height)))
            ((symbol-function 'font-info)
             (lambda (&rest _) [nil nil 0 20 0 0 0 0 16 4 0 0 nil nil]))
            ((symbol-function 'face-font) (lambda (&rest _) "font")))
    (let ((pretty-tables-image-spacing 0.25)
          (pretty-tables-image-spacing-factor 1)
          (margin (lambda (height ascent)
                    (let* ((pretty-tables-tests--image-height height)
                           (image `(image :type svg :data "<svg/>" :width 40
                                          ,@(and ascent (list :ascent ascent))))
                           (copy (pretty-tables--image-with-margin image)))
                      (if (eq copy image)
                          'unchanged
                        (list (image-property copy :margin)
                              (image-property copy :ascent)))))))
      ;; 30 x 0.8 = 24, 8 past the ascent: the margin is 3, and 27 / 33
      ;; is 81.8%.
      (should (equal (funcall margin 30 80) '((0 . 3) 82)))
      ;; No `:ascent' is 50: 15, and 15 below, 11 past the descent;
      ;; 18 / 33 is 54.5%.
      (should (equal (funcall margin 30 nil) '((0 . 3) 55)))
      ;; `center': (30 + 16 - 4 + 1) / 2 = 21, 5 past the ascent;
      ;; 24 / 33 is 72.7%.
      (should (equal (funcall margin 30 'center) '((0 . 3) 73)))
      ;; 18 x 0.8 = 14 above and 4 below: it fits, and gets no margin.
      (should (eq (funcall margin 18 80) 'unchanged))
      ;; 20 x 0.85 = 17, 1 past the ascent, and 3 below: the margin is
      ;; 1, and 18 / 21 is 85.7%.
      (should (equal (funcall margin 20 85) '((0 . 1) 86)))
      ;; With the factor 2, the margin is 2: 19 / 22 is 86.4%.
      (let ((pretty-tables-image-spacing-factor 2))
        (should (equal (funcall margin 20 85) '((0 . 2) 87))))
      ;; With 0, no image gets a margin.
      (let ((pretty-tables-image-spacing-factor 0))
        (should (eq (funcall margin 30 80) 'unchanged)))
      ;; With t, or an infinite factor, an image past the font gets the
      ;; most, and one that fits none.
      (dolist (factor (list t 1.0e+INF))
        (let ((pretty-tables-image-spacing-factor factor))
          (should (equal (funcall margin 20 85) '((0 . 3) 87)))
          (should (eq (funcall margin 18 80) 'unchanged))))
      ;; With nil, every image gets the most, also one that fits:
      ;; 17 / 21 is 81%.
      (let ((pretty-tables-image-spacing-factor nil))
        (should (equal (funcall margin 18 80) '((0 . 3) 81))))
      ;; Without a font, the margin is the most.
      (cl-letf (((symbol-function 'font-info) #'ignore))
        (should (equal (funcall margin 18 80) '((0 . 3) 81))))
      ;; An image with a margin, or the option 0, is left as it is.
      (let ((image '(image :type svg :data "<svg/>" :width 40 :margin 2)))
        (should (eq (pretty-tables--image-with-margin image) image)))
      (let ((image pretty-tables-tests--image)
            (pretty-tables-image-spacing 0))
        (should (eq (pretty-tables--image-with-margin image) image)))
      ;; The string shows the copy.
      (cl-letf (((symbol-function 'pretty-tables--pixel-width)
                 #'pretty-tables-tests--pixel-width))
        (let* ((pretty-tables--unit 10)
               (string (pretty-tables--image-string
                        pretty-tables-tests--image 1)))
          (should (equal (image-property (get-text-property 0 'display string)
                                         :margin)
                         '(0 . 3))))))))

(ert-deftest pretty-tables-test-visible-string-image ()
  "An image is one character, measured, with or without a `:width'.
In columns, as on a text terminal, the text under the image is read."
  (with-temp-buffer
    (insert "a $x$ b")
    (let ((ov (make-overlay 3 6)))
      (overlay-put ov 'display pretty-tables-tests--image)
      (pretty-tables-tests--with-images
        (let ((s (pretty-tables--visible-string 1 8)))
          (should (equal (substring-no-properties s) "a x b"))
          (should (eq (get-text-property 2 'display s)
                      pretty-tables-tests--image))
          (should (equal (get-text-property 2 'pretty-tables-image s) '(25)))
          (should (null (get-text-property 3 'display s)))
          (should (equal (mapcar (lambda (i)
                                   (pretty-tables--position s i))
                                 (number-sequence 0 (1- (length s))))
                         '(1 2 3 6 7)))
          (should (= (pretty-tables--widest-image s) 25)))
        ;; In columns, the text is read.
        (let ((pretty-tables--unit nil))
          (should (equal (substring-no-properties
                          (pretty-tables--visible-string 1 8))
                         "a $x$ b")))
        ;; An image without a `:width' is measured too.
        (overlay-put ov 'display '(image :type svg :data "<svg/>"))
        (cl-letf (((symbol-function 'pretty-tables--pixel-width)
                   (lambda (string)
                     (if (eq (car-safe (get-text-property 0 'display string))
                             'image)
                         17
                       (pretty-tables-tests--pixel-width string)))))
          (let ((s (pretty-tables--visible-string 1 8)))
            (should (equal (substring-no-properties s) "a x b"))
            (should (equal (get-text-property 2 'pretty-tables-image s)
                           '(17)))))))))

(ert-deftest pretty-tables-test-break-word-image ()
  "An image is one character, so a word is not broken inside it."
  (pretty-tables-tests--with-images
    (let* ((image (pretty-tables--image-string pretty-tables-tests--image 1))
           (word (concat "ab" image "cd")))
      ;; 10 + 10 + 25 + 10 + 10 pixels.
      (should (equal (mapcar #'substring-no-properties
                             (pretty-tables--break-word word 40))
                     '("ab" "xc" "d")))
      ;; An image wider than the width is a piece of its own.
      (should (equal (mapcar #'substring-no-properties
                             (pretty-tables--break-word (concat image "cd") 20))
                     '("x" "cd"))))))

(ert-deftest pretty-tables-test-image-floor ()
  "No column is narrowed below its widest image."
  (let ((pretty-tables-min-column-width 8))
    (should (equal (pretty-tables--column-widths '(30 30) 30 nil '(nil 12))
                   '(11 12)))
    ;; With a minimum width, the image is the floor when it is wider.
    (should (equal (pretty-tables--column-widths '(30 30) 30 '(nil 5) '(nil 12))
                   '(11 12)))))

(ert-deftest pretty-tables-test-image-drawn ()
  "An image in a cell is drawn, and its column is not narrowed below it."
  (pretty-tables-tests--with-buffer
      "Title\n\n| aaaa bbbb cccc | $x$ |\n"
    (let ((ov (make-overlay (- (point-max) 6) (- (point-max) 3))))
      (should (equal (buffer-substring (overlay-start ov) (overlay-end ov))
                     "$x$"))
      (overlay-put ov 'display
                   '(image :type svg :data "<svg/>" :width 95 :scale 1.0))
      (setq-local pretty-tables-width 20)
      (pretty-tables-tests--with-images
        (jit-lock-refontify)
        (jit-lock-fontify-now)
        ;; The image is 95 pixels wide, and the first column is at
        ;; `pretty-tables-min-column-width', 80 pixels.
        (should (equal (mapcar #'pretty-tables-tests--as-columns
                               (pretty-tables-tests--row-strings))
                       '("| aaaa     | x |\n| bbbb     |           |\n| cccc     |           |")))
        (should (equal (mapcar #'pretty-tables-tests--pixel-width
                               (split-string (car (pretty-tables-tests--row-strings))
                                             "\n"))
                       '(245 245 245)))))))

(ert-deftest pretty-tables-test-visible-string-space-pixels ()
  "In pixels, a `space' display is kept, as a new list."
  (with-temp-buffer
    (insert "abcd")
    (let ((spec '(space :width 3)))
      (put-text-property 2 3 'display spec)
      (put-text-property 3 4 'display spec)
      (cl-letf (((symbol-function 'pretty-tables--pixel-width)
                 #'pretty-tables-tests--pixel-width))
        (let* ((pretty-tables--unit 10)
               (s (pretty-tables--visible-string 1 5)))
          ;; `b' and `c' have the same `display', shown as one stretch.
          (should (equal (substring-no-properties s) "a d"))
          (should (equal (get-text-property 1 'display s) spec))
          (should-not (eq (get-text-property 1 'display s) spec))
          (should (= (pretty-tables-tests--pixel-width s) 50)))))))

(ert-deftest pretty-tables-test-positions-after-cuts ()
  "Each character of a wrapped line reads the buffer position it comes from.
The positions are kept by run, so the cuts of splitting at a line
break, trimming, wrapping and breaking a word put the position of its
new first character on a run cut in the middle."
  (with-temp-buffer
    (insert "  alpha beta<br> gamma deltaepsilonzeta {x} eta  ")
    ;; Hidden text is dropped, and a `display' string comes from the
    ;; position of the text it covers.
    (put-text-property 41 45 'invisible t)
    (put-text-property 1 2 'display "Z")
    (setq-local pretty-tables--adaptor (list :line-break "<br>"))
    (let ((lines (mapcan (lambda (p) (pretty-tables--wrap p 7))
                         (pretty-tables--cell-paragraphs 1 (point-max)))))
      (should (equal (mapcar #'substring-no-properties lines)
                     '("Z alpha" "beta" "gamma" "deltaep" "silonze" "ta eta")))
      (dolist (line lines)
        (dotimes (i (length line))
          (let ((pos (pretty-tables--position line i)))
            (if (eq (aref line i) ?Z)
                (should (= pos 1))
              (should (eq (char-after pos) (aref line i))))))))))

(ert-deftest pretty-tables-test-positions-in-drawn-rows ()
  "Each character of a drawn row with a position comes from that position.
A click reads it with `pretty-tables--position'."
  (dolist (pixels '(nil t))
    (let ((check
           (lambda ()
             (pretty-tables-tests--with-buffer
                 "Title\n\n| alpha beta gamma | *delta* epsilon |\n|---|---|\n| zeta eta | theta |\n"
               (setq-local pretty-tables-width 25)
               (jit-lock-refontify)
               (jit-lock-fontify-now)
               (let ((count 0))
                 (dolist (row (pretty-tables-tests--row-strings))
                   (dotimes (i (length row))
                     (when-let* ((pos (pretty-tables--position row i)))
                       (unless (eq (aref row i) ?\s)
                         (setq count (1+ count)))
                       (should (eq (char-after pos) (aref row i))))))
                 ;; Each of the 40 characters of the cells that are not
                 ;; spaces has a position.
                 (should (= count 40)))))))
      (if pixels
          (pretty-tables-tests--with-pixels (funcall check))
        (funcall check)))))

(ert-deftest pretty-tables-test-visible-string-newline ()
  "A newline in a `display' string is read as a space."
  (with-temp-buffer
    (insert "a b")
    (let ((ov (make-overlay 2 3)))
      (overlay-put ov 'display "\n"))
    (should (equal (substring-no-properties (pretty-tables--visible-string 1 4))
                   "a b"))))

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
                  (pretty-tables-width fill-column t)
                  (pretty-tables-width text-area t)
                  (pretty-tables-width window nil) (pretty-tables-width fill nil)
                  (pretty-tables-width -1 nil) (pretty-tables-width "72" nil)
                  (pretty-tables-min-column-width 8 t)
                  (pretty-tables-min-column-width -1 nil)
                  (pretty-tables-stripe-rows nil t) (pretty-tables-stripe-rows 1 nil)
                  (pretty-tables-row-lines t t) (pretty-tables-row-lines "t" nil)
                  (pretty-tables-borders ascii t) (pretty-tables-borders lines t)
                  (pretty-tables-borders nil nil)
                  (pretty-tables-separator-spacing 0 t)
                  (pretty-tables-separator-spacing 0.25 t)
                  (pretty-tables-separator-spacing -1 nil)
                  (pretty-tables-separator-spacing "1" nil)
                  (pretty-tables-image-spacing 0 t)
                  (pretty-tables-image-spacing 0.25 t)
                  (pretty-tables-image-spacing -1 nil)
                  (pretty-tables-image-spacing-factor 2 t)
                  (pretty-tables-image-spacing-factor nil t)
                  (pretty-tables-image-spacing-factor 0 t)
                  (pretty-tables-image-spacing-factor t t)
                  (pretty-tables-image-spacing-factor yes nil)
                  (pretty-tables-image-spacing-factor -1 nil)
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

;;; The text area

(defmacro pretty-tables-tests--with-text-area (width &rest body)
  "Run BODY with the text areas showing the current buffer WIDTH wide.
`pretty-tables--windows-changed' runs first, as on a window change.
The width is in pixels, which on the batch terminal are columns."
  (declare (indent 1) (debug t))
  `(cl-letf (((symbol-function 'pretty-tables--text-area-width)
              (lambda () ,width)))
     (pretty-tables--windows-changed (selected-frame))
     ,@body))

(ert-deftest pretty-tables-test-target-width ()
  "The target width is `pretty-tables-width', no wider than the text area.
The text area is less the widest prefix of the table's rows."
  (with-temp-buffer
    (setq-local fill-column 70)
    ;; Width, text area, prefix, target.
    (dolist (case '((fill-column nil 0 70)  ; No window: the width alone.
                    (nil nil 0 70)          ; Nil is `fill-column'.
                    (40 nil 4 40)
                    (text-area nil 0 70)    ; No window: `fill-column'.
                    (fill-column 100 0 70)  ; The width is narrower.
                    (fill-column 60 0 60)   ; The text area is narrower.
                    (fill-column 72 4 68)   ; A prefix takes room.
                    (40 30 4 26)
                    (0 100 0 0)
                    (text-area 100 0 100)
                    (text-area 100 4 96)))
      (setq-local pretty-tables-width (nth 0 case)
                  pretty-tables--text-area (nth 1 case))
      (should (= (pretty-tables--target-width (nth 2 case)) (nth 3 case))))
    ;; In pixels, a width in columns is multiplied by the pixels of a
    ;; column, and the text area is in pixels already.
    (let ((pretty-tables--unit 10))
      (setq-local pretty-tables-width 'fill-column
                  pretty-tables--text-area 650)
      (should (= (pretty-tables--target-width 20) 630))
      (setq-local pretty-tables--text-area 900)
      (should (= (pretty-tables--target-width 20) 700)))))

(ert-deftest pretty-tables-test-text-area-width ()
  "The text area is that of the narrowest window showing the buffer.
On a terminal it is `window-max-chars-per-line' columns."
  (pretty-tables-tests--with-buffer "| a |\n"
    (should-not (pretty-tables--text-area-width))
    (save-window-excursion
      (delete-other-windows)
      (set-window-buffer nil (current-buffer))
      (let ((full (pretty-tables--text-area-width)))
        (should (= full (window-max-chars-per-line)))
        (set-window-buffer (split-window-right) (current-buffer))
        (should (< (pretty-tables--text-area-width) full))))))

(ert-deftest pretty-tables-test-window-buffer-change ()
  "A window that stops showing the buffer updates its text area."
  (pretty-tables-tests--with-buffer "| a |\n"
    (should (memq #'pretty-tables--windows-changed
                  (default-value 'window-buffer-change-functions)))
    (should (memq #'pretty-tables--windows-changed
                  (default-value 'window-size-change-functions)))
    (save-window-excursion
      (delete-other-windows)
      (let ((buffer (current-buffer))
            (narrow (selected-window))
            (wide (split-window-right 20)))
        (set-window-buffer narrow buffer)
        (set-window-buffer wide buffer)
        (pretty-tables--windows-changed (selected-frame))
        (should (= pretty-tables--text-area
                   (window-max-chars-per-line narrow)))
        (with-temp-buffer
          (set-window-buffer narrow (current-buffer))
          (pretty-tables--windows-changed (selected-frame))
          (should (= (buffer-local-value 'pretty-tables--text-area buffer)
                     (window-max-chars-per-line wide))))))))

(ert-deftest pretty-tables-test-configuration-change-last ()
  "The text area is measured again by the last window hook of a redisplay.
A package that sets margins from `window-configuration-change-hook'
has set them by then: the default value of the hook runs after the
buffer-local ones, and the update is added after the functions of the
default depth.  The hook calls its functions with no argument."
  (let ((margins (lambda () nil)))
    (add-hook 'window-configuration-change-hook margins)
    (unwind-protect
        (pretty-tables-tests--with-buffer "| a |\n"
          (let ((hook (default-value 'window-configuration-change-hook)))
            (should (memq #'pretty-tables--windows-changed hook))
            (should (< (seq-position hook margins)
                       (seq-position hook #'pretty-tables--windows-changed))))
          (save-window-excursion
            (delete-other-windows)
            (set-window-buffer nil (current-buffer))
            (setq pretty-tables--text-area nil)
            (pretty-tables--windows-changed)
            (should (= pretty-tables--text-area
                       (window-max-chars-per-line)))))
      (remove-hook 'window-configuration-change-hook margins))))

(ert-deftest pretty-tables-test-redraw-command ()
  "`pretty-tables-redraw' measures the windows and draws the current buffer.
No window shows the buffer, so a text area left from before is nil
after it.  Another buffer with a mode on is not drawn again, and any
arguments a hook passes are ignored."
  (should (commandp #'pretty-tables-redraw))
  (pretty-tables-tests--with-buffer "Title\n\n| c |\n"
    (let ((other (current-buffer)))
      (pretty-tables-tests--with-buffer "Title\n\n| a | b |\n"
        (setq pretty-tables--text-area 5)
        (should (get-text-property (point-min) 'fontified))
        (pretty-tables-redraw (selected-frame))
        (should-not pretty-tables--text-area)
        (should-not (get-text-property (point-min) 'fontified))
        (should (with-current-buffer other
                  (get-text-property (point-min) 'fontified)))
        (jit-lock-fontify-now)
        (should (equal (pretty-tables-tests--rows) '("| a | b |"))))))
  ;; In a buffer without a mode on, it does nothing.
  (with-temp-buffer
    (pretty-tables-redraw)
    (should-not pretty-tables--text-area)))

(ert-deftest pretty-tables-test-window-size-redraws ()
  "A narrower text area draws the table again.
The window change marks the table for jit-lock, which draws it at the
next redisplay.  It does so with a width of its own too: the table is
no wider than the text area."
  (dolist (width '(text-area 80))
    (pretty-tables-tests--with-buffer
        "Title\n\n| a | b |\n|---|---|\n| x | one two three four |\n"
      (setq-local pretty-tables-width width
                  pretty-tables-min-column-width 1)
      (pretty-tables-tests--with-text-area 80
        (jit-lock-fontify-now)
        (should (equal (car (last (pretty-tables-tests--rows)))
                       "| x | one two three four |"))
        (should-not (text-property-any (point-min) (point-max) 'fontified nil)))
      (pretty-tables-tests--with-text-area 20
        (should-not (text-property-not-all (point-min) (point-max)
                                           'fontified nil))
        (jit-lock-fontify-now)
        (should (equal (car (last (pretty-tables-tests--rows)))
                       "| x | one two      |\n|   | three four   |")))
      ;; An unchanged width draws nothing again.
      (pretty-tables-tests--with-text-area 20
        (should-not (text-property-any (point-min) (point-max) 'fontified nil))))))

(ert-deftest pretty-tables-test-text-area-prefix ()
  "The indentation of a table takes room in the text area."
  (pretty-tables-tests--with-buffer
      "Title\n\n  | a | b |\n  |---|---|\n  | x | one two three four |\n"
    (setq-local pretty-tables-width 'text-area
                pretty-tables-min-column-width 1)
    (pretty-tables-tests--with-text-area 22
      (jit-lock-fontify-now)
      (should (equal (car (last (pretty-tables-tests--rows)))
                     "| x | one two      |\n|   | three four   |")))))

(ert-deftest pretty-tables-test-text-area-floors ()
  "No width narrows a column below its floor, nor widens a table."
  (pretty-tables-tests--with-buffer
      "Title\n\n| a | b |\n|---|---|\n| x | one two three four |\n"
    (setq-local pretty-tables-min-column-width 4)
    (dolist (width '(10 0))
      (setq-local pretty-tables-width width)
      (pretty-tables-tests--with-text-area 80
        (jit-lock-fontify-now)
        (should (equal (car (last (pretty-tables-tests--rows)))
                       "| x | one  |\n|   | two  |\n|   | thre |\n|   | e    |\n|   | four |"))))
    (setq-local pretty-tables-width 'text-area)
    (pretty-tables-tests--with-text-area 80
      (jit-lock-fontify-now)
      (should (equal (car (pretty-tables-tests--rows)) "| a | b                  |")))))

;; Batch frames have no colours, so the face whose background the stripe
;; rows take gets one for the tests.
(defconst pretty-tables-tests--stripe-colour "#c0cfe1"
  "Background given to `hl-line' in the tests.")

(set-face-attribute 'hl-line nil :background pretty-tables-tests--stripe-colour)

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
              (pcase (if (consp face) (plist-get face :inherit) face)
                ('pretty-tables-row 'row)
                ('pretty-tables-stripe 'stripe)))
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

(ert-deftest pretty-tables-test-options-watched-on-load ()
  "Every option in `pretty-tables--options' is watched once the file loads.
No mode needs to be turned on for that, so loading a new version of
the file watches the options it adds."
  (dolist (option pretty-tables--options)
    (should (memq #'pretty-tables--option-changed
                  (get-variable-watchers option)))))

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

(ert-deftest pretty-tables-test-face-remapping-redraws ()
  "A command that changes the face remapping draws the tables again.
A table laid out in pixels is measured in the buffer's faces.
`face-remap-add-relative' changes `face-remapping-alist' in place when
the face has an entry already, as after `text-scale-increase'."
  (pretty-tables-tests--with-buffer "Title\n\n| a | b |\n"
    (should (memq #'pretty-tables--check-remapping post-command-hook))
    (run-hooks 'post-command-hook)
    (should (get-text-property (point-min) 'fontified))
    (text-scale-increase 1)
    (run-hooks 'post-command-hook)
    (should-not (get-text-property (point-min) 'fontified))
    (jit-lock-fontify-now)
    (face-remap-add-relative 'default :family "Monospace")
    (run-hooks 'post-command-hook)
    (should-not (get-text-property (point-min) 'fontified))
    (jit-lock-fontify-now)
    (run-hooks 'post-command-hook)
    (should (get-text-property (point-min) 'fontified))
    (pretty-tables-disable)
    (should-not (memq #'pretty-tables--check-remapping post-command-hook))))

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
  "The stripe face takes only the background of `hl-line'.
The row face has no background; a background set on the package's
face takes the place of the default."
  (let ((weight (face-attribute 'hl-line :weight))
        (foreground (face-attribute 'hl-line :foreground)))
    (unwind-protect
        (progn
          (set-face-attribute 'hl-line nil :weight 'bold :foreground "red")
          (should (equal (pretty-tables--row-face t)
                         (list :inherit 'pretty-tables-stripe
                               :background pretty-tables-tests--stripe-colour)))
          (should (eq (pretty-tables--row-face nil) 'pretty-tables-row))
          (should-not (eq (face-attribute 'pretty-tables-stripe :weight nil t)
                          'bold))
          (set-face-attribute 'pretty-tables-row nil :background "#123456")
          (should (equal (plist-get (pretty-tables--row-face nil) :background)
                         "#123456")))
      (set-face-attribute 'hl-line nil :weight weight :foreground foreground)
      (set-face-attribute 'pretty-tables-row nil :background 'unspecified))))

(ert-deftest pretty-tables-test-theme-redraws ()
  "Enabling a theme draws the tables again with the new background."
  (pretty-tables-tests--with-buffer pretty-tables-tests--four-rows
    (unwind-protect
        (progn
          (set-face-attribute 'hl-line nil :background "#654321")
          (run-hook-with-args 'enable-theme-functions 'user)
          (jit-lock-fontify-now)
          (should (member (list :inherit 'pretty-tables-stripe
                                :background "#654321")
                          (pretty-tables-tests--faces
                           (nth 3 (pretty-tables-tests--row-strings))))))
      (set-face-attribute 'hl-line nil
                          :background pretty-tables-tests--stripe-colour))))

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
  "The face whose background the stripe rows take is defined once the package is."
  (should (facep 'hl-line)))

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

(ert-deftest pretty-tables-test-borders-lines-terminal ()
  "On a text terminal, `lines' draws box-drawing characters.
The adaptor's separator is not called.  A separator at the top of the
table is drawn as a row."
  (let ((pretty-tables-borders 'lines))
    (pretty-tables-tests--with-buffer
        "Title\n\n|---|---|\n| a | b |\n| r0 | x |\n"
      (should (equal (pretty-tables-tests--rows)
                     '("├────┼───┤" "│ a  │ b │" "│ r0 │ x │")))
      (should (memq 'pretty-tables-border
                    (pretty-tables-tests--faces
                     (car (pretty-tables-tests--row-strings))))))))

(defun pretty-tables-tests--underlined-p (string)
  "Return non-nil when STRING has a face that underlines at the descent line."
  (seq-some (lambda (face)
              (and (consp face)
                   (plist-get (plist-get face :underline) :position)))
            (pretty-tables-tests--faces string)))

(ert-deftest pretty-tables-test-borders-lines-hide-separator ()
  "With `lines', a separator after a row is hidden with its newline.
The row before it is underlined in its last screen line; with
`ascii', nothing is hidden or underlined."
  (let ((pretty-tables-borders 'lines))
    (pretty-tables-tests--with-buffer
        "Title\n\n| a<br>b | c |\n|---|---|\n| r0 | x |\n"
      (let* ((ovs (pretty-tables-tests--overlays))
             (sep (nth 1 ovs))
             (header (overlay-get (nth 0 ovs) 'pretty-tables-string))
             (newline (string-search "\n" header)))
        (should (equal (overlay-get sep 'display) ""))
        (should (equal (overlay-get sep 'before-string) ""))
        (should (eq (overlay-end sep) (overlay-start (nth 2 ovs))))
        (should-not (pretty-tables-tests--underlined-p
                     (substring header 0 newline)))
        (should (pretty-tables-tests--underlined-p
                 (substring header (1+ newline))))
        (should-not (pretty-tables-tests--underlined-p
                     (overlay-get (nth 2 ovs) 'pretty-tables-string))))
      (setq-local pretty-tables-borders 'ascii)
      (jit-lock-fontify-now)
      (let ((ovs (pretty-tables-tests--overlays)))
        (should (equal (substring-no-properties
                        (overlay-get (nth 1 ovs) 'pretty-tables-string))
                       "|----|---|"))
        (should (eq (overlay-end (nth 1 ovs))
                    (1- (overlay-start (nth 2 ovs)))))
        (should-not (pretty-tables-tests--underlined-p
                     (overlay-get (nth 0 ovs) 'pretty-tables-string)))))))

(defun pretty-tables-tests--spacing ()
  "Return the `line-spacing' of each spacing overlay, by position."
  (mapcar (lambda (ov) (cons (overlay-start ov) (overlay-get ov 'line-spacing)))
          (seq-filter (lambda (ov) (overlay-get ov 'pretty-tables-spacing))
                      (overlays-in (point-min) (point-max)))))

(ert-deftest pretty-tables-test-separator-spacing ()
  "With `lines', the newline of an underlined row gets a `line-spacing'.
It is `(t . RATIO)' with RATIO the option, on the newline after the
row; it is not added with `ascii' or with 0, and drawing the table
again replaces it."
  (let ((pretty-tables-borders 'lines))
    (pretty-tables-tests--with-buffer
        "Title\n\n| a | b |\n|---|---|\n| r0 | x |\n"
      (let ((newline (overlay-end (car (pretty-tables-tests--overlays)))))
        (should (eql (char-after newline) ?\n))
        (should (equal (pretty-tables-tests--spacing)
                       (list (cons newline '(t . 0.25)))))
        (setq-local pretty-tables-separator-spacing 0.5)
        (jit-lock-fontify-now)
        (should (equal (pretty-tables-tests--spacing)
                       (list (cons newline '(t . 0.5)))))
        (setq-local pretty-tables-separator-spacing 0)
        (jit-lock-fontify-now)
        (should-not (pretty-tables-tests--spacing))
        (kill-local-variable 'pretty-tables-separator-spacing)
        (setq-local pretty-tables-borders 'ascii)
        (jit-lock-fontify-now)
        (should-not (pretty-tables-tests--spacing))))))

(defun pretty-tables-tests--displays (string)
  "Return the `display' and `face' of each character of STRING."
  (mapcar (lambda (i)
            (list (get-text-property i 'display string)
                  (get-text-property i 'face string)))
          (number-sequence 0 (1- (length string)))))

(ert-deftest pretty-tables-test-borders-lines-graphic ()
  "On a graphical display, `lines' draws 1-pixel lines.
Each vertical line is a 1-pixel stretch in reverse video in a column
of 10 pixels: in the middle between two columns, on the outer side at
the left and right edges.  In a data row, all the space between two
lines or pieces of text is one stretch.  A separator row at the top
of the table is a stretch per column with an underline at the descent
line, and the other stretches of its vertical lines have one too."
  (let ((pretty-tables-borders 'lines)
        (pretty-tables-stripe-rows nil))
    (pretty-tables-tests--with-pixels
      (pretty-tables-tests--with-buffer
          "Title\n\n|---|---|\n| a | b |\n| r0 | x |\n"
        (let* ((rows (pretty-tables-tests--row-strings))
               (line '((space :width (1))
                       (:inherit pretty-tables-border :inverse-video t)))
               (displays
                (lambda (face)
                  (let ((edge (list '(space :width (- width (1))) face))
                        (half (list '(space :width (0.5 . width)) face))
                        (rest (list '(space :width (- (0.5 . width) (0.5)))
                                    face)))
                    (list (list line edge) (list half line rest)
                          (list edge line)))))
               (rule (funcall displays
                              '(:inherit pretty-tables-border :underline (:position t))))
               (data-row (pretty-tables-tests--displays (nth 2 rows))))
          (should (equal (substring-no-properties (nth 2 rows)) "  r0   x  "))
          ;; Columns of 20 and 10 pixels, with 10 on each side.
          (should (equal data-row
                         (list line '((space :width (19)) nil)
                               '(nil nil) '(nil nil)
                               '((space :width (15)) nil) line
                               '((space :width (14)) nil)
                               '(nil nil)
                               '((space :width (19)) nil) line)))
          (should (equal (pretty-tables-tests--displays (nth 0 rows))
                         (append (nth 0 rule)
                                 ;; The columns are 20 and 10 pixels
                                 ;; wide, with 10 on each side.
                                 (list (list '(space :width (40))
                                             (cadr (car (nth 1 rule)))))
                                 (nth 1 rule)
                                 (list (list '(space :width (30))
                                             (cadr (car (nth 1 rule)))))
                                 (nth 2 rule)))))))))

;;; The pixel layout

(ert-deftest pretty-tables-test-pixel-rows ()
  "In pixels, every row of a table is as wide as the others.
An `i' is 4 pixels wide, so `iiii' is narrower than `ab', and its cell
is padded with the pixels left.  The padding and the space of one
column on each side of a cell are one stretch."
  (pretty-tables-tests--with-pixels
    (pretty-tables-tests--with-buffer "Title\n\n| iiii | b |\n| ab | c |\n"
      (let ((rows (pretty-tables-tests--row-strings)))
        (should (equal (mapcar #'pretty-tables-tests--pixel-width rows)
                       ;; 10 per `|', 20 per cell's sides, 20 and 10 of text.
                       '(100 100)))
        (should (equal (substring-no-properties (car rows)) "| iiii | b |"))
        (should (equal (get-text-property 1 'display (car rows))
                       '(space :width (10))))
        ;; 4 pixels of padding and 10 of space.
        (should (equal (get-text-property 6 'display (car rows))
                       '(space :width (14))))))))

(defun pretty-tables-tests--as-columns (string)
  "Return STRING with each `space' display read as spaces of 10 pixels."
  (let ((i 0) (parts nil))
    (while (< i (length string))
      (let ((display (get-text-property i 'display string))
            (next (next-single-property-change i 'display string (length string))))
        (push (pcase display
                (`(space :width ,w)
                 (make-string (/ (pretty-tables-tests--space-pixels w) 10) ?\s))
                (_ (substring-no-properties string i next)))
              parts)
        (setq i next)))
    (apply #'concat (nreverse parts))))

(ert-deftest pretty-tables-test-pixel-as-columns ()
  "With every character one column wide, pixels draw what columns draw.
The table is narrowed and wrapped; each stretch is read as spaces."
  (let* ((text "Title\n\n| alpha beta gamma | delta epsilon |\n|---|---|\n| one two three four five | six | |\n")
         (draw (lambda (as-text)
                 (pretty-tables-tests--with-buffer text
                   (setq-local pretty-tables-width 30)
                   (jit-lock-refontify)
                   (jit-lock-fontify-now)
                   (mapcar as-text (pretty-tables-tests--row-strings))))))
    (should (equal (let ((pretty-tables-tests--char-pixels nil))
                     (pretty-tables-tests--with-pixels
                       (funcall draw #'pretty-tables-tests--as-columns)))
                   (funcall draw #'substring-no-properties)))))

(ert-deftest pretty-tables-test-pixel-wrap ()
  "In pixels, lines are wrapped and words broken at their measured width."
  (pretty-tables-tests--with-pixels
    (let ((pretty-tables--unit 10))
      ;; 12 + 10 + 12 pixels.
      (should (equal (pretty-tables--wrap "iii iii aa" 34) '("iii iii" "aa")))
      (should (equal (pretty-tables--wrap "iii iii aa" 33) '("iii" "iii" "aa")))
      ;; A paragraph that fits is not split.
      (should (equal (pretty-tables--wrap "iii  iii" 100) '("iii  iii")))
      (should (equal (pretty-tables--break-word "iiiiiiiiiia" 20)
                     '("iiiii" "iiiii" "a"))))))

(ert-deftest pretty-tables-test-pixel-column-widths ()
  "In pixels, columns are narrowed one column of pixels at a time."
  (let ((pretty-tables--unit 10))
    ;; 100 + W + 70 fits 300 at W = 125, 18 columns narrower.
    (should (equal (pretty-tables--column-widths '(100 305) 300 nil nil 70)
                   '(100 125)))
    ;; The floor is `pretty-tables-min-column-width' columns.
    (should (equal (pretty-tables--column-widths '(100 305) 100 nil nil 70)
                   '(80 80)))))

(ert-deftest pretty-tables-test-pixel-separator ()
  "In pixels, the adaptor draws a separator of `-' that fit each column.
Each piece is filled with a stretch to the width of its column, so the
vertical lines are where those of the other rows are."
  (pretty-tables-tests--with-pixels
    (pretty-tables-tests--with-buffer
        "Title\n\n| iiii | b |\n|---|---|\n| x | y |\n"
      (let ((rows (pretty-tables-tests--row-strings)))
        (should (equal (mapcar #'pretty-tables-tests--pixel-width rows)
                       '(96 96 96)))
        ;; 16 pixels of text and 20 of sides take three `-', 30 pixels.
        (should (equal (substring-no-properties (nth 1 rows)) "|--- |---|"))
        (should (equal (get-text-property 4 'display (nth 1 rows))
                       '(space :width (6))))))))

(ert-deftest pretty-tables-test-pixel-line-width ()
  "In pixels, `|' and the separator's `+' are centred in the wider of them."
  (let ((pretty-tables-tests--char-pixels '((?| . 4) (?+ . 8)))
        (separator (lambda (widths _alignments)
                     (concat "|"
                             (mapconcat (lambda (w) (make-string (+ 2 w) ?-))
                                        widths "+")
                             "|"))))
    (pretty-tables-tests--with-pixels
      (let ((pretty-tables--unit 10)
            (pretty-tables--adaptor (list :separator separator)))
        (should (= (pretty-tables--line-width 2 '(left left)) 8))
        (let ((pretty-tables--line 8))
          ;; `|' is 4 pixels wide, with 2 on each side.
          (let ((line (pretty-tables--pixel-line '("ab" "cd") '(20 20)
                                                 '(left left))))
            (should (equal (substring-no-properties line) " | ab | cd | "))
            (should (equal (mapcar #'car (pretty-tables-tests--displays line))
                           '((space :width (2)) nil (space :width (12)) nil nil
                             (space :width (12)) nil (space :width (12)) nil nil
                             (space :width (12)) nil (space :width (2)))))
            (should (= (pretty-tables-tests--pixel-width line)
                       (+ (* 3 8) (* 2 40)))))
          ;; Two columns of 20 pixels and 10 on each side take four `-'
          ;; each; `+' is 8 pixels wide already.
          (let ((rule (pretty-tables--separator '(20 20) '(left left))))
            (should (equal (substring-no-properties rule) " | ----+---- | "))
            (should (= (pretty-tables-tests--pixel-width rule)
                       (+ (* 3 8) (* 2 40))))))
        (let ((pretty-tables-borders 'lines))
          (should-not (pretty-tables--line-width 2 '(left left))))))))

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

(ert-deftest pretty-tables-test-typing-in-revealed-row ()
  "Typing in the revealed row does not draw the table again.
The other rows keep their overlays and strings, also when the whole
table is fontified again, as `markdown-ts-appear' has it after each
change; when point leaves the row, the table is drawn with the widths
of the new text.  A newline typed in the row draws the table at once."
  (pretty-tables-tests--with-buffer "Title\n\n| a | b |\n| c | d |\n| e | f |\n"
    (let ((ovs (pretty-tables-tests--overlays))
          (this-command 'self-insert-command))
      (pretty-tables-tests--goto-row 1)
      (pretty-tables--reveal)
      (search-forward "c")
      (insert "ccc")
      (should (eq pretty-tables--edited 'row))
      ;; Within the table, the adaptor is not asked for the tables.
      (let ((calls 0)
            (table (overlay-get (car ovs) 'pretty-tables-table)))
        (cl-letf* ((tables (symbol-function 'pretty-tables-tests--tables))
                   ((symbol-function 'pretty-tables-tests--tables)
                    (lambda (beg end)
                      (setq calls (1+ calls))
                      (funcall tables beg end))))
          (jit-lock-refontify (car table) (cdr table))
          (jit-lock-fontify-now)
          (should (= calls 0))
          ;; Past the table, it is, and the table is still not drawn.
          (jit-lock-refontify)
          (jit-lock-fontify-now)
          (should (> calls 0))))
      (should (equal (pretty-tables-tests--overlays) ovs))
      ;; The revealed row keeps the string it had too.
      (should (equal (pretty-tables-tests--rows)
                     '("| a | b |" "| c | d |" "| e | f |")))
      ;; Leaving the row draws the table with the new width.
      (pretty-tables-tests--goto-row 2)
      (pretty-tables--reveal)
      (should-not pretty-tables--edited)
      (jit-lock-fontify-now)
      (should-not (memq (car (pretty-tables-tests--overlays)) ovs))
      (should (equal (substring-no-properties
                      (overlay-get (car (pretty-tables-tests--overlays))
                                   'pretty-tables-string))
                     "| a    | b |"))
      ;; A newline typed in the revealed row reaches past its line.
      (setq ovs (pretty-tables-tests--overlays))
      (end-of-line)
      (insert "\n| g | h |")
      (should (eq pretty-tables--edited 'other))
      (jit-lock-fontify-now)
      (should-not pretty-tables--edited)
      (should-not (memq (car (pretty-tables-tests--overlays)) ovs)))))

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
