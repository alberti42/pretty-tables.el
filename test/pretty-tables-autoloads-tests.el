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
;; test generates the file from a copy of the package and loads it in a
;; fresh Emacs.

;;; Code:

(require 'ert)

(defconst pretty-tables-autoloads-tests--root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Directory of the package sources.")

(defun pretty-tables-autoloads-tests--emacs (&rest args)
  "Run a fresh `emacs -Q --batch' with ARGS.
Return a cons of the exit status and the output."
  (with-temp-buffer
    (let ((status (apply #'call-process
                         (expand-file-name invocation-name invocation-directory)
                         nil t nil "-Q" "--batch" args)))
      (cons status (buffer-string)))))

(ert-deftest pretty-tables-autoloads-load-without-the-macro ()
  "The autoloads file loads in an Emacs where no package file is loaded."
  (let ((dir (make-temp-file "pretty-tables-autoloads" t)))
    (unwind-protect
        (progn
          (dolist (file (directory-files pretty-tables-autoloads-tests--root
                                         t "\\`pretty-tables.*\\.el\\'"))
            (copy-file file (file-name-as-directory dir)))
          (let ((gen (pretty-tables-autoloads-tests--emacs
                      "--eval" "(require 'package)"
                      "--eval" (format "(package-generate-autoloads %S %S)"
                                       "pretty-tables" dir))))
            (ert-info ((cdr gen))
              (should (file-exists-p
                       (expand-file-name "pretty-tables-autoloads.el" dir)))))
          (let ((result
                 (pretty-tables-autoloads-tests--emacs
                  "-l" (expand-file-name "pretty-tables-autoloads.el" dir)
                  "--eval"
                  (format "%S"
                          '(dolist (spec '((pretty-tables-for-org-mode org-mode)
                                           (pretty-tables-for-markdown-mode
                                            markdown-ts-mode)))
                             (let ((def (symbol-function (car spec))))
                               (unless (and (autoloadp def)
                                            (equal (nth 3 def) (cdr spec)))
                                 (error "Not autoloaded for %S: %S"
                                        (cdr spec) (car spec)))))))))
            (ert-info ((cdr result))
              (should (eq 0 (car result))))))
      (delete-directory dir t))))

(provide 'pretty-tables-autoloads-tests)
;;; pretty-tables-autoloads-tests.el ends here
