;;; org-table-shrink-check.el --- Compare Org's column shrinking with our copy  -*- lexical-binding: t -*-

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
;; `pretty-tables-for-org' advises Org's `org-table--shrink-columns' and
;; `org-table-expand'.  `test/fixtures/org-table-shrink.el' holds a copy
;; of the two.  This script reads both definitions from the source of
;; the Emacs that runs it and from the copy, drops their docstrings
;; (reading them drops comments and whitespace), and compares them.
;; When they differ, it prints a unified diff and exits with status 1;
;; when it cannot find a definition, with status 2.
;;
;;   emacs -Q -batch -l .github/scripts/org-table-shrink-check.el
;;
;; CI runs it on Emacs 31.1 and snapshot, in a job that is allowed to
;; fail.

;;; Code:

(require 'find-func)
(require 'pp)
(require 'org-table)

(defconst org-table-shrink-check-functions
  '(org-table--shrink-columns org-table-expand)
  "The functions of org-table.el compared with the copy.")

(defconst org-table-shrink-check-copy
  (expand-file-name "../../test/fixtures/org-table-shrink.el"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The file that holds the copy.")

(defun org-table-shrink-check--without-docstring (form)
  "Return the `defun' FORM without its docstring."
  (if (and (eq (car-safe form) 'defun) (stringp (nth 3 form)))
      (append (seq-take form 3) (nthcdr 4 form))
    form))

(defun org-table-shrink-check--read-defun (function buffer)
  "Return the `defun' of FUNCTION read from BUFFER, or nil."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward
             (format "^(defun %s[ \n]" (regexp-quote (symbol-name function)))
             nil t)
        (goto-char (match-beginning 0))
        (read (current-buffer))))))

(defun org-table-shrink-check--emacs-defun (function)
  "Return the `defun' of FUNCTION read from the source of this Emacs, or nil."
  (when-let* ((found (ignore-errors (find-function-noselect function t))))
    (with-current-buffer (car found)
      (save-excursion
        (goto-char (cdr found))
        (read (current-buffer))))))

(defun org-table-shrink-check--diff (expected actual)
  "Return a unified diff of the forms EXPECTED and ACTUAL, as a string."
  (let ((old (make-temp-file "org-copy-" nil ".el" (pp-to-string expected)))
        (new (make-temp-file "org-emacs-" nil ".el" (pp-to-string actual))))
    (unwind-protect
        (with-temp-buffer
          (call-process "diff" nil t nil "-u"
                        "--label" "copy (test/fixtures)" "--label"
                        (format "Emacs %s, Org %s" emacs-version (org-version))
                        old new)
          (buffer-string))
      (delete-file old)
      (delete-file new))))

(defun org-table-shrink-check ()
  "Compare `org-table-shrink-check-functions' with the copy; exit with a status."
  (let ((copy (find-file-noselect org-table-shrink-check-copy))
        (status 0))
    (dolist (function org-table-shrink-check-functions)
      (let ((expected (org-table-shrink-check--read-defun function copy))
            (actual (org-table-shrink-check--emacs-defun function)))
        (cond
         ((null expected)
          (message "%s: not in %s" function org-table-shrink-check-copy)
          (setq status 2))
         ((null actual)
          (message "%s: not defined, or no source found, in Emacs %s, Org %s"
                   function emacs-version (org-version))
          (setq status 2))
         ((equal (org-table-shrink-check--without-docstring expected)
                 (org-table-shrink-check--without-docstring actual))
          (message "%s: same as the copy in Emacs %s, Org %s"
                   function emacs-version (org-version)))
         (t
          (message "%s: differs from the copy in Emacs %s, Org %s:\n%s"
                   function emacs-version (org-version)
                   (org-table-shrink-check--diff
                    (org-table-shrink-check--without-docstring expected)
                    (org-table-shrink-check--without-docstring actual)))
          (setq status (if (= status 2) 2 1))))))
    (kill-emacs status)))

(org-table-shrink-check)

;;; org-table-shrink-check.el ends here
