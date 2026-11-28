;;; pretty-tables-autoloads-tests.el --- Tests for the generated autoloads -*- lexical-binding: t; -*-

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
;; Package managers load the generated autoloads file before any file of
;; the package, so it must not call anything the package defines.  The
;; tests generate the autoloads from a copy of the sources, laid out as
;; one package or as one package per file, and load them in a fresh
;; Emacs.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defconst pretty-tables-autoloads-tests--root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Directory of the package sources.")

(defconst pretty-tables-autoloads-tests--adaptors
  '(("pretty-tables-for-org" pretty-tables-for-org-mode org-mode)
    ("pretty-tables-for-markdown" pretty-tables-for-markdown-mode
     markdown-ts-mode))
  "Each adaptor: its file, its mode and the major modes of the command.")

(defun pretty-tables-autoloads-tests--emacs (&rest args)
  "Run a fresh `emacs -Q --batch' with ARGS.
Return a cons of the exit status and the output."
  (with-temp-buffer
    (let ((status (apply #'call-process
                         (expand-file-name invocation-name invocation-directory)
                         nil t nil "-Q" "--batch" args)))
      (cons status (buffer-string)))))

(defun pretty-tables-autoloads-tests--package (dir name files)
  "Copy FILES of the sources to DIR, and generate the autoloads of NAME there.
Return the file of the autoloads."
  (make-directory dir t)
  (dolist (file files)
    (copy-file (expand-file-name file pretty-tables-autoloads-tests--root)
               (file-name-as-directory dir)))
  (let ((gen (pretty-tables-autoloads-tests--emacs
              "--eval" "(require 'package)"
              "--eval" (format "(package-generate-autoloads %S %S)" name dir)))
        (autoloads (expand-file-name (concat name "-autoloads.el") dir)))
    (ert-info ((cdr gen))
      (should (file-exists-p autoloads)))
    autoloads))

(defun pretty-tables-autoloads-tests--check (dirs autoloads)
  "Load AUTOLOADS in a fresh Emacs with DIRS on `load-path', and check them.
Each adaptor's mode is a command autoloaded for its major modes, and
calling the autoload loads its file."
  (let ((result
         (apply #'pretty-tables-autoloads-tests--emacs
                (append
                 (mapcan (lambda (dir) (list "-L" dir)) dirs)
                 (mapcan (lambda (file) (list "-l" file)) autoloads)
                 (list
                  "--eval"
                  (format
                   "%S"
                   `(dolist (adaptor ',pretty-tables-autoloads-tests--adaptors)
                      (let ((mode (nth 1 adaptor))
                            (modes (nthcdr 2 adaptor)))
                        (unless (and (autoloadp (symbol-function mode))
                                     (commandp mode)
                                     (equal (command-modes mode) modes))
                          (error "Not autoloaded for %S: %S" modes mode))
                        (autoload-do-load (symbol-function mode) mode)
                        (when (autoloadp (symbol-function mode))
                          (error "Not defined by its file: %S" mode))))))))))
    (ert-info ((cdr result))
      (should (eq 0 (car result))))))

(ert-deftest pretty-tables-autoloads-one-package ()
  "The autoloads of the sources as one package load without the macro."
  (let ((dir (make-temp-file "pretty-tables-autoloads" t)))
    (unwind-protect
        (pretty-tables-autoloads-tests--check
         (list dir)
         (list (pretty-tables-autoloads-tests--package
                dir "pretty-tables"
                (directory-files pretty-tables-autoloads-tests--root
                                 nil "\\`pretty-tables.*\\.el\\'"))))
      (delete-directory dir t))))

(ert-deftest pretty-tables-autoloads-package-per-file ()
  "The autoloads of each file as its own package load without the macro.
That is how the README installs the adaptors, and how MELPA builds them."
  (let* ((root (make-temp-file "pretty-tables-autoloads" t))
         (names (cons "pretty-tables"
                      (mapcar #'car pretty-tables-autoloads-tests--adaptors)))
         (dirs (mapcar (lambda (name) (expand-file-name name root)) names)))
    (unwind-protect
        (pretty-tables-autoloads-tests--check
         dirs
         (cl-mapcar (lambda (dir name)
                      (pretty-tables-autoloads-tests--package
                       dir name (list (concat name ".el"))))
                    dirs names))
      (delete-directory root t))))

(ert-deftest pretty-tables-autoloads-cookie-matches-mode ()
  "The `autoload' form on an adaptor's cookie line matches its mode.
It names the mode's file, and has the mode's doc string, argument list
and major modes."
  (dolist (adaptor pretty-tables-autoloads-tests--adaptors)
    (with-temp-buffer
      (insert-file-contents (expand-file-name
                             (concat (car adaptor) ".el")
                             pretty-tables-autoloads-tests--root))
      (re-search-forward "^;;;###autoload (autoload ")
      (goto-char (+ (match-beginning 0) (length ";;;###autoload ")))
      (let ((cookie (read (current-buffer))))
        (re-search-forward "^(pretty-tables-define-mode ")
        (goto-char (match-beginning 0))
        (let ((form (read (current-buffer))))
          (should (equal (nth 1 cookie) (list 'quote (nth 1 adaptor))))
          (should (equal (nth 1 form) (nth 1 adaptor)))
          (should (equal (nth 2 cookie) (car adaptor)))
          (should (equal (nth 3 cookie)
                         (concat (nth 2 form) "\n\n(fn &optional ARG)")))
          (should (equal (nth 4 cookie)
                         (list 'quote
                               (plist-get (nthcdr 3 form) :interactive))))
          (should (equal (plist-get (nthcdr 3 form) :interactive)
                         (nthcdr 2 adaptor))))))))

(provide 'pretty-tables-autoloads-tests)
;;; pretty-tables-autoloads-tests.el ends here
