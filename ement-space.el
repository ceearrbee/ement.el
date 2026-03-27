;;; ement-space.el --- Space hierarchy browser for Ement  -*- lexical-binding: t; -*-

;; Copyright (C) 2024  Free Software Foundation, Inc.

;; Author: Adam Porter <adam@alphapapa.net>
;; Maintainer: Adam Porter <adam@alphapapa.net>

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This library provides a space hierarchy browser for Ement, allowing
;; users to browse rooms within a Matrix space, including nested spaces.

;;; Code:

;;;; Requirements

(require 'ement)
(require 'ement-lib)
(require 'ement-room-list)

(require 'taxy)
(require 'taxy-magit-section)

;;;; Variables

(defvar ement-space-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ement-space-RET)
    (define-key map [mouse-1] #'ement-space-RET)
    (define-key map (kbd "+") #'ement-space-next)
    (define-key map (kbd "s") #'ement-room-toggle-space)
    (define-key map (kbd "g") #'revert-buffer)
    map))

(defvar-local ement-space-etc nil
  "Alist storing information in `ement-space' buffers.")

;;;; Customization

(defgroup ement-space nil
  "Options for space hierarchy browsers."
  :group 'ement)

;;;; Mode

(define-derived-mode ement-space-mode magit-section-mode "Ement-Space"
  :global nil
  (setq-local revert-buffer-function #'ement-space-revert))

;;;;; Column definitions

(eval-and-compile
  (taxy-magit-section-define-column-definer "ement-space"))

(ement-space-define-column "Joined" (:align 'right :max-width 3)
  (pcase-let (((map ('room_id id)) item)
              ((map session) ement-space-etc))
    (if (cl-find id (ement-session-rooms session)
                 :key #'ement-room-id :test #'equal)
        (propertize "✓" 'face 'success)
      "")))

(ement-space-define-column "Name" (:max-width 35)
  (pcase-let* (((map name ('room_type type) ('canonical_alias alias)) item)
               (display-name (or name alias ""))
               (face (if (equal "m.space" type)
                         '(:inherit (ement-room-list-space bold))
                       'ement-room-list-name)))
    (ement-propertize display-name
      'face face
      'mouse-face 'highlight)))

(ement-space-define-column "Members" (:align 'right)
  (pcase-let (((map ('num_joined_members members)) item))
    (when members
      (number-to-string members))))

(ement-space-define-column "Topic" (:max-width 50)
  (pcase-let (((map topic) item))
    (when topic
      (replace-regexp-in-string "\n" " " (truncate-string-to-width topic 50 nil nil t)))))

(ement-space-define-column "Alias" (:max-width 30)
  (pcase-let (((map ('canonical_alias alias)) item))
    (or alias "")))

;;;; Commands

(defun ement-space-browse (space session)
  "Browse the hierarchy of SPACE on SESSION.
SPACE should be an `ement-room' struct for a space."
  (interactive (pcase-let* ((`(,room ,session)
                             (ement-complete-room :session (ement-complete-session)
                               :prompt "Browse space: "
                               :predicate #'ement--space-p)))
                 (list room session)))
  (let* ((space-name (or (ement-room-display-name space)
                         (ement--room-display-name space)))
         (buffer-name (format "*Ement Space: %s*" space-name)))
    (with-current-buffer (get-buffer-create buffer-name)
      (ement-space-mode)
      (setf ement-space-etc (ement-alist 'session session
                                         'space space
                                         'next-batch nil))
      (ement-space--fetch-hierarchy space session))
    (pop-to-buffer buffer-name)))

(defun ement-space-RET ()
  "View or join the room/space at point."
  (interactive)
  (pcase-let* ((section (magit-current-section))
               (item (oref section value))
               ((map ('room_id id) ('room_type type)) item)
               ((map session) ement-space-etc))
    (if-let ((room (cl-find id (ement-session-rooms session)
                            :key #'ement-room-id :test #'equal)))
        (if (equal "m.space" type)
            (ement-space-browse room session)
          (ement-view-room room session))
      (when (yes-or-no-p (format "Join room %s? " (or (alist-get 'name item) id)))
        (ement-room-join id session)))))

(defun ement-space-next ()
  "Fetch and display the next page of hierarchy results."
  (interactive)
  (pcase-let (((map session space next-batch) ement-space-etc))
    (if next-batch
        (ement-space--fetch-hierarchy space session next-batch)
      (message "No more results."))))

(defun ement-space-revert (&optional _ignore-auto _noconfirm)
  "Revert the space hierarchy buffer."
  (pcase-let (((map session space) ement-space-etc))
    (setf (alist-get 'next-batch ement-space-etc) nil)
    (ement-space--fetch-hierarchy space session)))

;;;; Functions

(defun ement-space--fetch-hierarchy (space session &optional from)
  "Fetch hierarchy for SPACE on SESSION.
Optional FROM is a pagination token."
  (let* ((room-id (ement-room-id space))
         (endpoint (format "rooms/%s/hierarchy" (url-hexify-string room-id)))
         (params (append (list (cons "limit" "50"))
                         (when from
                           (list (cons "from" from))))))
    (message "Fetching space hierarchy...")
    (ement-api session endpoint :params params :version "v1"
      :then (lambda (data)
              (ement-space--display-hierarchy data space session))
      :else (lambda (err)
              (message "Error fetching space hierarchy: %S" err)))))

(defun ement-space--display-hierarchy (data space session)
  "Display hierarchy DATA for SPACE on SESSION."
  (pcase-let* (((map rooms ('next_batch next-batch)) data)
               (space-name (or (ement-room-display-name space)
                               (ement--room-display-name space)))
               (buffer-name (format "*Ement Space: %s*" space-name)))
    (when (buffer-live-p (get-buffer buffer-name))
      (with-current-buffer buffer-name
        (setf (alist-get 'next-batch ement-space-etc) next-batch)
        (let* ((room-items (cl-coerce rooms 'list))
               ;; Simple flat display: show all rooms with their type.
               (taxy (make-taxy
                      :name space-name
                      :taxys (list (make-taxy :name "Spaces"
                                              :predicate (lambda (item)
                                                           (equal "m.space"
                                                                  (alist-get 'room_type item))))
                                   (make-taxy :name "Rooms"
                                              :predicate #'identity))
                      :items room-items))
               (taxy-magit-section-insert-indent-items nil)
               (format-cons (taxy-magit-section-format-items
                             ement-space-columns ement-space-column-formatters
                             ement-space-etc))
               (inhibit-read-only t))
          (setf taxy (taxy-fill room-items taxy))
          (erase-buffer)
          (setf header-line-format (format "Space: %s (%d rooms%s)"
                                           space-name
                                           (length room-items)
                                           (if next-batch " [more available, press +]" "")))
          (taxy-magit-section-insert taxy :items 'first
            :initial-depth 0 :blank-between-depth 1))
        (goto-char (point-min))
        (message "Space hierarchy loaded: %d rooms." (length (cl-coerce rooms 'list)))))))

(provide 'ement-space)

;;; ement-space.el ends here
