;;; vc-accurev.el --- VC backend for the Accurev version-control system

;; Copyright (C) 2008 Bryan Shell

;; Author:      Bryan Shell
;; Maintainer:  Bryan Shell

;;; Commentary:

;;; Bugs:

;;; Code:

(eval-when-compile
  (require 'vc)
  (require 'cl))

(require 'xml)

(add-to-list 'vc-handled-backends 'Accurev)

;; Clear the vc cache to force vc-call to check again and discover new
;; fuctions when we reload this file.
(put 'Accurev 'vc-functions nil)

;;;
;;; Customization options
;;;

(defgroup vc-accurev nil
  "VC Accurev backen."
  :version "22.2"
  :group 'vc)

(defcustom vc-accurev-program "accurev"
  "Name of the accurev command (excluding any arguments.)"
  :group 'vc-accurev
  :type 'string)

(defcustom vc-accurev-global-switches nil
  "String/list of strings specifying extra switches for accurev any command under VC."
  :type '(choice (const :tag "None" nil)
		 (string :tag "Argument String")
		 (repeat :tag "Argument List" :value ("") string))
  :group 'vc-accurev)

;;;
;;; State-querying functions
;;;

;;;###autoload (defun vc-accurev-registered (file)
;;;###autoload   (if (executable-find "accurev")
;;;###autoload       (progn
;;;###autoload 	       (load "vc-accurev")
;;;###autoload 	       (vc-accurev-registered file))))

 (defun vc-accurev-registered (file)
   "Return non-nil if FILE is registered with Accurev."
   (let ((state (vc-accurev-state file)))
     (not (memq state '(nil unregistered ignored)))))

(defun vc-accurev-state (file)
  "Return the current version control state of FILE."
  (let ((status (vc-accurev--get-status-for-file file)))
    (vc-accurev-status->status status)))

(defun vc-accurev-dir-status (dir update-function)
  "Return a list of (FILE STATE EXTRA) entries for DIR."
  (let ((result nil)
	(status (vc-accurev--get-status dir)))
    (dolist (x status) 
      (push (list (vc-accurev-status->file x)
		  (vc-accurev-status->status x))
	    result))
    (funcall update-function result nil)))

(defun vc-accurev-working-revision (file)
  "Return the working revision of FILE."
  (let ((status (vc-accurev--get-status-for-file file)))
    (vc-accurev-status->named-revision status)))

(defun vc-accurev-checkout-model (file)
  "Accurev specific version of `vc-checkout-model'."
  'implicit)

;;;
;;; State-changing functions
;;;

(defun vc-accurev-register (file &optional rev comment)
  "Register FILE into the Accurev version-control system.
COMMENT can be used to provide an initial description of FILE.

`vc-register-switches' and `vc-accurev-register-switches' are passed to
the Accurev command (in that order)."
  (apply 'vc-accurev-command nil 0 file "add"
	 (if comment (concat "-c" comment))
	 (vc-switches 'ACCUREV 'register)))

(defalias 'vc-accurev-responsible-p 'vc-accurev-root
  "Return non-nil if CVS thinks it is responsible for FILE.")

(defalias 'vc-cvs-could-register 'vc-cvs-responsible-p
  "Return non-nil if FILE could be registered in Meta-CVS.
This is only possible if Meta-CVS is responsible for FILE's directory.")

(defun vc-accurev-checkin (file rev comment)
  "Meta-CVS-specific version of `vc-backend-checkin'."
  (unless (or (not rev) (vc-accurev-valid-version-number-p rev))
    (if (not (vc-accurev-valid-symbolic-tag-name-p rev))
	(error "%s is not a valid symbolic tag name" rev)
      ;; If the input revision is a valid symbolic tag name, we create it
      ;; as a branch, commit and switch to it.
      ;; This file-specific form of branching is deprecated.
      ;; We can't use `accurev branch' and `accurev switch' because they cannot
      ;; be applied just to this one file.
      (apply 'vc-accurev-command nil 0 file "tag" "-b" (list rev))
      (apply 'vc-accurev-command nil 0 file "update" "-r" (list rev))
      (vc-file-setprop file 'vc-accurev-sticky-tag rev)
      (setq rev nil)))
  ;; This commit might cvs-commit several files (e.g. MAP and TYPES)
  ;; so using numbered revs here is dangerous and somewhat meaningless.
  (when rev (error "Cannot commit to a specific revision number"))
  (let ((status (apply 'vc-accurev-command nil 1 file
		       "ci" "-m" comment
		       (vc-switches 'ACCUREV 'checkin))))
    (set-buffer "*vc*")
    (goto-char (point-min))
    (when (not (zerop status))
      ;; Check checkin problem.
      (cond
       ((re-search-forward "Up-to-date check failed" nil t)
        (vc-file-setprop file 'vc-state 'needs-merge)
        (error (substitute-command-keys
                (concat "Up-to-date check failed: "
                        "type \\[vc-next-action] to merge in changes"))))
       (t
        (pop-to-buffer (current-buffer))
        (goto-char (point-min))
        (shrink-window-if-larger-than-buffer)
        (error "Check-in failed"))))
    ;; Update file properties
    (vc-file-setprop
     file 'vc-workfile-version
     (vc-parse-buffer "^\\(new\\|initial\\) revision: \\([0-9.]+\\)" 2))
    ;; Forget the checkout model of the file, because we might have
    ;; guessed wrong when we found the file.  After commit, we can
    ;; tell it from the permissions of the file (see
    ;; vc-accurev-checkout-model).
    (vc-file-setprop file 'vc-checkout-model nil)

    ;; if this was an explicit check-in (does not include creation of
    ;; a branch), remove the sticky tag.
    (if (and rev (not (vc-accurev-valid-symbolic-tag-name-p rev)))
	(vc-accurev-command nil 0 file "update" "-A"))))

(defun vc-accurev-find-version (file rev buffer)
  (apply 'vc-accurev-command
	 buffer 0 file
	 "-Q"				; suppress diagnostic output
	 "update"
	 (and rev (not (string= rev ""))
	      (concat "-r" rev))
	 "-p"
	 (vc-switches 'ACCUREV 'checkout)))

(defun vc-accurev-checkout (file &optional editable rev)
  (message "Checking out %s..." file)
  (with-current-buffer (or (get-file-buffer file) (current-buffer))
    (vc-call update file editable rev (vc-switches 'ACCUREV 'checkout)))
  (vc-mode-line file)
  (message "Checking out %s...done" file))

(defun vc-accurev-update (file editable rev switches)
  (if (and (file-exists-p file) (not rev))
      ;; If no revision was specified, just make the file writable
      ;; if necessary (using `cvs-edit' if requested).
      (and editable (not (eq (vc-accurev-checkout-model file) 'implicit))
	   (if vc-accurev-use-edit
	       (vc-accurev-command nil 0 file "edit")
	     (set-file-modes file (logior (file-modes file) 128))
	     (if (equal file buffer-file-name) (toggle-read-only -1))))
    ;; Check out a particular version (or recreate the file).
    (vc-file-setprop file 'vc-workfile-version nil)
    (apply 'vc-accurev-command nil 0 file
	   (if editable "-w")
	   "update"
	   ;; default for verbose checkout: clear the sticky tag so
	   ;; that the actual update will get the head of the trunk
	   (if (or (not rev) (string= rev ""))
	       "-A"
	     (concat "-r" rev))
	   switches)))

(defun vc-svn-delete-file (file)
  (vc-svn-command nil 0 file "defunct"))

(defun vc-accurev-rename-file (old new)
  (vc-accurev-command nil 0 new "move" (file-relative-name old)))

(defun vc-accurev-revert (file &optional contents-done)
  "Revert FILE to the version it was based on."
  (vc-default-revert 'ACCUREV file contents-done)
  (unless (eq (vc-checkout-model file) 'implicit)
    (if vc-accurev-use-edit
        (vc-accurev-command nil 0 file "unedit")
      ;; Make the file read-only by switching off all w-bits
      (set-file-modes file (logand (file-modes file) 3950)))))

(defun vc-accurev-merge (file first-version &optional second-version)
  "Merge changes into current working copy of FILE.
The changes are between FIRST-VERSION and SECOND-VERSION."
  (vc-accurev-command nil 0 file
		   "update" "-kk"
		   (concat "-j" first-version)
		   (concat "-j" second-version))
  (vc-file-setprop file 'vc-state 'edited)
  (with-current-buffer (get-buffer "*vc*")
    (goto-char (point-min))
    (if (re-search-forward "conflicts during merge" nil t)
        1				; signal error
      0)))				; signal success

(defun vc-accurev-merge-news (file)
  "Merge in any new changes made to FILE."
  (message "Merging changes into %s..." file)
  ;; (vc-file-setprop file 'vc-workfile-version nil)
  (vc-file-setprop file 'vc-checkout-time 0)
  (vc-accurev-command nil 0 file "update")
  ;; Analyze the merge result reported by Meta-CVS, and set
  ;; file properties accordingly.
  (with-current-buffer (get-buffer "*vc*")
    (goto-char (point-min))
    ;; get new workfile version
    (if (re-search-forward
	 "^Merging differences between [0-9.]* and \\([0-9.]*\\) into" nil t)
	(vc-file-setprop file 'vc-workfile-version (match-string 1))
      (vc-file-setprop file 'vc-workfile-version nil))
    ;; get file status
    (prog1
        (if (eq (buffer-size) 0)
            0 ;; there were no news; indicate success
          (if (re-search-forward
               (concat "^\\([CMUP] \\)?"
                       ".*"
                       "\\( already contains the differences between \\)?")
               nil t)
              (cond
               ;; Merge successful, we are in sync with repository now
               ((or (match-string 2)
                    (string= (match-string 1) "U ")
                    (string= (match-string 1) "P "))
                (vc-file-setprop file 'vc-state 'up-to-date)
                (vc-file-setprop file 'vc-checkout-time
                                 (nth 5 (file-attributes file)))
                0);; indicate success to the caller
               ;; Merge successful, but our own changes are still in the file
               ((string= (match-string 1) "M ")
                (vc-file-setprop file 'vc-state 'edited)
                0);; indicate success to the caller
               ;; Conflicts detected!
               (t
                (vc-file-setprop file 'vc-state 'edited)
                1);; signal the error to the caller
               )
            (pop-to-buffer "*vc*")
            (error "Couldn't analyze accurev update result")))
      (message "Merging changes into %s...done" file))))

;;;
;;; History functions
;;;

(defun vc-accurev-print-log (files buffer &optional shortlog start-revision limit)
  "Insert the revision log for FILES into BUFFER, or the *vc* buffer
if BUFFER is nil. If SHORTLOG is true insert a short version of the log."
  ;; I'm not sure how useful shortlog is.  Directories are real
  ;; elements and have histories; accurev doesn't recurse into them
  ;; for the histories of other children elements like other vcs.
  (vc-setup-buffer buffer)
  (let ((inhibit-read-only t))
    (with-current-buffer buffer
      (vc-accurev-command buffer 'async files "hist"
			  (if shortlog "-ft")))))

(define-derived-mode vc-accurev-log-view-mode log-view-mode "Accurev-Log-View"
  (require 'add-log) ;; we need the faces add-log
  ;; Don't have file markers, so use impossible regexp.
  (set (make-local-variable 'log-view-file-re) "^[ \t]*element:[ \t]+\\([^\n]+\\)")
  (set (make-local-variable 'log-view-per-file-logs) nil)
  (set (make-local-variable 'log-view-message-re) "^[ \t]*transaction[ \t]+\\([0-9]+\\);")
  (set (make-local-variable 'log-view-font-lock-keywords)
       (append
	`((,log-view-file-re
	   (1 'log-view-file))
	  (,log-view-message-re
	   (1 'change-log-acknowledgement)
	   ("[ \t]+\\([^;]+\\);[ \t]+\\([0-9/]+ [0-9:]+\\)[ \t]+;[ \t]+user:[ \t]+\\([^;\n]+\\)" nil nil
	    (2 'change-log-date)
	    (3 'change-log-name))
	   ))
        '(("^[ \t]*eid:[ \t]\\([0-9]+\\)"
	   (1 'log-view-file))
	  ("^[ \t]+#\\([^\n]*\\)"
	   (1 'log-view-message))
	  ("^[ \t]+version \\([0-9]+/[0-9]+\\) (\\([0-9]+/[0-9]+\\))"
	   (1 'change-log-acknowledgement)
	   (2 'change-log-list))
	  ("^[ \t]+ancestor:[ \t]+(\\([0-9]+/[0-9]+\\))"
           (1 'change-log-function)
	   ("[ \t]+merged against:[ \t]+(\\([0-9]+/[0-9]+\\))" nil nil
	    (1 'change-log-conditionals)))))))

(defun vc-accurev-show-log-entry (revision)
  "Find entry for patch name REVISION in accurev change log buffer."
  (goto-char (point-min))
  (when revision
    (let (case-fold-search)
      (if (re-search-forward
           (concat "^[ \t]+version " (regexp-quote revision)) nil t)
          (beginning-of-line 0)
        (goto-char (point-min))))))

;;;
;;; Diff
;;;

(defun vc-accurev-diff (files &optional rev1 rev2 buffer)
  "Insert the diff for FILE into BUFFER, or the *vc-diff* buffer if
   BUFFER is nil.  If REV1 and REV2 are non-nil, report differences
   from REV1 to REV2.  If REV1 is nil, use the working revision (as
   found in the repository) as the older revision; if REV2 is nil,
   use the current working-copy contents as the newer revision.  This
   function should pass the value of (vc-switches BACKEND 'diff) to
   the backend command.  It should return a status of either 0 (no
   differences found), or 1 (either non-empty diff or the diff is
   run asynchronously)."
  (apply 'vc-accurev-command (or buffer "*vc-diff*") async files "diff"
	 (append
	  (if (not (or rev1 rev2)) (list "-b")) ;; diff to basis version
	  (if rev1 (list "-v" rev1))
	  (if rev2 (list "-V" rev2)))))

(defun vc-accurev-revision-completion-table (files)
  "Return a completion table for existing revisions of FILES.
   The default is to not use any completion table."
  (lexical-let ((files files)
		table)
    (setq table (lazy-completion-table
		 table (lambda () (vc-accurev--revision-table files))))
    table))

(defun vc-accurev--revision-table (files)
  "Return a completion table for existing revisions of FILES.
   This currently returns virtual versions."
  (with-temp-buffer
    (vc-accurev-command t nil files "hist" "-fx")
    (goto-char (point-min))
    (let ((ids ()))
      (while (re-search-forward "\\(?:virtualNamedVersion\\|virtual\\)=\"\\([^\"]+\\)\"" nil t)
	(push (match-string 1) ids))
      ids)))

;;;
;;; Annotate
;;;

(defun vc-accurev-annotate-command (file buffer &optional version)
  "Execute \"accurev annotate\" on FILE, inserting the contents in BUFFER.
Optional arg VERSION is a version to annotate from."
  (vc-accurev-command buffer 0 file "annotate" "-fuvd" (if version
							  (concat "-v" version))))

(defconst vc-accurev-annotate-time-regex "^\\S-+\\s-+\\S-+\\s-+\\([0-9]+\\)/\\([0-9]+\\)/\\([0-9]+\\)\\s-+\\([0-9]+\\):\\([0-9]+\\):\\([0-9]+\\)")

(defun vc-accurev-annotate-time ()
  "Return the time of the next annotation (as fraction of days)
systime, or nil if there is none."
  (let* ((bol (point))
	 (cache (get-text-property bol 'vc-accurev-annotate-time))
	 buffer-read-only)
    (cond (cache)
	  ((looking-at vc-accurev-annotate-time-regex)
	   (let ((year (string-to-number (match-string 1)))
		 (month (string-to-number (match-string 2)))
		 (day (string-to-number (match-string 3)))
		 (hour (string-to-number (match-string 4)))
		 (minute (string-to-number (match-string 5)))
		 (second (string-to-number (match-string 6))))
	     (put-text-property
	      bol (1+ bol) 'vc-accurev-annotate-time
	      (setq cache (cons
			   (match-end 0)
			   (vc-annotate-convert-time
			    (encode-time second minute hour day month year))))))))
    (when cache
      (goto-char (car cache))
      (cdr cache))))

(defun vc-accurev-annotate-extract-revision-at-line ()
  "Return the revision corresponding to the current line, or nil
if there is no revision corresponding to the current line."
  (save-excursion
    (beginning-of-line)
    (if (re-search-forward "^\\S-+\\s-+\\([0-9]+/[0-9]+\\)" (line-end-position) t)
	(match-string-no-properties 1)
      nil)))
		       

;;;
;;; Snapshot system
;;;

(defun vc-accurev-create-snapshot (dir name branchp)
  "Create a snapshot from the current DIR's basis stream with the given NAME.
If BRANCHP is non-nil, the current workspace is moved to that new
stream."
  (let ((basis (vc-accurev-basis-stream dir))
	(default-directory dir))
    (vc-accurev-command t 0 nil "mkstream" "-s" name "-b" basis))
  (when branchp (vc-accurev-retrieve-snapshot dir name nil)))
    
(defun vc-accurev-retrieve-snapshot (dir name update)
  "Retrieve a snapshot at and below DIR.
NAME is the name of the snapshot; if it is empty, do a `cvs update'.
If UPDATE is non-nil, then update (resynch) any affected buffers."
  (with-current-buffer (get-buffer-create "*vc*")
    (let ((default-directory dir)
	  (workspace (vc-accurev-workspace-name dir)))
      (erase-buffer)
      (if (and name (not (string= name "")))
	  (vc-accurev-command t 0 nil "chws" "-w" workspace "-b" name))
      (vc-accurev-command t 0 nil "update")
      (when update
	(goto-char (point-min))
	(while (not (eobp))
	  (if (looking-at (concat "\\("
				  "Removing " "\\|"
				  "Content ([^)]*) of " "\\|"
				  "Creating dir " "\\)"
				  "\"\\([^\"]*\""))
	      (let* ((file (expand-file-name (match-string 2) dir))
		     (state (match-string 1))
		     (buffer (find-buffer-visiting file)))
		(when buffer
		  (cond
		   ((string-match "Content\\|Creating" state)
		    (vc-file-setprop file 'vc-state 'up-to-date)
		    (vc-file-setprop file 'vc-workfile-version nil)
		    (vc-file-setprop file 'vc-checkout-time
				     (nth 5 (file-attributes file)))))
		  (vc-file-setprop file 'vc-accurev-backing-stream name)
		  (vc-file-setprop file 'vc-accurev-workspace workspace)
		  (vc-resynch-buffer file t t))))
	  (forward-line 1))))))

;;;
;;; Internal functions
;;;

(defun vc-accurev-command (buffer okstatus file-or-list &rest args)
  "A wrapper around `vc-do-command' for use in vc-accurev.el."
  (apply 'vc-do-command (or buffer "*vc*") okstatus
	 vc-accurev-program file-or-list
	 (if (stringp vc-accurev-global-switches)
	     (cons vc-accurev-global-switches args)
	   (append vc-accurev-global-switches args))))

(defun vc-accurev--get-status-for-file (file &optional flags function)
  (funcall (if (null function) 'identity function)
	   (vc-accurev--get-status file flags (lambda (x)
						(if (= (length x) 1)
						    (car x)
						  x)))))

(defun vc-accurev--get-status (files &optional flags function)
  "Retrieve all status information about FILES.  This drives other information services."
  (condition-case ()
      (let ((results '())
	    str)
	(with-temp-buffer
	  (vc-accurev-command t 0 files "stat" "-fxr" flags)
	  (setq str (xml-parse-region (point-min) (point-max))))
	(dolist (element (xml-get-children (xml-node-name str) 'element))
	  (let ((status (vc-accurev-create-status (xml-get-attribute-or-nil element 'location)))
		(stati (vc-accurev--parse-nested-statuses (xml-get-attribute-or-nil element 'status))))
	    (add-to-list 'results status 't)
	    (setf (vc-accurev-status->real-revision status) (xml-get-attribute-or-nil element 'Real))
	    (setf (vc-accurev-status->named-revision status) (xml-get-attribute-or-nil element 'namedVersion))
	    (setf (vc-accurev-status->virtual-revison status) (xml-get-attribute-or-nil element 'Virtual))
	    (setf (vc-accurev-status->element-id status) (xml-get-attribute-or-nil element 'id))
	    (setf (vc-accurev-status->element-type status) (xml-get-attribute-or-nil element 'elemType))
	    (setf (vc-accurev-status->status status) (car stati))
	    (setf (vc-accurev-status->extra-status status) (cadr stati))
	    (setf (vc-accurev-status->directory-p status) (xml-get-attribute-or-nil element 'dir))
	    (setf (vc-accurev-status->hierarchy-type status) (xml-get-attribute-or-nil element 'hierType))
	    (setf (vc-accurev-status->size status) (xml-get-attribute-or-nil element 'size))
	    (setf (vc-accurev-status->modified-time status) (xml-get-attribute-or-nil element 'modTime))))
	(funcall (if (null function) 'identity function) results))
    (error)))


(defun vc-accurev--parse-nested-statuses (stati)
  "Convert a list of accurev statuses into vc states"
  (let ((translation '(("backed" up-to-date . 0)
		       ("modified" edited . 1) 
		       ("stale" needs-update . 2)
		       ("overlap" needs-merge . 3)
		       ("underlap" needs-merge . 3)
		       ("member" added . 4)
		       ("kept" added . 4)
		       ("defunct" removed . 5)
		       ("missing" missing . 6)
		       ("excluded" missing . 6)
		       ("external" unregistered . 10)
		       ("no such elem" unregistered . 10)))
	(str stati)
	(result nil)
	(rest nil))
    (while (string-match "(\\([^)]*\\))\\(.*\\)" str)
      (let ((match (cdr (assoc (match-string 1 str) translation))))
	(setq str (match-string 2 str))
	(cond ((null match))
		; do nothing
	      ((null result)
		(setq result match))
	      ((< (cdr result) (cdr match))
		(push result rest)
		(setq result match))
	      (t
		(push match rest)))))
    (list (car result) (mapcar (lambda (x) (car x)) rest))))

(defun vc-accurev--parse-info (info)
  "Create a info structure from accurev's output"
  (goto-char (point-min))
  (while (not (eobp))
    (cond ((looking-at "Shell:\\s-+\\(.+\\)")
	   (setf (vc-accurev-info->shell info) (match-string 1)))
	  ((looking-at "Principal:\\s-+\\(.+\\)")
	   (setf (vc-accurev-info->principal info) (match-string 1)))
	  ((looking-at "Host:\\s-+\\(.+\\)")
	   (setf (vc-accurev-info->host info) (match-string 1)))
	  ((looking-at "Domain:\\s-+\\(.+\\)")
	   (setf (vc-accurev-info->domain info) (match-string 1)))
	  ((looking-at "client_ver:\\s-+\\(.+\\)")
	   (setf (vc-accurev-info->client-version info) (match-string 1)))
	  ((looking-at "Server name:\\s-+\\(.+\\)")
	   (setf (vc-accurev-info->server-name info) (match-string 1)))
	  ((looking-at "Port:\\s-+\\(.+\\)")
	   (setf (vc-accurev-info->port info) (match-string 1)))
	  ((looking-at "ACCUREV_BIN:\\s-+\\(.+\\)")
	   (setf (vc-accurev-info->bin info) (match-string 1)))
	  ((looking-at "server_ver:\\s-+\\(.+\\)")
	   (setf (vc-accurev-info->server-version info) (match-string 1)))
	  ((looking-at "Client time:\\s-+\\(.+\\)")
	   (setf (vc-accurev-info->client-time info) (match-string 1)))
	  ((looking-at "Server time:\\s-+\\(.+\\)")
	   (setf (vc-accurev-info->server-time info) (match-string 1)))
	  ((looking-at "Depot:\\s-+\\(.+\\)")
	   (setf (vc-accurev-info->depot info) (match-string 1)))
	  ((looking-at "Workspace/ref:\\s-+\\(.+\\)")
	   (setf (vc-accurev-info->workspace info) (match-string 1)))
	  ((looking-at "Basis:\\s-+\\(.+\\)")
	   (setf (vc-accurev-info->basis info) (match-string 1)))
	  ((looking-at "Top:\\s-+\\(.+\\)")
	   (setf (vc-accurev-info->top info) (match-string 1))))
    (forward-line 1)))

(defun vc-accurev--get-info (file)
  "Create a info structure from accurev's output"
  (let ((default-directory file)
	(info (vc-accurev-create-info)))
    (with-temp-buffer
      (vc-accurev-command 't 0 file "info" "-v")
      (vc-accurev--parse-info info)
      info)))

;;;
;;; Intermediate Structures
;;;

(defstruct (vc-accurev-info
	    (:copier nil)
	    (:type list)
	    (:constructor vc-accurev-create-info (&optional top depot workspace basis
							    server-name server-version))
	    (:conc-name vc-accurev-info->))
  top ;; root directory for the project workspace
  depot workspace basis server-name server-version principal
  domain port client-version server-time client-time
  host bin shell)

(defstruct (vc-accurev-status
	    (:copier nil)
	    (:type list)
	    (:constructor vc-accurev-create-status (file &optional real-revison status))
	    (:conc-name vc-accurev-status->))
  file
  real-revision
  named-revision
  virtual-revison
  element-id
  element-type
  status
  extra-status
  directory-p
  hierarchy-type
  size
  modified-time)

(provide 'vc-accurev)

;;; vc-accurev.el ends here
