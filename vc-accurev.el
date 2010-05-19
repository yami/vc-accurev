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
   "Return non-nil if FILE is registered in this backend."
   (let ((info (vc-accurev--get-info file)))
     (vc-accurev-info->top info)))

(defun vc-accurev-state (file)
  "Accurev-specific version of `vc-state'."
  (with-temp-buffer
    (vc-accurev-command t 0 file "stat" "-fre")
    (last (vc-accurev-status->status (vc-accurev--parse-status file)))))

(defun vc-accurev-dir-state (dir &optional localp)
  ;; This would assume the Meta-CVS sandbox is synchronized.
  ;; (vc-accurev-cvs state file))
  "Meta-CVS-specific version of `vc-state'."
  (setq localp (or localp (vc-stay-local-p file)))
  (let ((default-directory dir))
    (with-temp-buffer
      (vc-accurev-command t 0 file "stat" "-fr" (if localp "-m" "-a"))
      (vc-accurev-parse-status))))

(defun vc-accurev-workfile-version (file)
  "Return the working revision of FILE.  This is the revision fetched
   by the last checkout or upate, not necessarily the same thing as the
   head or tip revision.  Should return \"0\" for a file added but not yet
   committed."
  (with-temp-buffer
    (vc-accurev-command t 0 file "stat" "-fre")
    (vc-accurev-status->element-target (vc-accurev--parse-status file))))

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

(defun vc-accurev-print-log (files &optional buffer)
  "Insert the revision log for FILES into BUFFER, or the *vc* buffer
   if BUFFER is nil.  (Note: older versions of this function expected
   only a single file argument.)"
  (vc-setup-buffer buffer)
  (let ((inhibit-read-only t))
    (with-current-buffer buffer
      (vc-accurev-command buffer 'async files "hist"))))

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

;;;
;;; Diff
;;;

(defun vc-accurev-diff (file &optional oldvers newvers buffer)
  "Get a difference report using Accurev between two versions of FILE."
  (unless buffer (setq buffer "*vc-diff*"))
  (if (string= (vc-workfile-version file) "0")
      ;; This file is added but not yet committed; there is no master file.
      (if (or oldvers newvers)
	  (error "No revisions of %s exist" file)
	;; We regard this as "changed".
	;; Diff it against /dev/null.
	;; Note: this is NOT a "accurev diff".
	(apply 'vc-do-command buffer 1 "diff" file
	       (append (vc-switches nil 'diff) '("/dev/null")))
	;; Even if it's empty, it's locally modified.
	1)
    (let* ((async (and (not vc-disable-async-diff)
                       (vc-stay-local-p file)
                       (fboundp 'start-process)))
	   ;; Run the command from the root dir so that `accurev filt' returns
	   ;; valid relative names.
	   (default-directory (vc-accurev-root file))
	   (status
	    (apply 'vc-accurev-command buffer
		   (if async 'async 1)
		   file "diff"
		   (and oldvers (concat "-v" oldvers))
		   (and newvers (concat "-V" newvers))
		   (vc-switches 'ACCUREV 'diff))))
      (if async 1 status))))	       ; async diff, pessimistic assumption.

(defun vc-accurev-diff-tree (dir &optional rev1 rev2)
  "Diff all files at and below DIR."
  (with-current-buffer "*vc-diff*"
    ;; Run the command from the root dir so that `accurev filt' returns
    ;; valid relative names.
    (setq default-directory (vc-accurev-root dir))
    ;; cvs diff: use a single call for the entire tree
    (let ((coding-system-for-read (or coding-system-for-read 'undecided)))
      (apply 'vc-accurev-command "*vc-diff*" 1 dir "diff" "-a"
	     (and rev1 (concat "-v" rev1))
	     (and rev2 (concat "-V" rev2))
	     (vc-switches 'ACCUREV 'diff)))))

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

(defun vc-accurev--parse-status (&optional filename)
  "Create a status structure from accurev's output"
  (let ((file (concat "^\\("
		      (if filename
			  (concat "./" (file-relative-name filename))
			"[^[:space:]]*")
		      "\\)\\s-+"))
	status)
    (goto-char (point-min))
    (while (not (eobp))
      (cond ((looking-at (concat file
				 "\\([^[:space:]]*\\)\\s-+"  ;; element id
				 "\\([^[:space:]]*\\)\\s-+"  ;; element target
				 "(\\([^[:space:]]*\\))\\s-+" ;; version
				 "\\(.*\\)$")) ;; stati
	       (add-to-list 'status
			    (vc-accurev-create-status (match-string 1) (match-string 4)
						      (match-string 3) (match-string 2)
						      (vc-accurev--parse-nested-statuses (match-string 5)))))
	      ((looking-at (concat file "\\(.*\\)$")) ;; stati
	       (add-to-list 'status
			    (vc-accurev-create-status (match-string 1) nil nil nil
						      (vc-accurev--parse-nested-statuses (match-string 2))))))
      (forward-line 1))
    (if filename (car status)
      status)))

(defun vc-accurev--parse-nested-statuses (stati)
  "Convert a list of accurev statuses into vc states"
  (if (string-match "(\\([^)]*\\))\\(.*\\)" stati)
      (let ((rest (match-string 2 stati)))
	(cons (vc-accurev--state-code (match-string 1 stati))
	      (vc-accurev--parse-nested-statuses rest)))))

(defun vc-accurev--state-code (code)
  "Convert from a string to a vc state."
  (let ((code (or code "")))
    (cond ((string-match "backed" code) 'up-to-date)
	  ((string-match "modified" code) 'edited)
	  ((string-match "stale" code) 'needs-update)
	  ((string-match "overlap\\|underlap" code) 'needs-merge)
	  ((string-match "kept" code) 'added)
	  ((string-match "defunct" code) 'removed)
;;; ((string-match "" code) 'conflict) ;;; not needed, kept automatically after merge/patch
	  ((string-match "missing" code) 'missing)
	  ((string-match "ignored\\|excluded" code) 'ignored)
	  ((string-match "external\\|no such elem" code) 'unregistered))))

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
	    (:constructor vc-accurev-create-status (file &optional revision element-target element-id status))
	    (:conc-name vc-accurev-status->))
  file
  revision
  element-target
  element-id
  element-type
  status)

(provide 'vc-accurev)

;;; vc-accurev.el ends here
