;;; org-table-shrink.el --- Copy of two functions of Org's org-table.el  -*- lexical-binding: t -*-

;; Copied from GNU Emacs, lisp/org/org-table.el (Copyright (C) 2004-2026
;; Free Software Foundation, Inc.), Org 9.8.10 in Emacs 32.0.50, under
;; the GNU General Public License version 3 or later.  This file is data,
;; not code: nothing loads it.

;;; Commentary:
;;
;; `pretty-tables-for-org' advises `org-table--shrink-columns', which is
;; internal to Org, and `org-table-expand', so that a table is drawn
;; again when a column is shrunk or expanded.
;; `.github/scripts/org-table-shrink-check.el' compares the two
;; definitions below, without their docstrings, with those of the Emacs
;; that runs it, and prints a diff when they differ.  CI runs it on
;; Emacs 31.1 and snapshot.
;;
;; When it reports a difference: read the diff, decide whether the
;; advices in `pretty-tables-for-org.el' must follow, then replace the
;; definitions below with the new ones.

;;; Code:

(defun org-table--shrink-columns (columns beg end)
  "Shrink COLUMNS in a table.
COLUMNS is a sorted list of column numbers.  BEG and END are,
respectively, the beginning position and the end position of the
table."
  (org-with-wide-buffer
   (font-lock-ensure beg end)
   (dolist (c columns)
     (goto-char beg)
     (let ((align nil)
	   (width nil)
	   (fields nil))
       (while (< (point) end)
	 (catch :continue
	   (let* ((hline? (org-at-table-hline-p))
		  (separator (if hline? "+" "|")))
	     ;; Move to COLUMN.
	     (search-forward "|")
	     (or (= c 1)		;already there
		 (search-forward separator (line-end-position) t (1- c))
		 (throw :continue nil)) ;skip invalid columns
	     ;; Extract boundaries and contents from current field.
	     ;; Also set the column's width if we encounter a width
	     ;; cookie for the first time.
	     (let* ((start (point))
		    (end (progn
			   (skip-chars-forward (concat "^|" separator)
					       (line-end-position))
			   (point)))
		    (contents (if hline? 'hline
				(org-trim (buffer-substring start end)))))
	       (push (list start end contents) fields)
	       (when (and (not hline?)
			  (string-match "\\`<\\([lrc]\\)?\\([0-9]+\\)>\\'"
					contents))
		 (unless align (setq align (match-string 1 contents)))
		 (unless width
		   (setq width (string-to-number (match-string 2 contents))))))))
	 (forward-line))
       ;; Link overlays for current field to the other overlays in the
       ;; same column.
       (let ((chain (list 'siblings)))
	 (dolist (field fields)
	   (dolist (new (apply #'org-table--shrink-field
			       (or width 0) (or align "l") field))
	     (push new (cdr chain))
	     (overlay-put new 'org-table-column-overlays chain))))))))

;;;###autoload
(defun org-table-expand (&optional begin end)
  "Expand all columns in the table at point.
Optional arguments BEGIN and END, when non-nil, specify the
beginning and end position of the current table."
  (interactive)
  (unless (or begin (org-at-table-p)) (user-error "Not at a table"))
  (org-with-wide-buffer
   (let ((begin (or begin (org-table-begin)))
	 (end (or end (org-table-end))))
     (remove-overlays begin end 'org-overlay-type 'table-column-hide))))

;;; org-table-shrink.el ends here
