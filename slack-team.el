;;; slack-team.el ---  team class                    -*- lexical-binding: t; -*-

;; Copyright (C) 2016  南優也

;; Author: 南優也 <yuyaminami@minamiyuunari-no-MacBook-Pro.local>
;; Keywords:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:
(require 'eieio)
(require 'slack-util)

(defvar slack-teams nil)
(defvar slack-current-team nil)
(defcustom slack-prefer-current-team nil
  "If set to t, using `slack-current-team' for interactive function.
use `slack-change-current-team' to change `slack-current-team'"
  :group 'slack)

(defcustom slack-modeline-count-only-subscribed-channel t
  "Count unread only subscribed channel."
  :group 'slack)

(defclass slack-team-threads ()
  ((initializedp :initform nil)
   (has-more :initform t)
   (total-unread-replies :initform 0 :type number)
   (new-threads-count :initform 0 :type number)))

(defclass slack-team ()
  ((id :initarg :id)
   (token :initarg :token :initform nil)
   (client-id :initarg :client-id)
   (client-secret :initarg :client-secret)
   (name :initarg :name :initform nil)
   (domain :initarg :domain)
   (self :initarg :self)
   (self-id :initarg :self-id)
   (self-name :initarg :self-name)
   (channels :initarg :channels :initform nil)
   (groups :initarg :groups :initform nil)
   (ims :initarg :ims :initform nil)
   (file-room :initform nil)
   (search-results :initform nil)
   (users :initarg :users :initform nil)
   (bots :initarg :bots :initform nil)
   (ws-url :initarg :ws-url)
   (ws-conn :initarg :ws-conn :initform nil)
   (ping-timer :initform nil)
   (check-ping-timeout-timer :initform nil)
   (check-ping-timeout-sec :initarg :check-ping-timeout-sec
                           :initform 20)
   (reconnect-auto :initarg :reconnect-auto :initform t)
   (reconnect-timer :initform nil)
   (reconnect-after-sec :initform 10)
   (reconnect-count :initform 0)
   (reconnect-count-max :initform 360)
   (last-pong :initform nil)
   (waiting-send :initform nil)
   (sent-message :initform (make-hash-table))
   (message-id :initform 0)
   (connected :initform nil)
   (subscribed-channels :initarg :subscribed-channels
                        :type list :initform nil)
   (typing :initform nil)
   (typing-timer :initform nil)
   (reminders :initform nil :type list)
   (ping-check-timers)
   (threads :type slack-team-threads :initform (make-instance 'slack-team-threads))
   (modeline-enabled :initarg :modeline-enabled :initform nil)
   (modeline-name :initarg :modeline-name :initform nil)))

(defun slack-team-find (id)
  (cl-find-if #'(lambda (team) (string= id (oref team id)))
              slack-teams))

(defmethod slack-team-disconnect ((team slack-team))
  (slack-ws-close team))

(defmethod slack-team-equalp ((team slack-team) other)
  (with-slots (client-id) team
    (string= client-id (oref other client-id))))

(defmethod slack-team-name ((team slack-team))
  (oref team name))

;;;###autoload
(defun slack-register-team (&rest plist)
  "PLIST must contain :name :client-id :client-secret with value.
setting :token will reduce your configuration step.
you will notified when receive message with channel included in subscribed-chennels.
if :default is t and `slack-prefer-current-team' is t, skip selecting team when channels listed.
you can change current-team with `slack-change-current-team'"
  (interactive
   (let ((name (read-from-minibuffer "Team Name: "))
         (client-id (read-from-minibuffer "Client Id: "))
         (client-secret (read-from-minibuffer "Client Secret: "))
         (token (read-from-minibuffer "Token: ")))
     (list :name name :client-id client-id :client-secret client-secret
           :token token)))
  (cl-labels ((same-client-id
               (client-id)
               (cl-find-if #'(lambda (team)
                               (string= client-id (oref team client-id)))
                           slack-teams))
              (missing (plist)
                       (cl-remove-if
                        #'null
                        (mapcar #'(lambda (key)
                                    (unless (plist-member plist key)
                                      key))
                                '(:name :client-id :client-secret)))))
    (let ((missing (missing plist)))
      (if missing
          (error "Missing Keyword: %s" missing)))
    (let ((team (apply #'slack-team "team"
                       (slack-collect-slots 'slack-team plist))))
      (let ((same-team (cl-find-if
                        #'(lambda (o) (slack-team-equalp team o))
                        slack-teams)))
        (if same-team
            (progn
              (slack-team-disconnect same-team)
              (slack-start team))))

      (setq slack-teams
            (cons team
                  (cl-remove-if #'(lambda (other)
                                    (slack-team-equalp team other))
                                slack-teams)))
      (if (plist-get plist :default)
          (setq slack-current-team team)))))

(defun slack-team-find-by-name (name)
  (if name
      (cl-find-if #'(lambda (team) (string= name (oref team name)))
                  slack-teams)))

(cl-defun slack-team-select (&optional no-default include-not-connected)
  (cl-labels ((select-team ()
                           (slack-team-find-by-name
                            (funcall slack-completing-read-function
                                     "Select Team: "
                                     (mapcar #'(lambda (team) (oref team name))
                                             (if include-not-connected
                                                 slack-teams
                                               (slack-team-connected-list)))))))
    (let ((team (if (and slack-prefer-current-team
                         slack-current-team
                         (not no-default))
                    slack-current-team
                  (select-team))))
      ;; (if (and slack-prefer-current-team
      ;;          (not slack-current-team)
      ;;          (not no-default))
      ;;     (if (yes-or-no-p (format "Set %s to current-team?"
      ;;                              (oref team name)))
      ;;         (setq slack-current-team team)))
      team)))

(defmethod slack-team-connectedp ((team slack-team))
  (oref team connected))

(defun slack-team-connected-list ()
  (cl-remove-if #'null
                (mapcar #'(lambda (team)
                            (if (slack-team-connectedp team) team))
                        slack-teams)))

(defun slack-change-current-team ()
  (interactive)
  (let ((team (slack-team-find-by-name
               (funcall slack-completing-read-function
                "Select Team: "
                (mapcar #'(lambda (team) (oref team name))
                        slack-teams)))))
    (setq slack-current-team team)
    (message "Set slack-current-team to %s" (or (and team (oref team name))
                                                "nil"))
    (if team
        (slack-team-connect team))))

(defmethod slack-team-connect ((team slack-team))
  (unless (slack-team-connectedp team)
    (slack-start team)))

(defun slack-team-delete ()
  (interactive)
  (let ((selected (slack-team-select t t)))
    (if (yes-or-no-p (format "Delete %s from `slack-teams'?"
                             (oref selected name)))
        (progn
          (setq slack-teams
                (cl-remove-if #'(lambda (team)
                                  (slack-team-equalp selected team))
                              slack-teams))
          (slack-team-disconnect selected)
          (message "Delete %s from `slack-teams'" (oref selected name))))))

(defmethod slack-team-init-ping-check-timers ((team slack-team))
  (oset team ping-check-timers (make-hash-table :test 'equal)))

(defmethod slack-team-get-ping-check-timers ((team slack-team))
  (if (not (slot-boundp team 'ping-check-timers))
      (slack-team-init-ping-check-timers team))
  (oref team ping-check-timers))

(defmethod slack-team-need-token-p ((team slack-team))
  (with-slots (token) team
    (or (not token) (< (length token) 1))))

(defun slack-team-get-unread-messages (team)
  (cl-labels
      ((count-unread (rooms)
                     (cl-reduce #'(lambda (a e) (+ a (oref e unread-count-display)))
                                rooms :initial-value 0)))
    (with-slots (ims channels groups) team
      (let ((rooms (append ims channels groups)))
        (+ (count-unread (if slack-modeline-count-only-subscribed-channel
                             (cl-remove-if-not #'(lambda (e) (slack-room-subscribedp e team))
                                               rooms)
                           rooms)))))))

(defun slack-team-modeline-enabledp (team)
  (oref team modeline-enabled))

(defcustom slack-all-unreads-only-subscribed-channels nil
  "If set t, display subscribed channels unreads messages.")

(define-derived-mode slack-all-unread-mode lui-mode "Slack All Unread")

(defun slack-all-unread-create-buffer (team)
  (let ((buf-name (format "%s - All Unreads" (slack-team-name team))))
    (or (get-buffer buf-name)
        (let ((buf (generate-new-buffer buf-name)))
          (with-current-buffer buf
            (slack-all-unread-mode))
          buf))))

(defface slack-all-unread-channel-line-face
  '((t (:weight bold :height 1.5 :underline t)))
  "Face used to All Unread Header."
  :group 'slack)

(defface slack-all-unread-show-more-message-line-face
  '((t (:underline t)))
  "Face used to \"show more message\" line."
  :group 'slack)

(defun slack-all-unread-channel-line (room team)
  (let ((str (format "# %s\t\t%s messages"
                     (slack-room-name room)
                     (oref room unread-count-display))))
    (propertize str 'face 'slack-all-unread-channel-line-face)))

(defun slack-all-unread-insert-messages (room team messages)
  (let ((lui-time-stamp-position nil))
    (lui-insert (format "%s\n" (slack-all-unread-channel-line room team))))
  (let* ((max-display-count 5)
         (unread-count (oref room unread-count-display))
         (messages-display (cl-subseq messages
                                      0 (min unread-count max-display-count (length messages)))))
    (mapc #'(lambda (message) (slack-buffer-insert message team t)) messages-display)

    (when (< max-display-count unread-count)
      (let ((lui-time-stamp-position nil))
        (lui-insert "show more messages")))

    (lui-insert "\n")))

(defun slack-all-unread ()
  (interactive)
  (cl-labels
      ((unread-messages (room)
                        (slack-room-latest-messages room (slack-room-sorted-messages room)))
       (channels-display (team)
                         (let ((all (cl-remove-if #'slack-room-hiddenp
                                                  (append (oref team ims) (oref team channels) (oref team groups)))))
                           (cl-sort (if slack-all-unreads-only-subscribed-channels
                                        (cl-remove-if-not #'(lambda (e) (slack-room-subscribedp e team))
                                                          all)
                                      all)
                                    #'string>
                                    :key #'(lambda (e) (oref e last-read))))))
    (let* ((team (slack-team-select))
           (channels (channels-display team))
           (buf (slack-all-unread-create-buffer team))
           (inhibit-read-only t))
      (with-current-buffer buf
        (delete-region (point-min) (point-max))
        (goto-char (point-min))
        (mapc #'(lambda (room)
                  (let* ((unread-messages (unread-messages room))
                         (need-request (= 0 (length (oref room messages)))))
                    (when (< 0 (oref room unread-count-display))
                      (if need-request
                          (slack-room-history-request
                           room team
                           :async t
                           :after-success #'(lambda ()
                                              (slack-all-unread-insert-messages room team (unread-messages room))))
                        (slack-all-unread-insert-messages room team unread-messages)))))
              channels)
        (goto-char (point-min)))
      (funcall slack-buffer-function buf))))

(provide 'slack-team)
;;; slack-team.el ends here
