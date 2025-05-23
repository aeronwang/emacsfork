;;; server.el --- Lisp code for GNU Emacs running as server process -*- lexical-binding: t -*-

;; Copyright (C) 1986-1987, 1992, 1994-2024 Free Software Foundation,
;; Inc.

;; Author: William Sommerfeld <wesommer@athena.mit.edu>
;; Maintainer: emacs-devel@gnu.org
;; Keywords: processes

;; Changes by peck@sun.com and by rms.
;; Overhaul by Karoly Lorentey <lorentey@elte.hu> for multi-tty support.

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This library allows Emacs to operate as a server for other
;; processes.

;; Load this library and do `M-x server-start' to enable Emacs as a server.
;; Emacs opens up a socket for communication with clients.  If there are no
;; client buffers to edit, `server-edit' acts like (switch-to-buffer
;; (other-buffer))

;; When some other program runs "the editor" to edit a file,
;; "the editor" can be the Emacs client program ../lib-src/emacsclient.
;; This program transmits the file names to Emacs through
;; the server subprocess, and Emacs visits them and lets you edit them.

;; Note that any number of clients may dispatch files to Emacs to be edited.

;; When you finish editing a Server buffer, again call `server-edit'
;; to mark that buffer as done for the client and switch to the next
;; Server buffer.  When all the buffers for a client have been edited
;; and exited with `server-edit', the client "editor" will return
;; to the program that invoked it.

;; Your editing commands and Emacs's display output go to and from
;; the terminal in the usual way.  Thus, server operation is possible
;; only when Emacs can talk to the terminal at the time you invoke
;; the client.  This is possible in four cases:

;; 1. On a window system, where Emacs runs in one window and the
;;    program that wants to use "the editor" runs in another.

;; 2. On a multi-terminal system, where Emacs runs on one terminal and
;;    the program that wants to use "the editor" runs on another.

;; 3. When the program that wants to use "the editor" is running as a
;;    subprocess of Emacs.

;; 4. On a system with job control, when Emacs is suspended, the
;;    program that wants to use "the editor" will stop and display
;;    "Waiting for Emacs...".  It can then be suspended, and Emacs can
;;    be brought into the foreground for editing.  When done editing,
;;    Emacs is suspended again, and the client program is brought into
;;    the foreground.

;; The buffer local variable `server-buffer-clients' lists
;; the clients who are waiting for this buffer to be edited.
;; The global variable `server-clients' lists all the waiting clients,
;; and which files are yet to be edited for each.

;;; Code:

;; Todo:

;; - handle command-line-args-left.
;; - move most of the args processing and decision making from emacsclient.c
;;   to here.
;; - fix up handling of the client's environment (place it in the terminal?).

(eval-when-compile (require 'cl-lib))

(defgroup server nil
  "Emacs running as a server process."
  :group 'external)

(defcustom server-use-tcp nil
  "If non-nil, use TCP sockets instead of local sockets."
  :set (lambda (sym val)
         (unless (featurep 'make-network-process '(:family local))
           (setq val t)
           (unless load-in-progress
             (message "Local sockets unsupported, using TCP sockets")))
         (set-default sym val))
  :type 'boolean
  :version "22.1")

(defcustom server-host nil
  "The name or IP address to use as host address of the server process.
If set, the server accepts remote connections; otherwise it is local.

DO NOT give this a non-nil value unless you know what you are doing!
On unsecured networks, accepting remote connections is very dangerous,
because server-client communication (including session authentication)
is not encrypted."
  :type '(choice
          (string :tag "Name or IP address")
          (const :tag "Local" nil))
  :version "22.1")
;;;###autoload
(put 'server-host 'risky-local-variable t)

(defcustom server-port nil
  "The port number that the server process should listen on.
This variable only takes effect when the Emacs server is using
TCP instead of local sockets.  A nil value means to use a random
port number."
  :type '(choice
          (string :tag "Port number")
          (const :tag "Random" nil))
  :version "24.1")
;;;###autoload
(put 'server-port 'risky-local-variable t)

(defcustom server-auth-dir (locate-user-emacs-file "server/")
  "Directory for server authentication files.
We only use this if `server-use-tcp' is non-nil.
Otherwise we use `server-socket-dir'.

NOTE: On FAT32 filesystems, directories are not secure;
files can be read and modified by any user or process.
It is strongly suggested to set `server-auth-dir' to a
directory residing in a NTFS partition instead."
  :type 'directory
  :version "22.1")
;;;###autoload
(put 'server-auth-dir 'risky-local-variable t)

(defcustom server-auth-key nil
  "Server authentication key.
This is only used if `server-use-tcp' is non-nil.

Normally, the authentication key is randomly generated when the
server starts.  It is recommended to leave it that way.  Using a
long-lived shared key will decrease security (especially since
the key is transmitted as plain-text).

In some situations however, it can be difficult to share randomly
generated passwords with remote hosts (e.g., no shared directory),
so you can set the key with this variable and then copy the
server file to the remote host (with possible changes to IP
address and/or port if that applies).

Note that the usual security risks of using the server over
remote TCP, arising from the fact that client-server
communications are unencrypted, still apply.

The key must consist of 64 ASCII printable characters except for
space (this means characters from ! to ~; or from code 33 to
126).  You can use \\[server-generate-key] to get a random key."
  :type '(choice
	  (const :tag "Random" nil)
	  (string :tag "Password"))
  :version "24.3")

(defcustom server-raise-frame t
  "If non-nil, raise frame when switching to a buffer."
  :type 'boolean
  :version "22.1")

(defcustom server-visit-hook nil
  "Hook run when visiting a file for the Emacs server."
  :type 'hook)

(defcustom server-switch-hook nil
  "Hook run when switching to a buffer for the Emacs server."
  :type 'hook)

(defcustom server-after-make-frame-hook nil
  "Hook run when the Emacs server starts using a client frame.
The client frame is selected when the hook is called.
The client frame could be a newly-created frame, or an
existing frame reused for this purpose."
  :type 'hook
  :version "27.1")

(defcustom server-done-hook nil
  "Hook run when done editing a buffer for the Emacs server."
  :type 'hook)

(defvar server-process nil
  "The current server process.")

(defvar server-clients nil
  "List of current server clients.
Each element is a process.")

(defvar-local server-buffer-clients nil
  "List of client processes requesting editing of current buffer.")
;; Changing major modes should not erase this local.
(put 'server-buffer-clients 'permanent-local t)

(defcustom server-window nil
  "Specification of the window to use for selecting Emacs server buffers.
If nil, use the selected window.
If it is a function, it should take one argument (a buffer) and
display and select it.  A common value is `pop-to-buffer'.
If it is a window, use that.
If it is a frame, use the frame's selected window.

It is not meaningful to set this to a specific frame or window with Custom.
Only programs can do so."
  :version "22.1"
  :type '(choice (const :tag "Use selected window"
			:match (lambda (widget value)
				 (not (functionp value)))
			nil)
		 (function-item :tag "Display in new frame" switch-to-buffer-other-frame)
		 (function-item :tag "Use pop-to-buffer" pop-to-buffer)
		 (function :tag "Other function")))

(defcustom server-temp-file-regexp "\\`/tmp/Re\\|/draft\\'"
  "Regexp matching names of temporary files.
These are deleted and reused after each edit by the programs that
invoke the Emacs server."
  :type 'regexp)

(defcustom server-kill-new-buffers t
  "Whether to kill buffers when done with them.
If non-nil, kill a buffer unless it already existed before editing
it with the Emacs server.  If nil, kill only buffers as specified by
`server-temp-file-regexp'.
Please note that only buffers that still have a client are killed,
i.e. buffers visited with \"emacsclient --no-wait\" are never killed
in this way."
  :type 'boolean
  :version "21.1")

(defvar-local server-existing-buffer nil
  "Non-nil means the buffer existed before the server was asked to visit it.
This means that the server should not kill the buffer when you say you
are done with it in the server.")

(defvar server--external-socket-initialized nil
  "When an external socket is passed into Emacs, we need to call
`server-start' in order to initialize the connection.  This flag
prevents multiple initializations when an external socket has
been consumed.")

(defcustom server-name
  (if internal--daemon-sockname
      (file-name-nondirectory internal--daemon-sockname)
    "server")
  "The name of the Emacs server, if this Emacs process creates one.
The command `server-start' makes use of this.  It should not be
changed while a server is running.
If this is a file name with no leading directories, Emacs will
create a socket file by that name under `server-socket-dir'
if `server-use-tcp' is nil, else under `server-auth-dir'.
If this is an absolute file name, it specifies where the socket
file will be created.  To have emacsclient connect to the same
socket, use the \"-s\" switch for local non-TCP sockets, and
the \"-f\" switch otherwise."
  :type 'string
  :version "23.1")

(defcustom server-client-instructions t
  "If non-nil, display instructions on how to exit the client on connection.
If nil, no instructions are displayed."
  :version "28.1"
  :type 'boolean)

(defvar server-stop-automatically)      ; Defined below to avoid recursive load.

(defvar server-stop-automatically--timer nil
  "The timer object for `server-stop-automatically--maybe-kill-emacs'.")

;; We do not use `temporary-file-directory' here, because emacsclient
;; does not read the init file.
(defvar server-socket-dir
  (if internal--daemon-sockname
      (file-name-directory internal--daemon-sockname)
    (and (featurep 'make-network-process '(:family local))
	 (let ((runtime-dir (getenv "XDG_RUNTIME_DIR")))
	   (if runtime-dir
	       (expand-file-name "emacs" runtime-dir)
	     (expand-file-name (format "emacs%d" (user-uid))
                               (or (getenv "TMPDIR") "/tmp"))))))
  "The directory in which to place the server socket.
If local sockets are not supported, this is nil.")

(define-error 'server-running-external "External server running")

(defun server-clients-with (property value)
  "Return a list of clients with PROPERTY set to VALUE."
  (let (result)
    (dolist (proc server-clients)
      (when (equal value (process-get proc property))
	(push proc result)))
    result))

(defun server-add-client (proc)
  "Create a client for process PROC, if it doesn't already have one.
New clients have no properties."
  (add-to-list 'server-clients proc))

(defmacro server-with-environment (env vars &rest body)
  "Evaluate BODY with environment variables VARS set to those in ENV.
The environment variables are then restored to their previous values.

VARS should be a list of strings.
ENV should be in the same format as `process-environment'."
  (declare (indent 2))
  (let ((var (make-symbol "var"))
	(value (make-symbol "value")))
    `(let ((process-environment process-environment))
       (dolist (,var ,vars)
         (let ((,value (getenv-internal ,var ,env)))
           (push (if (stringp ,value)
                     (concat ,var "=" ,value)
                   ,var)
                 process-environment)))
       (progn ,@body))))

(defun server-delete-client (proc &optional noframe)
  "Delete PROC, including its buffers, terminals and frames.
If NOFRAME is non-nil, let the frames live.
If NOFRAME is the symbol \\='dont-kill-client, also don't
delete PROC or its terminals, just kill its buffers: this is
for when `find-alternate-file' calls this via `kill-buffer-hook'.
Updates `server-clients'."
  (server-log (concat "server-delete-client" (if noframe " noframe")) proc)
  ;; Force a new lookup of client (prevents infinite recursion).
  (when (memq proc server-clients)
    (let ((buffers (process-get proc 'buffers)))

      ;; Kill the client's buffers.
      (dolist (buf buffers)
	(when (buffer-live-p buf)
	  (with-current-buffer buf
	    ;; Kill the buffer if necessary.
	    (when (and (equal server-buffer-clients
			      (list proc))
		       (or (and server-kill-new-buffers
				(not server-existing-buffer))
			   (server-temp-file-p))
		       (not (buffer-modified-p)))
	      (let (flag)
		(unwind-protect
		    (progn (setq server-buffer-clients nil)
			   (kill-buffer (current-buffer))
			   (setq flag t))
		  (unless flag
		    ;; Restore clients if user pressed C-g in `kill-buffer'.
		    (setq server-buffer-clients (list proc)))))))))

      ;; Delete the client's frames.
      (unless noframe
	(dolist (frame (frame-list))
	  (when (and (frame-live-p frame)
		     (equal proc (frame-parameter frame 'client)))
	    ;; Prevent `server-handle-delete-frame' from calling us
	    ;; recursively.
	    (set-frame-parameter frame 'client nil)
	    (delete-frame frame))))

      (or (eq noframe 'dont-kill-client)
          (setq server-clients (delq proc server-clients)))

      ;; Delete the client's tty, except on Windows (both GUI and
      ;; console), where there's only one terminal and does not make
      ;; sense to delete it, or if we are explicitly told not.
      (unless (or (eq system-type 'windows-nt)
                  ;; 'find-alternate-file' caused the last client
                  ;; buffer to be killed, but we will reuse the client
                  ;; for another buffer.
                  (eq noframe 'dont-kill-client)
                  (process-get proc 'no-delete-terminal))
	(let ((terminal (process-get proc 'terminal)))
	  ;; Only delete the terminal if it is non-nil.
	  (when (and terminal (eq (terminal-live-p terminal) t))
	    (delete-terminal terminal))))

      ;; Delete the client's process (or don't).
      (unless (eq noframe 'dont-kill-client)
        (if (eq (process-status proc) 'open)
	    (delete-process proc))
        (server-log "Deleted" proc)))))

(defvar server-log-time-function #'current-time-string
  "Function to generate timestamps for `server-buffer'.")

(defconst server-buffer " *server*"
  "Buffer used internally by Emacs's server.
One use is to log the I/O for debugging purposes (see option `server-log'),
the other is to provide a current buffer in which the process filter can
safely let-bind buffer-local variables like `default-directory'.")

(defvar server-log nil
  "If non-nil, log the server's inputs and outputs in the `server-buffer'.")

(defun server-log (string &optional client)
  "If option `server-log' is non-nil, log STRING to `server-buffer'.
If CLIENT is non-nil, add a description of it to the logged message."
  (when server-log
    (with-current-buffer (get-buffer-create server-buffer)
      (goto-char (point-max))
      (insert (funcall server-log-time-function)
	      (cond
	       ((null client) " ")
	       ((listp client) (format " %s: " (car client)))
	       (t (format " %s: " client)))
	      string)
      (or (bolp) (newline)))))

(defun server-sentinel (proc msg)
  "The process sentinel for Emacs server connections."
  ;; If this is a new client process, set the query-on-exit flag to nil
  ;; for this process (it isn't inherited from the server process).
  (when (and (eq (process-status proc) 'open)
	     (process-query-on-exit-flag proc))
    (set-process-query-on-exit-flag proc nil))
  ;; Delete the associated connection file, if applicable.
  ;; Although there's no 100% guarantee that the file is owned by the
  ;; running Emacs instance, server-start uses server-running-p to check
  ;; for possible servers before doing anything, so it *should* be ours.
  (and (process-contact proc :server)
       (eq (process-status proc) 'closed)
       ;; If this variable is non-nil, the socket was passed in to
       ;; Emacs, and not created by Emacs itself (for instance,
       ;; created by systemd).  In that case, don't delete the socket.
       (not internal--daemon-sockname)
       (ignore-errors
	 (delete-file (process-get proc :server-file))))
  (server-log (format "Status changed to %s: %s"
                      (process-status proc) msg) proc)
  (server-delete-client proc))

(defun server--on-display-p (frame display)
  (and (equal (frame-parameter frame 'display) display)
       ;; Note: TTY frames still get a `display' parameter set to the value of
       ;; $DISPLAY.  This is useful when running from that tty frame
       ;; sub-processes that want to connect to the X server, but that means we
       ;; have to be careful here not to be tricked into thinking those frames
       ;; are on `display'.
       (not (eq (framep frame) t))))

(defun server-select-display (display)
  ;; If the current frame is on `display' we're all set.
  ;; Similarly if we are unable to open frames on other displays, there's
  ;; nothing more we can do.
  (unless (or (not (fboundp 'make-frame-on-display))
              (server--on-display-p (selected-frame) display))
    ;; Otherwise, look for an existing frame there and select it.
    (dolist (frame (frame-list))
      (when (server--on-display-p frame display)
	(select-frame frame)))
    ;; If there's no frame on that display yet, create and select one.
    (unless (server--on-display-p (selected-frame) display)
      (let* ((buffer (generate-new-buffer " *server-dummy*"))
             (frame (make-frame-on-display
                     display
                     ;; Make it display (and remember) some dummy buffer, so
                     ;; we can detect later if the frame is in use or not.
                     `((server-dummy-buffer . ,buffer)
                       ;; This frame may be deleted later (see
                       ;; server-unselect-display) so we want it to be as
                       ;; unobtrusive as possible.
                       (visibility . nil)))))
        (select-frame frame)
        (set-window-buffer (selected-window) buffer)
        frame))))

(defun server-unselect-display (frame)
  (when (frame-live-p frame)
    ;; If the temporary frame is in use (displays something real), make it
    ;; visible.  If not (which can happen if the user's customizations call
    ;; pop-to-buffer etc.), delete it to avoid preserving the connection after
    ;; the last real frame is deleted.

    ;; Rewritten to avoid inadvertently killing the current buffer after
    ;; `delete-frame' removed FRAME (Bug#10729).
    (let ((buffer (frame-parameter frame 'server-dummy-buffer)))
      (if (and (one-window-p 'nomini frame)
	       (eq (window-buffer (frame-first-window frame)) buffer))
	  ;; The temp frame still only shows one buffer, and that is the
	  ;; internal temp buffer.
	  (delete-frame frame)
	(set-frame-parameter frame 'visibility t)
	(set-frame-parameter frame 'server-dummy-buffer nil))
      (when (buffer-live-p buffer)
	(kill-buffer buffer)))))

(defun server-handle-delete-frame (frame)
  "Delete the client connection when the emacsclient frame is deleted.
\(To be used from `delete-frame-functions'.)"
  (let ((proc (frame-parameter frame 'client)))
    (when (and (frame-live-p frame)
	       proc
	       ;; See if this is the last frame for this client.
               (not (seq-some
                     (lambda (f)
                       (and (not (eq frame f))
                            (eq proc (frame-parameter f 'client))))
                     (frame-list))))
      (server-log (format "server-handle-delete-frame, frame %s" frame) proc)
      (server-delete-client proc 'noframe)))) ; Let delete-frame delete the frame later.

(defun server-handle-suspend-tty (terminal)
  "Notify the client process that its tty device is suspended."
  (dolist (proc (server-clients-with 'terminal terminal))
    (server-log (format "server-handle-suspend-tty, terminal %s" terminal)
                proc)
    (condition-case nil
	(server-send-string proc "-suspend \n")
      (file-error                       ;The pipe/socket was closed.
       (ignore-errors (server-delete-client proc))))))

(defun server-unquote-arg (arg)
  "Remove &-quotation from ARG.
See `server-quote-arg' and `server-process-filter'."
  (replace-regexp-in-string
   "&." (lambda (s)
	  (pcase (aref s 1)
	    (?& "&")
	    (?- "-")
	    (?n "\n")
	    (_ " ")))
   arg t t))

(defun server-quote-arg (arg)
  "In ARG, insert a & before each &, each space, each newline, and -.
Change spaces to underscores, too, so that the return value never
contains a space.

See `server-unquote-arg' and `server-process-filter'."
  (replace-regexp-in-string
   "[-&\n ]" (lambda (s)
	       (pcase (aref s 0)
		 (?& "&&")
		 (?- "&-")
		 (?\n "&n")
		 (?\s "&_")))
   arg t t))

(defun server-send-string (proc string)
  "A wrapper around `process-send-string' for logging."
  (server-log (concat "Sent " string) proc)
  (process-send-string proc string))

(defun server-ensure-safe-dir (dir)
  "Make sure DIR is a directory with no race-condition issues.
Creates the directory if necessary and makes sure:
- there's no symlink involved
- it's owned by us
- it's not readable/writable by anybody else."
  (setq dir (directory-file-name dir))
  (let ((attrs (file-attributes dir 'integer)))
    (unless attrs
      (with-file-modes ?\700
        (make-directory dir t))
      (setq attrs (file-attributes dir 'integer)))

    ;; Check that it's safe for use.
    (let* ((uid (file-attribute-user-id attrs))
	   (w32 (eq system-type 'windows-nt))
           (unsafe (cond
                    ((not (eq t (file-attribute-type attrs)))
                     (if (null attrs) "its attributes can't be checked"
                       (format "it is a %s"
                               (if (stringp (file-attribute-type attrs))
                                   "symlink" "file"))))
                    ((and w32 (zerop uid)) ; on FAT32?
                     (display-warning
                      'server
                      (format-message "\
Using `%s' to store Emacs-server authentication files.
Directories on FAT32 filesystems are NOT secure against tampering.
See variable `server-auth-dir' for details."
                                      (file-name-as-directory dir))
                      :warning)
                     nil)
                    ((and (/= uid (user-uid)) ; is the dir ours?
                          (or (not w32)
                              ;; Files created on Windows by Administrator
                              ;; (RID=500) have the Administrators (RID=544)
                              ;; group recorded as the owner.
                              (/= uid 544) (/= (user-uid) 500)))
                     (format "it is not owned by you (owner = %s (%d))"
                             (user-full-name uid) uid))
                    (w32 nil)           ; on NTFS?
                    ((let ((modes (file-modes dir 'nofollow)))
                       (unless (zerop (logand (or modes 0) #o077))
                         (format "it is accessible by others (%03o)" modes))))
                    (t nil))))
      (when unsafe
        (error "`%s' is not a safe directory because %s"
               (expand-file-name dir) unsafe)))))

(defun server-generate-key ()
  "Generate and return a random authentication key.
The key is a 64-byte string of random chars in the range `!'..`~'.
If called interactively, also inserts it into current buffer."
  (interactive)
  (let ((auth-key
	 (cl-loop repeat 64
                  collect (+ 33 (random 94)) into auth
                  finally return (concat auth))))
    (if (called-interactively-p 'interactive)
	(insert auth-key))
    auth-key))

(defun server-get-auth-key ()
  "Return server's authentication key.

If `server-auth-key' is nil, just call `server-generate-key'.
Otherwise, if `server-auth-key' is a valid key, return it.
If the key is not valid, signal an error."
  (if server-auth-key
    (if (string-match-p "^[!-~]\\{64\\}$" server-auth-key)
        server-auth-key
      (error "The key `%s' is invalid" server-auth-key))
    (server-generate-key)))

(defsubst server--file-name ()
  "Return the file name to use for the server socket."
  (let ((server-dir (if server-use-tcp server-auth-dir server-socket-dir)))
    (expand-file-name server-name server-dir)))

(defun server-stop (&optional noframe)
  "If this Emacs process has a server communication subprocess, stop it.
If this actually stopped the server, return non-nil.  If the
server is running in some other Emacs process (see
`server-running-p'), signal a `server-running-external' error.

If NOFRAME is non-nil, don't delete any existing frames
associated with a client process.  This is useful, for example,
when killing Emacs, in which case the frames will get deleted
anyway."
  (let ((server-file (server--file-name))
        stopped-p)
    (when server-process
      ;; Kill it dead!
      (ignore-errors (delete-process server-process))
      (server-log "Stopped server")
      (setq stopped-p t
            server-process nil
            server-mode nil
            global-minor-modes (delq 'server-mode global-minor-modes))
      (server-apply-stop-automatically))
    (unwind-protect
        ;; Delete the socket files made by previous server
        ;; invocations.
        (if (not (eq t (server-running-p server-name)))
            ;; Remove any leftover socket or authentication file.
            (ignore-errors
              (let (delete-by-moving-to-trash)
                (delete-file server-file)
                ;; Also delete the directory that the server file was
                ;; created in -- but only in /tmp (see bug#44644).
                ;; There may be other servers running, too, so this may
                ;; fail.
                (when (equal (file-name-directory
                              (directory-file-name
                               (file-name-directory server-file)))
                             "/tmp/")
                  (ignore-errors
                    (delete-directory (file-name-directory server-file))))))
            (signal 'server-running-external
                    (list (format "There is an existing Emacs server, named %S"
                                  server-name))))
      ;; If this Emacs already had a server, clear out associated status.
      (while server-clients
        (server-delete-client (car server-clients) noframe)))
    stopped-p))

;;;###autoload
(defun server-start (&optional leave-dead inhibit-prompt)
  "Allow this Emacs process to be a server for client processes.
This starts a server communications subprocess through which client
\"editors\" can send your editing commands to this Emacs job.
To use the server, set up the program `emacsclient' in the Emacs
distribution as your standard \"editor\".

Optional argument LEAVE-DEAD (interactively, a prefix arg) means just
kill any existing server communications subprocess.

If a server is already running, restart it.  If clients are
running, ask the user for confirmation first, unless optional
argument INHIBIT-PROMPT is non-nil.

To force-start a server, do \\[server-force-delete] and then
\\[server-start].

To check from a Lisp program whether a server is running, use
the `server-process' variable."
  (interactive "P")
  (when (or (not server-clients)
	    ;; Ask the user before deleting existing clients---except
	    ;; when we can't get user input, which may happen when
	    ;; doing emacsclient --eval "(kill-emacs)" in daemon mode.
	    (cond
	     ((and (daemonp)
		   (null (cdr (frame-list)))
		   (eq (selected-frame) terminal-frame))
	      leave-dead)
	     (inhibit-prompt t)
	     (t (yes-or-no-p
		 "The current server still has clients; delete them? "))))
    ;; If a server is already running, try to stop it.
    (condition-case err
        ;; Check to see if an uninitialized external socket has been
        ;; passed in.  If that is the case, don't try to stop the
        ;; server.  (`server-stop' checks `server-running-p', which
        ;; would return the wrong result).
        (if (and internal--daemon-sockname
                 (not server--external-socket-initialized))
            (setq server--external-socket-initialized t)
          (when (server-stop)
            (message (if leave-dead "Stopped server" "Restarting server"))))
      (server-running-external
       (display-warning
        'server
        (concat "Unable to start the Emacs server.\n"
                (cadr err)
                (substitute-command-keys
                 (concat "\nTo start the server in this Emacs process, stop "
                         "the existing server or call \\[server-force-delete] "
                         "to forcibly disconnect it.")))
        :warning)
       (setq leave-dead t)))
      ;; Now any previous server is properly stopped.
    (unless leave-dead
      (let ((server-file (server--file-name)))
	;; Make sure there is a safe directory in which to place the socket.
	(server-ensure-safe-dir (file-name-directory server-file))
        (with-file-modes ?\700
	  (add-hook 'suspend-tty-functions #'server-handle-suspend-tty)
	  (add-hook 'delete-frame-functions #'server-handle-delete-frame)
	  (add-hook 'kill-emacs-query-functions
                    #'server-kill-emacs-query-function)
          ;; We put server's kill-emacs-hook after the others, so that
          ;; frames are not deleted too early, because doing that
          ;; would severely degrade our abilities to communicate with
          ;; the user, while some hooks may wish to ask the user
          ;; questions (e.g., desktop-kill).
	  (add-hook 'kill-emacs-hook #'server-force-stop t) ;Cleanup upon exit.
	  (setq server-process
		(apply #'make-network-process
		       :name server-name
		       :server t
		       :noquery t
		       :sentinel #'server-sentinel
		       :filter #'server-process-filter
		       :use-external-socket t
		       ;; We must receive file names without being decoded.
		       ;; Those are decoded by server-process-filter according
		       ;; to file-name-coding-system.  Also don't get
		       ;; confused by CRs since we don't quote them.
                       ;; For encoding, we must use the locale's encoding,
                       ;; since emacsclient shows that verbatim on the
                       ;; console.
		       :coding (cons 'raw-text-unix locale-coding-system)
		       ;; The other args depend on the kind of socket used.
		       (if server-use-tcp
			   (list :family 'ipv4  ;; We're not ready for IPv6 yet
				 :service (or server-port t)
				 :host (or server-host 'local)
				 :plist '(:authenticated nil))
			 (list :family 'local
			       :service server-file
			       :plist '(:authenticated t)))))
          (server-apply-stop-automatically)
	  (unless server-process (error "Could not start server process"))
          (server-log "Started server")
	  (process-put server-process :server-file server-file)
          (setq server-mode t)
          (push 'server-mode global-minor-modes)
	  (when server-use-tcp
	    (let ((auth-key (server-get-auth-key)))
	      (process-put server-process :auth-key auth-key)
	      (with-temp-file server-file
		(set-buffer-multibyte nil)
		(setq buffer-file-coding-system 'no-conversion)
		(insert (format-network-address
			 (process-contact server-process :local))
			" " (number-to-string (emacs-pid)) ; Kept for compatibility
			"\n" auth-key)))))))))

(defun server-force-stop ()
  "Kill all connections to the current server.
This function is meant to be called from `kill-emacs-hook'."
  (ignore-errors (server-stop 'noframe)))

;;;###autoload
(defun server-force-delete (&optional name)
  "Unconditionally delete connection file for server NAME.
If server is running, it is first stopped.
NAME defaults to `server-name'.  With argument, ask for NAME."
  (interactive
   (list (if current-prefix-arg
	     (read-string (format-prompt "Server name" server-name)
                          nil nil server-name))))
  (when server-mode (with-temp-message nil (server-mode -1)))
  (let ((file (expand-file-name (or name server-name)
				(if server-use-tcp
				    server-auth-dir
				  server-socket-dir))))
    (condition-case nil
	(let (delete-by-moving-to-trash)
	  (delete-file file)
	  (message "Connection file %S deleted" file))
      (file-error
       (message "No connection file %S" file)))))

(defun server-running-p (&optional name)
  "Test whether server NAME is running.

Return values:
  nil              the server is definitely not running.
  t                the server seems to be running.
  something else   we cannot determine whether it's running without using
                   commands which may have to wait for a long time.

This function can return non-nil if the server was started by some other
Emacs process.  To check from a Lisp program whether a server was started
by the current Emacs process, use the `server-process' variable."
  (unless name (setq name server-name))
  (condition-case nil
      (if server-use-tcp
	  (with-temp-buffer
            (setq default-directory server-auth-dir)
	    (insert-file-contents-literally (expand-file-name name))
	    (or (and (looking-at "127\\.0\\.0\\.1:[0-9]+ \\([0-9]+\\)")
		     (assq 'comm
			   (process-attributes
			    (string-to-number (match-string 1))))
		     t)
		:other))
	(delete-process
	 (make-network-process
	  :name "server-client-test" :family 'local :server nil :noquery t
	  :service (expand-file-name name server-socket-dir)))
	t)
    (file-error nil)))

;; This keymap is empty, but allows users to define keybindings to use
;; when `server-mode' is active.
(defvar-keymap server-mode-map)

;;;###autoload
(define-minor-mode server-mode
  "Toggle Server mode.

Server mode runs a process that accepts commands from the
`emacsclient' program.  See Info node `Emacs server' and
`server-start' for details."
  :global t
  :version "22.1"
  :keymap server-mode-map
  ;; Fixme: Should this check for an existing server socket and do
  ;; nothing if there is one (for multiple Emacs sessions)?
  (server-start (not server-mode)))

(defun server-eval-and-print (expr proc)
  "Eval EXPR and send the result back to client PROC."
  ;; While we're running asynchronously (from a process filter), it is likely
  ;; that the emacsclient command was run in response to a user
  ;; action, so the user probably knows that Emacs is processing this
  ;; emacsclient request, so if we get a C-g it's likely that the user
  ;; intended it to interrupt us rather than interrupt whatever Emacs
  ;; was doing before it started handling the process filter.
  ;; Hence `with-local-quit' (bug#6585).
  (let ((v (with-local-quit (eval (car (read-from-string expr)) t))))
    (when proc
      (with-temp-buffer
        (let ((standard-output (current-buffer)))
          (pp v)
          (let ((text (buffer-substring-no-properties
                       (point-min) (point-max))))
            (server-reply-print (server-quote-arg text) proc)))))))

(defconst server-msg-size 1024
  "Maximum size of a message sent to a client.")

(defun server-reply-print (qtext proc)
  "Send a `-print QTEXT' command to client PROC.
QTEXT must be already quoted.
This handles splitting the command if it would be bigger than
`server-msg-size'."
  (let ((prefix "-print ")
	part)
    (while (> (+ (length qtext) (length prefix) 1) server-msg-size)
      ;; We have to split the string
      (setq part (substring qtext 0 (- server-msg-size (length prefix) 1)))
      ;; Don't split in the middle of a quote sequence
      (if (string-match "\\(^\\|[^&]\\)&\\(&&\\)*$" part)
	  ;; There is an uneven number of & at the end
	  (setq part (substring part 0 -1)))
      (setq qtext (substring qtext (length part)))
      (server-send-string proc (concat prefix part "\n"))
      (setq prefix "-print-nonl "))
    (server-send-string proc (concat prefix qtext "\n"))))

(defun server-create-tty-frame (tty type proc &optional parameters)
  (unless tty
    (error "Invalid terminal device"))
  (unless type
    (error "Invalid terminal type"))
  (let ((frame
         (server-with-environment
             (process-get proc 'env)
             '("LANG" "LC_CTYPE" "LC_ALL"
               ;; For tgetent(3); list according to ncurses(3).
               "BAUDRATE" "COLUMNS" "ESCDELAY" "HOME" "LINES"
               "NCURSES_ASSUMED_COLORS" "NCURSES_NO_PADDING"
               "NCURSES_NO_SETBUF" "TERM" "TERMCAP" "TERMINFO"
               "TERMINFO_DIRS" "TERMPATH"
               ;; rxvt wants these
               "COLORFGBG" "COLORTERM")
           (server--create-frame
            ;; Ignore nowait here; we always need to
            ;; clean up opened ttys when the client dies.
            nil proc
            `((window-system . nil)
              (tty . ,tty)
              (tty-type . ,type)
              ,@parameters)))))

    ;; ttys don't use the `display' parameter, but callproc.c does to set
    ;; the DISPLAY environment on subprocesses.
    (set-frame-parameter frame 'display
                         (getenv-internal "DISPLAY" (process-get proc 'env)))
    frame))

(defun server-create-window-system-frame (display nowait proc parent-id
						  &optional parameters)
  (let* ((display (or display
                      (frame-parameter nil 'display)
                      (error "Please specify display")))
         (w (or (cdr (assq 'window-system parameters))
                (window-system-for-display display))))

    ;; Special case for ns.  This is because DISPLAY may not be set at all
    ;; which in the ns case isn't an error.  The variable display then becomes
    ;; the fully qualified hostname, which make-frame-on-display below
    ;; does not understand and throws an error.
    ;; It may also be a valid X display, but if Emacs is compiled for ns, it
    ;; can not make X frames.
    (if (featurep 'ns-win)
	(setq w 'ns display "ns")
      ;; FIXME! Not sure what this was for, and not sure how it should work
      ;; in the cl-defmethod new world!
      ;;(unless (assq w window-system-initialization-alist)
      ;;  (setq w nil))
      )

    (cond (w
           (condition-case nil
               (server--create-frame
                nowait proc
                `((display . ,display)
                  ,@(if parent-id
                        `((parent-id . ,(string-to-number parent-id))))
                  ,@parameters))
             (error
              (server-log "Window system unsupported" proc)
              (server-send-string proc "-window-system-unsupported \n")
              nil)))

          (t
           (server-log "Window system unsupported" proc)
           (server-send-string proc "-window-system-unsupported \n")
           nil))))

(defun server-create-dumb-terminal-frame (nowait proc &optional parameters)
  ;; If the destination is a dumb terminal, we can't really run Emacs
  ;; in its tty.  So instead, we use whichever terminal is currently
  ;; selected.  This situation typically occurs when `emacsclient' is
  ;; running inside something like an Emacs shell buffer (bug#25547).
  (let ((frame (server--create-frame nowait proc parameters)))
    ;; The client is not the exclusive owner of this terminal, so don't
    ;; delete the terminal when the client exits.
    ;; FIXME: Maybe we just shouldn't set the `terminal' property instead?
    (process-put proc 'no-delete-terminal t)
    frame))

(defun server--create-frame (nowait proc parameters)
  (add-to-list 'frame-inherited-parameters 'client)
  ;; When `nowait' is set, flag frame as client-created, but use
  ;; a dummy client.  This will prevent the frame from being deleted
  ;; when emacsclient quits while also preventing
  ;; `server-save-buffers-kill-terminal' from unexpectedly killing
  ;; emacs on that frame.
  (let ((frame (make-frame `((client . ,(if nowait 'nowait proc))
                             ;; This is a leftover from an earlier
                             ;; attempt at making it possible for process
                             ;; run in the server process to use the
                             ;; environment of the client process.
                             ;; It has no effect now and to make it work
                             ;; we'd need to decide how to make
                             ;; process-environment interact with client
                             ;; envvars, and then to change the
                             ;; C functions `child_setup' and
                             ;; `getenv_internal' accordingly.
                             (environment . ,(process-get proc 'env))
                             ,@parameters))))
    (server-log (format "%s created" frame) proc)
    (select-frame frame)
    (process-put proc 'frame frame)
    (process-put proc 'terminal (frame-terminal frame))
    frame))

(defun server-goto-toplevel (proc)
  (condition-case nil
      ;; If we're running isearch, we must abort it to allow Emacs to
      ;; display the buffer and switch to it.
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (bound-and-true-p isearch-mode)
            (isearch-cancel))))
    ;; Signaled by isearch-cancel.
    (quit (message nil)))
  (when (> (minibuffer-depth) 0)
    ;; We're inside a minibuffer already, so if the emacs-client is trying
    ;; to open a frame on a new display, we might end up with an unusable
    ;; frame because input from that display will be blocked (until exiting
    ;; the minibuffer).  Better exit this minibuffer right away.
    (run-with-timer 0 nil (lambda () (server-execute-continuation proc)))
    (top-level)))

;; We use various special properties on process objects:
;; - `env' stores the info about the environment of the emacsclient process.
;; - `continuation' is a no-arg function that we need to execute.  It contains
;;   commands we wanted to execute in some earlier invocation of the process
;;   filter but that we somehow were unable to process at that time
;;   (e.g. because we first need to throw to the toplevel).

(defun server-execute-continuation (proc)
  (let ((continuation (process-get proc 'continuation)))
    (process-put proc 'continuation nil)
    (if continuation (ignore-errors (funcall continuation)))))

(cl-defun server-process-filter (proc string)
  "Process a request from the server to edit some files.
PROC is the server process.  STRING consists of a sequence of
commands prefixed by a dash.  Some commands have arguments;
these are &-quoted and need to be decoded by `server-unquote-arg'.
The filter parses and executes these commands.

To illustrate the protocol, here is an example command that
emacsclient sends to create a new X frame (note that the whole
sequence is sent on a single line):

	-env HOME=/home/lorentey
	-env DISPLAY=:0.0
	... lots of other -env commands
	-display :0.0
	-window-system

The following commands are accepted by the server:

`-auth AUTH-STRING'
  Authenticate the client using the secret authentication string
  AUTH-STRING.

`-env NAME=VALUE'
  An environment variable on the client side.

`-dir DIRNAME'
  The current working directory of the client process.

`-current-frame'
  Forbid the creation of new frames.

`-frame-parameters ALIST'
  Set the parameters of the created frame.

`-nowait'
  Request that the next frame created should not be
  associated with this client.

`-display DISPLAY'
  Set the display name to open X frames on.

`-position +LINE[:COLUMN]'
  Go to the given line and column number
  in the next file opened.

`-file FILENAME'
  Load the given file in the current frame.

`-eval EXPR'
  Evaluate EXPR as a Lisp expression and return the
  result in -print commands.

`-window-system'
  Open a new X frame.

`-tty DEVICENAME TYPE'
  Open a new tty frame at the client.

`-suspend'
  Suspend this tty frame.  The client sends this string in
  response to SIGTSTP and SIGTTOU.  The server must cease all I/O
  on this tty until it gets a -resume command.

`-resume'
  Resume this tty frame.  The client sends this string when it
  gets the SIGCONT signal and it is the foreground process on its
  controlling tty.

`-ignore COMMENT'
  Do nothing, but put the comment in the server log.
  Useful for debugging.


The following commands are accepted by the client:

`-emacs-pid PID'
  Describes the process id of the Emacs process;
  used to forward window change signals to it.

`-window-system-unsupported'
  Signals that the server does not support creating X frames;
  the client must try again with a tty frame.

`-print STRING'
  Print STRING on stdout.  Used to send values
  returned by -eval.

`-print-nonl STRING'
  Print STRING on stdout.  Used to continue a
  preceding -print command that would be too big to send
  in a single message.

`-error DESCRIPTION'
  Signal an error and delete process PROC.

`-suspend'
  Suspend this terminal, i.e., stop the client process.
  Sent when the user presses \\[suspend-frame]."
  (server-log (concat "Received " string) proc)
  ;; First things first: let's check the authentication
  (unless (process-get proc :authenticated)
    (if (and (string-match "-auth \\([!-~]+\\)\n?" string)
	     (equal (match-string 1 string) (process-get proc :auth-key)))
	(progn
	  (setq string (substring string (match-end 0)))
	  (process-put proc :authenticated t)
	  (server-log "Authentication successful" proc))
      (server-log "Authentication failed" proc)
      ;; Display the error as a message and give the user time to see
      ;; it, in case the error written by emacsclient to stderr is not
      ;; visible for some reason.
      (message "Authentication failed")
      (sit-for 2)
      (server-send-string
       proc (concat "-error " (server-quote-arg "Authentication failed")))
      (unless (eq system-type 'windows-nt)
        (let ((terminal (process-get proc 'terminal)))
          ;; Only delete the terminal if it is non-nil.
          (when (and terminal (eq (terminal-live-p terminal) t))
	    (delete-terminal terminal))))
      ;; Before calling `delete-process', give emacsclient time to
      ;; receive the error string and shut down on its own.
      (sit-for 1)
      (delete-process proc)
      ;; We return immediately.
      (cl-return-from server-process-filter)))
  (let ((prev (process-get proc 'previous-string)))
    (when prev
      (setq string (concat prev string))
      (process-put proc 'previous-string nil)))
  (condition-case err
      (progn
	(server-add-client proc)
	;; Send our pid
	(server-send-string proc (concat "-emacs-pid "
					 (number-to-string (emacs-pid)) "\n"))
	(if (not (string-match "\n" string))
            ;; Save for later any partial line that remains.
            (when (> (length string) 0)
              (process-put proc 'previous-string string))

          ;; In earlier versions of server.el (where we used an `emacsserver'
          ;; process), there could be multiple lines.  Nowadays this is not
          ;; supported any more.
          (cl-assert (eq (match-end 0) (length string)))
	  (let ((request (substring string 0 (match-beginning 0)))
		(coding-system (or file-name-coding-system
				   default-file-name-coding-system))
		nowait     ; t if emacsclient does not want to wait for us.
		frame      ; Frame opened for the client (if any).
		display    ; Open frame on this display.
		parent-id  ; Window ID for XEmbed
		dontkill   ; t if client should not be killed.
		commands
		evalexprs
		dir
		use-current-frame
		frame-parameters  ;parameters for newly created frame
		tty-name   ; nil, `window-system', or the tty name.
		tty-type   ; string.
		files
		filepos
		args-left)
	    ;; Remove this line from STRING.
	    (setq string (substring string (match-end 0)))
	    (setq args-left
		  (mapcar #'server-unquote-arg (split-string request " " t)))
	    (while args-left
              (pcase (pop args-left)
                ;; -version CLIENT-VERSION: obsolete at birth.
                ("-version" (pop args-left))

                ;; -nowait:  Emacsclient won't wait for a result.
                ("-nowait" (setq nowait t))

                ;; -current-frame:  Don't create frames.
                ("-current-frame" (setq use-current-frame t))

                ;; -frame-parameters: Set frame parameters
                ("-frame-parameters"
                 (let ((alist (pop args-left)))
                   (if coding-system
                       (setq alist (decode-coding-string alist coding-system)))
                   (setq frame-parameters (car (read-from-string alist)))))

                ;; -display DISPLAY:
                ;; Open X frames on the given display instead of the default.
                ("-display"
                 (setq display (pop args-left))
                 (if (zerop (length display)) (setq display nil)))

                ;; -parent-id ID:
                ;; Open X frame within window ID, via XEmbed.
                ("-parent-id"
                 (setq parent-id (pop args-left))
                 (if (zerop (length parent-id)) (setq parent-id nil)))

                ;; -window-system:  Open a new X frame.
                ("-window-system"
		 (if (fboundp 'x-create-frame)
		     (setq dontkill t
			   tty-name 'window-system)))

                ;; -resume:  Resume a suspended tty frame.
                ("-resume"
                 (let ((terminal (process-get proc 'terminal)))
                   (setq dontkill t)
                   (push (lambda ()
                           (when (eq (terminal-live-p terminal) t)
                             (resume-tty terminal)))
                         commands)))

                ;; -suspend:  Suspend the client's frame.  (In case we
                ;; get out of sync, and a C-z sends a SIGTSTP to
                ;; emacsclient.)
                ("-suspend"
                 (let ((terminal (process-get proc 'terminal)))
                   (setq dontkill t)
                   (push (lambda ()
                           (when (eq (terminal-live-p terminal) t)
                             (suspend-tty terminal)))
                         commands)))

                ;; -ignore COMMENT:  Noop; useful for debugging emacsclient.
                ;; (The given comment appears in the server log.)
                ("-ignore"
                 (setq dontkill t)
                 (pop args-left))

		;; -tty DEVICE-NAME TYPE:  Open a new tty frame.
		;; (But if we see -window-system later, use that.)
                ("-tty"
                 (setq tty-name (pop args-left)
                       tty-type (pop args-left)
                       dontkill (or dontkill
                                    (not use-current-frame)))
                 ;; On Windows, emacsclient always asks for a tty
                 ;; frame.  If running a GUI server, force the frame
                 ;; type to GUI.  (Cygwin is perfectly happy with
                 ;; multi-tty support, so don't override the user's
                 ;; choice there.)  In daemon mode on Windows, we can't
                 ;; make tty frames, so force the frame type to GUI
                 ;; there too.
                 (when (or (and (eq system-type 'windows-nt)
                                (or (daemonp)
                                    (eq window-system 'w32)))
                           ;; Client runs on Windows, but the server
                           ;; runs on a Posix host.
                           (equal tty-name "CONOUT$"))
                   (push "-window-system" args-left)))

                ;; -position +LINE[:COLUMN]:  Set point to the given
                ;;  position in the next file.
                ("-position"
                 (if (not (string-match "\\+\\([0-9]+\\)\\(?::\\([0-9]+\\)\\)?"
                                        (car args-left)))
                     (error "Invalid -position command in client args"))
                 (let ((arg (pop args-left)))
                   (setq filepos
                         (cons (string-to-number (match-string 1 arg))
                               (string-to-number (or (match-string 2 arg)
                                                     ""))))))

                ;; -file FILENAME:  Load the given file.
                ("-file"
                 (let ((file (pop args-left)))
                   (if coding-system
                       (setq file (decode-coding-string file coding-system)))
                   ;; Allow Cygwin's emacsclient to be used as a file
                   ;; handler on MS-Windows, in which case FILENAME
                   ;; might start with a drive letter.
                   (when (and (fboundp 'cygwin-convert-file-name-from-windows)
                              (string-match "\\`[A-Za-z]:" file))
                     (setq file (cygwin-convert-file-name-from-windows file)))
                   (setq file (expand-file-name file dir))
                   (push (cons file filepos) files)
                   (server-log (format "New file: %s %s"
                                       file (or filepos ""))
                               proc))
                 (setq filepos nil))

                ;; -eval EXPR:  Evaluate a Lisp expression.
                ("-eval"
                 (if use-current-frame
                     (setq use-current-frame 'always))
                 (let ((expr (pop args-left)))
                   (if coding-system
                       (setq expr (decode-coding-string expr coding-system)))
                   (push expr evalexprs)
                   (setq filepos nil)))

                ;; -env NAME=VALUE:  An environment variable.
                ("-env"
                 (let ((var (pop args-left)))
                   ;; XXX Variables should be encoded as in getenv/setenv.
                   (process-put proc 'env
                                (cons var (process-get proc 'env)))))

                ;; -dir DIRNAME:  The cwd of the emacsclient process.
                ("-dir"
                 (setq dir (pop args-left))
                 (if coding-system
                     (setq dir (decode-coding-string dir coding-system)))
                 (setq dir (command-line-normalize-file-name dir))
                 (process-put proc 'server-client-directory dir))

                ;; Unknown command.
                (arg (error "Unknown command: %s" arg))))

	    ;; If both -no-wait and -tty are given with file or sexp
	    ;; arguments, use an existing frame.
	    (and nowait
		 (not (eq tty-name 'window-system))
		 (or files commands evalexprs)
		 (setq use-current-frame t))

	    (setq frame
		  (cond
		   ((and use-current-frame
			 (or (eq use-current-frame 'always)
			     ;; We can't use the Emacs daemon's
			     ;; terminal frame.
			     (not (and (daemonp)
				       (null (cdr (frame-list)))
				       (eq (selected-frame)
					   terminal-frame)))))
		    (setq tty-name nil tty-type nil)
		    (if display (server-select-display display)))
                   ((equal tty-type "dumb")
                    (server-create-dumb-terminal-frame nowait proc
                                                       frame-parameters))
		   ((or (and (eq system-type 'windows-nt)
			     (daemonp)
			     (setq display "w32"))
		        (eq tty-name 'window-system))
		    (server-create-window-system-frame display nowait proc
						       parent-id
						       frame-parameters))
		   ;; When resuming on a tty, tty-name is nil.
		   (tty-name
		    (server-create-tty-frame tty-name tty-type proc
                                             frame-parameters))

                   ;; If there won't be a current frame to use, fall
                   ;; back to trying to create a new one.
		   ((and use-current-frame
			 (daemonp)
			 (null (cdr (frame-list)))
			 (eq (selected-frame) terminal-frame)
			 display)
		    (setq tty-name nil tty-type nil)
		    (server-select-display display))))

            (process-put
             proc 'continuation
             (lambda ()
               (with-current-buffer (get-buffer-create server-buffer)
                 ;; Use the same cwd as the emacsclient, if possible, so
                 ;; relative file names work correctly, even in `eval'.
                 (let ((default-directory
                         (if (and dir (file-directory-p dir))
                             dir default-directory)))
                   (server-execute proc files nowait commands evalexprs
                                   dontkill frame tty-name)))))

            (when (or frame files)
              (server-goto-toplevel proc))

            (server-execute-continuation proc))))
    ;; condition-case
    (t (server-return-error proc err))))

(defvar server-eval-args-left nil
  "List of eval args not yet processed.

Adding or removing strings from this variable while the Emacs
server is processing a series of eval requests will affect what
Emacs evaluates.

See also `argv' for a similar variable which works for
invocations of \"emacs\".")

(defun server-execute (proc files nowait commands evalexprs dontkill frame tty-name)
  ;; This is run from timers and process-filters, i.e. "asynchronously".
  ;; But w.r.t the user, this is not really asynchronous since the timer
  ;; is run after 0s and the process-filter is run in response to the
  ;; user running `emacsclient'.  So it is OK to override the
  ;; inhibit-quit flag, which is good since `evalexprs' (as well as
  ;; find-file-noselect via the major-mode) can run arbitrary code,
  ;; including code that needs to wait.
  (with-local-quit
    (condition-case err
        (let ((buffers (server-visit-files files proc nowait)))
          (mapc 'funcall (nreverse commands))
          (let ((server-eval-args-left (nreverse evalexprs)))
            (while server-eval-args-left
              (server-eval-and-print (pop server-eval-args-left) proc)))
	  ;; If we were told only to open a new client, obey
	  ;; `initial-buffer-choice' if it specifies a file
          ;; or a function.
          (unless (or files commands evalexprs)
            (let ((buf
                   (cond ((stringp initial-buffer-choice)
			  (find-file-noselect initial-buffer-choice))
			 ((functionp initial-buffer-choice)
			  (funcall initial-buffer-choice)))))
	      (switch-to-buffer
	       (if (buffer-live-p buf) buf (get-scratch-buffer-create))
	       'norecord)))

          ;; Delete the client if necessary.
          (cond
           (nowait
            ;; Client requested nowait; return immediately.
            (server-log "Close nowait client" proc)
            (server-delete-client proc))
           ((and (not dontkill) (null buffers))
            ;; This client is empty; get rid of it immediately.
            (server-log "Close empty client" proc)
            (server-delete-client proc)))
          (cond
           ((or isearch-mode (minibufferp))
            nil)
           ((and frame (null buffers))
            (run-hooks 'server-after-make-frame-hook)
            (when server-client-instructions
              (message "%s"
                       (substitute-command-keys
                        "When done with this frame, type \\[delete-frame]"))))
           ((not (null buffers))
            (run-hooks 'server-after-make-frame-hook)
            (server-switch-buffer
             (car buffers) nil (cdr (car files))
             ;; When triggered from "emacsclient -c", we popped up a
             ;; new frame.  Ensure that we switch to the requested
             ;; buffer in that frame, and not in some other frame
             ;; where it may be displayed.
             (plist-get (process-plist proc) 'frame))
            (run-hooks 'server-switch-hook)
            (when (and (not nowait)
                       server-client-instructions)
              (message "%s"
                       (substitute-command-keys
                        "When done with a buffer, type \\[server-edit]")))))
          (when (and frame (null tty-name))
            (server-unselect-display frame)))
      ((quit error)
       (when (eq (car err) 'quit)
         (message "Quit emacsclient request"))
       (server-return-error proc err)))))

(defun server-return-error (proc err)
  (ignore-errors
    ;; Display the error as a message and give the user time to see
    ;; it, in case the error written by emacsclient to stderr is not
    ;; visible for some reason.
    (message (error-message-string err))
    (sit-for 2)
    (server-send-string
     proc (concat "-error " (server-quote-arg
                             (error-message-string err))))
    (server-log (error-message-string err) proc)
    (unless (eq system-type 'windows-nt)
      (let ((terminal (process-get proc 'terminal)))
        ;; Only delete the terminal if it is non-nil.
        (when (and terminal (eq (terminal-live-p terminal) t))
	  (delete-terminal terminal))))
    ;; Before calling `delete-process', give emacsclient time to
    ;; receive the error string and shut down on its own.
    (sit-for 5)
    (delete-process proc)))

(defun server-goto-line-column (line-col)
  "Move point to the position indicated in LINE-COL.
LINE-COL should be a pair (LINE . COL)."
  (when line-col
    (goto-char (point-min))
    (forward-line (1- (car line-col)))
    (let ((column-number (cdr line-col)))
      (when (> column-number 0)
        (move-to-column (1- column-number))))))

(defun server-visit-files (files proc &optional nowait)
  "Find FILES and return a list of buffers created.
FILES is an alist whose elements are (FILENAME . FILEPOS)
where FILEPOS can be nil or a pair (LINENUMBER . COLUMNNUMBER).
PROC is the client that requested this operation.
NOWAIT non-nil means this client is not waiting for the results,
so don't mark these buffers specially, just visit them normally."
  ;; Bind last-nonmenu-event to force use of keyboard, not mouse, for queries.
  (let ((last-nonmenu-event t) client-record)
    ;; Restore the current buffer afterward, but not using save-excursion,
    ;; because we don't want to save point in this buffer
    ;; if it happens to be one of those specified by the server.
    (save-current-buffer
      (dolist (file files)
	;; If there is an existing buffer modified or the file is
	;; modified, revert it.  If there is an existing buffer with
	;; deleted file, offer to write it.
	(let* ((minibuffer-auto-raise (or server-raise-frame
					  minibuffer-auto-raise))
	       (filen (car file))
	       (obuf (get-file-buffer filen)))
          (file-name-history--add filen)
	  (if (null obuf)
	      (progn
		(run-hooks 'pre-command-hook)
		(set-buffer (find-file-noselect filen)))
            (set-buffer obuf)
	    ;; separately for each file, in sync with post-command hooks,
	    ;; with the new buffer current:
	    (run-hooks 'pre-command-hook)
            (cond ((file-exists-p filen)
                   (when (not (verify-visited-file-modtime obuf))
                     (revert-buffer t nil)))
                  (t
                   (when (y-or-n-p
                          (concat "File no longer exists: " filen
                                  ", write buffer to file? "))
                     (write-file filen))))
            (unless server-buffer-clients
              (setq server-existing-buffer t)))
          (server-goto-line-column (cdr file))
          (run-hooks 'server-visit-hook)
	  ;; hooks may be specific to current buffer:
	  (run-hooks 'post-command-hook))
	(unless nowait
	  ;; When the buffer is killed, inform the clients.
	  (add-hook 'kill-buffer-hook #'server-kill-buffer nil t)
	  (push proc server-buffer-clients))
	(push (current-buffer) client-record)))
    (unless nowait
      (process-put proc 'buffers
                   (nconc (process-get proc 'buffers) client-record)))
    client-record))

(defvar server-kill-buffer-running nil
  "Non-nil while `server-kill-buffer' or `server-buffer-done' is running.")

(defun server-buffer-done (buffer &optional for-killing)
  "Mark BUFFER as \"done\" for its client(s).
This buries the buffer, then returns a list of the form (NEXT-BUFFER KILLED).
NEXT-BUFFER is another server buffer, as a suggestion for what to select next,
or nil.  KILLED is t if we killed BUFFER (typically, because it was visiting
a temp file).
FOR-KILLING if non-nil indicates that we are called from `kill-buffer'."
  (let ((next-buffer nil)
	(killed nil))
    (dolist (proc server-clients)
      (let ((buffers (process-get proc 'buffers)))
	(or next-buffer
	    (setq next-buffer (nth 1 (memq buffer buffers))))
	(when buffers			; Ignore bufferless clients.
	  (setq buffers (delq buffer buffers))
	  ;; Delete all dead buffers from PROC.
	  (dolist (b buffers)
	    (and (bufferp b)
		 (not (buffer-live-p b))
		 (setq buffers (delq b buffers))))
	  (process-put proc 'buffers buffers)
	  ;; If client now has no pending buffers,
	  ;; tell it that it is done, and forget it entirely.
	  (unless buffers
	    (server-log "Close" proc)
	    (if for-killing
		;; `server-delete-client' might delete the client's
		;; frames, which might change the current buffer.  We
		;; don't want that (bug#640).
		(save-current-buffer
		  (server-delete-client proc
                                        find-alternate-file-dont-kill-client))
	      (server-delete-client proc))))))
    (when (and (bufferp buffer) (buffer-name buffer))
      ;; We may or may not kill this buffer;
      ;; if we do, do not call server-buffer-done recursively
      ;; from kill-buffer-hook.
      (let ((server-kill-buffer-running t))
	(with-current-buffer buffer
	  (setq server-buffer-clients nil)
	  (run-hooks 'server-done-hook))
	;; Notice whether server-done-hook killed the buffer.
	(if (null (buffer-name buffer))
	    (setq killed t)
	  ;; Don't bother killing or burying the buffer
	  ;; when we are called from kill-buffer.
	  (unless for-killing
	    (when (and (not killed)
		       server-kill-new-buffers
		       (with-current-buffer buffer
			 (not server-existing-buffer)))
	      (setq killed t)
	      (bury-buffer buffer)
	      ;; Prevent kill-buffer from prompting (Bug#3696).
	      (with-current-buffer buffer
		(set-buffer-modified-p nil))
	      (kill-buffer buffer))
	    (unless killed
	      (if (server-temp-file-p buffer)
		  (progn
		    (with-current-buffer buffer
		      (set-buffer-modified-p nil))
		    (kill-buffer buffer)
		    (setq killed t))
		(bury-buffer buffer)))))))
    (list next-buffer killed)))

(defun server-temp-file-p (&optional buffer)
  "Return non-nil if BUFFER contains a file considered temporary.
These are files whose names suggest they are repeatedly
reused to pass information to another program.

The variable `server-temp-file-regexp' controls which filenames
are considered temporary."
  (and (buffer-file-name buffer)
       (string-match-p server-temp-file-regexp (buffer-file-name buffer))))

(defun server-done ()
  "Offer to save current buffer, mark it as \"done\" for clients.
This kills or buries the buffer, then returns a list
of the form (NEXT-BUFFER KILLED).  NEXT-BUFFER is another server buffer,
as a suggestion for what to select next, or nil.
KILLED is t if we killed BUFFER, which happens if it was created
specifically for the clients and did not exist before their request for it."
  (when server-buffer-clients
    (if (server-temp-file-p)
	;; For a temp file, save, and do make a non-numeric backup
	;; (unless make-backup-files is nil).
	(let ((version-control nil)
	      (buffer-backed-up nil))
	  (save-buffer))
      (when (and (buffer-modified-p)
		 buffer-file-name
		 (y-or-n-p (concat "Save file " buffer-file-name "? ")))
	(save-buffer)))
    (server-buffer-done (current-buffer))))

(defun server-kill-emacs-query-function ()
  "Ask before exiting Emacs if it has other live clients.
A \"live client\" is a client with at least one live buffer
associated with it.  These clients were (probably) started by
external processes that are waiting for some buffers to be
edited.  If there are any other clients, we don't want to fail
their waiting processes, so ask the user to be sure."
  (let ((this-client (frame-parameter nil 'client)))
    (or (not (seq-some (lambda (proc)
                         (unless (eq proc this-client)
                           (seq-some #'buffer-live-p
                                     (process-get proc 'buffers))))
                       server-clients))
        (yes-or-no-p "This Emacs session has other clients; exit anyway? "))))

(defun server-kill-buffer ()
  "Remove the current buffer from its clients' buffer list.
Designed to be added to `kill-buffer-hook'."
  ;; Prevent infinite recursion if user has made server-done-hook
  ;; call kill-buffer.
  (or server-kill-buffer-running
      (and server-buffer-clients
	   (let ((server-kill-buffer-running t))
	     (when server-process
	       (server-buffer-done (current-buffer) t))))))

(defun server-edit (&optional arg)
  "Switch to next server editing buffer; say \"Done\" for current buffer.
If a server buffer is current, it is marked \"done\" and optionally saved.
The buffer is also killed if it did not exist before the clients asked for it.
When all of a client's buffers are marked as \"done\", the client is notified.

Temporary files such as MH <draft> files are always saved and backed up,
no questions asked.  (The variable `make-backup-files', if nil, still
inhibits a backup; you can set it locally in a particular buffer to
prevent a backup for it.)  The variable `server-temp-file-regexp' controls
which filenames are considered temporary.

If invoked with a prefix argument, or if there is no server process running,
starts server process and that is all.  Invoked by \\[server-edit].

To abort an edit instead of saying \"Done\", use \\[server-edit-abort]."
  (interactive "P")
  (cond
   ((or arg
	(not server-process)
	(memq (process-status server-process) '(signal exit)))
    (server-mode 1))
   (server-clients (apply #'server-switch-buffer (server-done)))
   (t (message "No server editing buffers exist"))))

(defun server-edit-abort ()
  "Abort editing the current client buffer."
  (interactive)
  (if server-clients
      (mapc (lambda (proc)
              (server-send-string
               proc (concat "-error "
                            (server-quote-arg "Aborted by the user"))))
            server-clients)
    (message "This buffer has no clients")))

(defun server-switch-buffer (&optional next-buffer killed-one filepos
                                       this-frame-only)
  "Switch to another buffer, preferably one that has a client.
Arg NEXT-BUFFER is a suggestion; if it is a live buffer, use it.

KILLED-ONE is t in a recursive call if we have already killed one
temp-file server buffer.  This means we should avoid the final
\"switch to some other buffer\" since we've already effectively
done that.

FILEPOS specifies a new buffer position for NEXT-BUFFER, if we
visit NEXT-BUFFER in an existing window.  If non-nil, it should
be a cons cell (LINENUMBER . COLUMNNUMBER)."
  (if (null next-buffer)
      (progn
	(let ((rest server-clients))
	  (while (and rest (not next-buffer))
	    (let ((proc (car rest)))
	      ;; Only look at frameless clients, or those in the selected
	      ;; frame.
	      (when (or (not (process-get proc 'frame))
			(eq (process-get proc 'frame) (selected-frame)))
		(setq next-buffer (car (process-get proc 'buffers))))
	      (setq rest (cdr rest)))))
	(and next-buffer (server-switch-buffer next-buffer killed-one))
	(unless (or next-buffer killed-one (window-dedicated-p))
	  ;; (switch-to-buffer (other-buffer))
	  (message "No server buffers remain to edit")))
    (if (not (buffer-live-p next-buffer))
	;; If NEXT-BUFFER is a dead buffer, remove the server records for it
	;; and try the next surviving server buffer.
	(apply #'server-switch-buffer (server-buffer-done next-buffer))
      ;; OK, we know next-buffer is live, let's display and select it.
      (if (functionp server-window)
	  (funcall server-window next-buffer)
	(let ((win (get-buffer-window next-buffer
                                      (if this-frame-only nil 0))))
	  (if (and win (not server-window))
	      ;; The buffer is already displayed: just reuse the
	      ;; window.  If FILEPOS is non-nil, use it to replace the
	      ;; window's own value of point.
              (progn
                (select-window win)
                (set-buffer next-buffer)
		(when filepos
		  (server-goto-line-column filepos)))
	    ;; Otherwise, let's find an appropriate window.
	    (cond ((window-live-p server-window)
		   (select-window server-window))
		  ((framep server-window)
		   (unless (frame-live-p server-window)
		     (setq server-window (make-frame)))
		   (select-window (frame-selected-window server-window))))
	    (when (window-minibuffer-p)
	      (select-window (next-window nil 'nomini
                                          (if this-frame-only nil 0))))
	    ;; Move to a non-dedicated window, if we have one.
	    (when (window-dedicated-p)
	      (select-window
	       (get-window-with-predicate
		(lambda (w)
		  (and (not (window-dedicated-p w))
		       (equal (frame-terminal (window-frame w))
			      (frame-terminal))))
		'nomini 'visible (selected-window))))
	    (condition-case nil
                ;; If the client specified a new buffer position,
                ;; treat that as an explicit point-move command, and
                ;; override switch-to-buffer-preserve-window-point.
                (let ((switch-to-buffer-preserve-window-point
                       (if filepos
                           nil
                         switch-to-buffer-preserve-window-point)))
                  (switch-to-buffer next-buffer))
	      ;; After all the above, we might still have ended up with
	      ;; a minibuffer/dedicated-window (if there's no other).
	      (error (pop-to-buffer next-buffer)))))))
    (when server-raise-frame
      (select-frame-set-input-focus (window-frame)))))

;;;###autoload
(defun server-save-buffers-kill-terminal (arg)
  ;; Called from save-buffers-kill-terminal in files.el.
  "Offer to save each buffer, then kill the current client.
With ARG non-nil, silently save all file-visiting buffers, then kill.

If emacsclient was started with a list of filenames to edit, then
only these files will be asked to be saved.

When running Emacs as a daemon and with
`server-stop-automatically' (which see) set to `kill-terminal' or
`delete-frame', this function may call `save-buffers-kill-emacs'
if there are no other active clients."
  (let ((stop-automatically
         (and (daemonp)
              (memq server-stop-automatically '(kill-terminal delete-frame))))
        (proc (frame-parameter nil 'client)))
    (cond ((eq proc 'nowait)
	   ;; Nowait frames have no client buffer list.
	   (if (length> (frame-list) (if stop-automatically 2 1))
               ;; If there are any other frames, only delete this one.
               ;; When `server-stop-automatically' is set, don't count
               ;; the daemon frame.
	       (progn (save-some-buffers arg)
		      (delete-frame))
	     ;; If we're the last frame standing, kill Emacs.
	     (save-buffers-kill-emacs arg)))
	  ((processp proc)
           (if (or (not stop-automatically)
                   (length> server-clients 1)
                   (seq-some
                    (lambda (frame)
                      (when-let ((p (frame-parameter frame 'client)))
                        (not (eq proc p))))
                    (frame-list)))
               ;; If `server-stop-automatically' is not enabled, there
               ;; are any other clients, or there are frames not owned
               ;; by the current client (e.g. `nowait' frames), then
               ;; we just want to delete this client.
	       (let ((buffers (process-get proc 'buffers)))
	         (save-some-buffers
	          arg (if buffers
                          ;; Only files from emacsclient file list.
		          (lambda () (memq (current-buffer) buffers))
                        ;; No emacsclient file list: don't override
                        ;; `save-some-buffers-default-predicate' (unless
                        ;; ARG is non-nil), since we're not killing
                        ;; Emacs (unlike `save-buffers-kill-emacs').
		        (and arg t)))
	         (server-delete-client proc))
             ;; Otherwise, we want to kill Emacs.
             (save-buffers-kill-emacs arg)))
	  (t (error "Invalid client frame")))))

(defun server-stop-automatically--handle-delete-frame (_frame)
  "Handle deletion of FRAME when `server-stop-automatically' is `delete-frame'."
  (when (null (cddr (frame-list)))
    (let ((server-stop-automatically nil))
      (save-buffers-kill-emacs))))

(defun server-stop-automatically--maybe-kill-emacs ()
  "Handle closing of Emacs daemon when `server-stop-automatically' is `empty'."
  (unless (cdr (frame-list))
    (when (and
	   (not (memq t (mapcar (lambda (b)
				  (and (buffer-file-name b)
				       (buffer-modified-p b)))
				(buffer-list))))
	   (not (memq t (mapcar (lambda (p)
				  (and (memq (process-status p)
					     '(run stop open listen))
				       (process-query-on-exit-flag p)))
				(process-list)))))
      (kill-emacs))))

(defun server-apply-stop-automatically ()
  "Apply the current value of `server-stop-automatically'.
This function adds or removes the necessary helpers to manage
stopping the Emacs server automatically, depending on the whether
the server is running or not.  This function only applies when
running Emacs as a daemon."
  (when (daemonp)
    (let (empty-timer-p delete-frame-p)
      (when server-process
        (pcase server-stop-automatically
          ('empty        (setq empty-timer-p t))
          ('delete-frame (setq delete-frame-p t))))
      ;; Start or stop the timer.
      (if empty-timer-p
          (unless server-stop-automatically--timer
            (setq server-stop-automatically--timer
                  (run-with-timer
                   10 2
		   #'server-stop-automatically--maybe-kill-emacs)))
        (when server-stop-automatically--timer
          (cancel-timer server-stop-automatically--timer)
          (setq server-stop-automatically--timer nil)))
      ;; Add or remove the delete-frame hook.
      (if delete-frame-p
          (add-hook 'delete-frame-functions
		    #'server-stop-automatically--handle-delete-frame)
        (remove-hook 'delete-frame-functions
                     #'server-stop-automatically--handle-delete-frame))))
  ;; Return the current value of `server-stop-automatically'.
  server-stop-automatically)

(defcustom server-stop-automatically nil
  "If non-nil, stop the server under the requested conditions.

If this is the symbol `empty', stop the server when it has no
remaining clients, no remaining unsaved file-visiting buffers,
and no running processes with a `query-on-exit' flag.

If this is the symbol `delete-frame', ask the user when the last
frame is deleted whether each unsaved file-visiting buffer must
be saved and each running process with a `query-on-exit' flag
can be stopped, and if so, stop the server itself.

If this is the symbol `kill-terminal', ask the user when the
terminal is killed with \\[save-buffers-kill-terminal] \
whether each unsaved file-visiting
buffer must be saved and each running process with a `query-on-exit'
flag can be stopped, and if so, stop the server itself."
  :type '(choice
          (const :tag "Never" nil)
          (const :tag "When no clients, unsaved files, or processes"
                 empty)
          (const :tag "When killing last terminal" kill-terminal)
          (const :tag "When killing last terminal or frame" delete-frame))
  :set (lambda (symbol value)
         (set-default symbol value)
         (server-apply-stop-automatically))
  :version "29.1")

;;;###autoload
(defun server-stop-automatically (value)
  "Automatically stop the Emacs server as specified by VALUE.
This sets the variable `server-stop-automatically' (which see)."
  (setopt server-stop-automatically value))

(define-key ctl-x-map "#" 'server-edit)

(defun server-unload-function ()
  "Unload the Server library."
  (server-mode -1)
  (substitute-key-definition 'server-edit nil ctl-x-map)
  (save-current-buffer
    (dolist (buffer (buffer-list))
      (set-buffer buffer)
      (remove-hook 'kill-buffer-hook #'server-kill-buffer t)))
  ;; continue standard unloading
  nil)

(define-error 'server-return-invalid-read-syntax
              "Emacs server returned unreadable result of evaluation"
              'invalid-read-syntax)

(defun server-eval-at (server form)
  "Contact the Emacs server named SERVER and evaluate FORM there.
Returns the result of the evaluation.  For example:
  (server-eval-at \"server\" \\='(emacs-pid))
returns the process ID of the Emacs instance running \"server\".

This function signals `error' if it could not contact the server.

This function signals `server-return-invalid-read-syntax' if
`read' fails on the result returned by the server.
This will occur whenever the result of evaluating FORM is
something that cannot be printed readably."
  (let* ((server-dir (if server-use-tcp server-auth-dir server-socket-dir))
         (server-file (expand-file-name server server-dir))
         (coding-system-for-read 'binary)
         (coding-system-for-write 'binary)
         address port secret process)
    (unless (file-exists-p server-file)
      (error "No such server: %s" server))
    (with-temp-buffer
      (when server-use-tcp
	(let ((coding-system-for-read 'no-conversion))
	  (insert-file-contents server-file)
	  (unless (looking-at "\\([0-9.]+\\):\\([0-9]+\\)")
	    (error "Invalid auth file"))
	  (setq address (match-string 1)
		port (string-to-number (match-string 2)))
	  (forward-line 1)
	  (setq secret (buffer-substring (point) (line-end-position)))
	  (erase-buffer)))
      (unless (setq process (make-network-process
			     :name "eval-at"
			     :buffer (current-buffer)
			     :host address
			     :service (if server-use-tcp port server-file)
			     :family (if server-use-tcp 'ipv4 'local)
			     :noquery t))
	       (error "Unable to contact the server"))
      (if server-use-tcp
	  (process-send-string process (concat "-auth " secret "\n")))
      (process-send-string process
			   (concat "-eval "
				   (server-quote-arg (format "%S" form))
				   "\n"))
      (while (memq (process-status process) '(open run))
	(accept-process-output process 0.01))
      (goto-char (point-min))
      ;; If the result is nil, there's nothing in the buffer.  If the
      ;; result is non-nil, it's after "-print ".
      (let ((answer ""))
	(while (re-search-forward "\n-print\\(-nonl\\)? " nil t)
	  (setq answer
		(concat answer
			(buffer-substring (point)
					  (progn (skip-chars-forward "^\n")
						 (point))))))
	(if (not (equal answer ""))
            (condition-case err
	        (read
                 (decode-coding-string (server-unquote-arg answer)
				       'emacs-internal))
              ;; Re-signal with a more specific condition.
              (invalid-read-syntax
               (signal 'server-return-invalid-read-syntax
                       (cdr err)))))))))


(provide 'server)

;;; server.el ends here
