;;; -*- mode: emacs-lisp ; coding: utf-8-unix ; lexical-binding: nil -*-
;;; last updated : 2013/09/29.03:58:39

;;; ac-clang.el --- Auto Completion source for clang for GNU Emacs

;; Copyright (C) 2010  Brian Jiang
;; Copyright (C) 2012  Taylan Ulrich Bayirli/Kammer
;; Copyright (C) 2013  Golevka
;; Copyright (C) 2013  yaruopooner
;; 
;; Original Authors: Brian Jiang <brianjcj@gmail.com>
;;                   Golevka [https://github.com/Golevka]
;;                   Taylan Ulrich Bayirli/Kammer <taylanbayirli@gmail.com>
;;                   Many others
;; Author          : yaruopooner [https://github.com/yaruopooner]
;; Keywords        : completion, convenience
;; Version         : 1.0

;; This program is free software; you can redistribute it and/or modify
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
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.


;;; Commentary:
;; 
;; This program fork from auto-complete-clang-async.el
;; - Basic Features(same auto-complete-clang-async)
;;   Auto Completion source for clang.
;;   Uses a "completion server" process to utilize libclang.
;;   Also provides flymake syntax checking.
;;   smart-jump. jump to declaration or definition. return from jumped location.
;; - Extended Features
;;   "completion server" process is 1 process only. (original version is per buffer)
;;   libclang CXTranslationUnit Flags support.
;;   libclang CXCodeComplete Flags support.
;;   multi-byte support.
;;   debug logger buffer support.
;; - Optional Features
;;   "completion server" program & libclang.dll build by Microsoft Visual Studio 2010.
;;   x86_64 Machine Architecture + Windows Platform support.

;;; Code:


(eval-when-compile (require' cl))
(require 'auto-complete)
(require 'flymake)




(defconst ac-clang:version "1.0")


;;;
;;; for Server vars
;;;


;; clang-server binary type
(defvar ac-clang:server-type 'x86_64
  " clang-server binary type
`x86_64'   64bit release build version
`x86_64d'  64bit debug build version (server develop only)
`x86_32'   32bit release build version
`x86_32d'  32bit debug build version (server develop only)
")


;; server binaries property list
(defconst ac-clang:server-binaries '(x86_64  "clang-server-x86_64"
									 x86_64d "clang-server-x86_64d"
									 x86_32  "clang-server-x86_32"
									 x86_32d "clang-server-x86_32d"))


;; server process details
(defcustom ac-clang:server-executable nil
  "Location of clang-complete executable."
  :group 'auto-complete
  :type 'file)


(defconst ac-clang:process-name "clang-server")
(defconst ac-clang:process-buffer-name "*clang-complete*")

(defvar ac-clang:server-process nil)
(defvar ac-clang:status 'idle)


(defvar ac-clang:activate-buffers nil)


;; server debug
(defvar ac-clang:debug-log-buffer-p nil)
(defconst ac-clang:debug-log-buffer-name "*clang-log*")
(defvar ac-clang:debug-log-buffer-size (* 1024 50))

(defconst ac-clang:error-buffer-name "*clang-error*")


;; clang-server behaviors
(defvar ac-clang:clang-translation-unit-flags "CXTranslationUnit_PrecompiledPreamble|CXTranslationUnit_CacheCompletionResults"
  "CXTranslationUnit Flags
CXTranslationUnit_DetailedPreprocessingRecord
CXTranslationUnit_Incomplete
CXTranslationUnit_PrecompiledPreamble
CXTranslationUnit_CacheCompletionResults
CXTranslationUnit_ForSerialization
CXTranslationUnit_CXXChainedPCH
CXTranslationUnit_SkipFunctionBodies
CXTranslationUnit_IncludeBriefCommentsInCodeCompletion
")

(defvar ac-clang:clang-complete-at-flags "CXCodeComplete_IncludeMacros"
  "CXCodeComplete Flags
CXCodeComplete_IncludeMacros
CXCodeComplete_IncludeCodePatterns
CXCodeComplete_IncludeBriefComments
")



;;;
;;; for auto-complete vars
;;;

;; clang-server response filter pattern for auto-complete candidates
(defconst ac-clang:completion-pattern "^COMPLETION: \\(%s[^\s\n:]*\\)\\(?: : \\)*\\(.*$\\)")

;; auto-complete behaviors
(defvar ac-clang:async-do-autocompletion-automatically t
  "If autocompletion is automatically triggered when you type ., -> or ::")

(defvar ac-clang:saved-prefix "")

(defvar ac-clang:template-start-point nil)
(defvar ac-clang:template-candidates (list "ok" "no" "yes:)"))


;; auto-complete faces
(defface ac-clang:candidate-face
  '((t (:background "lightgray" :foreground "navy")))
  "Face for clang candidate"
  :group 'auto-complete)

(defface ac-clang:selection-face
  '((t (:background "navy" :foreground "white")))
  "Face for the clang selected candidate."
  :group 'auto-complete)



;;;
;;; for Session vars
;;;

(defvar ac-clang:activate-p nil)
(make-variable-buffer-local 'ac-clang:activate-p)

(defvar ac-clang:session-name nil)
(make-variable-buffer-local 'ac-clang:session-name)

;; for patch
(defvar ac-clang:suspend-p nil)
(make-variable-buffer-local 'ac-clang:suspend-p)


;; auto-complete candidate
(defvar ac-clang:current-candidate nil)
(make-variable-buffer-local 'ac-clang:current-candidate)


;; CFLAGS build behaviors
(defcustom ac-clang:lang-option-function nil
  "Function to return the lang type for option -x."
  :group 'auto-complete
  :type 'function)
(make-variable-buffer-local 'ac-clang:lang-option-function)

(defvar ac-clang:prefix-header nil
  "The prefix header to pass to the Clang executable.")
(make-variable-buffer-local 'ac-clang:prefix-header)


;; clang-server session behavior
(defcustom ac-clang:cflags nil
  "Extra flags to pass to the Clang executable.
This variable will typically contain include paths, e.g., (\"-I~/MyProject\" \"-I.\")."
  :group 'auto-complete
  :type '(repeat (string :tag "Argument" "")))
(make-variable-buffer-local 'ac-clang:cflags)


(defvar ac-clang:jump-stack nil
  "The jump stack (keeps track of jumps via jump-declaration and jump-definition)") 




;;;
;;; primitive functions
;;;

;; CFLAGS builders
(defsubst ac-clang:lang-option ()
  (or (and ac-clang:lang-option-function
           (funcall ac-clang:lang-option-function))
      (cond ((eq major-mode 'c++-mode)
             "c++")
            ((eq major-mode 'c-mode)
             "c")
            ((eq major-mode 'objc-mode)
             (cond ((string= "m" (file-name-extension (buffer-file-name)))
                    "objective-c")
                   (t
                    "objective-c++")))
            (t
             "c++"))))


(defsubst ac-clang:build-complete-cflags ()
  (append '("-cc1" "-fsyntax-only")
          (list "-x" (ac-clang:lang-option))
          ac-clang:cflags
          (when (stringp ac-clang:prefix-header)
            (list "-include-pch" (expand-file-name ac-clang:prefix-header)))))



(defsubst ac-clang:create-position-string (pos)
  (save-excursion
    (goto-char pos)
    (format "line:%d\ncolumn:%d\n"
            (line-number-at-pos)
			(1+ (length 
				 (encode-coding-string (buffer-substring (line-beginning-position) (point)) 'binary))))))




;;;
;;; Functions to speak with the clang-server process
;;;

(defun ac-clang:process-send-string (process string)
  (let ((coding-system-for-write 'binary))
    (process-send-string process string))

  (when ac-clang:debug-log-buffer-p
	(let ((log-buffer (get-buffer-create ac-clang:debug-log-buffer-name)))
	  (when log-buffer
		(with-current-buffer log-buffer
		  (when (and ac-clang:debug-log-buffer-size (> (buffer-size) ac-clang:debug-log-buffer-size))
			(erase-buffer))

		  (goto-char (point-max))
		  (pp (encode-coding-string string 'binary) log-buffer)
		  (insert "\n"))))))


(defun ac-clang:send-set-clang-parameters (process)
  (ac-clang:process-send-string process (format "translation_unit_flags:%s\n" ac-clang:clang-translation-unit-flags))
  (ac-clang:process-send-string process (format "complete_at_flags:%s\n" ac-clang:clang-complete-at-flags)))


(defun ac-clang:send-cflags (process)
  ;; send message head and num_cflags
  (ac-clang:process-send-string process (format "num_cflags:%d\n" (length (ac-clang:build-complete-cflags))))

  (let (cflags)
	;; create CFLAGS strings
	(mapc
	 (lambda (arg)
	   (setq cflags (concat cflags (format "%s\n" arg))))
	 (ac-clang:build-complete-cflags))
	;; send cflags
	(ac-clang:process-send-string process cflags)))


(defun ac-clang:send-source-code (process)
  (save-restriction 
    (widen) 
    (let ((source-buffuer (current-buffer)) 
		  (cs (coding-system-change-eol-conversion buffer-file-coding-system 'unix)))
      (with-temp-buffer
		(set-buffer-multibyte nil)
		(let ((tmp-buffer (current-buffer))) 
		  (with-current-buffer source-buffuer 
			(decode-coding-region (point-min) (point-max) cs tmp-buffer))) 

		(ac-clang:process-send-string process
									  (format "source_length:%d\n" 
											  (length (string-as-unibyte ; fix non-ascii character problem 
													   (buffer-substring-no-properties (point-min) (point-max))))))
		(ac-clang:process-send-string process (buffer-substring-no-properties (point-min) (point-max)))
		(ac-clang:process-send-string process "\n\n")))))


(defsubst ac-clang:send-command (process command-type command-name &optional session-name)
  (let ((command (format "command_type:%s\ncommand_name:%s\n" command-type command-name)))
	(when session-name
	  (setq command (concat command (format "session_name:%s\n" session-name))))
	(ac-clang:process-send-string process command)))



(defun ac-clang:send-clang-parameters-request (process)
  (when (eq (process-status process) 'run)
	(ac-clang:send-command process "Server" "SET_CLANG_PARAMETERS")
	(ac-clang:send-set-clang-parameters process)))


(defun ac-clang:send-create-session-request (process)
  (when (eq (process-status process) 'run)
	(ac-clang:send-command process "Server" "CREATE_SESSION" ac-clang:session-name)
	(save-restriction
	  (widen)
	  (ac-clang:send-cflags process)
	  (ac-clang:send-source-code process))))


(defun ac-clang:send-delete-session-request (process)
  (when (eq (process-status process) 'run)
	(ac-clang:send-command process "Server" "DELETE_SESSION" ac-clang:session-name)))


(defun ac-clang:send-shutdown-request (process)
  (when (eq (process-status process) 'run)
	(ac-clang:send-command process "Server" "SHUTDOWN")))


(defun ac-clang:send-suspend-request (process)
  (when (eq (process-status process) 'run)
	(ac-clang:send-command process "Session" "SUSPEND" ac-clang:session-name)))


(defun ac-clang:send-resume-request (process)
  (when (eq (process-status process) 'run)
	(ac-clang:send-command process "Session" "RESUME" ac-clang:session-name)))


(defun ac-clang:send-cflags-request (process)
  (if (listp ac-clang:cflags)
	  (when (eq (process-status process) 'run)
		(ac-clang:send-command process "Session" "SET_CFLAGS" ac-clang:session-name)
		(ac-clang:send-cflags process)
		(ac-clang:send-source-code process))
	(message "`ac-clang:cflags' should be a list of strings")))


(defun ac-clang:send-reparse-request (process)
  (when (eq (process-status process) 'run)
	(save-restriction
	  (widen)
	  (ac-clang:send-command process "Session" "SET_SOURCECODE" ac-clang:session-name)
	  (ac-clang:send-source-code process)
	  (ac-clang:send-command process "Session" "REPARSE" ac-clang:session-name))))


(defun ac-clang:send-completion-request (process)
  (save-restriction
    (widen)
	(ac-clang:send-command process "Session" "COMPLETION" ac-clang:session-name)
    (ac-clang:process-send-string process (ac-clang:create-position-string (- (point) (length ac-prefix))))
    (ac-clang:send-source-code process)))


(defun ac-clang:send-syntaxcheck-request (process)
  (save-restriction
    (widen)
	(ac-clang:send-command process "Session" "SYNTAXCHECK" ac-clang:session-name)
    (ac-clang:send-source-code process)))


(defun ac-clang:send-declaration-request (process)
  (save-restriction
    (widen)
	(ac-clang:send-command process "Session" "DECLARATION" ac-clang:session-name)
    (ac-clang:process-send-string process (ac-clang:create-position-string (- (point) (length ac-prefix))))
    (ac-clang:send-source-code process)))


(defun ac-clang:send-definition-request (process)
  (save-restriction
    (widen)
	(ac-clang:send-command process "Session" "DEFINITION" ac-clang:session-name)
    (ac-clang:process-send-string process (ac-clang:create-position-string (- (point) (length ac-prefix))))
    (ac-clang:send-source-code process)))


(defun ac-clang:send-smart-jump-request (process)
  (save-restriction
    (widen)
	(ac-clang:send-command process "Session" "SMARTJUMP" ac-clang:session-name)
    (ac-clang:process-send-string process (ac-clang:create-position-string (- (point) (length ac-prefix))))
    (ac-clang:send-source-code process)))




;;;
;;; Receive clang-server responses (completion candidates) and fire auto-complete
;;;

(defun ac-clang:parse-output (prefix)
  (goto-char (point-min))
  (let ((pattern (format ac-clang:completion-pattern
                         (regexp-quote prefix)))
        lines match detailed-info
        (prev-match ""))
    (while (re-search-forward pattern nil t)
      (setq match (match-string-no-properties 1))
      (unless (string= "Pattern" match)
        (setq detailed-info (match-string-no-properties 2))

        (if (string= match prev-match)
            (progn
              (when detailed-info
                (setq match (propertize match
                                        'ac-clang:help
                                        (concat
                                         (get-text-property 0 'ac-clang:help (car lines))
                                         "\n"
                                         detailed-info)))
                (setf (car lines) match)
                ))
          (setq prev-match match)
          (when detailed-info
            (setq match (propertize match 'ac-clang:help detailed-info)))
          (push match lines))))
    lines))


(defun ac-clang:handle-error (res args)
  (goto-char (point-min))
  (let* ((buf (get-buffer-create ac-clang:error-buffer-name))
         (cmd (concat ac-clang:server-executable " " (mapconcat 'identity args " ")))
         (pattern (format ac-clang:completion-pattern ""))
         (err (if (re-search-forward pattern nil t)
                  (buffer-substring-no-properties (point-min)
                                                  (1- (match-beginning 0)))
                ;; Warn the user more agressively if no match was found.
                (message "clang failed with error %d:\n%s" res cmd)
                (buffer-string))))

    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (current-time-string)
                (format "\nclang failed with error %d:\n" res)
                cmd "\n\n")
        (insert err)
        (setq buffer-read-only t)
        (goto-char (point-min))))))


(defun ac-clang:call-process (prefix &rest args)
  (let ((buf (get-buffer-create "*clang-output*"))
        res)
    (with-current-buffer buf (erase-buffer))
    (setq res (apply 'call-process-region (point-min) (point-max)
                     ac-clang:server-executable nil buf nil args))
    (with-current-buffer buf
      (unless (eq 0 res)
        (ac-clang:handle-error res args))
      ;; Still try to get any useful input.
      (ac-clang:parse-output prefix))))


;; filters
(defun ac-clang:append-process-output-to-process-buffer (process output)
  "Append process output to the process buffer."
  (with-current-buffer (process-buffer process)
    (save-excursion
      ;; Insert the text, advancing the process marker.
      (goto-char (process-mark process))
      (insert output)
      (set-marker (process-mark process) (point)))
    (goto-char (process-mark process))))


(defun ac-clang:parse-completion-results (process)
  (with-current-buffer (process-buffer process)
    (ac-clang:parse-output ac-clang:saved-prefix)))


(defun ac-clang:filter-output (process string)
  (ac-clang:append-process-output-to-process-buffer process string)
  (when (string= (substring string -1 nil) "$")
	(case ac-clang:status
	  (preempted
	   (setq ac-clang:status 'idle)
	   (ac-start)
	   (ac-update))
	  
	  (otherwise
	   (setq ac-clang:current-candidate (ac-clang:parse-completion-results process))
	   ;; (message "ac-clang results arrived")
	   (setq ac-clang:status 'acknowledged)
	   (ac-start :force-init t)
	   (ac-update)
	   (setq ac-clang:status 'idle)))))




;;;
;;; Syntax checking with flymake
;;;

(defun ac-clang:flymake-process-sentinel ()
  (interactive)
  (setq flymake-err-info flymake-new-err-info)
  (setq flymake-new-err-info nil)
  (setq flymake-err-info
        (flymake-fix-line-numbers
         flymake-err-info 1 (flymake-count-lines)))
  (flymake-delete-own-overlays)
  (flymake-highlight-err-lines flymake-err-info))

(defun ac-clang:flymake-process-filter (process output)
  (ac-clang:append-process-output-to-process-buffer process output)
  (flymake-log 3 "received %d byte(s) of output from process %d"
               (length output) (process-id process))
  (flymake-parse-output-and-residual output)
  (when (string= (substring output -1 nil) "$")
    (flymake-parse-residual)
    (ac-clang:flymake-process-sentinel)
    (setq ac-clang:status 'idle)
    (set-process-filter ac-clang:server-process 'ac-clang:filter-output)))

(defun ac-clang:syntax-check ()
  (interactive)
  (when (and ac-clang:activate-p (eq ac-clang:status 'idle))
    (with-current-buffer (process-buffer ac-clang:server-process)
      (erase-buffer))
    (setq ac-clang:status 'wait)
    (set-process-filter ac-clang:server-process 'ac-clang:flymake-process-filter)
    (ac-clang:send-syntaxcheck-request ac-clang:server-process)))




;;;
;;; jump declaration/definition/smart-jump
;;;


(defun ac-clang:jump-filter (process string)
  (ac-clang:append-process-output-to-process-buffer process string)
  (setq ac-clang:status 'idle)
  (set-process-filter ac-clang:server-process 'ac-clang:filter-output)
  (when (not (string= string "$"))
    (let* ((parsed (split-string-and-unquote string))
           (filename (pop parsed))
           (line (string-to-number (pop parsed)))
           (column (1- (string-to-number (pop parsed))))
           (new-loc (list filename line column))
           (current-loc (list (buffer-file-name) (line-number-at-pos) (current-column))))
      (when (not (equal current-loc new-loc))
        (push current-loc ac-clang:jump-stack)
        (ac-clang:jump new-loc)))))


(defun ac-clang:jump (location)
  (let* ((filename (pop location))
         (line (pop location))
         (column (pop location)))
    (find-file filename)
    (goto-line line)
    (move-to-column column)))


(defun ac-clang:jump-back ()
  (interactive)

  (when ac-clang:jump-stack
    (ac-clang:jump (pop ac-clang:jump-stack))))


(defun ac-clang:jump-declaration ()
  (interactive)

  (if ac-clang:suspend-p
	  (ac-clang:resume)
	(ac-clang:activate))

  (when (eq ac-clang:status 'idle)
    (with-current-buffer (process-buffer ac-clang:server-process)
      (erase-buffer))
    (setq ac-clang:status 'wait)
    (set-process-filter ac-clang:server-process 'ac-clang:jump-filter)
    (ac-clang:send-declaration-request ac-clang:server-process)))


(defun ac-clang:jump-definition ()
  (interactive)

  (if ac-clang:suspend-p
	  (ac-clang:resume)
	(ac-clang:activate))

  (when (eq ac-clang:status 'idle)
    (with-current-buffer (process-buffer ac-clang:server-process)
      (erase-buffer))
    (setq ac-clang:status 'wait)
    (set-process-filter ac-clang:server-process 'ac-clang:jump-filter)
    (ac-clang:send-definition-request ac-clang:server-process)))


(defun ac-clang:jump-smart ()
  (interactive)

  (if ac-clang:suspend-p
	  (ac-clang:resume)
	(ac-clang:activate))

  (when (eq ac-clang:status 'idle)
    (with-current-buffer (process-buffer ac-clang:server-process)
      (erase-buffer))
    (setq ac-clang:status 'wait)
    (set-process-filter ac-clang:server-process 'ac-clang:jump-filter)
    (ac-clang:send-smart-jump-request ac-clang:server-process)))




;;;
;;; auto-complete ac-source build functions
;;;

(defun ac-clang:candidate ()
  (case ac-clang:status
    (idle
     ;; (message "ac-clang:candidate triggered - fetching candidates...")
     (setq ac-clang:saved-prefix ac-prefix)

     ;; NOTE: although auto-complete would filter the result for us, but when there's
     ;;       a HUGE number of candidates avaliable it would cause auto-complete to
     ;;       block. So we filter it uncompletely here, then let auto-complete filter
     ;;       the rest later, this would ease the feeling of being "stalled" at some degree.

     ;; (message "saved prefix: %s" ac-clang:saved-prefix)
     (with-current-buffer (process-buffer ac-clang:server-process)
       (erase-buffer))
     (setq ac-clang:status 'wait)
     (setq ac-clang:current-candidate nil)

     ;; send completion request
     (ac-clang:send-completion-request ac-clang:server-process)
     ac-clang:current-candidate)

    (wait
     ;; (message "ac-clang:candidate triggered - wait")
     ac-clang:current-candidate)

    (acknowledged
     ;; (message "ac-clang:candidate triggered - ack")
     (setq ac-clang:status 'idle)
     ac-clang:current-candidate)

    (preempted
     ;; (message "clang-async is preempted by a critical request")
     nil)))


(defsubst ac-clang:clean-document (s)
  (when s
    (setq s (replace-regexp-in-string "<#\\|#>\\|\\[#" "" s))
    (setq s (replace-regexp-in-string "#\\]" " " s)))
  s)


(defsubst ac-clang:in-string/comment ()
  "Return non-nil if point is in a literal (a comment or string)."
  (nth 8 (syntax-ppss)))


(defun ac-clang:prefix ()
  (or (ac-prefix-symbol)
      (let ((c (char-before)))
        (when (or (eq ?\. c)
                  ;; ->
                  (and (eq ?> c)
                       (eq ?- (char-before (1- (point)))))
                  ;; ::
                  (and (eq ?: c)
                       (eq ?: (char-before (1- (point))))))
          (point)))))


(defun ac-clang:action ()
  (interactive)
  ;; (ac-last-quick-help)
  (let ((help (ac-clang:clean-document (get-text-property 0 'ac-clang:help (cdr ac-last-completion))))
        (raw-help (get-text-property 0 'ac-clang:help (cdr ac-last-completion)))
        (candidates (list)) ss fn args (ret-t "") ret-f)
    (setq ss (split-string raw-help "\n"))
    (dolist (s ss)
      (when (string-match "\\[#\\(.*\\)#\\]" s)
        (setq ret-t (match-string 1 s)))
      (setq s (replace-regexp-in-string "\\[#.*?#\\]" "" s))
      (cond ((string-match "^\\([^(]*\\)\\((.*)\\)" s)
             (setq fn (match-string 1 s)
                   args (match-string 2 s))
             (push (propertize (ac-clang:clean-document args) 'ac-clang:help ret-t
                               'raw-args args) candidates)
             (when (string-match "\{#" args)
               (setq args (replace-regexp-in-string "\{#.*#\}" "" args))
               (push (propertize (ac-clang:clean-document args) 'ac-clang:help ret-t
                                 'raw-args args) candidates))
             (when (string-match ", \\.\\.\\." args)
               (setq args (replace-regexp-in-string ", \\.\\.\\." "" args))
               (push (propertize (ac-clang:clean-document args) 'ac-clang:help ret-t
                                 'raw-args args) candidates)))
            ((string-match "^\\([^(]*\\)(\\*)\\((.*)\\)" ret-t) ;; check whether it is a function ptr
             (setq ret-f (match-string 1 ret-t)
                   args (match-string 2 ret-t))
             (push (propertize args 'ac-clang:help ret-f 'raw-args "") candidates)
             (when (string-match ", \\.\\.\\." args)
               (setq args (replace-regexp-in-string ", \\.\\.\\." "" args))
               (push (propertize args 'ac-clang:help ret-f 'raw-args "") candidates)))))
    (cond (candidates
           (setq candidates (delete-dups candidates))
           (setq candidates (nreverse candidates))
           (setq ac-clang:template-candidates candidates)
           (setq ac-clang:template-start-point (point))
           (ac-complete-clang-template)

           (unless (cdr candidates) ;; unless length > 1
             (message (replace-regexp-in-string "\n" "   ;    " help))))
          (t
           (message (replace-regexp-in-string "\n" "   ;    " help))))))


(defun ac-clang:document (item)
  (if (stringp item)
      (let (s)
        (setq s (get-text-property 0 'ac-clang:help item))
        (ac-clang:clean-document s)))
  ;; (popup-item-property item 'ac-clang:help)
  )



(ac-define-source clang-async
  '((candidates			.		ac-clang:candidate)
    (candidate-face		.		ac-clang:candidate-face)
    (selection-face		.		ac-clang:selection-face)
    (prefix				.		ac-clang:prefix)
    (requires			.		0)
    (action				.		ac-clang:action)
    (document			.		ac-clang:document)
    (cache)
    (symbol				.		"c")))



(defun ac-clang:same-count-in-string (c1 c2 s)
  (let ((count 0) (cur 0) (end (length s)) c)
    (while (< cur end)
      (setq c (aref s cur))
      (cond ((eq c1 c)
             (setq count (1+ count)))
            ((eq c2 c)
             (setq count (1- count))))
      (setq cur (1+ cur)))
    (= count 0)))


(defun ac-clang:split-args (s)
  (let ((sl (split-string s ", *")))
    (cond ((string-match "<\\|(" s)
           (let ((res (list)) (pre "") subs)
             (while sl
               (setq subs (pop sl))
               (unless (string= pre "")
                 (setq subs (concat pre ", " subs))
                 (setq pre ""))
               (cond ((and (ac-clang:same-count-in-string ?\< ?\> subs)
                           (ac-clang:same-count-in-string ?\( ?\) subs))
                      ;; (cond ((ac-clang:same-count-in-string ?\< ?\> subs)
                      (push subs res))
                     (t
                      (setq pre subs))))
             (nreverse res)))
          (t
           sl))))


(defun ac-clang:template-candidate ()
  ac-clang:template-candidates)


(defun ac-clang:template-prefix ()
  ac-clang:template-start-point)


(defun ac-clang:template-action ()
  (interactive)
  (unless (null ac-clang:template-start-point)
    (let ((pos (point)) sl (snp "")
          (s (get-text-property 0 'raw-args (cdr ac-last-completion))))
      (cond ((string= s "")
             ;; function ptr call
             (setq s (cdr ac-last-completion))
             (setq s (replace-regexp-in-string "^(\\|)$" "" s))
             (setq sl (ac-clang:split-args s))
             (cond ((featurep 'yasnippet)
                    (dolist (arg sl)
                      (setq snp (concat snp ", ${" arg "}")))
                    (condition-case nil
                        (yas/expand-snippet (concat "("  (substring snp 2) ")")
                                            ac-clang:template-start-point pos) ;; 0.6.1c
                      (error
                       ;; try this one:
                       (ignore-errors (yas/expand-snippet
                                       ac-clang:template-start-point pos
                                       (concat "("  (substring snp 2) ")"))) ;; work in 0.5.7
                       )))
                   ((featurep 'snippet)
                    (delete-region ac-clang:template-start-point pos)
                    (dolist (arg sl)
                      (setq snp (concat snp ", $${" arg "}")))
                    (snippet-insert (concat "("  (substring snp 2) ")")))
                   (t
                    (message "Dude! You are too out! Please install a yasnippet or a snippet script:)"))))
            (t
             (unless (string= s "()")
               (setq s (replace-regexp-in-string "{#" "" s))
               (setq s (replace-regexp-in-string "#}" "" s))
               (cond ((featurep 'yasnippet)
                      (setq s (replace-regexp-in-string "<#" "${" s))
                      (setq s (replace-regexp-in-string "#>" "}" s))
                      (setq s (replace-regexp-in-string ", \\.\\.\\." "}, ${..." s))
                      (condition-case nil
                          (yas/expand-snippet s ac-clang:template-start-point pos) ;; 0.6.1c
                        (error
                         ;; try this one:
                         (ignore-errors (yas/expand-snippet ac-clang:template-start-point pos s)) ;; work in 0.5.7
                         )))
                     ((featurep 'snippet)
                      (delete-region ac-clang:template-start-point pos)
                      (setq s (replace-regexp-in-string "<#" "$${" s))
                      (setq s (replace-regexp-in-string "#>" "}" s))
                      (setq s (replace-regexp-in-string ", \\.\\.\\." "}, $${..." s))
                      (snippet-insert s))
                     (t
                      (message "Dude! You are too out! Please install a yasnippet or a snippet script:)")))))))))


;; This source shall only be used internally.
(ac-define-source clang-template
  '((candidates .		ac-clang:template-candidate)
    (prefix		.		ac-clang:template-prefix)
    (requires	.		0)
    (action		.		ac-clang:template-action)
    (document	.		ac-clang:document)
    (cache)
    (symbol		.		"t")))



;; auto-complete features

(defun ac-clang:async-preemptive ()
  (interactive)
  (self-insert-command 1)
  (if (eq ac-clang:status 'idle)
      (ac-start)
    (setq ac-clang:status 'preempted)))


(defun ac-clang:async-autocomplete-autotrigger ()
  (interactive)
  (if ac-clang:async-do-autocompletion-automatically
      (ac-clang:async-preemptive)
	(self-insert-command 1)))




;;;
;;; Session control functions
;;;

(defun ac-clang:activate ()
  (interactive)

  (remove-hook 'first-change-hook 'ac-clang:activate t)

  (unless ac-clang:activate-p
	;; (if ac-clang:activate-buffers
	;; 	(ac-clang:update-cflags)
	;;   (ac-clang:initialize))

	(setq ac-clang:activate-p t)
	(setq ac-clang:session-name (buffer-file-name))
	(setq ac-clang:suspend-p nil)
	(push (current-buffer) ac-clang:activate-buffers)

	(ac-clang:send-create-session-request ac-clang:server-process)

	(local-set-key (kbd ":") 'ac-clang:async-autocomplete-autotrigger)
	(local-set-key (kbd ".") 'ac-clang:async-autocomplete-autotrigger)
	(local-set-key (kbd ">") 'ac-clang:async-autocomplete-autotrigger)

	(add-hook 'before-save-hook 'ac-clang:suspend nil t)
	;; (add-hook 'after-save-hook 'ac-clang:deactivate nil t)
	;; (add-hook 'first-change-hook 'ac-clang:activate nil t)
	;; (add-hook 'before-save-hook 'ac-clang:reparse-buffer nil t)
	;; (add-hook 'after-save-hook 'ac-clang:reparse-buffer nil t)
	(add-hook 'before-revert-hook 'ac-clang:deactivate nil t)
	(add-hook 'kill-buffer-hook 'ac-clang:deactivate nil t)))


(defun ac-clang:deactivate ()
  (interactive)

  (when ac-clang:activate-p
	(remove-hook 'before-save-hook 'ac-clang:suspend t)
	(remove-hook 'first-change-hook 'ac-clang:resume t)
	;; (remove-hook 'before-save-hook 'ac-clang:reparse-buffer t)
	;; (remove-hook 'after-save-hook 'ac-clang:reparse-buffer t)
	(remove-hook 'before-revert-hook 'ac-clang:deactivate t)
	(remove-hook 'kill-buffer-hook 'ac-clang:deactivate t)

	(ac-clang:send-delete-session-request ac-clang:server-process)

	(pop ac-clang:activate-buffers)
	(setq ac-clang:suspend-p nil)
	(setq ac-clang:session-name nil)
	(setq ac-clang:activate-p nil)

	;; (unless ac-clang:activate-buffers
	;;   (ac-clang:finalize))
	))


(defun ac-clang:activate-after-modify ()
  (interactive)

  (if (buffer-modified-p)
	  (ac-clang:activate)
	(add-hook 'first-change-hook 'ac-clang:activate nil t)))


(defun ac-clang:suspend ()
  (when (and ac-clang:activate-p (not ac-clang:suspend-p))
	(setq ac-clang:suspend-p t)
	(ac-clang:send-suspend-request ac-clang:server-process)
	(add-hook 'first-change-hook 'ac-clang:resume nil t)))


(defun ac-clang:resume ()
  (when (and ac-clang:activate-p ac-clang:suspend-p)
	(setq ac-clang:suspend-p nil)
	(remove-hook 'first-change-hook 'ac-clang:resume t)
	(ac-clang:send-resume-request ac-clang:server-process)))


(defun ac-clang:reparse-buffer ()
  (when ac-clang:server-process
	(ac-clang:send-reparse-request ac-clang:server-process)))


(defun ac-clang:update-cflags ()
  (interactive)

  (when ac-clang:activate-p
	;; (message "ac-clang:update-cflags %s" ac-clang:session-name)
	(ac-clang:send-cflags-request ac-clang:server-process)))


(defun ac-clang:set-cflags ()
  "Set `ac-clang:cflags' interactively."
  (interactive)
  (setq ac-clang:cflags (split-string (read-string "New cflags: ")))
  (ac-clang:update-cflags))


(defun ac-clang:set-cflags-from-shell-command ()
  "Set `ac-clang:cflags' to a shell command's output.
  set new cflags for ac-clang from shell command output"
  (interactive)
  (setq ac-clang:cflags
        (split-string
         (shell-command-to-string
          (read-shell-command "Shell command: " nil nil
                              (and buffer-file-name
                                   (file-relative-name buffer-file-name))))))
  (ac-clang:update-cflags))


(defun ac-clang:set-prefix-header (prefix-header)
  "Set `ac-clang:prefix-header' interactively."
  (interactive
   (let ((default (car (directory-files "." t "\\([^.]h\\|[^h]\\).pch\\'" t))))
     (list
      (read-file-name (concat "Clang prefix header (currently " (or ac-clang:prefix-header "nil") "): ")
                      (when default (file-name-directory default))
                      default nil (when default (file-name-nondirectory default))))))
  (cond
   ((string-match "^[\s\t]*$" prefix-header)
    (setq ac-clang:prefix-header nil))
   (t
    (setq ac-clang:prefix-header prefix-header))))




;;;
;;; Server control functions
;;;

(defun ac-clang:launch-process ()
  (interactive)

  (unless ac-clang:server-process
	(let ((process-connection-type nil))
	  (setq ac-clang:server-process
			(apply 'start-process
				   ac-clang:process-name ac-clang:process-buffer-name
				   ac-clang:server-executable nil)))

	(setq ac-clang:status 'idle)

	;; (set-process-coding-system ac-clang:server-process
	;; 						   (coding-system-change-eol-conversion buffer-file-coding-system 'unix)
	;; 						   'binary)

	(set-process-filter ac-clang:server-process 'ac-clang:filter-output)
	(set-process-query-on-exit-flag ac-clang:server-process nil)

	(ac-clang:send-clang-parameters-request ac-clang:server-process)
	t))


(defun ac-clang:shutdown-process ()
  (interactive)

  (when ac-clang:server-process
	(ac-clang:send-shutdown-request ac-clang:server-process)

	(setq ac-clang:status 'shutdown)

	(setq ac-clang:server-process nil)
	t))


(defun ac-clang:update-clang-parameters ()
  (interactive)

  (when ac-clang:server-process
	(ac-clang:send-clang-parameters-request ac-clang:server-process)
	t))




(defun ac-clang:initialize ()
  (interactive)

  ;; server binary decide
  (unless ac-clang:server-executable
	(setq ac-clang:server-executable (executable-find (or (plist-get ac-clang:server-binaries ac-clang:server-type) ""))))

  ;; (message "ac-clang:initialize")
  (when (and ac-clang:server-executable (ac-clang:launch-process))
	;; Optional keybindings
	(define-key ac-mode-map (kbd "M-.") 'ac-clang:jump-smart)
	(define-key ac-mode-map (kbd "M-,") 'ac-clang:jump-back)
	;; (define-key ac-mode-map (kbd "C-c `") 'ac-clang:syntax-check)) 

	t))


(defun ac-clang:finalize ()
  (interactive)

  ;; (message "ac-clang:finalize")
  (when (ac-clang:shutdown-process)
	(define-key ac-mode-map (kbd "M-.") nil)
	(define-key ac-mode-map (kbd "M-,") nil)

	(setq ac-clang:server-executable nil)

	t))





(provide 'ac-clang)